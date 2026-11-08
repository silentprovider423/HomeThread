import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Bilder verkleinern, Vorschauen erzeugen, EXIF/Ort entfernen – mit ImageIO, auf iPhone und Mac gleich.
enum Media {
    /// Lädt ein Bild verkleinert (längste Kante `maxPixel`) und richtig gedreht.
    static func cgImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func cgImage(data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpeg(_ img: CGImage, quality: Double = 0.82) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // Nur Pixel schreiben: keine EXIF-/GPS-Daten übernehmen
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// Foto für die Ablage: höchstens 2560 px, JPEG ohne Metadaten; dazu Vorschau 480 px.
    static func prepareImage(_ data: Data) -> (full: Data, thumb: Data, w: Int, h: Int)? {
        guard let full = cgImage(data: data, maxPixel: 2560), let fd = jpeg(full),
              let th = cgImage(data: data, maxPixel: 480), let td = jpeg(th, quality: 0.7) else { return nil }
        return (fd, td, full.width, full.height)
    }

    static func videoInfo(_ url: URL) async -> (thumb: Data?, w: Int, h: Int, duration: Double) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        var thumb: Data?
        var w = 0, h = 0
        if let (img, _) = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) {
            thumb = jpeg(img, quality: 0.7)
            w = img.width; h = img.height
        }
        let d = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        return (thumb, w, h, d.isFinite ? d : 0)
    }

    static func mime(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func platformImage(_ url: URL, maxPixel: Int = 1200) -> PlatformImage? {
        guard let cg = cgImage(at: url, maxPixel: maxPixel) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}

/// Kleiner Zwischenspeicher für verkleinerte Bilder (Vorschauen in Liste und Bubbles).
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    func image(_ url: URL, maxPixel: Int) -> PlatformImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let i = cache.object(forKey: key) { return i }
        guard let i = Media.platformImage(url, maxPixel: maxPixel) else { return nil }
        cache.setObject(i, forKey: key)
        return i
    }
}
