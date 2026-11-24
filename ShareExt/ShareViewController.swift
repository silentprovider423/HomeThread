import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// „HomeThread“ im Teilen-Menü anderer Apps (Safari, Karten, Fotos, Dateien …): Chat wählen, optional etwas dazu
/// schreiben, ablegen. Die Erweiterung legt alles in den gemeinsamen Ordner (App-Gruppe); HomeThread übernimmt es
/// beim nächsten Öffnen in den Chat und gleicht ab. So schreibt nur die App in ihre Datenbank.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = switch ShareInbox.appearance { case 1: .light; case 2: .dark; default: .unspecified }
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        model.providers = items.flatMap { $0.attachments ?? [] }
        model.sharedText = items.compactMap { $0.attributedContentText?.string }.filter { !$0.isEmpty }.joined(separator: "\n")
        Task { await model.inspect() }
    }
}

@MainActor @Observable
final class ShareModel {
    enum Part: Hashable { case text(String), url(URL), image, video, file(String) }

    var providers: [NSItemProvider] = []
    var sharedText = ""
    var parts: [Part] = []
    var rooms = ShareInbox.loadRooms()
    var available = ShareInbox.root != nil
    var saving = false
    var error: String?

    /// was geteilt wird (für die Zusammenfassung oben)
    func inspect() async {
        var out: [Part] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { out.append(.video) }
            else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) { out.append(.image) }
            else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let u = await Self.loadURL(p) { out.append(u.isFileURL ? .file(u.lastPathComponent) : .url(u)) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let t = await Self.loadText(p), !t.isEmpty { out.append(.text(t)) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                out.append(.file(p.suggestedName ?? String(localized: "Datei")))
            }
        }
        parts = out
    }

    var summary: String {
        let images = parts.filter { $0 == .image }.count, videos = parts.filter { $0 == .video }.count
        let files = parts.filter { if case .file = $0 { true } else { false } }.count
        var s: [String] = []
        if images > 0 { s.append(images == 1 ? String(localized: "1 Foto") : String(localized: "\(images) Fotos")) }
        if videos > 0 { s.append(videos == 1 ? String(localized: "1 Video") : String(localized: "\(videos) Videos")) }
        if files > 0 { s.append(files == 1 ? String(localized: "1 Datei") : String(localized: "\(files) Dateien")) }
        return s.joined(separator: " · ")
    }

    /// geteilte Texte und Links (Seitentitel aus Safari + Adresse)
    var texts: [String] {
        var t: [String] = []
        let shared = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in parts {
            switch p {
            case .text(let s): t.append(s)
            case .url(let u): t.append(u.absoluteString)
            default: break
            }
        }
        if !shared.isEmpty && !t.contains(where: { $0.contains(shared) }) { t.insert(shared, at: 0) }
        return t
    }

    func save(room: String, comment: String) async -> Bool {
        guard let (id, dir) = ShareInbox.newDropFolder() else { error = String(localized: "Bitte HomeThread einmal öffnen."); return false }
        saving = true
        defer { saving = false }
        var items: [ShareInbox.Item] = []
        for (i, p) in providers.enumerated() {
            let kind: ShareInbox.Item.Kind
            let type: UTType
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) { kind = .video; type = .movie }
            else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) { kind = .image; type = .image }
            else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) || p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                // Dateien aus „Dateien“ kommen als file-URL
                if let u = await Self.loadURL(p), u.isFileURL, let f = Self.copy(u, into: dir, index: i) {
                    items.append(.init(kind: .file, file: f))
                }
                continue
            } else if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) { kind = .file; type = .data }
            else { continue }
            if let f = await Self.file(from: p, type: type, into: dir, index: i) { items.append(.init(kind: kind, file: f)) }
        }
        let text = ([comment.trimmingCharacters(in: .whitespacesAndNewlines)] + texts).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !items.isEmpty || !text.isEmpty else { ShareInbox.remove(dir); error = String(localized: "Nichts zum Ablegen gefunden."); return false }
        let ok = ShareInbox.commit(.init(id: id, room: room, text: text, items: items, created: Date()), dir: dir)
        if !ok { ShareInbox.remove(dir); error = String(localized: "Konnte nicht gespeichert werden.") }
        return ok
    }

    // MARK: Laden aus der fremden App

    private static func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) }
        }
    }

    private static func loadText(_ p: NSItemProvider) async -> String? {
        await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: String.self) { s, _ in c.resume(returning: s) }
        }
    }

    private static func copy(_ u: URL, into dir: URL, index: Int) -> String? {
        let access = u.startAccessingSecurityScopedResource()
        defer { if access { u.stopAccessingSecurityScopedResource() } }
        let name = "\(index)-\(u.lastPathComponent)"
        return (try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent(name))) != nil ? name : nil
    }

    /// Datei holen (Video vor Bild, damit Live-/Bewegtbilder als Video ankommen); notfalls nur Daten
    private static func file(from p: NSItemProvider, type: UTType, into dir: URL, index: Int) async -> String? {
        let preferred = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
        return await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: preferred) { url, _ in
                if let url {
                    // die Datei gehört dem System nur während dieses Rückrufs → kopieren
                    let name = "\(index)-\(url.lastPathComponent)"
                    cont.resume(returning: (try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))) != nil ? name : nil)
                    return
                }
                p.loadDataRepresentation(forTypeIdentifier: preferred) { d, _ in
                    guard let d else { cont.resume(returning: nil); return }
                    let ext = UTType(preferred)?.preferredFilenameExtension ?? "dat"
                    let name = "\(index)-\(p.suggestedName ?? "geteilt").\(ext)"
                    cont.resume(returning: (try? d.write(to: dir.appendingPathComponent(name))) != nil ? name : nil)
                }
            }
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    var done: () -> Void
    var cancel: () -> Void
    @State private var query = ""
    @State private var selected: String?
    @State private var comment = ""

    private var hits: [ShareInbox.RoomEntry] {
        query.isEmpty ? model.rooms : model.rooms.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !model.summary.isEmpty {
                        Label(model.summary, systemImage: "paperclip").foregroundStyle(.secondary)
                    }
                    ForEach(model.texts, id: \.self) { t in
                        Text(t).lineLimit(3).font(.callout).foregroundStyle(.secondary)
                    }
                    TextField("Kommentar hinzufügen …", text: $comment, axis: .vertical)
                        .lineLimit(1...5)
                        .accessibilityIdentifier("share.comment")
                }
                Section("Chat wählen") {
                    if !model.available {
                        Text("Teilen ist in dieser Installation nicht verfügbar (App-Gruppe fehlt).").foregroundStyle(.secondary)
                    } else if model.rooms.isEmpty {
                        Text("Bitte HomeThread einmal öffnen, damit die Chats hier erscheinen.").foregroundStyle(.secondary)
                    }
                    ForEach(hits) { r in
                        Button { selected = r.id } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(ShareTheme.accent.opacity(0.18))
                                    Image(systemName: r.group ? "person.2.fill" : "bubble.left.fill")
                                        .font(.system(size: 13)).foregroundStyle(ShareTheme.accent)
                                }
                                .frame(width: 34, height: 34)
                                Text(r.title).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 0)
                                if selected == r.id { Image(systemName: "checkmark").foregroundStyle(ShareTheme.accent).fontWeight(.semibold) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("share.room")
                        .accessibilityAddTraits(selected == r.id ? .isSelected : [])
                    }
                }
                if let e = model.error {
                    Section { Text(e).foregroundStyle(.red) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Chats durchsuchen"))
            .navigationTitle("HomeThread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.saving { ProgressView() } else {
                        Button("Ablegen") {
                            guard let room = selected else { return }
                            Task { if await model.save(room: room, comment: comment) { done() } }
                        }
                        .fontWeight(.semibold)
                        .disabled(selected == nil)
                        .accessibilityIdentifier("share.send")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Wird beim nächsten Öffnen von HomeThread im Chat abgelegt.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
        .tint(ShareTheme.accent)
    }
}

/// Akzentfarbe wie in der App
enum ShareTheme {
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x36 / 255, green: 0xD5 / 255, blue: 0x88 / 255, alpha: 1)
        : UIColor(red: 0x0B / 255, green: 0x73 / 255, blue: 0x4E / 255, alpha: 1) })
}
