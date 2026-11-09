import Foundation

/// Lokale Datenbank eines Kontos: alles liegt auf dem Gerät (offline-first), der Server ist die gemeinsame Wahrheit.
/// Änderungen des Nutzers werden sofort hier eingetragen (`pending`) und als Operation in die Warteschlange gelegt.
nonisolated final class LocalStore {
    let db: SQLiteDB
    let root: URL
    private(set) var ftsAvailable = true

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        db = try SQLiteDB(path: root.appendingPathComponent("homethread.sqlite").path)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS rooms(id TEXT PRIMARY KEY, kind TEXT, title TEXT, avatar TEXT, about TEXT, created_by TEXT,
          created_at REAL, updated_at REAL, deleted INTEGER DEFAULT 0, pending INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS members(room_id TEXT, user_id TEXT, role TEXT, display_name TEXT, username TEXT, color INTEGER,
          removed INTEGER DEFAULT 0, PRIMARY KEY(room_id, user_id));
        CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, room_id TEXT, author_id TEXT, device_id TEXT, kind TEXT, body TEXT,
          payload TEXT, reply_to TEXT, attachment TEXT, thumb TEXT, created_at REAL, edited_at REAL, pinned INTEGER DEFAULT 0,
          deleted INTEGER DEFAULT 0, seq INTEGER DEFAULT 0, pending INTEGER DEFAULT 0, failed TEXT);
        CREATE INDEX IF NOT EXISTS m_room ON messages(room_id, created_at);
        CREATE INDEX IF NOT EXISTS m_room_seq ON messages(room_id, seq);
        CREATE TABLE IF NOT EXISTS reactions(message_id TEXT, user_id TEXT, emoji TEXT, active INTEGER, room_id TEXT,
          PRIMARY KEY(message_id, user_id, emoji));
        CREATE TABLE IF NOT EXISTS stars(message_id TEXT PRIMARY KEY, active INTEGER, room_id TEXT);
        CREATE TABLE IF NOT EXISTS votes(message_id TEXT, user_id TEXT, choices TEXT, PRIMARY KEY(message_id, user_id));
        CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, message_id TEXT, room_id TEXT, text TEXT, done INTEGER DEFAULT 0,
          position REAL, deleted INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS roomstate(room_id TEXT PRIMARY KEY, pinned INTEGER DEFAULT 0, archived INTEGER DEFAULT 0,
          muted INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS outbox(n INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT, kind TEXT, body TEXT,
          attempts INTEGER DEFAULT 0, last_error TEXT);
        CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY, name TEXT, mime TEXT, size INTEGER, uploaded INTEGER DEFAULT 0);
        CREATE INDEX IF NOT EXISTS i_room ON items(room_id);
        CREATE INDEX IF NOT EXISTS r_room ON reactions(room_id);
        """)
        do {
            try db.exec("CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(id UNINDEXED, room_id UNINDEXED, body, tokenize='unicode61 remove_diacritics 2')")
        } catch {
            ftsAvailable = false
        }
    }

    // MARK: Schlüssel/Wert

    func get(_ k: String) -> String? { db.one("SELECT v FROM kv WHERE k=?", k)?.str("v") }
    func set(_ k: String, _ v: String?) {
        if let v { try? db.run("INSERT OR REPLACE INTO kv(k, v) VALUES(?,?)", k, v) } else { try? db.run("DELETE FROM kv WHERE k=?", k) }
    }

    var cursor: Int {
        get { Int(get("cursor") ?? "0") ?? 0 }
        set { set("cursor", String(newValue)) }
    }

    // MARK: Dateien

    func fileURL(_ id: String) -> URL? {
        guard let r = db.one("SELECT name FROM files WHERE id=?", id) else { return nil }
        let u = root.appendingPathComponent("files/\(id)/\(r.s("name"))")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func plannedFileURL(_ id: String, name: String) -> URL {
        root.appendingPathComponent("files/\(id)/\(Self.safeName(name))")
    }

    static func safeName(_ n: String) -> String {
        let s = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return s.isEmpty ? "datei" : String(s.prefix(120))
    }

    /// Datei ins Konto übernehmen (kopiert/verschiebt nach files/<id>/<name>).
    @discardableResult
    func importFile(_ src: URL, id: String, name: String, mime: String, move: Bool = false, uploaded: Bool = false) throws -> URL {
        let dest = plannedFileURL(id, name: name)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        if move { try FileManager.default.moveItem(at: src, to: dest) } else { try FileManager.default.copyItem(at: src, to: dest) }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        try db.run("INSERT OR REPLACE INTO files(id, name, mime, size, uploaded) VALUES(?,?,?,?,?)",
                   id, Self.safeName(name), mime, size, uploaded)
        return dest
    }

    func registerDownloaded(id: String, name: String, mime: String) {
        try? db.run("INSERT OR REPLACE INTO files(id, name, mime, size, uploaded) VALUES(?,?,?,0,1)", id, Self.safeName(name), mime)
    }

    func removeFile(_ id: String?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: root.appendingPathComponent("files/\(id)"))
        try? db.run("DELETE FROM files WHERE id=?", id)
    }

    /// Größe aller heruntergeladenen Dateien (nur fertig hochgeladene dürfen gelöscht werden).
    func cacheSize() -> Int {
        let dir = root.appendingPathComponent("files")
        var total = 0
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        return total
    }

    func clearDownloadedFiles() {
        for r in db.query("SELECT id FROM files WHERE uploaded=1") { removeFile(r.s("id")) }
    }

    // MARK: Lesen

    func room(_ id: String) -> Room? {
        guard let r = db.one("""
            SELECT r.*, COALESCE(s.pinned,0) AS rs_pinned, COALESCE(s.archived,0) AS rs_archived, COALESCE(s.muted,0) AS rs_muted,
              (SELECT COUNT(*) FROM members m WHERE m.room_id=r.id AND m.removed=0) AS mcount
            FROM rooms r LEFT JOIN roomstate s ON s.room_id=r.id WHERE r.id=? AND r.deleted=0
            """, id) else { return nil }
        return Self.room(r)
    }

    static func room(_ r: Row) -> Room {
        Room(id: r.s("id"), kind: RoomKind(rawValue: r.s("kind")) ?? .chat, title: r.s("title"), avatar: r.str("avatar"),
             about: r.s("about"), createdBy: r.s("created_by"), createdAt: r.date("created_at"), updatedAt: r.date("updated_at"),
             pinned: r.bool("rs_pinned"), archived: r.bool("rs_archived"), muted: r.bool("rs_muted"), memberCount: max(1, r.int("mcount")))
    }

    static func message(_ r: Row) -> Message {
        Message(id: r.s("id"), roomId: r.s("room_id"), authorId: r.s("author_id"), deviceId: r.str("device_id"),
                kind: MessageKind(rawValue: r.s("kind")) ?? .text, body: r.s("body"), payload: Payload.decode(r.str("payload") ?? "{}"),
                replyTo: r.str("reply_to"), attachment: r.str("attachment"), thumb: r.str("thumb"), createdAt: r.date("created_at"),
                editedAt: r.v["edited_at"] == nil ? nil : r.date("edited_at"), pinned: r.bool("pinned"), deleted: r.bool("deleted"),
                seq: r.int("seq"), pending: r.bool("pending"), failed: r.str("failed"))
    }

    func summaries(myDevice: String, archived: Bool) -> [RoomSummary] {
        // Zwei Abfragen für alle Räume statt zwei je Raum (518 Räume = 1.036 Abfragen bei jedem Neuaufbau)
        let rows = db.query("""
            SELECT r.*, COALESCE(s.pinned,0) AS rs_pinned, COALESCE(s.archived,0) AS rs_archived, COALESCE(s.muted,0) AS rs_muted,
              (SELECT COUNT(*) FROM members m WHERE m.room_id=r.id AND m.removed=0) AS mcount,
              (SELECT rowid FROM messages WHERE room_id=r.id AND deleted=0 ORDER BY created_at DESC LIMIT 1) AS last_rowid,
              (SELECT COUNT(*) FROM messages WHERE room_id=r.id
                 AND seq>COALESCE((SELECT CAST(v AS INTEGER) FROM kv WHERE k='read:'||r.id),0)
                 AND deleted=0 AND COALESCE(device_id,'')<>? AND pending=0) AS unread
            FROM rooms r LEFT JOIN roomstate s ON s.room_id=r.id
            WHERE r.deleted=0 AND COALESCE(s.archived,0)=?
            """, myDevice, archived)
        var kv: [String: String] = [:]
        for r in db.query("SELECT k, v FROM kv WHERE k LIKE 'unreadmark:%' OR k LIKE 'draft:%'") { kv[r.s("k")] = r.s("v") }
        var last: [Int: Message] = [:]
        let rowids = rows.map { $0.int("last_rowid") }.filter { $0 > 0 }
        for chunk in stride(from: 0, to: rowids.count, by: 500) {
            let part = Array(rowids[chunk..<min(chunk + 500, rowids.count)])
            let q = "SELECT rowid AS _rid, * FROM messages WHERE rowid IN (" + part.map { _ in "?" }.joined(separator: ",") + ")"
            for r in db.queryArgs(q, part) { last[r.int("_rid")] = Self.message(r) }
        }
        return rows.map { r in
            let room = Self.room(r)
            let unread = r.int("unread")
            return RoomSummary(room: room, last: last[r.int("last_rowid")], unread: kv["unreadmark:\(room.id)"] == "1" ? max(unread, 1) : unread,
                               draft: kv["draft:\(room.id)"])
        }
        .sorted { a, b in
            if a.room.pinned != b.room.pinned { return a.room.pinned }
            return a.sortDate > b.sortDate
        }
    }

    func archivedCount() -> Int {
        db.one("SELECT COUNT(*) AS n FROM rooms r JOIN roomstate s ON s.room_id=r.id WHERE r.deleted=0 AND s.archived=1")?.int("n") ?? 0
    }

    func messages(room: String, limit: Int) -> [Message] {
        db.query("SELECT * FROM (SELECT * FROM messages WHERE room_id=? AND deleted=0 ORDER BY created_at DESC LIMIT ?) ORDER BY created_at",
                 room, limit).map(Self.message)
    }

    func messageCount(room: String) -> Int {
        db.one("SELECT COUNT(*) AS n FROM messages WHERE room_id=? AND deleted=0", room)?.int("n") ?? 0
    }

    func message(_ id: String) -> Message? {
        db.one("SELECT * FROM messages WHERE id=?", id).map(Self.message)
    }

    /// Alle Räume als gesehen markieren (nach dem ersten Abgleich eines Geräts)
    func markAllSeen() {
        for r in db.query("SELECT room_id, MAX(seq) AS s FROM messages GROUP BY room_id") {
            set("read:\(r.s("room_id"))", String(r.int("s")))
        }
    }

    func maxSeq(room: String) -> Int {
        db.one("SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE room_id=?", room)?.int("s") ?? 0
    }

    func members(room: String) -> [Member] {
        db.query("SELECT * FROM members WHERE room_id=? AND removed=0 ORDER BY role='owner' DESC, display_name", room).map {
            Member(roomId: $0.s("room_id"), userId: $0.s("user_id"), role: $0.s("role"), displayName: $0.s("display_name"),
                   username: $0.s("username"), color: $0.int("color"))
        }
    }

    func reactions(room: String, me: String) -> [String: [ReactionCount]] {
        var out: [String: [ReactionCount]] = [:]
        for r in db.query("""
            SELECT message_id, emoji, COUNT(*) AS n, MAX(user_id=?) AS mine, MIN(rowid) AS first FROM reactions
            WHERE room_id=? AND active=1 GROUP BY message_id, emoji ORDER BY first
            """, me, room) {
            out[r.s("message_id"), default: []].append(ReactionCount(emoji: r.s("emoji"), count: r.int("n"), mine: r.bool("mine")))
        }
        return out
    }

    func starredIDs(room: String? = nil) -> Set<String> {
        let rows = room == nil ? db.query("SELECT message_id FROM stars WHERE active=1")
            : db.query("SELECT message_id FROM stars WHERE active=1 AND room_id=?", room)
        return Set(rows.map { $0.s("message_id") })
    }

    func starredMessages() -> [Message] {
        db.query("""
            SELECT m.* FROM messages m JOIN stars s ON s.message_id=m.id JOIN rooms r ON r.id=m.room_id
            WHERE s.active=1 AND m.deleted=0 AND r.deleted=0 ORDER BY m.created_at DESC
            """).map(Self.message)
    }

    func votes(message: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for r in db.query("SELECT user_id, choices FROM votes WHERE message_id=?", message) {
            let ch = (try? JSONSerialization.jsonObject(with: Data(r.s("choices").utf8))) as? [String] ?? []
            out[r.s("user_id")] = ch
        }
        return out
    }

    func items(message: String) -> [ChecklistItem] {
        db.query("SELECT * FROM items WHERE message_id=? AND deleted=0 ORDER BY position, rowid", message).map {
            ChecklistItem(id: $0.s("id"), messageId: $0.s("message_id"), text: $0.s("text"), done: $0.bool("done"), position: $0.dbl("position"))
        }
    }

    func messages(room: String, kinds: [MessageKind]) -> [Message] {
        let list = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        return db.query("SELECT * FROM messages WHERE room_id=? AND deleted=0 AND kind IN (\(list)) ORDER BY created_at DESC", room)
            .map(Self.message)
    }

    enum SearchScope: String, CaseIterable, Identifiable {
        case all, text, media, places, polls, checklists, starred
        var id: String { rawValue }
    }

    /// Volltextsuche über alle (oder einen) Räume; Groß/klein und Akzente egal, Wortanfang reicht.
    func search(_ q: String, room: String? = nil, scope: SearchScope = .all) -> [Message] {
        let terms = q.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init).filter { !$0.isEmpty }
        var kinds: [MessageKind]?
        switch scope {
        case .text: kinds = [.text]
        case .media: kinds = [.image, .video, .voice, .file]
        case .places: kinds = [.location]
        case .polls: kinds = [.poll]
        case .checklists: kinds = [.checklist]
        default: break
        }
        var sql = "SELECT m.* FROM messages m JOIN rooms r ON r.id=m.room_id WHERE m.deleted=0 AND r.deleted=0"
        var args: [Any?] = []
        if !terms.isEmpty {
            if ftsAvailable {
                let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
                sql += " AND m.id IN (SELECT id FROM fts WHERE fts MATCH ?)"
                args.append(match)
            } else {
                for t in terms {
                    sql += " AND m.body LIKE ?"
                    args.append("%\(t)%")
                }
            }
        } else if scope == .all || scope == .text {
            return []
        }
        if let room { sql += " AND m.room_id=?"; args.append(room) }
        if let kinds { sql += " AND m.kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")))" }
        if scope == .starred { sql += " AND m.id IN (SELECT message_id FROM stars WHERE active=1)" }
        sql += " ORDER BY m.created_at DESC LIMIT 300"
        return db.queryArgs(sql, args).map(Self.message)
    }

    /// Text, der für die Suche zählt (auch Antworten, Checklisten-Punkte, Dateinamen, Ortsnamen).
    func searchText(_ m: Message) -> String {
        var parts = [m.body]
        if let q = m.payload.question { parts.append(q) }
        parts += (m.payload.options ?? []).map(\.text)
        if let n = m.payload.name { parts.append(n) }
        if let f = m.payload.filename { parts.append(f) }
        parts += items(message: m.id).map(\.text)
        return parts.joined(separator: " ")
    }

    func reindex(_ id: String) {
        guard ftsAvailable else { return }
        try? db.run("DELETE FROM fts WHERE id=?", id)
        if let m = message(id), !m.deleted {
            try? db.run("INSERT INTO fts(id, room_id, body) VALUES(?,?,?)", m.id, m.roomId, searchText(m))
        }
    }

    // MARK: Warteschlange

    func enqueue(op: [String: Any]) {
        var o = op
        let id = (o["op_id"] as? String) ?? newID()
        o["op_id"] = id
        let body = String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), encoding: .utf8) ?? "{}"
        try? db.run("INSERT INTO outbox(op_id, kind, body) VALUES(?,?,?)", id, "op", body)
    }

    func enqueueUpload(id: String) {
        try? db.run("INSERT INTO outbox(op_id, kind, body) VALUES(?,?,?)", id, "blob", id)
    }

    var pendingCount: Int { db.one("SELECT COUNT(*) AS n FROM outbox")?.int("n") ?? 0 }

    // MARK: Vom Server übernehmen

    /// Wendet eine Änderung aus /api/sync an. Rückgabe: Raum-ID, falls dieser Raum vollständig nachgeladen werden muss.
    func apply(kind: String, d: [String: Any], me: String) -> String? {
        func s(_ k: String) -> String? { d[k] as? String }
        func n(_ k: String) -> Double { (d[k] as? Double) ?? Double(d[k] as? Int ?? 0) }
        func i(_ k: String) -> Int { (d[k] as? Int) ?? Int(d[k] as? Double ?? 0) }
        switch kind {
        case "room":
            guard let id = s("id") else { return nil }
            if i("deleted") == 1 {
                purgeRoom(id)
                try? db.run("INSERT OR REPLACE INTO rooms(id, kind, title, deleted) VALUES(?,?,?,1)", id, s("kind") ?? "chat", "")
            } else {
                try? db.run("""
                    INSERT INTO rooms(id, kind, title, avatar, about, created_by, created_at, updated_at, deleted, pending)
                    VALUES(?,?,?,?,?,?,?,?,0,0) ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title,
                    avatar=excluded.avatar, about=excluded.about, created_by=excluded.created_by, created_at=excluded.created_at,
                    updated_at=excluded.updated_at, deleted=0, pending=0
                    """, id, s("kind") ?? "chat", s("title") ?? "", s("avatar"), s("about") ?? "", s("created_by"), n("created_at"), n("updated_at"))
            }
        case "member":
            guard let rid = s("room_id"), let uid = s("user_id") else { return nil }
            let removed = i("removed") == 1
            try? db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color, removed) VALUES(?,?,?,?,?,?,?)",
                        rid, uid, s("role") ?? "member", s("display_name") ?? "", s("username") ?? "", i("color"), removed)
            if uid == me {
                if removed { purgeRoom(rid); try? db.run("DELETE FROM rooms WHERE id=?", rid) }
                else if db.one("SELECT 1 FROM messages WHERE room_id=? LIMIT 1", rid) == nil && get("backfilled:\(rid)") == nil {
                    return rid
                }
            }
        case "message":
            guard let id = s("id"), let rid = s("room_id") else { return nil }
            let payload = (d["payload"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let old = message(id)
            try? db.run("""
                INSERT OR REPLACE INTO messages(id, room_id, author_id, device_id, kind, body, payload, reply_to, attachment, thumb,
                  created_at, edited_at, pinned, deleted, seq, pending, failed) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,NULL)
                """, id, rid, s("author_id"), s("device_id"), s("kind") ?? "text", s("body") ?? "", payload, s("reply_to"),
                        s("attachment"), s("thumb"), n("created_at"), d["edited_at"] is NSNull ? nil : d["edited_at"] as? Double,
                        i("pinned"), i("deleted"), i("seq"))
            if i("deleted") == 1 {
                removeFile(old?.attachment)
                removeFile(old?.thumb)
            }
            reindex(id)
        case "reaction":
            guard let mid = s("message_id"), let uid = s("user_id"), let e = s("emoji") else { return nil }
            try? db.run("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, active, room_id) VALUES(?,?,?,?,?)",
                        mid, uid, e, i("active"), s("room_id"))
        case "star":
            guard let mid = s("message_id") else { return nil }
            try? db.run("INSERT OR REPLACE INTO stars(message_id, active, room_id) VALUES(?,?,?)", mid, i("active"), s("room_id"))
        case "vote":
            guard let mid = s("message_id"), let uid = s("user_id") else { return nil }
            let ch = (try? JSONSerialization.data(withJSONObject: d["choices"] as? [String] ?? [])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try? db.run("INSERT OR REPLACE INTO votes(message_id, user_id, choices) VALUES(?,?,?)", mid, uid, ch)
        case "item":
            guard let id = s("id") else { return nil }
            try? db.run("INSERT OR REPLACE INTO items(id, message_id, room_id, text, done, position, deleted) VALUES(?,?,?,?,?,?,?)",
                        id, s("message_id"), s("room_id"), s("text") ?? "", i("done"), n("position"), i("deleted"))
            if let mid = s("message_id") { reindex(mid) }
        case "roomstate":
            guard let rid = s("room_id") else { return nil }
            try? db.run("INSERT OR REPLACE INTO roomstate(room_id, pinned, archived, muted) VALUES(?,?,?,?)",
                        rid, i("pinned"), i("archived"), i("muted"))
        default: break
        }
        return nil
    }

    func purgeRoom(_ id: String) {
        for r in db.query("SELECT attachment, thumb FROM messages WHERE room_id=?", id) {
            removeFile(r.str("attachment")); removeFile(r.str("thumb"))
        }
        if let a = db.one("SELECT avatar FROM rooms WHERE id=?", id)?.str("avatar") { removeFile(a) }
        try? db.run("DELETE FROM messages WHERE room_id=?", id)
        try? db.run("DELETE FROM reactions WHERE room_id=?", id)
        try? db.run("DELETE FROM stars WHERE room_id=?", id)
        try? db.run("DELETE FROM items WHERE room_id=?", id)
        try? db.run("DELETE FROM roomstate WHERE room_id=?", id)
        if ftsAvailable { try? db.run("DELETE FROM fts WHERE room_id=?", id) }
    }

    /// Einträge mit Anhang, deren Vorschau (oder kleine Datei) noch fehlt.
    func missingDownloads(limit: Int = 30) -> [(id: String, name: String, mime: String)] {
        var out: [(String, String, String)] = []
        for r in db.query("""
            SELECT m.thumb, m.attachment, m.kind, m.payload, m.room_id FROM messages m WHERE m.deleted=0 AND
            ((m.thumb IS NOT NULL AND m.thumb NOT IN (SELECT id FROM files)) OR
             (m.kind IN ('image','voice') AND m.attachment IS NOT NULL AND m.attachment NOT IN (SELECT id FROM files)))
            ORDER BY m.created_at DESC LIMIT ?
            """, limit) {
            let p = Payload.decode(r.s("payload"))
            if let t = r.str("thumb"), fileURL(t) == nil { out.append((t, "thumb.jpg", "image/jpeg")) }
            if ["image", "voice"].contains(r.s("kind")), let a = r.str("attachment"), fileURL(a) == nil, (p.size ?? 0) < 25_000_000 {
                out.append((a, p.filename ?? (r.s("kind") == "voice" ? "sprachnotiz.m4a" : "foto.jpg"), p.mime ?? "application/octet-stream"))
            }
        }
        for r in db.query("SELECT avatar FROM rooms WHERE deleted=0 AND avatar IS NOT NULL AND avatar NOT IN (SELECT id FROM files)") {
            out.append((r.s("avatar"), "avatar.jpg", "image/jpeg"))
        }
        return out
    }
}
