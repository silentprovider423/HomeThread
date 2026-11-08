import SwiftUI

/// Chat-Liste: Angeheftete oben, dann nach letztem Eintrag; Wischen zum Anheften/Archivieren/Löschen.
struct ChatListView: View {
    @Environment(AppModel.self) private var model
    var archived = false
    /// Mac: Auswahl in der Seitenleiste. iPhone: nil → NavigationLink.
    var selection: Binding<String?>?
    @State private var showNew: NewRoomFlow.Mode?
    @State private var confirmDelete: RoomSummary?

    var body: some View {
        let _ = model.revision
        let rows = model.store?.summaries(myDevice: model.myDevice, archived: archived) ?? []
        let archivedCount = archived ? 0 : (model.store?.archivedCount() ?? 0)
        Group {
            if let selection {
                List(selection: selection) { content(rows, archivedCount) }
            } else {
                List { content(rows, archivedCount) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty && archivedCount == 0 {
                ContentUnavailableView {
                    Label(archived ? "Archiv ist leer" : "Noch keine Chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(archived ? "Archivierte Chats erscheinen hier." : "Lege einen Chat oder eine Gruppe an – zum Beispiel „Einkauf“, „Ideen“ oder „Urlaub“.")
                } actions: {
                    if !archived {
                        Button("Neuer Chat") { showNew = .chat }.htGlassButton(prominent: true)
                    }
                }
            }
        }
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
        .sheet(item: $showNew) { mode in
            NewRoomFlow(mode: mode) { id in
                if let selection { selection.wrappedValue = id } else { pendingOpen = id }
            }
        }
        .confirmationDialog("Chat löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { s in
            Button("„\(s.room.title)“ mit allen Einträgen löschen", role: .destructive) { model.deleteRoom(s.room.id) }
        } message: { _ in
            Text("Der Chat wird auf allen deinen Geräten und auf dem Server gelöscht.")
        }
        .navigationDestination(item: $pendingOpen) { id in ChatView(roomId: id) }
    }

    @State private var pendingOpen: String?

    @ViewBuilder
    private func content(_ rows: [RoomSummary], _ archivedCount: Int) -> some View {
        ForEach(rows) { s in
            Group {
                if selection != nil {
                    ChatRow(summary: s).tag(s.id)
                } else {
                    NavigationLink(value: s.id) { ChatRow(summary: s) }
                }
            }
            .accessibilityIdentifier("chat.\(s.room.title)")
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { s.unread > 0 ? model.markSeen(s.id) : model.markNew(s.id) } label: {
                    Label(s.unread > 0 ? "Gesehen" : "Als neu", systemImage: s.unread > 0 ? "checkmark.message" : "message.badge")
                }
                .tint(Theme.accent)
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
            .contextMenu { roomMenu(s) }
        }
        if archivedCount > 0 {
            NavigationLink {
                ChatListView(archived: true)
            } label: {
                HStack {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                    Text("Archiv")
                    Spacer()
                    Text("\(archivedCount)").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func roomMenu(_ s: RoomSummary) -> some View {
        Button { model.setRoomState(s.id, pinned: !s.room.pinned) } label: {
            Label(s.room.pinned ? "Lösen" : "Anheften", systemImage: s.room.pinned ? "pin.slash" : "pin")
        }
        Button { s.unread > 0 ? model.markSeen(s.id) : model.markNew(s.id) } label: {
            Label(s.unread > 0 ? "Als gesehen markieren" : "Als neu markieren", systemImage: "message.badge")
        }
        Button { model.setRoomState(s.id, archived: !s.room.archived) } label: {
            Label(s.room.archived ? "Zurückholen" : "Archivieren", systemImage: "archivebox")
        }
        Divider()
        Button(role: .destructive) { confirmDelete = s } label: { Label("Löschen", systemImage: "trash") }
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let summary: RoomSummary

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Avatar(title: summary.room.title, image: summary.room.avatar, isGroup: summary.room.kind == .group, size: 54,
                       colorKey: summary.room.id)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    if summary.room.kind == .group {
                        Image(systemName: "person.2.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(summary.room.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if summary.last?.pending == true {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Fmt.listDate(summary.sortDate)).font(.footnote).foregroundStyle(summary.unread > 0 ? Theme.accent : .secondary)
                        .monospacedDigit()
                }
                HStack(alignment: .top) {
                    Group {
                        if let d = summary.draft, !d.isEmpty {
                            Text("Entwurf: ").foregroundStyle(.red) + Text(d)
                        } else {
                            if let last = summary.last { PreviewText(message: last) } else { Text("Noch keine Einträge") }
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 6)
                    VStack(spacing: 4) {
                        if summary.unread > 0 {
                            Text(summary.unread > 99 ? "99+" : "\(summary.unread)")
                                .font(.caption.weight(.bold)).monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                                .background(Capsule().fill(Theme.accent))
                                .accessibilityLabel(Text("\(summary.unread) neu von anderem Gerät"))
                        }
                        if summary.room.pinned {
                            Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.pinned).rotationEffect(.degrees(45))
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Kleine Anzeige des Abgleichs oben links: Wolke mit Haken, Pfeilen oder durchgestrichen (offline).
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

    var statusText: String { model.statusText }
}
