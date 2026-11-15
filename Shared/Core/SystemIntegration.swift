import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Spotlight (freiwillig, Einstellungen)

/// Einträge in der Systemsuche (Spotlight) finden – nur, wenn in den Einstellungen eingeschaltet, nur auf diesem Gerät.
/// Ein Treffer öffnet den Eintrag in der App.
@MainActor
enum SpotlightIndex {
    static let domain = "org.homeroll.thread.entries"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "spotlight") }
        set { UserDefaults.standard.set(newValue, forKey: "spotlight") }
    }

    /// Neue und geänderte Einträge seit dem letzten Lauf aufnehmen, gelöschte entfernen.
    static func refresh(_ store: LocalStore) async {
        guard enabled else { return }
        let last = Int(store.get("spotlight:seq") ?? "0") ?? 0
        let rows = store.db.query("SELECT * FROM messages WHERE seq>? ORDER BY seq LIMIT 3000", last)
        guard !rows.isEmpty else { return }
        let msgs = rows.map(LocalStore.message)
        var titles: [String: String] = [:]
        var items: [CSSearchableItem] = [], gone: [String] = []
        for m in msgs {
            if m.deleted { gone.append(m.id); continue }
            let text = store.searchText(m)
            guard !text.isEmpty else { continue }
            if titles[m.roomId] == nil { titles[m.roomId] = store.room(m.roomId)?.title ?? "HomeThread" }
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = titles[m.roomId]
            a.contentDescription = String(text.prefix(300))
            a.textContent = text
            a.contentCreationDate = m.createdAt
            items.append(CSSearchableItem(uniqueIdentifier: EntryLink.make(m).absoluteString, domainIdentifier: domain, attributeSet: a))
        }
        let idx = CSSearchableIndex.default()
        if !items.isEmpty { try? await idx.indexSearchableItems(items) }
        if !gone.isEmpty { try? await idx.deleteSearchableItems(withIdentifiers: msgs.filter(\.deleted).map { EntryLink.make($0).absoluteString }) }
        store.set("spotlight:seq", String(msgs.map(\.seq).max() ?? last))
    }

    /// Ausschalten oder Abmelden: alles aus der Systemsuche entfernen.
    static func clear(_ store: LocalStore?) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
        store?.set("spotlight:seq", "0")
    }
}

// MARK: - Kurzbefehle / Siri

/// Ein Chat oder eine Gruppe als Auswahl in Kurzbefehlen.
struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Chat"
    static let defaultQuery = RoomQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct RoomQuery: EntityStringQuery {
    @MainActor private var rooms: [RoomEntity] {
        (AppModel.current?.summaries(archived: false) ?? []).map { RoomEntity(id: $0.room.id, title: $0.room.title) }
    }
    @MainActor func entities(for ids: [String]) async throws -> [RoomEntity] { rooms.filter { ids.contains($0.id) } }
    @MainActor func entities(matching s: String) async throws -> [RoomEntity] { rooms.filter { $0.title.localizedStandardContains(s) } }
    @MainActor func suggestedEntities() async throws -> [RoomEntity] { Array(rooms.prefix(30)) }
}

/// „Notiz in HomeThread ablegen“ – Text in einen Chat legen, ohne die App zu öffnen.
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Notiz ablegen"
    static let description = IntentDescription("Legt einen Text in einem HomeThread-Chat ab.")

    @Parameter(title: "Text") var text: String
    @Parameter(title: "Chat") var room: RoomEntity

    static var parameterSummary: some ParameterSummary { Summary("\(\.$text) in \(\.$room) ablegen") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.current, model.session != nil else {
            return .result(dialog: "Bitte zuerst in HomeThread anmelden.")
        }
        model.sendText(room: room.id, text, replyTo: nil)
        await model.syncNow()
        return .result(dialog: "In „\(room.title)“ abgelegt.")
    }
}

/// Chat öffnen
struct OpenRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Chat öffnen"
    static let openAppWhenRun = true
    @Parameter(title: "Chat") var room: RoomEntity

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.current?.openRequest = ChatRoute(room: room.id, jump: nil)
        return .result()
    }
}

struct HomeThreadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddNoteIntent(), phrases: ["Notiz in \(.applicationName) ablegen", "\(.applicationName) Notiz"],
                    shortTitle: "Notiz ablegen", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenRoomIntent(), phrases: ["\(.applicationName) Chat öffnen"],
                    shortTitle: "Chat öffnen", systemImageName: "bubble.left.and.bubble.right")
    }
}
