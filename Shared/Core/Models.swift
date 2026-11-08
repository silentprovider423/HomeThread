import Foundation

nonisolated enum RoomKind: String, Codable { case chat, group }

nonisolated enum MessageKind: String, Codable, CaseIterable {
    case text, voice, image, video, file, location, poll, checklist
}

nonisolated struct UserInfo: Codable, Hashable, Identifiable {
    var id: String
    var username: String
    var displayName: String
    var color: Int
    var avatar: String?

    init(id: String, username: String, displayName: String, color: Int = 0, avatar: String? = nil) {
        self.id = id; self.username = username; self.displayName = displayName; self.color = color; self.avatar = avatar
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        username = json["username"] as? String ?? ""
        displayName = json["display_name"] as? String ?? username
        color = json["color"] as? Int ?? 0
        avatar = json["avatar"] as? String
    }
}

/// Raum = „Chat“ (nur für sich) oder „Gruppe“ (Themen-Raum, später mit weiteren Personen desselben Servers).
nonisolated struct Room: Identifiable, Hashable {
    var id: String
    var kind: RoomKind
    var title: String
    var avatar: String?
    var about: String
    var createdBy: String
    var createdAt: Date
    var updatedAt: Date
    var pinned = false
    var archived = false
    var muted = false
    var memberCount = 1

    var subtitle: String {
        memberCount <= 1 ? String(localized: "Ich") : String(localized: "\(memberCount) Mitglieder")
    }
}

/// Eine Zeile der Chat-Liste: Raum + letzter Eintrag + Anzahl „neu von anderem Gerät“.
nonisolated struct RoomSummary: Identifiable, Hashable {
    var room: Room
    var last: Message?
    var unread: Int
    var draft: String?
    var id: String { room.id }
    var sortDate: Date { max(last?.createdAt ?? room.createdAt, room.createdAt) }
}

nonisolated struct Member: Identifiable, Hashable {
    var roomId: String
    var userId: String
    var role: String
    var displayName: String
    var username: String
    var color: Int
    var id: String { userId }
    var isOwner: Bool { role == "owner" }
}

/// Zusatzdaten je Eintragsart (als JSON beim Server gespeichert).
nonisolated struct Payload: Codable, Hashable {
    // Abstimmung
    var question: String?
    var options: [PollOption]?
    var multi: Bool?
    var showInterim: Bool?
    var closed: Bool?
    // Ort
    var lat: Double?
    var lon: Double?
    var name: String?
    // Medien/Datei
    var w: Int?
    var h: Int?
    var duration: Double?
    var filename: String?
    var size: Int?
    var mime: String?
    var wave: [Double]?
    // Import: Datei gab es nicht mehr / nur die Vorschau des Fotos ist erhalten
    var missing: Bool?
    var previewOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case question, options, multi, closed, lat, lon, name, w, h, duration, filename, size, mime, wave, missing
        case showInterim = "show_interim"
        case previewOnly = "preview_only"
    }

    static func decode(_ s: String) -> Payload {
        (try? JSONDecoder().decode(Payload.self, from: Data(s.utf8))) ?? Payload()
    }

    var json: String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    var dict: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }
}

nonisolated struct PollOption: Codable, Hashable, Identifiable {
    var id: String
    var text: String
}

nonisolated struct Message: Identifiable, Hashable {
    var id: String
    var roomId: String
    var authorId: String
    var deviceId: String?
    var kind: MessageKind
    var body: String
    var payload: Payload
    var replyTo: String?
    var attachment: String?
    var thumb: String?
    var createdAt: Date
    var editedAt: Date?
    var pinned: Bool
    var deleted: Bool
    var seq: Int
    var pending: Bool
    var failed: String?

    /// Kurzer Text für Chat-Liste, Zitat und Suche (ohne Symbol, das zeigt `kindSymbol`).
    var preview: String {
        switch kind {
        case .text: return body
        case .voice: return String(localized: "Sprachnotiz") + (payload.duration.map { " (\(Fmt.duration($0)))" } ?? "")
        case .image: return body.isEmpty ? String(localized: "Foto") : body
        case .video: return body.isEmpty ? String(localized: "Video") : body
        case .file: return payload.filename ?? String(localized: "Datei")
        case .location: return payload.name?.isEmpty == false ? payload.name! : String(localized: "Ort")
        case .poll: return payload.question ?? String(localized: "Abstimmung")
        case .checklist: return body.isEmpty ? String(localized: "Checkliste") : body
        }
    }

    /// SF-Symbol vor der Vorschau (wie kleine Symbole in Messenger-Listen)
    var kindSymbol: String? {
        switch kind {
        case .text: return nil
        case .voice: return "mic.fill"
        case .image: return "photo"
        case .video: return "video.fill"
        case .file: return "paperclip"
        case .location: return "mappin"
        case .poll: return "chart.bar.xaxis"
        case .checklist: return "checklist"
        }
    }

    var hasMedia: Bool { kind == .image || kind == .video }
}

nonisolated struct ReactionCount: Hashable, Identifiable {
    var emoji: String
    var count: Int
    var mine: Bool
    var id: String { emoji }
}

nonisolated struct ChecklistItem: Identifiable, Hashable {
    var id: String
    var messageId: String
    var text: String
    var done: Bool
    var position: Double
}

nonisolated struct DeviceInfo: Identifiable, Hashable {
    var id: String
    var name: String
    var platform: String
    var created: Date
    var lastSeen: Date
    var current: Bool
}

nonisolated enum Fmt {
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    /// Zeit in der Chat-Liste wie üblich: heute Uhrzeit, gestern „Gestern“, diese Woche Wochentag, sonst Datum.
    static func listDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time(d) }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: .now)).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }

    /// Zeitstempel im Desktop-Stil: heute „3:35“, „Gestern, 15:19“, „Freitag, 16:36“, „25. Sept., 17:16“ (anderes Jahr mit Jahr).
    static func stamp(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let t = time(d)
        if cal.isDate(d, inSameDayAs: now) { return t }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return String(localized: "Gestern, \(t)") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days > 0, days < 7 {
            return d.formatted(.dateTime.weekday(.wide)) + ", " + t
        }
        if cal.component(.year, from: d) == cal.component(.year, from: now) {
            return d.formatted(.dateTime.day().month(.abbreviated)) + ", " + t
        }
        return d.formatted(.dateTime.day().month(.abbreviated).year()) + ", " + t
    }

    static func dayPill(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return String(localized: "Heute") }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern") }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

nonisolated func newID() -> String { UUID().uuidString.lowercased() }
