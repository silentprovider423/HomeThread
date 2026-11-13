import SwiftUI

/// Ziel beim Öffnen eines Chats (optional mit Sprung zu einem Eintrag).
nonisolated struct ChatRoute: Hashable, Sendable {
    var room: String
    var jump: String?
}

#if os(iOS)
/// iPhone: klassische Tab-Leiste unten (Chats · Gemerkt · Einstellungen), deckend statt Glas; im geöffneten Chat ausgeblendet.
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var path = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case 1:
                    NavigationStack { StarredView(onOpen: open) }
                case 2:
                    NavigationStack { SettingsView() }
                default:
                    NavigationStack(path: $path) {
                        ChatListView(onOpen: open)
                            .navigationDestination(for: String.self) { ChatView(roomId: $0) }
                            .navigationDestination(for: ChatRoute.self) { ChatView(roomId: $0.room, jumpTo: $0.jump) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            if !(tab == 0 && !path.isEmpty) {
                PhoneTabBar(tab: $tab, unread: model.summaries(archived: false).reduce(0) { $0 + ($1.unread > 0 ? 1 : 0) })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: path.isEmpty)
        .tint(Theme.accent)
        .onChange(of: model.debugTab) { _, t in if let t { tab = t; model.debugTab = nil } }
        .onChange(of: model.openRequest) { _, r in
            if let r { open(r.room, r.jump ?? ""); model.openRequest = nil }
        }
        .onChange(of: model.debugOpen, initial: true) { _, t in
            guard let t, let s = model.summaries(archived: false).first(where: { $0.room.title == t }) else { return }
            tab = 0
            path = NavigationPath()
            path.append(s.id)
            model.debugOpen = nil
        }
    }

    private func open(_ room: String, _ message: String) {
        tab = 0
        path = NavigationPath()
        if message.isEmpty { path.append(room) } else { path.append(ChatRoute(room: room, jump: message)) }
    }
}

/// Deckende Tab-Leiste mit Symbol + Beschriftung, gewählter Tab in Akzentfarbe, Zähler am Chats-Symbol.
struct PhoneTabBar: View {
    @Binding var tab: Int
    var unread: Int

    var body: some View {
        HStack(spacing: 0) {
            item(0, "Chats", "bubble.left.and.bubble.right.fill", badge: unread)
            item(1, "Gemerkt", "star.fill")
            item(2, "Einstellungen", "gearshape.fill")
        }
        .padding(.top, 6)
        .background(Theme.tabBar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
    }

    private func item(_ i: Int, _ title: LocalizedStringKey, _ icon: String, badge: Int = 0) -> some View {
        Button { tab = i } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 21))
                    .frame(height: 26)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { UnreadBadge(count: badge).scaleEffect(0.85).offset(x: 14, y: -6) }
                    }
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == i ? Theme.accent : Color(white: 0.56))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(i)")
        .accessibilityAddTraits(tab == i ? .isSelected : [])
    }
}
#endif

/// Gemeinsamer Einstieg: Anmeldung oder Haupt-Oberfläche; Abgleich beim Öffnen und alle 15 s im Vordergrund.
struct AppRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var shownNotFound = 0

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
        // Links auf Einträge (homethread://entry/…): im Verlauf angetippt oder von außen geöffnet
        .environment(\.openURL, OpenURLAction { url in model.open(link: url) ? .handled : .systemAction })
        .onOpenURL { model.open(link: $0) }
        .alert("Eintrag nicht gefunden", isPresented: Binding(get: { model.linkNotFound > shownNotFound }, set: { if !$0 { shownNotFound = model.linkNotFound } })) {
            Button("OK") { shownNotFound = model.linkNotFound }
        } message: {
            Text("Der Link zeigt auf einen Eintrag, den es auf diesem Gerät nicht (mehr) gibt.")
        }
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
///   THREAD_PERF_SEED=1  synthetische Leistungsdaten (nur lokal, siehe PerfSeed)
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
        if env["THREAD_PERF_SEED"] == "1" {
            PerfSeed.run(model)
            #if os(iOS)
            FrameMonitor.shared.start()
            #endif
        }
        model.debugShowInfo = env["THREAD_SHOW"] == "info"
        if let open = env["THREAD_OPEN"], !open.isEmpty { model.debugOpen = open }
        if let menu = env["THREAD_MENU"], !menu.isEmpty { model.debugMenu = menu }
        if let n = env["THREAD_NEW"] { model.requestNew = NewRoomFlow.Mode(rawValue: n) }
        if let show = env["THREAD_SHOW"] { model.debugTab = ["starred": 1, "settings": 2][show] }
    }
}
#endif
