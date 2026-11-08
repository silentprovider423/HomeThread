import Foundation
import Observation
import SwiftUI

/// Zentraler Zustand der App: Anmeldung, lokale Datenbank, Abgleich und alle Nutzer-Aktionen.
/// Jede Aktion schreibt zuerst lokal (sofort sichtbar, auch offline) und legt eine Operation in die Warteschlange.
@Observable
final class AppModel {
    enum SyncState: Equatable { case idle, syncing, offline, error(String) }

    var session: Session?
    var store: LocalStore?
    /// Wird nach jeder Änderung hochgezählt; Ansichten lesen es, damit sie neu abfragen.
    var revision = 0
    var syncState: SyncState = .idle
    var lastSync: Date?
    var pending = 0
    var signedOutReason: String?
    var users: [UserInfo] = []
    var devices: [String: DeviceInfo] = [:]
    var appearance: Int = UserDefaults.standard.integer(forKey: "appearance") {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    /// Mac: Return legt ab (sonst ⌘↩)
    var returnSends: Bool = UserDefaults.standard.object(forKey: "returnSends") as? Bool ?? true {
        didSet { UserDefaults.standard.set(returnSends, forKey: "returnSends") }
    }

    private(set) var api: APIClient?
    private var syncTask: Task<Void, Never>?
    private var syncAgain = false
    private var timer: Timer?

    var me: String { session?.user.id ?? "" }
    var myDevice: String { session?.deviceId ?? "" }

    var statusText: String {
        switch syncState {
        case .syncing: return String(localized: "Abgleich läuft …")
        case .offline: return String(localized: "Offline – Änderungen werden später abgeglichen")
        case .error(let e): return e
        case .idle:
            if pending > 0 { return String(localized: "\(pending) Änderungen warten") }
            return String(localized: "Abgeglichen")
        }
    }

    /// Mac-Menü „Neuer Chat/Neue Gruppe“ → Seitenleiste zeigt den Dialog
    var requestNew: NewRoomFlow.Mode?
    /// Debug/Screenshots: Raum mit diesem Titel öffnen
    var debugOpen: String?
    /// Debug/Screenshots: Info-Seite des geöffneten Raums zeigen
    var debugShowInfo = false
    var debugTab: Int?

    var colorScheme: ColorScheme? { appearance == 1 ? .light : appearance == 2 ? .dark : nil }

    init() {
        if let s = Session.load() { open(s) }
    }

    // MARK: Sitzung

    static var platformName: String {
        #if os(iOS)
        return "ios"
        #else
        return "mac"
        #endif
    }

    static var defaultDeviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    func open(_ s: Session) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeThread/\(s.storageKey)", isDirectory: true)
        do {
            store = try LocalStore(root: root)
        } catch {
            signedOutReason = error.localizedDescription
            return
        }
        session = s
        api = APIClient(base: s.serverURL, token: s.token)
        pending = store?.pendingCount ?? 0
        signedOutReason = nil
        revision += 1
    }

    func login(server: String, username: String, password: String, code: String) async throws {
        let url = try APIClient.normalize(server)
        let c = APIClient(base: url)
        let r = try await c.login(username: username.trimmingCharacters(in: .whitespaces).lowercased(), password: password,
                                  code: code, deviceName: Self.defaultDeviceName, platform: Self.platformName)
        let s = Session(server: url.absoluteString, token: r.token, deviceId: r.deviceId, user: r.user)
        s.store()
        open(s)
        syncSoon()
    }

    /// Debug: Anmeldung über die Startumgebung (THREAD_SERVER + THREAD_TOKEN), nie gespeichert.
    func loginWithToken(server: String, token: String, reset: Bool) async throws {
        let url = try APIClient.normalize(server)
        let c = APIClient(base: url, token: token)
        let (u, did) = try await c.me()
        let s = Session(server: url.absoluteString, token: token, deviceId: did, user: u, ephemeral: true)
        if reset {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HomeThread/\(s.storageKey)", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
        }
        open(s)
        syncSoon()
    }

