import AppKit
import SwiftUI

@main
struct HomeThreadMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("HomeThread", id: "main") {
            AppRoot()
                .environment(model)
                .frame(minWidth: 820, minHeight: 500)
                #if DEBUG
                .task { await Snapshot.runIfRequested() }
                #endif
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
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
        // Hauptfenster nach <pfad>.png, weitere sichtbare Fenster (Aufklapp-Menü, Blätter) nach <pfad>-2.png …
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        for (i, w) in windows.enumerated() {
            guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let path = i == 0 ? out : out.replacingOccurrences(of: ".png", with: "-\(i + 1).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}
#endif
