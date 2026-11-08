import SwiftUI

/// iPhone-Chat-Liste: großer Titel „Chats“, Suchfeld, Angeheftete oben, dann nach letztem Eintrag;
/// Wischen zum Anheften/Archivieren/Löschen. Beim Suchen zeigt dieselbe Seite Treffer aus allen Chats.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    var archived = false
    /// Raum öffnen (neu angelegt oder Suchtreffer: Raum + Eintrag)
    var onOpen: (String, String) -> Void = { _, _ in }
    @State private var showNew: NewRoomFlow.Mode?
    @State private var confirmDelete: RoomSummary?
    @State private var query = ""
    @State private var scope: LocalStore.SearchScope = .all

    var body: some View {
        let rows = model.summaries(archived: archived)
        let archivedCount = archived ? 0 : (model.store?.archivedCount() ?? 0)
        let searching = !query.isEmpty || scope != .all
        List {
            if searching {
                SearchResults(query: query, scope: scope, onOpen: onOpen)
            } else {
                content(rows, archivedCount)
            }
        }
        .listStyle(.plain)
        .overlay {
            if !searching && rows.isEmpty && archivedCount == 0 {
                ContentUnavailableView {
                    Label(archived ? "Archiv ist leer" : "Noch keine Chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(archived ? "Archivierte Chats erscheinen hier." : "Lege einen Chat oder eine Gruppe an – zum Beispiel „Einkauf“, „Ideen“ oder „Urlaub“.")
                } actions: {
                    if !archived {
                        Button("Neuer Chat") { showNew = .chat }.buttonStyle(.borderedProminent)
                    }
                }
            } else if searching && !SearchResults.hasHits(model, query, scope) {
                if query.isEmpty { Color.clear } else { ContentUnavailableView.search(text: query) }
            }
        }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Suchen"))
        .searchScopes($scope, activation: .onSearchPresentation) {
            Text("Alles").tag(LocalStore.SearchScope.all)
            Text("Texte").tag(LocalStore.SearchScope.text)
            Text("Medien").tag(LocalStore.SearchScope.media)
            Text("Orte").tag(LocalStore.SearchScope.places)
            Text("Abstimmungen").tag(LocalStore.SearchScope.polls)
            Text("Checklisten").tag(LocalStore.SearchScope.checklists)
            Text("Gemerkt").tag(LocalStore.SearchScope.starred)
        }
        #endif
        .refreshable { await model.syncNow() }
        .navigationTitle(archived ? "Archiv" : "Chats")
        .toolbar {
            #if os(iOS)
            if !archived {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showNew = .chat } label: { Label("Neuer Chat", systemImage: "square.and.pencil") }
                        Button { showNew = .group } label: { Label("Neue Gruppe", systemImage: "person.3.sequence.fill") }
                    } label: {
                        Label("Neu", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("chats.new")
                }
                ToolbarItem(placement: .topBarLeading) { SyncBadge() }
            }
            #endif
        }
        .tint(Theme.accent)
        .sheet(item: $showNew) { mode in
            NewRoomFlow(mode: mode) { id in onOpen(id, "") }
        }
        .confirmationDialog("Chat löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { s in
            Button("„\(s.room.title)“ mit allen Einträgen löschen", role: .destructive) { model.deleteRoom(s.room.id) }
        } message: { _ in
            Text("Der Chat wird auf allen deinen Geräten und auf dem Server gelöscht.")
        }
    }

    @ViewBuilder
    private func content(_ rows: [RoomSummary], _ archivedCount: Int) -> some View {
        ForEach(rows) { s in
            NavigationLink(value: s.id) { ChatRow(summary: s) }
                .navigationLinkIndicatorVisibility(.hidden)
                .accessibilityIdentifier("chat.\(s.room.title)")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { s.unread > 0 ? model.markSeen(s.id) : model.markNew(s.id) } label: {
                        Label(s.unread > 0 ? "Gesehen" : "Als neu", systemImage: s.unread > 0 ? "eye.fill" : "envelope.badge.fill")
                    }
                    .tint(.blue)
                    Button { model.setRoomState(s.id, pinned: !s.room.pinned) } label: {
                        Label(s.room.pinned ? "Lösen" : "Anheften", systemImage: s.room.pinned ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(Theme.pinned)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { confirmDelete = s } label: { Label("Löschen", systemImage: "trash") }
                    Button { model.setRoomState(s.id, archived: !s.room.archived) } label: {
                        Label(s.room.archived ? "Zurückholen" : "Archivieren", systemImage: s.room.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
                    }
                    .tint(.gray)
                }
                .contextMenu { RoomMenu(summary: s) { confirmDelete = s } }
        }
        if archivedCount > 0 {
            NavigationLink {
                ChatListView(archived: true, onOpen: onOpen)
            } label: {
                HStack {
                    Text("Archivierte Chats").foregroundStyle(Theme.accent)
                    Spacer()
                    Text("\(archivedCount)").foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden, edges: .bottom)
        }
    }
}

/// Kontextmenü eines Chats (iPhone lange drücken, Mac Rechtsklick).
struct RoomMenu: View {
    @Environment(AppModel.self) private var model
    let summary: RoomSummary
    var onDelete: () -> Void

    var body: some View {
        let s = summary
        Button { model.setRoomState(s.id, pinned: !s.room.pinned) } label: {
            Label(s.room.pinned ? "Lösen" : "Anheften", systemImage: s.room.pinned ? "pin.slash" : "pin")
        }
        Button { s.unread > 0 ? model.markSeen(s.id) : model.markNew(s.id) } label: {
            Label(s.unread > 0 ? "Als gesehen markieren" : "Als neu markieren", systemImage: "envelope.badge")
        }
        Button { model.setRoomState(s.id, archived: !s.room.archived) } label: {
            Label(s.room.archived ? "Zurückholen" : "Archivieren", systemImage: "archivebox")
        }
        Divider()
        Button(role: .destructive, action: onDelete) { Label("Löschen", systemImage: "trash") }
    }
}

extension AppModel {
    /// „Ich“ bzw. Name des Verfassers vor der Vorschau – wie in Gruppen eines Messengers.
    func previewPrefix(_ s: RoomSummary) -> String? {
        guard let last = s.last, s.room.kind == .group else { return nil }
        if last.authorId == me { return String(localized: "Ich") }
        return user(last.authorId)?.displayName
    }
}

/// iPhone-Zeile: Avatar 56 mit rotem Zähler, Name fett, rechts Zeit mit Status, darunter zwei Zeilen Vorschau, Pin rechts.
struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let summary: RoomSummary

    var body: some View {
        HStack(alignment: .center, spacing: 15) {
            Avatar(title: summary.room.title, image: summary.room.avatar, isGroup: summary.room.kind == .group, size: 56,
                   colorKey: summary.room.id)
                .overlay(alignment: .topTrailing) {
                    if summary.unread > 0 { UnreadBadge(count: summary.unread).offset(x: 4, y: -2) }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary.room.title).font(.body.weight(.bold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.listDate(summary.sortDate)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    if let last = summary.last, last.authorId == model.me {
                        StatusIcon(message: last).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Group {
                        if let d = summary.draft, !d.isEmpty {
                            Text("Entwurf: ").foregroundStyle(.red) + Text(d)
                        } else if let last = summary.last {
                            PreviewText(message: last, prefix: model.previewPrefix(summary))
                        } else {
                            Text("Noch keine Einträge")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if summary.room.pinned {
                        Image(systemName: "pin.circle.fill").font(.body).foregroundStyle(Theme.pinned)
                            .accessibilityLabel(Text("Angeheftet"))
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Roter Zähler „neu von anderem Gerät“ am Avatar.
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Theme.unread))
            .accessibilityLabel(Text("\(count) neu von anderem Gerät"))
    }
}

/// Kleine Anzeige des Abgleichs: Wolke mit Haken, Pfeilen oder durchgestrichen (offline).
struct SyncBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.syncSoon()
        } label: {
            switch model.syncState {
            case .syncing: Image(systemName: "arrow.triangle.2.circlepath.icloud")
            case .offline: Image(systemName: "icloud.slash").foregroundStyle(.orange)
            case .error: Image(systemName: "exclamationmark.icloud").foregroundStyle(.red)
            case .idle:
                if model.pending > 0 { Image(systemName: "icloud.and.arrow.up") } else { Image(systemName: "checkmark.icloud") }
            }
        }
        .accessibilityLabel(Text(model.statusText))
        .accessibilityIdentifier("sync.badge")
        .help(Text(model.statusText))
    }
}
