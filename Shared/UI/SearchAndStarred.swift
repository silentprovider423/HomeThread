import SwiftUI

/// Treffer über alle Chats (Chat-Namen + Einträge), als Inhalt einer Liste – iPhone in der Chat-Liste, Mac in der Seitenspalte.
struct SearchResults: View {
    @Environment(AppModel.self) private var model
    let query: String
    var scope: LocalStore.SearchScope = .all
    var onOpen: (String, String) -> Void

    static func rooms(_ model: AppModel, _ q: String) -> [RoomSummary] {
        q.isEmpty ? [] : model.summaries(archived: false).filter { $0.room.title.localizedCaseInsensitiveContains(q) }
    }

    static func hasHits(_ model: AppModel, _ q: String, _ scope: LocalStore.SearchScope) -> Bool {
        !rooms(model, q).isEmpty || !(model.store?.search(q, scope: scope).isEmpty ?? true)
    }

    var body: some View {
        let _ = model.revision
        let rooms = scope == .all ? Self.rooms(model, query) : []
        let hits = model.store?.search(query, scope: scope) ?? []
        if !rooms.isEmpty {
            Section("Chats") {
                ForEach(rooms) { s in
                    Button { onOpen(s.id, "") } label: { SearchRoomRow(summary: s) }.buttonStyle(.plain)
                }
            }
        }
        if !hits.isEmpty {
            Section("Einträge") {
                ForEach(hits) { m in
                    Button { onOpen(m.roomId, m.id) } label: { MessageRow(message: m) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.hit")
                }
            }
        }
    }
}

/// Kompakte Raum-Zeile in Suchtreffern.
struct SearchRoomRow: View {
    let summary: RoomSummary
    var body: some View {
        HStack(spacing: 12) {
            Avatar(title: summary.room.title, image: summary.room.avatar, isGroup: summary.room.kind == .group, size: 36, colorKey: summary.room.id)
            Text(summary.room.title).font(.body.weight(.semibold)).lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// Alle gemerkten Einträge.
struct StarredView: View {
    @Environment(AppModel.self) private var model
    var onOpen: (String, String) -> Void

    var body: some View {
        let _ = model.revision
        let list = model.store?.starredMessages() ?? []
        List(list) { m in
            Button { onOpen(m.roomId, m.id) } label: { MessageRow(message: m) }
                .buttonStyle(.plain)
                .swipeActions { Button("Nicht mehr merken") { model.toggleStar(m) }.tint(.gray) }
                .contextMenu { Button { model.toggleStar(m) } label: { Label("Nicht mehr merken", systemImage: "star.slash") } }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Noch nichts gemerkt", systemImage: "star",
                                       description: Text("Halte einen Eintrag gedrückt und wähle „Merken“."))
            }
        }
        .navigationTitle("Gemerkt")
    }
}
