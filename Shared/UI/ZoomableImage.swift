import SwiftUI

#if os(iOS)
import UIKit

/// Foto in voller Größe wie im Messenger: zwei Finger zoomen (bis 5×), mit einem Finger im gezoomten Bild nach links,
/// rechts, oben und unten schieben, Doppeltippen zoomt an der angetippten Stelle hinein bzw. wieder ganz heraus.
/// Kleinere Bilder bleiben in der Mitte.
struct ZoomableImage: UIViewRepresentable {
    let url: URL
    /// nach unten wischen (ungezoomt) schließt
    var onDismiss: () -> Void = {}

    func makeUIView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.onDismiss = onDismiss
        v.load(url)
        return v
    }

    func updateUIView(_ v: ZoomScrollView, context: Context) {
        v.onDismiss = onDismiss
        if v.url != url { v.load(url) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private(set) var url: URL?
    var onDismiss: () -> Void = {}
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        alwaysBounceVertical = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "media.image"
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) {
        self.url = url
        let image = Media.cgImage(at: url, maxPixel: 4096).map { UIImage(cgImage: $0) }
        imageView.image = image
        lastSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, let img = imageView.image, img.size.width > 0, bounds.width > 0 else { return }
        lastSize = bounds.size
        // Ausgangslage: ganzes Bild sichtbar (Zoom 1 = eingepasst)
        let fit = min(bounds.width / img.size.width, bounds.height / img.size.height)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: img.size.width * fit, height: img.size.height * fit))
        contentSize = imageView.frame.size
        minimumZoomScale = 1
        // mindestens 5×, bei großen Fotos bis zur echten Pixelgröße
        maximumZoomScale = max(5, 1 / fit * (img.scale / UIScreen.main.scale))
        center()
    }

    /// Bild mittig halten, solange es kleiner als die Fläche ist
    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    /// Ungezoomt nach unten ziehen: Bild folgt, wird blasser; weit genug → schließen
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard zoomScale <= minimumZoomScale * 1.01 else { imageView.alpha = 1; return }
        let pull = -(contentOffset.y + contentInset.top)
        imageView.alpha = pull > 0 ? max(0.4, 1 - pull / 400) : 1
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pull = -(contentOffset.y + contentInset.top)
        if zoomScale <= minimumZoomScale * 1.01, pull > 110 || (pull > 40 && velocity.y < -1.2) { onDismiss() }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTap(_ g: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: imageView)
            let scale = min(maximumZoomScale, 3)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

#else

/// Mac: Bild zoomen (Zwei-Finger-Geste am Trackpad, Doppelklick) und gezoomt mit Ziehen verschieben.
struct ZoomableImage: View {
    let url: URL
    var onDismiss: () -> Void = {}
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { g in
            LocalImage(url: url, maxPixel: 4096, contentMode: .fit)
                .frame(width: g.size.width, height: g.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(1, min(8, base * $0.magnification)) }
                    .onEnded { _ in base = scale; if scale <= 1.01 { withAnimation { reset() } } else { clamp(g.size) } })
                .simultaneousGesture(DragGesture()
                    .onChanged { v in
                        guard scale > 1 else { return }
                        offset = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height)
                    }
                    .onEnded { _ in clamp(g.size); dragStart = offset })
                .onTapGesture(count: 2) { withAnimation { if scale > 1 { reset() } else { scale = 2.5; base = 2.5 } } }
                .clipped()
        }
    }

    private func reset() { scale = 1; base = 1; offset = .zero; dragStart = .zero }

    /// nicht weiter schieben, als das vergrößerte Bild reicht
    private func clamp(_ size: CGSize) {
        let mx = size.width * (scale - 1) / 2, my = size.height * (scale - 1) / 2
        withAnimation(.easeOut(duration: 0.2)) {
            offset = CGSize(width: min(mx, max(-mx, offset.width)), height: min(my, max(-my, offset.height)))
        }
        dragStart = offset
    }
}
#endif
