import AppKit
import SwiftUI

@main
struct HomeThreadMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("HomeThread", id: "main") {
            AppRoot()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                #if DEBUG
                .task { await Snapshot.runIfRequested() }
                #endif
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Chat") { model.requestNew = .chat }.keyboardShortcut("n")
                Button("Neue Gruppe") { model.requestNew = .group }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Jetzt abgleichen") { model.syncSoon() }.keyboardShortcut("r")
            }
        }
        Settings {
            NavigationStack { SettingsView() }
                .environment(model)
                .frame(width: 480, height: 620)
        }
    }
}

#if DEBUG
/// Nur Debug: THREAD_SNAPSHOT=<pfad.png> rendert nach dem Start das Hauptfenster in eine PNG-Datei (für die README).
enum Snapshot {
    static func runIfRequested() async {
        guard let out = ProcessInfo.processInfo.environment["THREAD_SNAPSHOT"], !out.isEmpty else { return }
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["THREAD_SNAPSHOT_DELAY"] ?? "6") ?? 6))
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let v = w.contentView?.superview ?? w.contentView else { return }
        let rect = v.bounds
        guard let rep = v.bitmapImageRepForCachingDisplay(in: rect) else { return }
        v.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        NSApp.terminate(nil)
    }
}
#endif
