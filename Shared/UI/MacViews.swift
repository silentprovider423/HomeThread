#if os(macOS)
import SwiftUI

/// Bereiche der schmalen Leiste ganz links.
enum MacSection: Hashable { case chats, starred, archive, settings }

/// Mac-Fenster wie ein Desktop-Messenger: Leiste (92) | Chat-Liste (308, ab 1500 pt Fensterbreite 400) | Chat | Infos (308).
struct MacRoot: View {
    @Environment(AppModel.self) private var model
    @State private var section: MacSection = .chats
    @State private var selection: String?
    @State private var jump: String?
    @State private var showInfo = false
    @State private var query = ""
    @State private var newRoom: NewRoomFlow.Mode?

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                MacRail(section: $section)
                if section == .settings {
                    NavigationStack { SettingsView() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.chatBackground)
                        .padding(.top, 28)
                        .background(Theme.chatBackground)
                } else {
                    navColumn
                        .frame(width: g.size.width >= 1500 ? 400 : 308)
                    Theme.panelGap.frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showInfo, let selection, model.store?.room(selection) != nil {
                        Theme.panelGap.frame(width: 1)
                        NavigationStack {
                            RoomInfoView(roomId: selection, onJump: { jump = $0 })
                        }
                        .frame(width: g.size.width >= 1500 ? 400 : 308)
                        .padding(.top, 28)
                        .background(Theme.chatBackground)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .sheet(item: $newRoom) { m in NewRoomFlow(mode: m) { selection = $0; section = .chats } }
        .onChange(of: model.requestNew) { _, m in if let m { newRoom = m; model.requestNew = nil } }
        .onChange(of: selection) { _, _ in jump = nil }
        .onChange(of: section) { _, s in if s != .settings { query = "" } }
        .onChange(of: model.debugOpen, initial: true) { _, t in
            guard let t, let s = model.summaries(archived: false).first(where: { $0.room.title == t }) else { return }
            section = .chats
            selection = s.id
            model.debugOpen = nil
        }
        .tint(Theme.accent)
    }

    // MARK: Spalte mit Titel, Suche und Liste

    private var navColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                Wordmark()
                HStack(spacing: 6) {
                    Spacer()
                    SyncBadge().buttonStyle(.plain).foregroundStyle(Theme.text2)
                    Menu {
                        Button("Neuer Chat") { newRoom = .chat }
                        Button("Neue Gruppe") { newRoom = .group }
                    } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 14)).foregroundStyle(Theme.text2)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help(Text("Neu"))
                }
                .padding(.trailing, 14)
            }
            .frame(height: 30)
            .padding(.top, 8).padding(.bottom, 14)
            MacSearchField(text: $query)
                .padding(.horizontal, 16).padding(.bottom, 10)
            Group {
                if !query.isEmpty {
                    List {
                        SearchResults(query: query, onOpen: open)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .overlay { if !SearchResults.hasHits(model, query, .all) { ContentUnavailableView.search(text: query) } }
                } else if section == .starred {
                    StarredView(onOpen: open)
                } else {
                    MacChatList(archived: section == .archive, selection: $selection)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.nav)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection, model.store?.room(selection) != nil {
            ChatView(roomId: selection, showInfo: $showInfo, jumpTo: jump)
                .id(selection + (jump ?? ""))
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 64)).foregroundStyle(Theme.text2.opacity(0.25))
                Text("Kein Chat ausgewählt").font(.system(size: 15)).foregroundStyle(Theme.text2)
                Text("Wähle links einen Chat oder lege mit ⌘N einen neuen an.").font(.system(size: 13)).foregroundStyle(Theme.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.chatBackground)
        }
    }

    private func open(_ room: String, _ message: String) {
        section = room.isEmpty ? section : (model.store?.room(room)?.archived == true ? .archive : .chats)
        query = ""
        selection = room
        jump = message.isEmpty ? nil : message
    }
}

/// Schriftzug oben in der Chat-Spalte: zweiteilig, fett + leicht, in Versalien.
struct Wordmark: View {
    var body: some View {
        (Text(verbatim: "HOME").font(.system(size: 19, weight: .heavy)) + Text(verbatim: "THREAD").font(.system(size: 19, weight: .light)))
            .tracking(0.6)
            .foregroundStyle(Theme.text1)
            .accessibilityLabel(Text(verbatim: "HomeThread"))
    }
}

