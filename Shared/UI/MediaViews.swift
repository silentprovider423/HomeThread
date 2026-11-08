import AVKit
import SwiftUI

/// Foto oder Video groß anzeigen (lädt das Original bei Bedarf nach).
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: Message
    @State private var url: URL?
    @State private var player: AVPlayer?
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if message.kind == .video {
                    if let player { VideoPlayer(player: player).ignoresSafeArea(edges: .bottom) } else { ProgressView().tint(.white) }
                } else if let url {
                    LocalImage(url: url, maxPixel: 3000, contentMode: .fit)
                        .scaleEffect(scale)
                        .gesture(MagnifyGesture().onChanged { scale = max(1, min(5, $0.magnification)) }.onEnded { _ in
                            withAnimation { if scale < 1.2 { scale = 1 } }
                        })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                } else {
                    // Vorschau zeigen, bis das Original da ist
                    LocalImage(url: message.thumb.flatMap { model.store?.fileURL($0) }, maxPixel: 800, contentMode: .fit)
                        .overlay(ProgressView().tint(.white))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { player?.pause(); dismiss() } }
                if let url {
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: url) }
                }
            }
            #if os(iOS)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(message.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .task {
            guard let a = message.attachment else { return }
            url = await model.ensureFile(id: a, name: message.payload.filename ?? (message.kind == .video ? "video.mov" : "foto.jpg"),
                                         mime: message.payload.mime ?? "application/octet-stream")
            if message.kind == .video, let url {
                player = AVPlayer(url: url)
                player?.play()
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
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
