import AVFoundation
import SwiftUI
#if os(iOS)
import Photos
import UIKit
#endif

/// Foto oder Video, das noch nicht abgelegt ist (Vorschau vor dem Senden).
struct PendingMedia: Identifiable {
    enum Kind { case image(Data), video(URL) }
    let id = UUID()
    var kind: Kind
    var caption = ""
}

/// Vorschau vor dem Ablegen: Fotos/Videos durchblättern, je Eintrag eine Bildunterschrift, einzelne entfernen,
/// dann alle ablegen.
struct MediaComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var items: [PendingMedia]
    var onSend: ([PendingMedia]) -> Void
    @State private var current: UUID?
    @FocusState private var captionFocused: Bool

    private var index: Int { items.firstIndex { $0.id == current } ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pages
                if items.count > 1 { strip.padding(.vertical, 8) }
                captionField
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(items.count > 1 ? String(localized: "\(index + 1) von \(items.count)") : String(localized: "Vorschau"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(items.count > 1 ? String(localized: "Ablegen (\(items.count))") : String(localized: "Ablegen")) {
                        let list = items
                        dismiss()
                        onSend(list)
                    }
                    .disabled(items.isEmpty)
                    .accessibilityIdentifier("compose.send")
                }
                if items.count > 1 {
                    ToolbarItem(placement: .destructiveAction) {
                        Button { remove(at: index) } label: { Image(systemName: "trash") }
                            .accessibilityLabel(Text("Entfernen"))
                    }
                }
            }
        }
        .onAppear { current = items.first?.id }
        #if os(macOS)
        .frame(width: 640, height: 560)
        #endif
    }

    @ViewBuilder private var pages: some View {
        #if os(iOS)
        TabView(selection: $current) {
            ForEach(items) { m in page(m).tag(Optional(m.id)) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        if items.indices.contains(index) {
            page(items[index]).id(items[index].id)
                .overlay(alignment: .leading) { arrow("chevron.left", -1) }
                .overlay(alignment: .trailing) { arrow("chevron.right", 1) }
        }
        #endif
    }

    private func page(_ m: PendingMedia) -> some View {
        PendingMediaView(media: m, maxPixel: 2000)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { captionFocused = false }
    }

    #if os(macOS)
    @ViewBuilder private func arrow(_ icon: String, _ d: Int) -> some View {
        if items.indices.contains(index + d) {
            Button { current = items[index + d].id } label: {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain).padding(12)
        }
    }
    #endif

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { m in
                    PendingMediaView(media: m, maxPixel: 200, fill: true)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(m.id == current ? Theme.accent : .clear, lineWidth: 2))
                        .onTapGesture { current = m.id }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var captionField: some View {
        HStack {
            if items.indices.contains(index) {
                TextField("Bildunterschrift hinzufügen …", text: $items[index].caption, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($captionFocused)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.12)))
                    .accessibilityIdentifier("compose.caption")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10).padding(.top, 4)
    }

    private func remove(at i: Int) {
        guard items.indices.contains(i) else { return }
        items.remove(at: i)
        if items.isEmpty { dismiss() } else { current = items[min(i, items.count - 1)].id }
    }
}

/// Bild bzw. erstes Videobild eines noch nicht abgelegten Eintrags
struct PendingMediaView: View {
    let media: PendingMedia
    var maxPixel = 1200
    var fill = false
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                ProgressView().tint(.white)
            }
            if case .video = media.kind {
                Image(systemName: "play.circle.fill").font(.system(size: fill ? 16 : 44)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .task(id: media.id) {
            switch media.kind {
            case .image(let d):
                let px = maxPixel
                image = await Task.detached { Media.cgImage(data: d, maxPixel: px) }.value
            case .video(let u):
                if let t = await Media.videoInfo(u).thumb { image = Media.cgImage(data: t, maxPixel: maxPixel) }
            }
        }
    }
}

#if os(iOS)
/// Neueste Fotos/Videos für den Streifen im Anhang-Menü; Auswahl in Tipp-Reihenfolge (höchstens 10).
@MainActor @Observable
final class RecentPhotos {
    var assets: [PHAsset] = []
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var picked: [String] = []
    var loading = false

    var allowed: Bool { status == .authorized || status == .limited }

