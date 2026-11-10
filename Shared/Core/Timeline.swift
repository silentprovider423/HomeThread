import Foundation
import Observation

/// Formatierter Text eines Eintrags (Links, **fett**, _kursiv_) – einmal im Hintergrund gebaut und zwischengespeichert.
/// Vergleich nur über den Quelltext, damit das Diff billig bleibt.
nonisolated struct RichText: Hashable, Sendable {
    let source: String
    let value: AttributedString

    static func == (a: RichText, b: RichText) -> Bool { a.source == b.source }
    func hash(into h: inout Hasher) { h.combine(source) }

    private final class Box: @unchecked Sendable { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 6000; return c }()
    nonisolated(unsafe) private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Links (auch nackte Adressen) und einfache Hervorhebungen anzeigen, Text sonst unverändert lassen.
    static func make(_ s: String) -> RichText {
        if let c = cache.object(forKey: s as NSString) { return RichText(source: s, value: c.value) }
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        let plain = String(a.characters)
        if plain.contains("."), let det = linkDetector {
            var from = a.startIndex
            for m in det.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = m.url, let r = Range(m.range, in: plain), from < a.endIndex,
                      let ar = a[from...].range(of: String(plain[r])) else { continue }
                if a[ar].link == nil { a[ar].link = url }
                from = ar.upperBound
            }
        }
        // Links auf andere Einträge (homethread://entry/…)
        for hit in EntryLink.ranges(in: plain) {
            if let ar = a.range(of: String(plain[hit.range])), a[ar].link == nil { a[ar].link = hit.url }
        }
        cache.setObject(Box(a), forKey: s as NSString)
        return RichText(source: s, value: a)
    }
}

/// Eine fertig vorbereitete Zeile des Verlaufs: alles, was die Bubble zeigt, ohne dass sie selbst die Datenbank fragt.
/// Gleichheit = gleiche Anzeige → nur geänderte Zeilen werden neu gezeichnet.
nonisolated struct TimelineRow: Hashable, Identifiable, Sendable {
    var message: Message
    var id: String { message.id }
    /// iPhone: Datums-Pille vor dieser Zeile (Tageswechsel)
    var dayPill: String?
    /// gleicher Verfasser kurz davor → weniger Abstand
    var compactTop = false
    /// „Neu von anderem Gerät (n)“ vor dieser Zeile
    var unreadCount: Int?
    var mine = false
    var isGroup = false
    var authorName: String?
    /// von einem anderen Gerät: Symbolname (Mac/iPhone)
    var deviceSymbol: String?
    var reactions: [ReactionCount] = []
    var starred = false
    var rich: RichText?
    /// Antwort: zitierter Eintrag (nil = nicht gefunden) und dessen Verfasser
    var quote: Message?
    var quoteAuthor: String?
    var items: [ChecklistItem] = []
    var votes: [String: [String]] = [:]
    /// lokal vorhandene Vorschau bzw. Datei
    var thumbURL: URL?
    var attachmentURL: URL?
    /// noch nicht geladene Vorschau bzw. Datei: die sichtbare Zelle holt sie selbst (ohne Neuaufbau des Verlaufs)
    var thumbRef: FileRef?
    var attachmentRef: FileRef?
}

/// Datei auf dem Server, die noch nicht auf dem Gerät liegt
nonisolated struct FileRef: Hashable, Sendable {
    var id: String
    var name: String
    var mime: String
}

/// Eingaben für den Aufbau im Hintergrund (vom Main-Actor eingesammelt).
nonisolated struct TimelineParams: Sendable {
    var room: String
    var me: String
    var myDevice: String
    var isGroup: Bool
    var names: [String: String]
    var macDevices: Set<String>
    var firstUnreadSeq: Int?
    var filesRoot: URL
    var showDayPills: Bool
}

