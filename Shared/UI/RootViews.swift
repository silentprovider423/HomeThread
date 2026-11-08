import SwiftUI

/// Ziel beim Öffnen eines Chats (optional mit Sprung zu einem Eintrag).
struct ChatRoute: Hashable {
    var room: String
    var jump: String?
}

#if os(iOS)
/// iPhone: Tabs Chats · Gemerkt · Einstellungen · Suche (Liquid-Glass-Tableiste von iOS 26).
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var path = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: 0) {
                NavigationStack(path: $path) {
                    ChatListView()
                        .navigationDestination(for: String.self) { ChatView(roomId: $0) }
                        .navigationDestination(for: ChatRoute.self) { ChatView(roomId: $0.room, jumpTo: $0.jump) }
                }
            }
            Tab("Gemerkt", systemImage: "star", value: 1) {
                NavigationStack { StarredView(onOpen: open) }
            }
            Tab("Einstellungen", systemImage: "gearshape", value: 2) {
                NavigationStack { SettingsView() }
            }
            Tab(value: 3, role: .search) {
                NavigationStack { GlobalSearchView(onOpen: open) }
            }
        }
        .tint(Theme.accent)
        .onChange(of: model.debugTab) { _, t in if let t { tab = t; model.debugTab = nil } }
        .onChange(of: model.debugOpen, initial: true) { _, t in
            guard let t, let s = model.store?.summaries(myDevice: model.myDevice, archived: false).first(where: { $0.room.title == t }) else { return }
            tab = 0
            path = NavigationPath()
            path.append(s.id)
            model.debugOpen = nil
        }
    }

    private func open(_ room: String, _ message: String) {
        tab = 0
        path = NavigationPath()
        path.append(ChatRoute(room: room, jump: message.isEmpty ? nil : message))
    }
}
#endif

#if os(macOS)
/// Mac: zwei Spalten wie ein Desktop-Messenger – links Chats/Gemerkt/Suche, rechts der Chat, Infos als Inspector (⌘I).
struct MacRoot: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var jump: String?
    @State private var showInfo = false
    @State private var mode = 0
    @State private var query = ""
    @State private var newRoom: NewRoomFlow.Mode?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Chats").tag(0)
                    Text("Gemerkt").tag(1)
                    Text("Archiv").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10).padding(.vertical, 6)
                if !query.isEmpty {
                    MacSearchResults(query: query) { r, m in selection = r; jump = m.isEmpty ? nil : m }
                } else if mode == 1 {
                    List(model.store?.starredMessages() ?? []) { m in
                        Button { selection = m.roomId; jump = m.id } label: { MessageRow(message: m) }.buttonStyle(.plain)
                    }
                    .overlay { if (model.store?.starredMessages() ?? []).isEmpty { ContentUnavailableView("Noch nichts gemerkt", systemImage: "star") } }
                } else {
                    ChatListView(archived: mode == 2, selection: $selection)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("In allen Chats suchen"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 420)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("Neuer Chat") { newRoom = .chat }
                        Button("Neue Gruppe") { newRoom = .group }
                    } label: { Label("Neu", systemImage: "square.and.pencil") }
                }
                ToolbarItem { SyncBadge() }
            }
        } detail: {
            if let selection, model.store?.room(selection) != nil {
                NavigationStack {
                    ChatView(roomId: selection, showInfo: $showInfo, jumpTo: jump)
                        .id(selection + (jump ?? ""))
                }
                .inspector(isPresented: $showInfo) {
                    NavigationStack { RoomInfoView(roomId: selection, onJump: { jump = $0 }) }
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
            } else {
                ContentUnavailableView {
                    Label("Kein Chat ausgewählt", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Wähle links einen Chat oder lege mit ⌘N einen neuen an.")
                }
            }
        }
        .sheet(item: $newRoom) { m in NewRoomFlow(mode: m) { selection = $0 } }
        .onChange(of: model.requestNew) { _, m in if let m { newRoom = m; model.requestNew = nil } }
        .onChange(of: selection) { _, _ in jump = nil }
        .onChange(of: model.debugOpen, initial: true) { _, t in
            guard let t, let s = model.store?.summaries(myDevice: model.myDevice, archived: false).first(where: { $0.room.title == t }) else { return }
            selection = s.id
            model.debugOpen = nil
        }
        .tint(Theme.accent)
    }
}

