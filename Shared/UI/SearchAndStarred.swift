import SwiftUI

/// Suche über alle Chats mit Bereichen (Texte, Medien, Orte, Abstimmungen, Checklisten, Gemerkt).
struct GlobalSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope: LocalStore.SearchScope = .all
    var onOpen: (String, String) -> Void

    var body: some View {
        let _ = model.revision
        let rooms = query.isEmpty ? [] : (model.store?.summaries(myDevice: model.myDevice, archived: false) ?? [])
            .filter { $0.room.title.localizedCaseInsensitiveContains(query) }
        let hits = model.store?.search(query, scope: scope) ?? []
        List {
            Picker("Bereich", selection: $scope) {
                Text("Alles").tag(LocalStore.SearchScope.all)
                Text("Texte").tag(LocalStore.SearchScope.text)
                Text("Medien").tag(LocalStore.SearchScope.media)
                Text("Orte").tag(LocalStore.SearchScope.places)
                Text("Abstimmungen").tag(LocalStore.SearchScope.polls)
                Text("Checklisten").tag(LocalStore.SearchScope.checklists)
                Text("Gemerkt").tag(LocalStore.SearchScope.starred)
            }
            .pickerStyle(.menu)
            if !rooms.isEmpty {
                Section("Chats") {
                    ForEach(rooms) { s in
                        Button { onOpen(s.id, "") } label: { ChatRow(summary: s) }.buttonStyle(.plain)
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
        .overlay {
            if !query.isEmpty && hits.isEmpty && rooms.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if query.isEmpty && scope == .all {
                ContentUnavailableView("In allen Chats suchen", systemImage: "magnifyingglass",
                                       description: Text("Texte, Checklisten-Punkte, Antworten, Orte und Dateinamen."))
            }
        }
        .searchable(text: $query, prompt: Text("In allen Chats suchen"))
        .navigationTitle("Suchen")
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
        }
        .overlay {
            if list.isEmpty {
                ContentUnavailableView("Noch nichts gemerkt", systemImage: "star",
                                       description: Text("Halte einen Eintrag gedrückt und wähle „Merken“."))
            }
        }
        .navigationTitle("Gemerkt")
    }
}
