import LocalAuthentication
import PhotosUI
import SwiftUI
import UserNotifications

// MARK: - App-Sperre (Face ID / Touch ID / Gerätecode)

/// Sperrt die App beim Verlassen; beim Zurückkommen entsperrt Face ID, Touch ID oder der Gerätecode.
@MainActor @Observable
final class AppLock {
    static let shared = AppLock()

    var enabled: Bool = UserDefaults.standard.bool(forKey: "appLock") {
        didSet { UserDefaults.standard.set(enabled, forKey: "appLock"); if !enabled { locked = false } }
    }
    /// ab Start gesperrt, wenn eingeschaltet
    var locked: Bool = UserDefaults.standard.bool(forKey: "appLock")
    private var asking = false

    /// Name der Methode für Einstellungen und Knopf („Face ID“, „Touch ID“, „Code“)
    var methodName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "Code")
        }
    }

    func lockIfEnabled() { if enabled { locked = true } }

    func unlock() {
        guard locked, !asking else { return }
        asking = true
        let c = LAContext()
        c.localizedCancelTitle = String(localized: "Abbrechen")
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "HomeThread entsperren")) { ok, _ in
            Task { @MainActor in
                self.asking = false
                if ok { self.locked = false }
            }
        }
    }

    /// Einschalten nur, wenn die Bestätigung gerade klappt (sonst sperrt man sich aus)
    func enable(_ on: Bool) {
        guard on else { enabled = false; return }
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "App-Sperre einschalten")) { ok, _ in
            Task { @MainActor in if ok { self.enabled = true; self.locked = false } }
        }
    }
}

/// Deckt die App ab, solange sie gesperrt ist.
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("HomeThread ist gesperrt").font(.title3.weight(.semibold))
                Button { lock.unlock() } label: {
                    Label("Mit \(lock.methodName) entsperren", systemImage: lock.methodName == "Face ID" ? "faceid" : "touchid")
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.accent.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("lock.unlock")
            }
        }
        .onAppear { lock.unlock() }
    }
}

// MARK: - Erinnerungen

/// Lokale Erinnerung an einen Eintrag (nur dieses Gerät). Tippen auf die Mitteilung öffnet den Eintrag.
enum Reminders {
    static func schedule(_ m: Message, roomTitle: String, at date: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return false }
        let c = UNMutableNotificationContent()
        c.title = roomTitle
        c.body = String(m.preview.prefix(180))
        c.sound = .default
        c.userInfo = ["link": EntryLink.make(m).absoluteString]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let req = UNNotificationRequest(identifier: "reminder.\(m.id)", content: c,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do { try await center.add(req); return true } catch { return false }
    }

    /// offene Erinnerung eines Eintrags (für Menü und Anzeige)
    static func pending(for id: String) async -> Date? {
        let reqs = await UNUserNotificationCenter.current().pendingNotificationRequests()
        guard let t = reqs.first(where: { $0.identifier == "reminder.\(id)" })?.trigger as? UNCalendarNotificationTrigger else { return nil }
        return t.nextTriggerDate()
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["reminder.\(id)"])
    }
}

/// Mitteilungen auch im Vordergrund zeigen; Antippen öffnet den Eintrag.
final class ReminderDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ReminderDelegate()
    var open: (URL) -> Void = { _ in }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let s = r.notification.request.content.userInfo["link"] as? String, let u = URL(string: s) else { return }
        await MainActor.run { open(u) }
    }
}