    func signOut(revoke: Bool = true, reason: String? = nil) async {
        stopTimer()
        syncTask?.cancel()
        if revoke { try? await api?.logout() }
        if let s = session, !s.ephemeral { Session.clear() }
        if let root = store?.root { try? FileManager.default.removeItem(at: root) }
        store = nil
        session = nil
        api = nil
        users = []
        devices = [:]
        signedOutReason = reason
        revision += 1
    }

    // MARK: Abgleich

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func syncSoon() {
        if syncTask != nil { syncAgain = true; return }
        syncTask = Task { await runSync() }
    }

    /// Abgleich und warten, bis er fertig ist (Ziehen zum Aktualisieren, Tests).
    func syncNow() async {
        if let t = syncTask { await t.value }
        syncTask = Task { await runSync() }
        await syncTask?.value
    }

    private func runSync() async {
        defer { syncTask = nil }
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain && !Task.isCancelled
    }

    private func syncOnce() async {
        guard let api, let store, session != nil else { return }
        syncState = .syncing
        do {
            try await push(api, store)
            try await pull(api, store)
            lastSync = .now
            syncState = .idle
            if users.isEmpty || Int.random(in: 0..<20) == 0 { await refreshUsersAndDevices() }
            await downloadMissing(api, store)
        } catch let e as APIError {
            if e.code == "unauthorized" {
                await signOut(revoke: false, reason: String(localized: "Dieses Gerät wurde abgemeldet. Bitte neu anmelden."))
                return
            }
            syncState = e.isNetwork ? .offline : .error(e.localizedDescription)
        } catch {
            syncState = .error(error.localizedDescription)
        }
        pending = store.pendingCount
        revision += 1
    }