/// Suchfeld „Suchen…“ mit Lupe auf dezent abgesetztem Grund.
struct MacSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.text2)
            TextField("Suchen…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text1)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text2) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Suche leeren"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.searchField))
        .background {
            // ⌘⇧F springt ins Suchfeld
            Button("") { focused = true }.keyboardShortcut("f", modifiers: [.command, .shift]).hidden()
        }
    }
}

/// Leiste ganz links: Chats, Gemerkt, Archiv – unten Einstellungen und das eigene Profilbild.
struct MacRail: View {
    @Environment(AppModel.self) private var model
    @Binding var section: MacSection

    var body: some View {
        VStack(spacing: 18) {
            Color.clear.frame(height: 44) // Platz für die Fensterknöpfe
            item(.chats, "Chats", "message")
            item(.starred, "Gemerkt", "star")
            item(.archive, "Archiv", "archivebox")
            Spacer()
            item(.settings, "Einstellungen", "gearshape")
            if let u = model.session?.user {
                Button { section = .settings } label: {
                    Avatar(title: u.displayName, size: 38, colorKey: u.id, person: true)
                }
                .buttonStyle(.plain)
                .help(Text(u.displayName))
            }
        }
        .padding(.bottom, 18)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .background(Theme.rail)
    }

    private func item(_ s: MacSection, _ title: LocalizedStringKey, _ icon: String) -> some View {
        let on = section == s
        return Button { section = s } label: {
            VStack(spacing: 6) {
                Image(systemName: on ? icon + ".fill" : icon)
                    .font(.system(size: 19))
                    .foregroundStyle(on ? Theme.railIconSelected : Theme.text1)
                    .frame(width: 44, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.railSelected : .clear))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .medium)).foregroundStyle(Theme.text1)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Chat-Liste der Mac-Spalte: nur die sichtbaren Zeilen werden gebaut (LazyVStack), Auswahl schwarz hinterlegt.
struct MacChatList: View {
    @Environment(AppModel.self) private var model
    var archived: Bool
    @Binding var selection: String?
    @State private var confirmDelete: RoomSummary?

    var body: some View {
        let rows = model.summaries(archived: archived)
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { s in
                    MacChatRow(summary: s, selected: selection == s.id)
                        .onTapGesture { selection = s.id }
                        .contextMenu { RoomMenu(summary: s) { confirmDelete = s } }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("chat.\(s.room.title)")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(archived ? "Archiv ist leer" : "Noch keine Chats", systemImage: archived ? "archivebox" : "bubble.left.and.bubble.right",
                                       description: Text(archived ? "Archivierte Chats erscheinen hier." : "Lege mit ⌘N einen Chat oder mit ⇧⌘N eine Gruppe an."))
            }
        }
        .confirmationDialog("Chat löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { s in
            Button("„\(s.room.title)“ mit allen Einträgen löschen", role: .destructive) {
                if selection == s.id { selection = nil }
                model.deleteRoom(s.room.id)
            }
        } message: { _ in
            Text("Der Chat wird auf allen deinen Geräten und auf dem Server gelöscht.")
        }
    }
}

/// Mac-Zeile: Avatar 48, Name, rechts Pin; darunter „Ich: …“ und rechts Zeitstempel mit Status.
struct MacChatRow: View {
    @Environment(AppModel.self) private var model
    let summary: RoomSummary
    var selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Avatar(title: summary.room.title, image: summary.room.avatar, isGroup: summary.room.kind == .group, size: 48,
                   colorKey: summary.room.id)
                .overlay(alignment: .topTrailing) {
                    if summary.unread > 0 { UnreadBadge(count: summary.unread).scaleEffect(0.9).offset(x: 5, y: -3) }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.room.title).font(.system(size: 15, weight: summary.unread > 0 ? .semibold : .regular))
                        .foregroundStyle(Theme.text1).lineLimit(1)
                    Spacer(minLength: 4)
                    if summary.room.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.pinned)
                            .accessibilityLabel(Text("Angeheftet"))
                    }
                }
                HStack(spacing: 6) {
                    Group {
                        if let d = summary.draft, !d.isEmpty {
                            Text("Entwurf: ").foregroundStyle(.red) + Text(d)
                        } else if let last = summary.last {
                            PreviewText(message: last, prefix: model.previewPrefix(summary))
                        } else {
                            Text("Noch keine Einträge")
                        }
                    }
                    .font(.system(size: 14)).foregroundStyle(Theme.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.stamp(summary.sortDate)).font(.system(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    if let last = summary.last, last.authorId == model.me {
                        StatusIcon(message: last).font(.system(size: 10)).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(selected ? Theme.rowSelected : hover ? Theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
#endif