/// Liest den Verlauf auf einer eigenen SQLite-Verbindung (WAL erlaubt Lesen parallel zum Schreiben des Main-Actors)
/// in einer seriellen Hintergrund-Warteschlange.
nonisolated final class TimelineLoader: @unchecked Sendable {
    private let db: SQLiteDB
    private let queue = DispatchQueue(label: "homethread.timeline", qos: .userInitiated)

    init(path: String) throws {
        db = try SQLiteDB(path: path)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable (TimelineLoader) -> T) async -> T {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: work(self)) }
        }
    }

    /// Beginn (created_at) des Fensters mit den `count` neuesten Einträgen bzw. `count` weiteren vor `before`; nil = alles.
    func windowStart(room: String, count: Int, before: Double? = nil) -> Double? {
        if let before {
            return db.one("SELECT created_at FROM messages WHERE room_id=? AND deleted=0 AND created_at<? ORDER BY created_at DESC LIMIT 1 OFFSET ?",
                          room, before, count - 1)?.dbl("created_at")
        }
        return db.one("SELECT created_at FROM messages WHERE room_id=? AND deleted=0 ORDER BY created_at DESC LIMIT 1 OFFSET ?",
                      room, count - 1)?.dbl("created_at")
    }

    func hasOlder(room: String, than t: Double?) -> Bool {
        guard let t else { return false }
        return db.one("SELECT 1 AS x FROM messages WHERE room_id=? AND deleted=0 AND created_at<? LIMIT 1", room, t) != nil
    }

    func createdAt(_ id: String) -> Double? {
        db.one("SELECT created_at FROM messages WHERE id=? AND deleted=0", id)?.dbl("created_at")
    }

    func pinned(room: String) -> [Message] {
        db.query("SELECT * FROM messages WHERE room_id=? AND deleted=0 AND pinned=1 ORDER BY created_at DESC", room).map(LocalStore.message)
    }

    /// Einträge im Bereich [from, until) fertig vorbereiten (ohne die Nachbar-abhängigen Felder, siehe `finalize`).
    func rows(_ p: TimelineParams, from: Double?, until: Double? = nil) -> [TimelineRow] {
        var sql = "SELECT * FROM messages WHERE room_id=? AND deleted=0"
        var args: [Any?] = [p.room]
        if let from { sql += " AND created_at>=?"; args.append(from) }
        if let until { sql += " AND created_at<?"; args.append(until) }
        sql += " ORDER BY created_at, id"
        let msgs = db.queryArgs(sql, args).map(LocalStore.message)
        guard !msgs.isEmpty else { return [] }
        let lo = msgs.first!.createdAt.timeIntervalSince1970, hi = msgs.last!.createdAt.timeIntervalSince1970

        var reactions: [String: [ReactionCount]] = [:]
        for r in db.query("""
            SELECT r.message_id, r.emoji, COUNT(*) AS n, MAX(r.user_id=?) AS mine, MIN(r.rowid) AS first FROM reactions r
            WHERE r.room_id=? AND r.active=1 GROUP BY r.message_id, r.emoji ORDER BY first
            """, p.me, p.room) {
            reactions[r.s("message_id"), default: []].append(ReactionCount(emoji: r.s("emoji"), count: r.int("n"), mine: r.bool("mine")))
        }
        let stars = Set(db.query("SELECT message_id FROM stars WHERE active=1 AND room_id=?", p.room).map { $0.s("message_id") })
        var items: [String: [ChecklistItem]] = [:]
        if msgs.contains(where: { $0.kind == .checklist }) {
            for r in db.query("SELECT * FROM items WHERE room_id=? AND deleted=0 ORDER BY position, rowid", p.room) {
                items[r.s("message_id"), default: []].append(ChecklistItem(id: r.s("id"), messageId: r.s("message_id"), text: r.s("text"),
                                                                             done: r.bool("done"), position: r.dbl("position")))
            }
        }
        var votes: [String: [String: [String]]] = [:]
        if msgs.contains(where: { $0.kind == .poll }) {
            for r in db.query("""
                SELECT v.message_id, v.user_id, v.choices FROM votes v JOIN messages m ON m.id=v.message_id
                WHERE m.room_id=? AND m.kind='poll' AND m.created_at>=? AND m.created_at<=?
                """, p.room, lo, hi) {
                let ch = (try? JSONSerialization.jsonObject(with: Data(r.s("choices").utf8))) as? [String] ?? []
                votes[r.s("message_id"), default: [:]][r.s("user_id")] = ch
            }
        }
        // zitierte Einträge (auch außerhalb des Fensters)
        let byID = Dictionary(msgs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let missingQuotes = Set(msgs.compactMap(\.replyTo)).subtracting(byID.keys)
        var quoted = byID
        if !missingQuotes.isEmpty {
            let list = Array(missingQuotes)
            for chunk in stride(from: 0, to: list.count, by: 400) {
                let part = Array(list[chunk..<min(chunk + 400, list.count)])
                let q = "SELECT * FROM messages WHERE id IN (" + part.map { _ in "?" }.joined(separator: ",") + ")"
                for m in db.queryArgs(q, part).map(LocalStore.message) { quoted[m.id] = m }
            }
        }
        // lokal vorhandene Dateien (Vorschau, Foto, Sprachnotiz)
        let fileIDs = Array(Set(msgs.flatMap { [$0.thumb, $0.attachment] }.compactMap { $0 }))
        var files: [String: URL] = [:]
        for chunk in stride(from: 0, to: fileIDs.count, by: 400) {
            let part = Array(fileIDs[chunk..<min(chunk + 400, fileIDs.count)])
            let q = "SELECT id, name FROM files WHERE id IN (" + part.map { _ in "?" }.joined(separator: ",") + ")"
            for r in db.queryArgs(q, part) {
                let u = p.filesRoot.appendingPathComponent("files/\(r.s("id"))/\(r.s("name"))")
                if FileManager.default.fileExists(atPath: u.path) { files[r.s("id")] = u }
            }
        }

        return msgs.map { m in
            var row = TimelineRow(message: m)
            row.mine = m.authorId == p.me
            row.isGroup = p.isGroup
            if p.isGroup && !row.mine { row.authorName = p.names[m.authorId] ?? String(localized: "Person") }
            if let d = m.deviceId, d != p.myDevice { row.deviceSymbol = p.macDevices.contains(d) ? "laptopcomputer" : "iphone" }
            row.reactions = reactions[m.id] ?? []
            row.starred = stars.contains(m.id)
            if m.kind == .text { row.rich = RichText.make(m.body) }
            if let r = m.replyTo {
                row.quote = quoted[r]
                row.quoteAuthor = quoted[r].flatMap { p.names[$0.authorId] }
            }
            if m.kind == .checklist { row.items = items[m.id] ?? [] }
            if m.kind == .poll { row.votes = votes[m.id] ?? [:] }
            row.thumbURL = (m.thumb ?? (m.kind == .image ? m.attachment : nil)).flatMap { files[$0] }
            row.attachmentURL = m.attachment.flatMap { files[$0] }
            if row.thumbURL == nil {
                if let t = m.thumb { row.thumbRef = FileRef(id: t, name: "thumb.jpg", mime: "image/jpeg") }
                else if m.kind == .image, let a = m.attachment {
                    row.thumbRef = FileRef(id: a, name: m.payload.filename ?? "foto.jpg", mime: m.payload.mime ?? "image/jpeg")
                }
            }
            if row.attachmentURL == nil, m.kind == .voice, let a = m.attachment {
                row.attachmentRef = FileRef(id: a, name: m.payload.filename ?? "sprachnotiz.m4a", mime: m.payload.mime ?? "audio/mp4")
            }
            return row
        }
    }

    /// Nachbar-abhängige Felder (Datums-Pille, kompakter Abstand, Neu-Linie) setzen und geänderte Zeilen gegenüber `previous` finden.
    func finalize(_ rows: [TimelineRow], _ p: TimelineParams, previous: [String: TimelineRow]) -> (rows: [TimelineRow], changed: [String]) {
        var out = rows
        var unread: Int?
        if let f = p.firstUnreadSeq, out.contains(where: { $0.message.seq == f }) {
            unread = db.one("SELECT COUNT(*) AS n FROM messages WHERE room_id=? AND deleted=0 AND seq>=? AND COALESCE(device_id,'')<>?",
                            p.room, f, p.myDevice)?.int("n")
        }
        let cal = Calendar.current
        var lastDay: Date?
        for i in out.indices {
            let m = out[i].message
            let prev = i > 0 ? out[i - 1].message : nil
            if p.showDayPills {
                let day = cal.startOfDay(for: m.createdAt)
                out[i].dayPill = day != lastDay ? Fmt.dayPill(m.createdAt) : nil
                lastDay = day
            }
            out[i].compactTop = prev.map { $0.authorId == m.authorId && m.createdAt.timeIntervalSince($0.createdAt) < 1800 } ?? false
            out[i].unreadCount = p.firstUnreadSeq == m.seq ? unread : nil
        }
        let changed = out.compactMap { r -> String? in
            guard let old = previous[r.id] else { return nil }
            return old != r ? r.id : nil
        }
        return (out, changed)
    }
}