    /// Warteschlange abarbeiten: erst Dateien hoch, dann Operationen gebündelt.
    private func push(_ api: APIClient, _ store: LocalStore) async throws {
        while true {
            let rows = store.db.query("SELECT * FROM outbox ORDER BY n LIMIT 50")
            guard let first = rows.first else { return }
            if first.s("kind") == "blob" {
                let id = first.s("body")
                if let f = store.db.one("SELECT * FROM files WHERE id=?", id), let url = store.fileURL(id) {
                    try await api.putBlob(id: id, file: url, mime: f.s("mime"), filename: f.s("name"))
                    try? store.db.run("UPDATE files SET uploaded=1 WHERE id=?", id)
                }
                try? store.db.run("DELETE FROM outbox WHERE n=?", first.int("n"))
                pending = store.pendingCount
                continue
            }
            // zusammenhängende Operationen bis zur nächsten Datei
            var batch: [Row] = []
            for r in rows { if r.s("kind") == "op" { batch.append(r) } else { break } }
            let ops = batch.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.s("body").utf8))) as? [String: Any] }
            let results = try await api.ops(ops)
            var byID: [String: [String: Any]] = [:]
            for r in results { if let id = r["op_id"] as? String { byID[id] = r } }
            var retryLater = false
            for (row, op) in zip(batch, ops) {
                let res = byID[row.s("op_id")] ?? [:]
                let ok = res["ok"] as? Bool ?? false
                let code = res["error"] as? String ?? ""
                if !ok && code == "blob_missing" {
                    retryLater = true
                    try? store.db.run("UPDATE outbox SET attempts=attempts+1, last_error=? WHERE n=?", code, row.int("n"))
                    break
                }
                if !ok && code != "exists" { markFailed(op, code: code, store) }
                try? store.db.run("DELETE FROM outbox WHERE n=?", row.int("n"))
            }
            pending = store.pendingCount
            if retryLater { return }
        }
    }

    private func markFailed(_ op: [String: Any], code: String, _ store: LocalStore) {
        if op["type"] as? String == "msg.create", let m = op["msg"] as? [String: Any], let id = m["id"] as? String {
            try? store.db.run("UPDATE messages SET failed=?, pending=0 WHERE id=?", code, id)
        }
    }

    private func pull(_ api: APIClient, _ store: LocalStore) async throws {
        var backfill: Set<String> = []
        while true {
            let page = try await api.sync(since: store.cursor, limit: 500)
            try store.db.transaction {
                for c in page.changes {
                    if let k = c["kind"] as? String, let d = c["data"] as? [String: Any],
                       let rid = store.apply(kind: k, d: d, me: me) { backfill.insert(rid) }
                }
                store.cursor = page.next
            }
            if !page.changes.isEmpty { revision += 1 }
            if !page.more { break }
        }
        // Neu hinzugekommene Räume vollständig nachladen (z. B. wenn jemand mich in eine Gruppe aufnimmt)
        for rid in backfill {
            var since = 0
            while true {
                let page = try await api.sync(since: since, limit: 500, room: rid)
                try store.db.transaction {
                    for c in page.changes {
                        if let k = c["kind"] as? String, let d = c["data"] as? [String: Any] { _ = store.apply(kind: k, d: d, me: me) }
                    }
                }
                since = page.next
                if !page.more { break }
            }
            store.set("backfilled:\(rid)", "1")
        }
    }

    private func downloadMissing(_ api: APIClient, _ store: LocalStore) async {
        for f in store.missingDownloads() {
            let dest = store.plannedFileURL(f.id, name: f.name)
            do {
                try await api.getBlob(id: f.id, to: dest)
                store.registerDownloaded(id: f.id, name: f.name, mime: f.mime)
                revision += 1
            } catch let e as APIError where e.status == 404 {
                continue
            } catch {
                return
            }
        }
    }

    /// Großen Anhang bei Bedarf laden (Video, Datei, Originalfoto).
    func ensureFile(id: String, name: String, mime: String) async -> URL? {
        guard let store, let api else { return nil }
        if let u = store.fileURL(id) { return u }
        let dest = store.plannedFileURL(id, name: name)
        do {
            try await api.getBlob(id: id, to: dest)
            store.registerDownloaded(id: id, name: name, mime: mime)
            revision += 1
            return store.fileURL(id)
        } catch {
            return nil
        }
    }

    func refreshUsersAndDevices() async {
        guard let api else { return }
        if let u = try? await api.users() { users = u }
        if let d = try? await api.devices() { devices = Dictionary(uniqueKeysWithValues: d.map { ($0.id, $0) }) }
    }

    // MARK: Hilfen für Aktionen

    private func changed() {
        pending = store?.pendingCount ?? 0
        revision += 1
        syncSoon()
    }

    private func op(_ type: String, _ fields: [String: Any]) {
        var o = fields
        o["type"] = type
        store?.enqueue(op: o)
    }

    func user(_ id: String) -> UserInfo? {
        if id == me { return session?.user }
        return users.first { $0.id == id }
    }

    // MARK: Räume

    @discardableResult
    func createRoom(kind: RoomKind, title: String, avatarImage: Data? = nil, members: [UserInfo] = []) -> String? {
        guard let store, let s = session else { return nil }
        let id = newID()
        var avatar: String?
        if let avatarImage, let prepared = Media.cgImage(data: avatarImage, maxPixel: 512).flatMap({ Media.jpeg($0) }) {
            avatar = saveData(prepared, name: "avatar.jpg", mime: "image/jpeg")
        }
        let now = Date()
        try? store.db.run("INSERT INTO rooms(id, kind, title, avatar, about, created_by, created_at, updated_at, pending) VALUES(?,?,?,?,?,?,?,?,1)",
                          id, kind.rawValue, title, avatar, "", me, now, now)
        try? store.db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color) VALUES(?,?,?,?,?,?)",
                          id, me, "owner", s.user.displayName, s.user.username, s.user.color)
        for u in members where u.id != me {
            try? store.db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color) VALUES(?,?,?,?,?,?)",
                              id, u.id, "member", u.displayName, u.username, u.color)
        }
        var room: [String: Any] = ["id": id, "kind": kind.rawValue, "title": title, "created_at": now.timeIntervalSince1970,
                                   "members": members.map(\.id)]
        if let avatar { room["avatar"] = avatar }
        op("room.create", ["room": room])
        changed()
        return id
    }

    func renameRoom(_ id: String, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? store?.db.run("UPDATE rooms SET title=? WHERE id=?", t, id)
        op("room.update", ["room_id": id, "title": t])
        changed()
    }

    func setRoomAbout(_ id: String, about: String) {
        try? store?.db.run("UPDATE rooms SET about=? WHERE id=?", about, id)
        op("room.update", ["room_id": id, "about": about])
        changed()
    }

    func setRoomKind(_ id: String, kind: RoomKind) {
        try? store?.db.run("UPDATE rooms SET kind=? WHERE id=?", kind.rawValue, id)
        op("room.update", ["room_id": id, "kind": kind.rawValue])
        changed()
    }

    func setRoomAvatar(_ id: String, image: Data?) {
        var avatar: String?
        if let image, let prepared = Media.cgImage(data: image, maxPixel: 512).flatMap({ Media.jpeg($0) }) {
            avatar = saveData(prepared, name: "avatar.jpg", mime: "image/jpeg")
        }
        try? store?.db.run("UPDATE rooms SET avatar=? WHERE id=?", avatar, id)
        op("room.update", ["room_id": id, "avatar": avatar.map { $0 as Any } ?? NSNull()])
        changed()
    }

    func deleteRoom(_ id: String) {
        store?.purgeRoom(id)
        try? store?.db.run("UPDATE rooms SET deleted=1 WHERE id=?", id)
        op("room.delete", ["room_id": id])
        changed()
    }

    func clearRoom(_ id: String) {
        guard let store else { return }
        for r in store.db.query("SELECT attachment, thumb FROM messages WHERE room_id=?", id) {
            store.removeFile(r.str("attachment")); store.removeFile(r.str("thumb"))
        }
        try? store.db.run("UPDATE messages SET deleted=1 WHERE room_id=?", id)
        op("room.clear", ["room_id": id])
        changed()
    }

    func setRoomState(_ id: String, pinned: Bool? = nil, archived: Bool? = nil, muted: Bool? = nil) {
        guard let store else { return }
        let cur = store.db.one("SELECT * FROM roomstate WHERE room_id=?", id)
        let p = pinned ?? cur?.bool("pinned") ?? false
        let a = archived ?? cur?.bool("archived") ?? false
        let m = muted ?? cur?.bool("muted") ?? false
        try? store.db.run("INSERT OR REPLACE INTO roomstate(room_id, pinned, archived, muted) VALUES(?,?,?,?)", id, p, a, m)
        var f: [String: Any] = ["room_id": id]
        if let pinned { f["pinned"] = pinned }
        if let archived { f["archived"] = archived }
        if let muted { f["muted"] = muted }
        op("roomstate.set", f)
        changed()
    }

    func addMember(_ room: String, user: UserInfo) {
        try? store?.db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color) VALUES(?,?,?,?,?,?)",
                           room, user.id, "member", user.displayName, user.username, user.color)
        op("member.add", ["room_id": room, "user_id": user.id])
        changed()
    }

    func removeMember(_ room: String, userId: String) {
        try? store?.db.run("UPDATE members SET removed=1 WHERE room_id=? AND user_id=?", room, userId)
        op("member.remove", ["room_id": room, "user_id": userId])
        changed()
    }

    /// „Als neu markieren“ (wie „ungelesen“) bzw. Raum als gesehen markieren.
    func markSeen(_ room: String) {
        guard let store else { return }
        let seq = store.maxSeq(room: room)
        if store.get("read:\(room)") != String(seq) || store.get("unreadmark:\(room)") != nil {
            store.set("read:\(room)", String(seq))
            store.set("unreadmark:\(room)", nil)
            revision += 1
        }
    }

    func markNew(_ room: String) {
        store?.set("unreadmark:\(room)", "1")
        revision += 1
    }

    func saveDraft(_ room: String, _ text: String) {
        store?.set("draft:\(room)", text.isEmpty ? nil : text)
    }

    // MARK: Einträge

    private func saveData(_ data: Data, name: String, mime: String) -> String? {
        guard let store else { return nil }
        let id = newID()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(id)")
        do {
            try data.write(to: tmp)
            try store.importFile(tmp, id: id, name: name, mime: mime, move: true)
            store.enqueueUpload(id: id)
            return id
        } catch {
            return nil
        }
    }

    private func saveFile(_ url: URL, name: String, mime: String, move: Bool) -> String? {
        guard let store else { return nil }
        let id = newID()
        do {
            try store.importFile(url, id: id, name: name, mime: mime, move: move)
            store.enqueueUpload(id: id)
            return id
        } catch {
            return nil
        }
    }

    @discardableResult
    private func addMessage(room: String, kind: MessageKind, body: String = "", payload: Payload = Payload(), replyTo: String? = nil,
                            attachment: String? = nil, thumb: String? = nil, items: [String] = []) -> String? {
        guard let store else { return nil }
        let id = newID()
        let now = Date()
        try? store.db.run("""
            INSERT INTO messages(id, room_id, author_id, device_id, kind, body, payload, reply_to, attachment, thumb, created_at, pending)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,1)
            """, id, room, me, myDevice, kind.rawValue, body, payload.json, replyTo, attachment, thumb, now)
        var itemOps: [[String: Any]] = []
        for (i, t) in items.enumerated() {
            let iid = newID()
            try? store.db.run("INSERT INTO items(id, message_id, room_id, text, done, position) VALUES(?,?,?,?,0,?)", iid, id, room, t, Double(i))
            itemOps.append(["id": iid, "text": t, "position": i])
        }
        store.reindex(id)
        var m: [String: Any] = ["id": id, "room_id": room, "kind": kind.rawValue, "body": body, "payload": payload.dict,
                                "created_at": now.timeIntervalSince1970, "items": itemOps]
        if let replyTo { m["reply_to"] = replyTo }
        if let attachment { m["attachment"] = attachment }
        if let thumb { m["thumb"] = thumb }
        op("msg.create", ["msg": m])
        store.set("read:\(room)", String(store.maxSeq(room: room)))
        changed()
        return id
    }

    func sendText(room: String, _ text: String, replyTo: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        addMessage(room: room, kind: .text, body: t, replyTo: replyTo)
        saveDraft(room, "")
    }

    func sendImage(room: String, data: Data, caption: String = "", replyTo: String? = nil) {
        guard let p = Media.prepareImage(data),
              let full = saveData(p.full, name: "foto-\(Date().formatted(.iso8601.year().month().day())).jpg", mime: "image/jpeg"),
              let thumb = saveData(p.thumb, name: "thumb.jpg", mime: "image/jpeg") else { return }
        var pl = Payload()
        pl.w = p.w; pl.h = p.h; pl.mime = "image/jpeg"; pl.size = p.full.count; pl.filename = "foto.jpg"
        addMessage(room: room, kind: .image, body: caption, payload: pl, replyTo: replyTo, attachment: full, thumb: thumb)
    }

    func sendVideo(room: String, url: URL, replyTo: String? = nil) async {
        let info = await Media.videoInfo(url)
        let name = url.lastPathComponent
        guard let att = saveFile(url, name: name, mime: Media.mime(for: url), move: false) else { return }
        let thumb = info.thumb.flatMap { saveData($0, name: "thumb.jpg", mime: "image/jpeg") }
        var pl = Payload()
        pl.w = info.w; pl.h = info.h; pl.duration = info.duration; pl.filename = name; pl.mime = Media.mime(for: url)
        pl.size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        addMessage(room: room, kind: .video, payload: pl, replyTo: replyTo, attachment: att, thumb: thumb)
    }

    func sendFile(room: String, url: URL, replyTo: String? = nil) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let mime = Media.mime(for: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if mime.hasPrefix("image/"), let d = try? Data(contentsOf: url), size < 40_000_000 {
            sendImage(room: room, data: d, replyTo: replyTo)
            return
        }
        guard let att = saveFile(url, name: name, mime: mime, move: false) else { return }
        var pl = Payload()
        pl.filename = name; pl.mime = mime; pl.size = size
        addMessage(room: room, kind: .file, payload: pl, replyTo: replyTo, attachment: att)
    }

    func sendVoice(room: String, url: URL, duration: Double, wave: [Double], replyTo: String? = nil) {
        guard let att = saveFile(url, name: "sprachnotiz.m4a", mime: "audio/mp4", move: true) else { return }
        var pl = Payload()
        pl.duration = duration; pl.wave = wave; pl.mime = "audio/mp4"; pl.filename = "sprachnotiz.m4a"
        addMessage(room: room, kind: .voice, payload: pl, replyTo: replyTo, attachment: att)
    }

    func sendLocation(room: String, lat: Double, lon: Double, name: String) {
        var pl = Payload()
        pl.lat = (lat * 1_000_000).rounded() / 1_000_000
        pl.lon = (lon * 1_000_000).rounded() / 1_000_000
        pl.name = name
        addMessage(room: room, kind: .location, payload: pl)
    }

    func sendPoll(room: String, question: String, options: [String], multi: Bool, showInterim: Bool) {
        var pl = Payload()
        pl.question = question
        pl.options = options.enumerated().map { PollOption(id: "o\($0.offset + 1)", text: $0.element) }
        pl.multi = multi; pl.showInterim = showInterim; pl.closed = false
        addMessage(room: room, kind: .poll, payload: pl)
    }

    func sendChecklist(room: String, title: String, items: [String]) {
        addMessage(room: room, kind: .checklist, body: title, items: items)
    }

    func editText(_ m: Message, body: String) {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? store?.db.run("UPDATE messages SET body=?, edited_at=? WHERE id=?", t, Date(), m.id)
        store?.reindex(m.id)
        op("msg.edit", ["id": m.id, "body": t])
        changed()
    }

    func deleteMessage(_ m: Message) {
        store?.removeFile(m.attachment)
        store?.removeFile(m.thumb)
        try? store?.db.run("UPDATE messages SET deleted=1 WHERE id=?", m.id)
        store?.reindex(m.id)
        if m.failed != nil {
            changed()
            return
        }
        op("msg.delete", ["id": m.id])
        changed()
    }

    /// Fehlgeschlagenen Eintrag erneut versuchen: als neue Operation mit gleichem Inhalt.
    func retry(_ m: Message) {
        guard let store else { return }
        try? store.db.run("UPDATE messages SET failed=NULL, pending=1 WHERE id=?", m.id)
        var msg: [String: Any] = ["id": m.id, "room_id": m.roomId, "kind": m.kind.rawValue, "body": m.body, "payload": m.payload.dict,
                                  "created_at": m.createdAt.timeIntervalSince1970,
                                  "items": store.items(message: m.id).map { ["id": $0.id, "text": $0.text, "position": $0.position] }]
        if let r = m.replyTo { msg["reply_to"] = r }
        if let a = m.attachment { msg["attachment"] = a }
        if let t = m.thumb { msg["thumb"] = t }
        op("msg.create", ["msg": msg])
        changed()
    }

    func togglePin(_ m: Message) {
        try? store?.db.run("UPDATE messages SET pinned=? WHERE id=?", !m.pinned, m.id)
        op("msg.pin", ["id": m.id, "pinned": !m.pinned])
        changed()
    }

    func toggleReaction(_ m: Message, emoji: String) {
        guard let store else { return }
        let on = !(store.db.one("SELECT active FROM reactions WHERE message_id=? AND user_id=? AND emoji=?", m.id, me, emoji)?.bool("active") ?? false)
        try? store.db.run("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, active, room_id) VALUES(?,?,?,?,?)", m.id, me, emoji, on, m.roomId)
        op("reaction.set", ["message_id": m.id, "emoji": emoji, "on": on])
        changed()
    }

    func toggleStar(_ m: Message) {
        guard let store else { return }
        let on = !(store.db.one("SELECT active FROM stars WHERE message_id=?", m.id)?.bool("active") ?? false)
        try? store.db.run("INSERT OR REPLACE INTO stars(message_id, active, room_id) VALUES(?,?,?)", m.id, on, m.roomId)
        op("star.set", ["message_id": m.id, "on": on])
        changed()
    }

    func vote(_ m: Message, choices: [String]) {
        guard let store else { return }
        let ch = String(data: (try? JSONSerialization.data(withJSONObject: choices)) ?? Data(), encoding: .utf8) ?? "[]"
        try? store.db.run("INSERT OR REPLACE INTO votes(message_id, user_id, choices) VALUES(?,?,?)", m.id, me, ch)
        op("vote.set", ["message_id": m.id, "choices": choices])
        changed()
    }

    func closePoll(_ m: Message) {
        var p = m.payload
        p.closed = true
        try? store?.db.run("UPDATE messages SET payload=? WHERE id=?", p.json, m.id)
        op("poll.close", ["message_id": m.id])
        changed()
    }

    func addItem(_ m: Message, text: String) {
        guard let store else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let iid = newID()
        let pos = (store.items(message: m.id).map(\.position).max() ?? -1) + 1
        try? store.db.run("INSERT INTO items(id, message_id, room_id, text, done, position) VALUES(?,?,?,?,0,?)", iid, m.id, m.roomId, t, pos)
        store.reindex(m.id)
        op("item.add", ["id": iid, "message_id": m.id, "text": t, "position": pos])
        changed()
    }

    func toggleItem(_ i: ChecklistItem) {
        try? store?.db.run("UPDATE items SET done=? WHERE id=?", !i.done, i.id)
        op("item.update", ["id": i.id, "done": !i.done])
        changed()
    }

    func deleteItem(_ i: ChecklistItem) {
        try? store?.db.run("UPDATE items SET deleted=1 WHERE id=?", i.id)
        store?.reindex(i.messageId)
        op("item.update", ["id": i.id, "deleted": true])
        changed()
    }

    // MARK: Konto

    func changePassword(current: String, new: String, code: String) async throws {
        try await api?.changePassword(current: current, new: new, code: code)
    }

    func revoke(_ d: DeviceInfo) async {
        try? await api?.revokeDevice(d.id)
        await refreshUsersAndDevices()
    }

    func rename(_ d: DeviceInfo, to name: String) async {
        try? await api?.renameDevice(d.id, name: name)
        await refreshUsersAndDevices()
    }

    /// Ganzen Chat als Textdatei (für „Chat als Datei sichern“).
    func exportText(room: String) -> URL? {
        guard let store, let r = store.room(room) else { return nil }
        var lines = ["# \(r.title)", ""]
        for m in store.messages(room: room, limit: 100_000) {
            var t = "\(m.createdAt.formatted(date: .numeric, time: .shortened))  \(m.preview)"
            if m.kind == .checklist {
                t += "\n" + store.items(message: m.id).map { "   [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
            }
            if m.kind == .location, let lat = m.payload.lat, let lon = m.payload.lon { t += " (\(lat), \(lon))" }
            lines.append(t)
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(LocalStore.safeName(r.title) + ".txt")
        try? lines.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
        return u
    }
}
