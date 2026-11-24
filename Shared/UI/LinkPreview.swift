import CryptoKit
import OSLog
import LinkPresentation
import SwiftUI

/// Vorschau eines Links (Titel, Seite, Bild) – wie im Messenger unter Einträgen mit Link. Wird auf dem Gerät von der
/// verlinkten Seite geholt (abschaltbar in den Einstellungen) und dauerhaft zwischengespeichert, damit sie beim
/// Scrollen sofort da ist und nicht jedes Mal neu lädt.
nonisolated struct LinkPreviewData: Codable, Hashable, Sendable {
    var title: String?
    var host: String
    /// lokal gespeichertes Vorschaubild
    var image: String?
}

@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()

    private var memory: [String: LinkPreviewData] = [:]
    /// Seiten, die keine Vorschau lieferten (nur für diesen Start)
    private var failed: Set<String> = []
    private var inflight: [String: Task<LinkPreviewData?, Never>] = [:]

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeThread/LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// schon bekannt (ohne Netz)
    func cached(_ url: URL) -> LinkPreviewData? {
        let k = key(url)
        if let p = memory[k] { return p }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(k + ".json")),
              let p = try? JSONDecoder().decode(LinkPreviewData.self, from: d) else { return nil }
        memory[k] = p
        return p
    }

    func imageURL(_ p: LinkPreviewData) -> URL? { p.image.map { dir.appendingPathComponent($0) } }

    func load(_ url: URL) async -> LinkPreviewData? {
        if let p = cached(url) { return p }
        let k = key(url)
        if failed.contains(k) { return nil }
        if let t = inflight[k] { return await t.value }
        let dir = self.dir
        let t = Task<LinkPreviewData?, Never> { @MainActor in
            let provider = LPMetadataProvider()
            provider.timeout = 12
            let meta: LPLinkMetadata
            do { meta = try await provider.startFetchingMetadata(for: url) } catch {
                Logger(subsystem: "org.homeroll.thread", category: "linkpreview").error("Vorschau fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            var p = LinkPreviewData(title: meta.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                                    host: (meta.url ?? url).host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
            if let ip = meta.imageProvider ?? meta.iconProvider, let data = await Self.imageData(ip),
               let cg = Media.cgImage(data: data, maxPixel: 600), let jpg = Media.jpeg(cg, quality: 0.8) {
                try? jpg.write(to: dir.appendingPathComponent(k + ".jpg"))
                p.image = k + ".jpg"
            }
            guard p.title?.isEmpty == false || p.image != nil else { return nil }
            if let d = try? JSONEncoder().encode(p) { try? d.write(to: dir.appendingPathComponent(k + ".json")) }
            return p
        }
        inflight[k] = t
        let p = await t.value
        inflight[k] = nil
        if let p { memory[k] = p } else { failed.insert(k) }
        return p
    }

    private static func imageData(_ ip: NSItemProvider) async -> Data? {
        await withCheckedContinuation { c in
            ip.loadDataRepresentation(forTypeIdentifier: "public.image") { d, _ in c.resume(returning: d) }
        }
    }

    /// erster Web-Link in einem formatierten Text (Links auf andere Einträge zählen nicht)
    static func firstWebLink(_ text: AttributedString) -> URL? {
        for run in text.runs {
            if let u = run.link, let s = u.scheme?.lowercased(), s == "http" || s == "https" { return u }
        }
        return nil
    }
}

/// Karte unter dem Text: Bild (falls vorhanden), Titel, Seite. Tippen öffnet den Link.
struct LinkPreviewCard: View {
    let url: URL
    @State private var data: LinkPreviewData?
    @Environment(\.openURL) private var openURL

    init(url: URL) {
        self.url = url
        _data = State(initialValue: LinkPreviewStore.shared.cached(url))
    }

    var body: some View {
        // nie ganz leer: eine leere Ansicht startet ihr `.task` nicht
        ZStack {
            if let data {
                Button { openURL(url) } label: { card(data) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("linkPreview")
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .task(id: url) {
            if data == nil { data = await LinkPreviewStore.shared.load(url) }
        }
    }

    private func card(_ p: LinkPreviewData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let img = LinkPreviewStore.shared.imageURL(p) {
                LocalImage(url: img, maxPixel: 600, contentMode: .fill)
                    .frame(height: 130)
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                if let t = p.title, !t.isEmpty {
                    Text(t).font(.callout.weight(.semibold)).foregroundStyle(Theme.text1Bubble).lineLimit(2)
                }
                Text(p.host).font(.caption).foregroundStyle(Theme.metaText).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 300)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