/// Verlauf eines Raums als Fenster aus der lokalen Datenbank (wie Threema): zuerst die neuesten 100 Einträge,
/// beim Hochscrollen je 150 ältere davor; Aufbau, Diff und Formatierung laufen im Hintergrund.
@Observable
final class ChatTimeline {
    enum Change { case initial, prepend, update }

    static let firstPage = 100
    static let olderPage = 150

    let roomId: String
    private(set) var rows: [TimelineRow] = []
    /// Zählt bei jeder Änderung hoch; die Tabelle übernimmt nur neue Stände.
    private(set) var version = 0
    private(set) var change: Change = .initial
    /// Zeilen, deren Anzeige sich geändert hat (für reconfigure)
    private(set) var changed: [String] = []
    private(set) var pinned: [Message] = []
    private(set) var hasOlder = false
    private(set) var loaded = false
    private(set) var firstUnreadSeq: Int?

    @ObservationIgnored private var loader: TimelineLoader?
    @ObservationIgnored private var windowStart: Double?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var reloadQueued = false
    @ObservationIgnored private weak var model: AppModel?

    init(roomId: String) { self.roomId = roomId }

    var lastID: String? { rows.last?.id }
    func index(of id: String) -> Int? { rows.firstIndex { $0.id == id } }

    /// Beim Öffnen: Neu-Linie bestimmen (vor „gesehen“), erste Seite laden.
    func start(_ model: AppModel) {
        guard loader == nil, let store = model.store else { return }
        self.model = model
        loader = try? TimelineLoader(path: store.db.path)
        let read = Int(store.get("read:\(roomId)") ?? "0") ?? 0
        firstUnreadSeq = store.db.one("""
            SELECT MIN(seq) AS s FROM messages WHERE room_id=? AND deleted=0 AND seq>? AND COALESCE(device_id,'')<>? AND pending=0
            """, roomId, read, model.myDevice).flatMap { $0.v["s"] == nil ? nil : $0.int("s") }
        reload()
    }

