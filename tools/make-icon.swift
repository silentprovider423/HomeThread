// Erzeugt das App-Symbol von HomeThread (zwei Sprechblasen, in der vorderen ein Haus) für iPhone und Mac:
//   swift tools/make-icon.swift
import AppKit

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

/// Sprechblase mit Zipfel unten links bzw. rechts.
func bubble(_ r: CGRect, radius: CGFloat, tailLeft: Bool) -> CGPath {
    let p = CGMutablePath()
    p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
    let tx = tailLeft ? r.minX + radius * 0.9 : r.maxX - radius * 0.9
    let dir: CGFloat = tailLeft ? -1 : 1
    p.move(to: CGPoint(x: tx - 40 * dir, y: r.minY + 6))
    p.addQuadCurve(to: CGPoint(x: tx + 70 * dir, y: r.minY - 70), control: CGPoint(x: tx + 10 * dir, y: r.minY - 20))
    p.addQuadCurve(to: CGPoint(x: tx + 60 * dir, y: r.minY + 6), control: CGPoint(x: tx + 60 * dir, y: r.minY - 20))
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext, mac: Bool) {
    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: mac ? 185 : 0, cornerHeight: mac ? 185 : 0, transform: nil)
    if mac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(rgb(0x0A4F57)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x1A9AA3), rgb(0x0A4F57)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
    // Maßstab innerhalb der Kachel
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    // hintere Blase (heller)
    ctx.addPath(bubble(CGRect(x: 390, y: 470, width: 470, height: 330), radius: 120, tailLeft: false))
    ctx.setFillColor(rgb(0x9FE3DC)); ctx.fillPath()
    // vordere Blase (weiß) mit Haus
    let front = CGRect(x: 160, y: 250, width: 540, height: 400)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0x00262B, 0.35))
    ctx.addPath(bubble(front, radius: 140, tailLeft: true))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    let cx = front.midX, base = front.minY + 95
    let house = CGMutablePath()
    house.move(to: CGPoint(x: cx - 130, y: base + 130))
    house.addLine(to: CGPoint(x: cx, y: base + 245))
    house.addLine(to: CGPoint(x: cx + 130, y: base + 130))
    ctx.addPath(house)
    ctx.setStrokeColor(rgb(0x0D6E78)); ctx.setLineWidth(38); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    let body = CGPath(roundedRect: CGRect(x: cx - 92, y: base, width: 184, height: 150), cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.addPath(body); ctx.setFillColor(rgb(0x0D6E78)); ctx.fillPath()
    // Tür als „Faden“-Linie
    ctx.addPath(CGPath(roundedRect: CGRect(x: cx - 26, y: base, width: 52, height: 88), cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
}

func render(_ px: Int, mac: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, mac: mac)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let ios = root.appendingPathComponent("iOS/Assets.xcassets/AppIcon.appiconset")
try! render(1024, mac: false).write(to: ios.appendingPathComponent("icon-1024.png"))
try! """
{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""".write(to: ios.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
let mac = root.appendingPathComponent("macOS/Assets.xcassets/AppIcon.appiconset")
var images: [String] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! render(pt * scale, mac: true).write(to: mac.appendingPathComponent(name))
    images.append("{\"filename\":\"\(name)\",\"idiom\":\"mac\",\"scale\":\"\(scale)x\",\"size\":\"\(pt)x\(pt)\"}")
}
try! "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
    .write(to: mac.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
// Akzentfarbe hell/dunkel in beiden Katalogen
let accent = """
{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0x78","green":"0x6E","red":"0x0D"}},"idiom":"universal"},
{"appearances":[{"appearance":"luminosity","value":"dark"}],"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0xC2","green":"0xCF","red":"0x3C"}},"idiom":"universal"}],
"info":{"author":"xcode","version":1}}
"""
for cat in ["iOS/Assets.xcassets", "macOS/Assets.xcassets"] {
    let dir = root.appendingPathComponent(cat)
    try! "{\"info\":{\"author\":\"xcode\",\"version\":1}}".write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    let ac = dir.appendingPathComponent("AccentColor.colorset")
    try! FileManager.default.createDirectory(at: ac, withIntermediateDirectories: true)
    try! accent.write(to: ac.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("Symbole geschrieben")
