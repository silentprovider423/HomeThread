import Foundation

/// Gemeinsamer Ordner von App und Teilen-Erweiterung (App-Gruppe). Die Erweiterung legt Geteiltes hier ab, die App
/// übernimmt es beim nächsten Öffnen in den gewählten Chat (sie allein schreibt in die Datenbank und gleicht ab).
///
/// Gruppen-Name: SideStore/AltStore hängen beim Installieren die Team-ID an und schreiben die echte Gruppe in die
/// Info.plist („ALTAppGroups“); wer selbst mit festen Gruppen signiert, trägt die Gruppe beim Signieren als
/// „SignedAppGroup“ in die Info.plist ein. Genommen wird die erste Gruppe, auf die diese Installation Zugriff hat.
nonisolated enum ShareInbox {
    static let base = "group.org.homeroll.thread"

    static let groupID: String? = {
        let info = Bundle.main.infoDictionary ?? [:]
        var candidates: [String] = []
        for case let list as [String] in [info["ALTAppGroups"]] + info.values.map({ Optional($0) }) {
            candidates += list.filter { $0.hasPrefix(base) }
        }
        if let signed = info["SignedAppGroup"] as? String { candidates.append(signed) }
        candidates.append(base)
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
    }()

    /// eigener Unterordner (die feste Gruppe könnte eine andere App mitbenutzen)
    static var root: URL? {
        guard let g = groupID, let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) else { return nil }
        let d = c.appendingPathComponent("HomeThread", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Chats für die Auswahl in der Erweiterung

    struct RoomEntry: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var title: String
        var group: Bool
        var members: Int
    }

    private static var roomsFile: URL? { root?.appendingPathComponent("chats.json") }

    /// Liste der Chats (neueste zuerst) – nur Titel und Kennung, keine Inhalte
    static func saveRooms(_ rooms: [RoomEntry]?) {
        guard let f = roomsFile else { return }
        guard let rooms, let d = try? JSONEncoder().encode(rooms) else { try? FileManager.default.removeItem(at: f); return }
        try? d.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Erscheinungsbild der App (0 automatisch, 1 hell, 2 dunkel), damit die Erweiterung gleich aussieht
    static var appearance: Int {
        get { (root.flatMap { try? String(contentsOf: $0.appendingPathComponent("erscheinungsbild.txt"), encoding: .utf8) }).flatMap { Int($0) } ?? 0 }
        set { if let r = root { try? String(newValue).write(to: r.appendingPathComponent("erscheinungsbild.txt"), atomically: true, encoding: .utf8) } }
    }

    static func loadRooms() -> [RoomEntry] {
        guard let f = roomsFile, let d = try? Data(contentsOf: f) else { return [] }
        return (try? JSONDecoder().decode([RoomEntry].self, from: d)) ?? []
    }

    // MARK: Abgelegtes

    struct Item: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case image, video, file }
        var kind: Kind
        /// Dateiname im Ordner des Pakets
        var file: String
    }

    /// Ein Teilen-Vorgang: Ziel-Chat, Text (Kommentar + geteilte Texte/Links), Dateien
    struct Drop: Codable, Sendable {
        var id: String
        var room: String
        var text: String
        var items: [Item]
        var created: Date
    }

    private static var inbox: URL? {
        guard let r = root else { return nil }
        let d = r.appendingPathComponent("Eingang", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// neuen Paket-Ordner anlegen (die Erweiterung kopiert die Dateien hinein und schreibt zuletzt `commit`)
    static func newDropFolder() -> (id: String, dir: URL)? {
        guard let i = inbox else { return nil }
        let id = UUID().uuidString
        let dir = i.appendingPathComponent(id + ".tmp", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return nil }
        return (id, dir)
    }

    /// Paket fertig: Beschreibung schreiben und Ordner umbenennen – erst dann sieht die App es
    static func commit(_ drop: Drop, dir: URL) -> Bool {
        guard let i = inbox, let d = try? JSONEncoder().encode(drop) else { return false }
        do {
            try d.write(to: dir.appendingPathComponent("paket.json"), options: .atomic)
            try FileManager.default.moveItem(at: dir, to: i.appendingPathComponent(drop.id, isDirectory: true))
            return true
        } catch { return false }
    }

    /// fertige Pakete (älteste zuerst); halb geschriebene (.tmp) älter als ein Tag werden weggeräumt
    static func pending() -> [(Drop, URL)] {
        guard let i = inbox, let list = try? FileManager.default.contentsOfDirectory(at: i, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        var out: [(Drop, URL)] = []
        for dir in list {
            if dir.lastPathComponent.hasSuffix(".tmp") {
                let c = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if c < Date().addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: dir) }
                continue
            }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("paket.json")),
                  let drop = try? JSONDecoder().decode(Drop.self, from: d) else { continue }
            out.append((drop, dir))
        }
        return out.sorted { $0.0.created < $1.0.created }
    }

    static func remove(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// Abmelden: Chat-Liste und nicht übernommene Pakete löschen
    static func clear() {
        saveRooms(nil)
        if let r = root { try? FileManager.default.removeItem(at: r.appendingPathComponent("erscheinungsbild.txt")) }
        if let i = inbox { try? FileManager.default.removeItem(at: i) }
    }
}