    private func params() -> TimelineParams? {
        guard let model, let store = model.store, let room = store.room(roomId) else { return nil }
        var names: [String: String] = [:]
        for u in model.users { names[u.id] = u.displayName }
        for m in store.members(room: roomId) where names[m.userId] == nil && !m.displayName.isEmpty { names[m.userId] = m.displayName }
        if let me = model.session?.user { names[me.id] = me.displayName }
        #if os(iOS)
        let pills = true
        #else
        let pills = false
        #endif
        return TimelineParams(room: roomId, me: model.me, myDevice: model.myDevice, isGroup: room.kind == .group && room.memberCount > 1,
                              names: names, macDevices: Set(model.devices.values.filter { $0.platform == "mac" }.map(\.id)),
                              firstUnreadSeq: firstUnreadSeq, filesRoot: store.root, showDayPills: pills)
    }

    /// Ganzes Fenster neu lesen (nach jeder Änderung in der Datenbank); geänderte Zeilen werden gemeldet.
    func reload() {
        guard let loader, let p = params() else { return }
        if busy { reloadQueued = true; return }
        busy = true
        let first = !loaded
        let start = windowStart
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let room = roomId
        let firstPage = Self.firstPage
        Task {
            let r = await loader.run { l -> (rows: [TimelineRow], changed: [String], start: Double?, older: Bool, pinned: [Message]) in
                let s = first ? l.windowStart(room: room, count: firstPage) : start
                let f = l.finalize(l.rows(p, from: s), p, previous: previous)
                return (f.rows, f.changed, s, l.hasOlder(room: room, than: s), l.pinned(room: room))
            }
            self.windowStart = r.start
            self.publish(r.rows, changed: r.changed, change: first ? .initial : .update, older: r.older)
            self.pinned = r.pinned
            self.finish()
        }
    }

