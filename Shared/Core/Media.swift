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
nonisolated enum Media {
    /// Lädt ein Bild verkleinert (längste Kante `maxPixel`) und richtig gedreht.
    static func cgImage(at url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
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

/// Verkleinerte Bilder für Bubbles, Liste und Avatare: im Hintergrund dekodiert (ImageIO-Downsampling, nie auf dem
/// Main-Thread), im Speicher zwischengespeichert; Vorschauen großer Originale (z. B. 12-MP-Fotos ohne Vorschau aus einem
/// Import) zusätzlich einmalig als kleines JPEG im Cache-Ordner, damit sie beim nächsten Mal sofort da sind.
nonisolated final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let memory: NSCache<NSString, PlatformImage> = { let c = NSCache<NSString, PlatformImage>(); c.totalCostLimit = 120_000_000; return c }()
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 3; q.qualityOfService = .userInitiated; return q }()
    private let diskDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HomeThread-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// stabiler Name für die Datei im Cache-Ordner (gleich über App-Starts hinweg)
    static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 36)
    }

    private func key(_ url: URL, _ maxPixel: Int) -> String { "\(url.path)#\(maxPixel)" }

    /// Nur aus dem Speicher (für den ersten Frame ohne Platzhalter-Flackern)
    func cached(_ url: URL, maxPixel: Int) -> PlatformImage? { memory.object(forKey: key(url, maxPixel) as NSString) }

    func load(_ url: URL, maxPixel: Int) async -> PlatformImage? {
        if let c = cached(url, maxPixel: maxPixel) { return c }
        return await withCheckedContinuation { c in
            queue.addOperation { c.resume(returning: self.decode(url, maxPixel: maxPixel)) }
        }
    }

    private func decode(_ url: URL, maxPixel: Int) -> PlatformImage? {
        let k = key(url, maxPixel)
        if let c = memory.object(forKey: k as NSString) { return c }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let useDisk = size > 600_000 && maxPixel <= 1200
        let diskURL = diskDir.appendingPathComponent(Self.fnv(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent) + "-\(maxPixel).jpg")
        var cg: CGImage?
        if useDisk, FileManager.default.fileExists(atPath: diskURL.path) { cg = Media.cgImage(at: diskURL, maxPixel: maxPixel) }
        if cg == nil {
            cg = Media.cgImage(at: url, maxPixel: maxPixel)
            if useDisk, let cg, let d = Media.jpeg(cg, quality: 0.8) { try? d.write(to: diskURL, options: .atomic) }
        }
        guard let cg else { return nil }
        #if os(iOS)
        let img = UIImage(cgImage: cg)
        #else
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
        memory.setObject(img, forKey: k as NSString, cost: cg.width * cg.height * 4)
        return img
    }
}
