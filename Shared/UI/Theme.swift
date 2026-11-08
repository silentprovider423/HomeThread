import SwiftUI

/// Farben von HomeThread: Petrol als Akzent (eigene Farbe, angelehnt an klassische Messenger-Optik, nicht identisch).
nonisolated enum Theme {
    static let accent = Color.dynamic(light: 0x0D6E78, dark: 0x3CCFC2)
    static let ownBubble = Color.dynamic(light: 0xD5F2EF, dark: 0x1F3D40)
    static let ownBubbleSelected = Color.dynamic(light: 0xA8E3DE, dark: 0x2C5A5E)
    static let otherBubble = Color.dynamic(light: 0xECEEF0, dark: 0x2C2C2E)
    static let chatBackground = Color.dynamic(light: 0xF7F8F9, dark: 0x000000)
    static let sidebar = Color.dynamic(light: 0xF4F5F7, dark: 0x161618)
    static let reactionPill = Color.dynamic(light: 0xE4E7EA, dark: 0x3A3A3C)
    static let reactionPillMine = Color.dynamic(light: 0xC9E9E5, dark: 0x2C5A5E)
    static let pinned = Color(hex: 0xF5B400)
    static let star = Color(hex: 0xF5B400)

    /// Personen-/Raumfarben (Systemfarben)
    static let palette: [Color] = [.blue, .indigo, .purple, .pink, .red, .orange, .yellow, .green, .mint, .teal, .cyan, .brown]

    static func color(for key: String) -> Color {
        var h: UInt32 = 2166136261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }

    static let bubbleRadius: CGFloat = {
        #if os(macOS)
        return 12
        #else
        return 16
        #endif
    }()
}

extension Color {
    nonisolated init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }

    /// nonisolated: SwiftUI löst die Farbe auch auf dem Render-Thread auf
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
        #else
        return Color(NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? NSColor(Color(hex: dark)) : NSColor(Color(hex: light))
        })
        #endif
    }
}

extension View {
    /// Liquid Glass ab iOS 26/macOS 26, sonst Material als Ersatz.
    @ViewBuilder
    func htGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func htGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}

/// Plattformübergreifendes Bild aus einer lokalen Datei.
struct LocalImage: View {
    let url: URL?
    var maxPixel = 600
    var contentMode: ContentMode = .fill

    var body: some View {
        if let url, let img = ImageCache.shared.image(url, maxPixel: maxPixel) {
            #if os(iOS)
            Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode)
            #else
            Image(nsImage: img).resizable().aspectRatio(contentMode: contentMode)
            #endif
        } else {
            Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
        }
    }
}

/// Rundes Bild für Räume/Personen: eigenes Foto oder Anfangsbuchstaben in Farbe.
struct Avatar: View {
    @Environment(AppModel.self) private var model
    let title: String
    var image: String?
    var isGroup = false
    var size: CGFloat = 54
    var colorKey: String?

    var body: some View {
        let _ = model.revision
        ZStack {
            if let image, let url = model.store?.fileURL(image) {
                LocalImage(url: url, maxPixel: Int(size * 3))
            } else {
                let c = Theme.color(for: colorKey ?? title)
                Circle().fill(c.gradient)
                if isGroup && initials.isEmpty {
                    Image(systemName: "person.3.fill").font(.system(size: size * 0.32)).foregroundStyle(.white)
                } else {
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = title.split(separator: " ").prefix(2)
        let s = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
        return s.isEmpty ? "" : s
    }
}

/// Vorschau eines Eintrags mit Symbol davor (Chat-Liste, Zitat, angeheftete Leiste).
struct PreviewText: View {
    let message: Message
    var body: some View {
        if let sym = message.kindSymbol {
            Text(Image(systemName: sym)) + Text(" " + message.preview)
        } else {
            Text(message.preview)
        }
    }
}