    func start() { if allowed && assets.isEmpty { fetch() } }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if allowed { fetch() }
    }

    func toggle(_ a: PHAsset) {
        if let i = picked.firstIndex(of: a.localIdentifier) { picked.remove(at: i) } else if picked.count < 10 { picked.append(a.localIdentifier) }
    }

    private func fetch() {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.fetchLimit = 40
        o.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let r = PHAsset.fetchAssets(with: o)
        var list: [PHAsset] = []
        r.enumerateObjects { a, _, _ in list.append(a) }
        assets = list
    }

    /// gewählte Einträge laden (Original, notfalls aus iCloud)
    func load() async -> [PendingMedia] {
        loading = true
        defer { loading = false }
        let byID = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [PendingMedia] = []
        for id in picked {
            guard let a = byID[id] else { continue }
            if a.mediaType == .video, let u = await Self.videoFile(a) { out.append(PendingMedia(kind: .video(u))) }
            else if let d = await Self.imageData(a) { out.append(PendingMedia(kind: .image(d))) }
        }
        return out
    }

    private static func imageData(_ a: PHAsset) async -> Data? {
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true
        o.deliveryMode = .highQualityFormat
        o.version = .current
        return await withCheckedContinuation { c in
            PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { d, _, _, _ in c.resume(returning: d) }
        }
    }

    private static func videoFile(_ a: PHAsset) async -> URL? {
        let res = PHAssetResource.assetResources(for: a)
        guard let r = res.first(where: { $0.type == .fullSizeVideo }) ?? res.first(where: { $0.type == .video }) else { return nil }
        let ext = (r.originalFilename as NSString).pathExtension
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
        let o = PHAssetResourceRequestOptions()
        o.isNetworkAccessAllowed = true
        return await withCheckedContinuation { c in
            PHAssetResourceManager.default().writeData(for: r, toFile: dest, options: o) { err in c.resume(returning: err == nil ? dest : nil) }
        }
    }
}

/// Streifen mit den neuesten Fotos/Videos: vorne Kamera, antippen wählt aus (Nummer = Reihenfolge).
struct RecentPhotosStrip: View {
    let photos: RecentPhotos
    var onCamera: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button(action: onCamera) {
                    Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                        .frame(width: 84, height: 84)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chatBarField))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Foto oder Video aufnehmen"))
                if photos.allowed {
                    ForEach(photos.assets, id: \.localIdentifier) { a in tile(a) }
                } else if photos.status == .notDetermined {
                    Button("Letzte Fotos zeigen") { Task { await photos.requestAccess() } }
                        .font(.callout).padding(.horizontal, 12)
                        .accessibilityIdentifier("attach.strip.allow")
                } else {
                    Text("Kein Zugriff auf Fotos").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)
                }
            }
        }
        .frame(height: 84)
        .onAppear { photos.start() }
    }

    private func tile(_ a: PHAsset) -> some View {
        let n = photos.picked.firstIndex(of: a.localIdentifier).map { $0 + 1 }
        return Button { photos.toggle(a) } label: {
            AssetThumb(asset: a)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(n != nil ? Theme.accent : .black.opacity(0.25))
                        Circle().strokeBorder(.white, lineWidth: 1.5)
                        if let n { Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white) }
                    }
                    .frame(width: 22, height: 22).padding(5)
                }
                .overlay(alignment: .bottomLeading) {
                    if a.mediaType == .video {
                        Text(Fmt.duration(a.duration)).font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                            .padding(5).shadow(radius: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(a.mediaType == .video ? "Video" : "Foto"))
        .accessibilityAddTraits(n != nil ? .isSelected : [])
        .accessibilityIdentifier("attach.strip.item")
    }
}

private struct AssetThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: asset.localIdentifier) {
            let o = PHImageRequestOptions()
            o.deliveryMode = .opportunistic
            o.isNetworkAccessAllowed = true
            o.resizeMode = .fast
            let size = CGSize(width: 240, height: 240)
            for await img in Self.images(asset, size, o) { image = img }
        }
    }

    private static func images(_ a: PHAsset, _ size: CGSize, _ o: PHImageRequestOptions) -> AsyncStream<UIImage> {
        AsyncStream { cont in
            let id = PHImageManager.default().requestImage(for: a, targetSize: size, contentMode: .aspectFill, options: o) { img, info in
                if let img { cont.yield(img) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.finish() }
            }
            cont.onTermination = { _ in PHImageManager.default().cancelImageRequest(id) }
        }
    }
}
#endif
