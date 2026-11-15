import AVKit
import SwiftUI

/// Fotos und Videos eines Raums groß anzeigen: beginnt beim angetippten Eintrag, links/rechts wischen blättert
/// (Mac: Pfeiltasten bzw. Knöpfe), Fotos zoomen und verschieben, nach unten wischen schließt (iPhone).
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: Message
    @State private var items: [Message] = []
    @State private var current: String?

    private var shown: Message { items.first { $0.id == current } ?? message }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if items.isEmpty {
                    MediaPage(message: message, onDismiss: { dismiss() })
                } else {
                    #if os(iOS)
                    TabView(selection: $current) {
                        ForEach(items) { m in MediaPage(message: m, active: current == m.id, onDismiss: { dismiss() }).tag(Optional(m.id)) }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea(edges: .bottom)
                    #else
                    MediaPage(message: shown, onDismiss: { dismiss() }).id(shown.id)
                        .overlay(alignment: .leading) { arrow("chevron.left", step: -1) }
                        .overlay(alignment: .trailing) { arrow("chevron.right", step: 1) }
                    #endif
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if let url = shown.attachment.flatMap({ model.store?.fileURL($0) }) {
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
                }
            }
            #if os(iOS)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(title)
        }
        .task {
            // Medien des Raums in Verlaufsreihenfolge (älteste zuerst)
            let list = (model.store?.messages(room: message.roomId, kinds: [.image, .video]) ?? []).reversed()
                .filter { $0.payload.missing != true }
            items = list.contains { $0.id == message.id } ? Array(list) : [message]
            current = message.id
        }
        #if os(macOS)
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .frame(minWidth: 640, idealWidth: 900, maxWidth: .infinity, minHeight: 480, idealHeight: 640, maxHeight: .infinity)
        #endif
    }

    private var title: String {
        let date = shown.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard items.count > 1, let i = items.firstIndex(where: { $0.id == shown.id }) else { return date }
        return "\(i + 1) / \(items.count) · " + date
    }

    private func step(_ d: Int) {
        guard let i = items.firstIndex(where: { $0.id == shown.id }), items.indices.contains(i + d) else { return }
        current = items[i + d].id
    }

    #if os(macOS)
    @ViewBuilder private func arrow(_ icon: String, step d: Int) -> some View {
        let i = items.firstIndex { $0.id == shown.id } ?? 0
        if items.indices.contains(i + d) {
            Button { step(d) } label: {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain).padding(16)
        }
    }
    #endif
}

/// Eine Seite des Betrachters: Foto (zoombar) oder Video; lädt das Original bei Bedarf.
private struct MediaPage: View {
    @Environment(AppModel.self) private var model
    let message: Message
    var active = true
    var onDismiss: () -> Void = {}
    @State private var url: URL?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if message.kind == .video {
                if let player { VideoPlayer(player: player) } else { ProgressView().tint(.white) }
            } else if let url {
                ZoomableImage(url: url, onDismiss: onDismiss)
            } else {
                // Vorschau zeigen, bis das Original da ist
                LocalImage(url: message.thumb.flatMap { model.store?.fileURL($0) }, maxPixel: 800, contentMode: .fit)
                    .overlay(ProgressView().tint(.white))
            }
        }
        .task {
            guard let a = message.attachment else { return }
            url = await model.ensureFile(id: a, name: message.payload.filename ?? (message.kind == .video ? "video.mov" : "foto.jpg"),
                                         mime: message.payload.mime ?? "application/octet-stream")
            if message.kind == .video, let url {
                player = AVPlayer(url: url)
                if active { player?.play() }
            }
        }
        .onChange(of: active) { _, a in if !a { player?.pause() } }
        .onDisappear { player?.pause() }
    }
}

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Kamera (Foto oder Video) über UIImagePickerController.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    var onVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.videoQuality = .typeHigh
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let u = info[.mediaURL] as? URL {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(newID()).\(u.pathExtension)")
                try? FileManager.default.copyItem(at: u, to: dest)
                parent.onVideo(dest)
            } else if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.9) {
                parent.onImage(d)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