struct MacSearchResults: View {
    @Environment(AppModel.self) private var model
    let query: String
    var onOpen: (String, String) -> Void

    var body: some View {
        let _ = model.revision
        let rooms = (model.store?.summaries(myDevice: model.myDevice, archived: false) ?? []).filter { $0.room.title.localizedCaseInsensitiveContains(query) }
        let hits = model.store?.search(query) ?? []
        List {
            if !rooms.isEmpty {
                Section("Chats") {
                    ForEach(rooms) { s in Button { onOpen(s.id, "") } label: { ChatRow(summary: s) }.buttonStyle(.plain) }
                }
            }
            Section("Einträge") {
                ForEach(hits) { m in Button { onOpen(m.roomId, m.id) } label: { MessageRow(message: m) }.buttonStyle(.plain) }
            }
        }
        .overlay { if hits.isEmpty && rooms.isEmpty { ContentUnavailableView.search(text: query) } }
    }
}
#endif

/// Gemeinsamer Einstieg: Anmeldung oder Haupt-Oberfläche; Abgleich beim Öffnen und alle 15 s im Vordergrund.
struct AppRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if model.session == nil {
                LoginView()
            } else {
                #if os(iOS)
                PhoneRoot()
                #else
                MacRoot()
                #endif
            }
        }
        .preferredColorScheme(model.colorScheme)
        .tint(Theme.accent)
        .onChange(of: phase, initial: true) { _, p in
            if p == .active && model.session != nil {
                model.syncSoon()
                model.startTimer()
            } else if p != .active {
                model.stopTimer()
            }
        }
        .onChange(of: model.session?.token) { _, t in
            if t != nil && phase == .active { model.startTimer() }
        }
        #if DEBUG
        .task { await DebugLogin.run(model) }
        #endif
    }
}

#if DEBUG
/// Nur Debug-Builds: Anmeldung über die Startumgebung, damit Simulator- und iPhone-Tests ohne Tippen gehen.
///   THREAD_SERVER + THREAD_TOKEN                (Token wird nicht gespeichert)
///   THREAD_SERVER + THREAD_USER + THREAD_PASSWORD + THREAD_TOTP_SECRET
///   THREAD_RESET=1      lokale Daten vorher löschen
///   THREAD_OPEN=<Titel> diesen Chat öffnen (Screenshots)
///   THREAD_APPEARANCE=1|2  hell/dunkel erzwingen
enum DebugLogin {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        // Unit-Tests laufen in der App als Gastgeber – dort meldet sich der Test selbst an
        if env["XCTestConfigurationFilePath"] != nil && env["THREAD_UITEST"] == nil { return }
        if let a = env["THREAD_APPEARANCE"], let v = Int(a) { model.appearance = v }
        guard let server = env["THREAD_SERVER"], !server.isEmpty else { return }
        let reset = env["THREAD_RESET"] == "1"
        if let token = env["THREAD_TOKEN"], !token.isEmpty {
            if model.session?.token != token || reset {
                try? await model.loginWithToken(server: server, token: token, reset: reset)
            }
        } else if let u = env["THREAD_USER"], let p = env["THREAD_PASSWORD"], let sec = env["THREAD_TOTP_SECRET"],
                  model.session?.user.username != u, let code = TOTP.code(secret: sec) {
            try? await model.login(server: server, username: u, password: p, code: code)
        }
        await model.syncNow()
        model.debugShowInfo = env["THREAD_SHOW"] == "info"
        if let open = env["THREAD_OPEN"], !open.isEmpty { model.debugOpen = open }
        if let show = env["THREAD_SHOW"] { model.debugTab = ["starred": 1, "settings": 2, "search": 3][show] }
    }
}
#endif