    /// Ältere Seite vor das Fenster setzen (die Tabelle hält dabei die Scroll-Position).
    func loadOlder(count: Int = olderPage, completion: (@MainActor () -> Void)? = nil) {
        guard let loader, let p = params(), hasOlder, !busy, let until = windowStart else { completion?(); return }
        busy = true
        let room = roomId
        let current = rows
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Task {
            let r = await loader.run { l -> (rows: [TimelineRow], changed: [String], start: Double?, older: Bool) in
                let s = l.windowStart(room: room, count: count, before: until)
                let f = l.finalize(l.rows(p, from: s, until: until) + current, p, previous: previous)
                return (f.rows, f.changed, s, l.hasOlder(room: room, than: s))
            }
            self.windowStart = r.start
            self.publish(r.rows, changed: r.changed, change: .prepend, older: r.older)
            self.finish()
            completion?()
        }
    }

    /// Sprung zu einem Eintrag (Zitat, Suche, Angeheftet): Fenster bis 75 Einträge vor dem Ziel erweitern.
    func ensureLoaded(_ id: String) async -> Bool {
        // erst die erste Seite abwarten (Sprung direkt beim Öffnen)
        var waited = 0
        while (!loaded || busy) && waited < 300 { try? await Task.sleep(for: .milliseconds(20)); waited += 1 }
        if index(of: id) != nil { return true }
        guard let loader, let ws = windowStart else { return false }
        let room = roomId
        guard let t = await loader.run({ $0.createdAt(id) }), t < ws else { return index(of: id) != nil }
        let n = await loader.run { l in l.count(room: room, from: l.windowStart(room: room, count: 75, before: t), until: ws) }
        await withCheckedContinuation { c in loadOlder(count: max(n, 1)) { c.resume() } }
        return index(of: id) != nil
    }

    private func publish(_ new: [TimelineRow], changed: [String], change: Change, older: Bool) {
        rows = new
        self.changed = changed
        self.change = change
        hasOlder = older
        loaded = true
        version += 1
    }

    private func finish() {
        busy = false
        if reloadQueued { reloadQueued = false; reload() }
    }
}

extension TimelineLoader {
    /// Anzahl Einträge im Bereich [from, until); from nil = ab Anfang
    nonisolated func count(room: String, from: Double?, until: Double) -> Int {
        db.one("SELECT COUNT(*) AS n FROM messages WHERE room_id=? AND deleted=0 AND created_at>=? AND created_at<?",
               room, from ?? -Double.greatestFiniteMagnitude, until)?.int("n") ?? 0
    }
}