/// „Erinnern …“: schnelle Zeiten oder eigener Zeitpunkt.
struct ReminderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let message: Message
    let roomTitle: String
    var onDone: (String) -> Void = { _ in }
    @State private var custom = Date().addingTimeInterval(3600)
    @State private var existing: Date?

    private var presets: [(LocalizedStringKey, Date)] {
        let cal = Calendar.current, now = Date()
        let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now)!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!)!
        let nextWeek = cal.date(byAdding: .day, value: 7, to: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!)!
        var out: [(LocalizedStringKey, Date)] = [("In 1 Stunde", now.addingTimeInterval(3600))]
        if evening > now.addingTimeInterval(1800) { out.append(("Heute Abend (18:00)", evening)) }
        out += [("Morgen früh (9:00)", tomorrow), ("In einer Woche", nextWeek)]
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                if let existing {
                    Section {
                        Label("Erinnerung am \(existing.formatted(date: .abbreviated, time: .shortened))", systemImage: "bell.fill")
                        Button("Erinnerung entfernen", role: .destructive) { Reminders.cancel(message.id); dismiss() }
                    }
                }
                Section {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                        Button { set(p.1) } label: {
                            HStack {
                                Text(p.0).foregroundStyle(.primary)
                                Spacer()
                                Text(p.1.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    DatePicker("Zeitpunkt", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Button("Zu diesem Zeitpunkt erinnern") { set(custom) }
                } footer: {
                    Text("Die Erinnerung kommt als Mitteilung auf diesem Gerät. Antippen öffnet den Eintrag.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Erinnern")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { existing = await Reminders.pending(for: message.id) }
        }
        #if os(macOS)
        .frame(width: 420, height: 440)
        #endif
    }

    private func set(_ date: Date) {
        Task {
            let ok = await Reminders.schedule(message, roomTitle: roomTitle, at: date)
            onDone(ok ? String(localized: "Erinnerung: \(date.formatted(date: .abbreviated, time: .shortened))")
                      : String(localized: "Mitteilungen sind ausgeschaltet – erlaube sie in den Einstellungen."))
            dismiss()
        }
    }
}

// MARK: - Hintergrundbild je Chat (nur auf diesem Gerät)

enum Wallpaper {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeThread/wallpapers", isDirectory: true)
    }

    static func url(room: String) -> URL? {
        let u = dir.appendingPathComponent("\(room).jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func set(room: String, data: Data?) {
        let u = dir.appendingPathComponent("\(room).jpg")
        guard let data else { try? FileManager.default.removeItem(at: u); return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // verkleinert ablegen (Bildschirmgröße reicht)
        let jpg = Media.cgImage(data: data, maxPixel: 2400).flatMap { Media.jpeg($0) } ?? data
        try? jpg.write(to: u, options: .atomic)
    }
}

/// Hintergrund des Verlaufs: eigenes Bild (abgedunkelt, damit die Bubbles lesbar bleiben) oder die Standardfarbe.
struct ChatBackground: View {
    let room: String
    var version = 0

    var body: some View {
        if let u = Wallpaper.url(room: room) {
            GeometryReader { g in
                LocalImage(url: u, maxPixel: 2400, contentMode: .fill)
                    .frame(width: g.size.width, height: g.size.height)
                    .clipped()
                    .overlay(Theme.chatBackground.opacity(0.35))
            }
            .ignoresSafeArea()
            .id("\(u.path)-\(version)")
        } else {
            Theme.chatBackground
        }
    }
}

/// Einstellung in der Chat-Info: Bild wählen / entfernen.
struct WallpaperRow: View {
    let roomId: String
    var onChange: () -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label("Hintergrundbild wählen …", systemImage: "photo")
        }
        .onChange(of: item) { _, i in
            Task {
                if let d = try? await i?.loadTransferable(type: Data.self) { Wallpaper.set(room: roomId, data: d); onChange() }
                item = nil
            }
        }
        if Wallpaper.url(room: roomId) != nil {
            Button("Hintergrundbild entfernen", role: .destructive) { Wallpaper.set(room: roomId, data: nil); onChange() }
        }
    }
}

// MARK: - Dokument scannen (iPhone)

#if os(iOS)
import PDFKit
import VisionKit

struct DocumentScanner: UIViewControllerRepresentable {
    /// fertiges PDF (temporäre Datei)
    var onPDF: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ p: DocumentScanner) { parent = p }

        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pdf = PDFDocument()
            for i in 0..<scan.pageCount {
                if let page = PDFPage(image: scan.imageOfPage(at: i)) { pdf.insert(page, at: pdf.pageCount) }
            }
            let name = "Scan \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).pdf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            if pdf.write(to: url) { parent.onPDF(url) }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) { parent.dismiss() }
        func documentCameraViewController(_ c: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
    }
}
#endif
