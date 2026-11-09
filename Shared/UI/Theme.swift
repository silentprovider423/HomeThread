import SwiftUI

/// Farben und Maße von HomeThread – klassischer Messenger-Look: iPhone wie ein iOS-Messenger mit hellgrünen eigenen
/// Bubbles, Mac wie ein Desktop-Messenger mit schmaler Leiste, dunkelgrauer Chat-Liste und Bubbles ohne Schwänzchen.
nonisolated enum Theme {
    static let accent = Color.dynamic(light: 0x0B734E, dark: 0x36D588)

    #if os(macOS)
    static let ownBubble = Color.dynamic(light: 0xD9FAE9, dark: 0x151513)
    static let otherBubble = Color.dynamic(light: 0xF3F4F6, dark: 0x3D3D3B)
    static let chatBackground = Color.dynamic(light: 0xFFFFFF, dark: 0x2A2A2A)
    static let link = Color.dynamic(light: 0x002E63, dark: 0x41AFE0)
    static let systemPill = Color.dynamic(light: 0xF3F4F6, dark: 0x151513)
    static let text1Bubble = Color.dynamic(light: 0x2C2C2B, dark: 0xE5E5E5)
    static let metaText = Color.dynamic(light: 0x6B6B6B, dark: 0xB8B8B8)
    #else
    static let ownBubble = Color.dynamic(light: 0xD9FAE9, dark: 0x212121)
    static let otherBubble = Color.dynamic(light: 0xE7E7E7, dark: 0x424242)
    static let chatBackground = Color.dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let link = Color.dynamic(light: 0x0B734E, dark: 0x36D588)
    static let systemPill = Color.dynamic(light: 0xF2F2F2, dark: 0x212121)
    static let text1Bubble = Color.primary
    static let metaText = Color.secondary
    #endif
    static let ownBubbleSelected = Color.dynamic(light: 0x7DEEB5, dark: 0x575757)
    static let otherBubbleSelected = Color.dynamic(light: 0xCECECE, dark: 0x737373)

    // Mac-Fenster: Leiste | Chat-Liste | Chat
    static let rail = Color.dynamic(light: 0xFFFFFF, dark: 0x2C2C2C)
    static let railSelected = Color.dynamic(light: 0xE5E7EB, dark: 0x5B5B5A)
    static let railIconSelected = Color.dynamic(light: 0x2C2C2B, dark: 0xFFFFFF)
    static let nav = Color.dynamic(light: 0xF3F4F6, dark: 0x151513)
    static let rowSelected = Color.dynamic(light: 0xDDE0E5, dark: 0x000000)
    static let rowHover = Color.dynamic(light: 0xE8EAEE, dark: 0x0E0E0C)
    static let panelGap = Color.dynamic(light: 0xE5E7EB, dark: 0x393939)
    static let text1 = Color.dynamic(light: 0x2C2C2B, dark: 0xE5E5E5)
    static let text2 = Color.dynamic(light: 0x6B6B6B, dark: 0x9D9D9D)
    static let searchField = Color.dynamic(light: 0xEAEBED, dark: 0x1E1F1C)

    // iPhone: Eingabeleiste und Tab-Leiste
    static let chatBar = Color.dynamic(light: 0xF5F5F5, dark: 0x1C1C1C)
    static let chatBarField = Color.dynamic(light: 0xFFFFFF, dark: 0x2A2A2A)
    static let tabBar = Color.dynamic(light: 0xF8F8F8, dark: 0x161616)
    static let hairline = Color.dynamic(light: 0xD1D1D6, dark: 0x38383A)
    #if os(macOS)
    static let infoTile = Color.dynamic(light: 0xF3F4F6, dark: 0x3D3D3B)
    #else
    static let infoTile = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    #endif
    static let onAccent = Color.dynamic(light: 0xFFFFFF, dark: 0x151513)
    #if os(macOS)
    static let barBackground = chatBackground
    static let fieldBackground = searchField
    #else
    static let barBackground = chatBar
    static let fieldBackground = chatBarField
    #endif

    static let reactionPill = Color.dynamic(light: 0xF7F7F7, dark: 0x444444)
    static let reactionPillMine = Color.dynamic(light: 0xDADADA, dark: 0x5D5D5D)
    static let reactionBorder = Color.dynamic(light: 0xE0E0E0, dark: 0x2A2A2A)
    static let pinned = Color(hex: 0xFEC400)
    static let star = Color(hex: 0xFEC400)
    static let unread = Color(hex: 0xE11D24)

    /// Avatar-Farben: Initialen in der Farbe, Kreis in derselben Farbe zu 15 % (hell/dunkel je eigener Ton).
    static let avatarColors: [(light: UInt32, dark: UInt32)] = [
        (0xFF8F00, 0xFFCA28), (0x1565C0, 0x42A5F5), (0x0097A7, 0x26C6DA), (0xD84315, 0xFF7043),
        (0x7B3AB7, 0x7E57D6), (0x2E7D32, 0x66BB6A), (0x283593, 0x6371FF), (0x0288D1, 0x4FC3F7),
        (0x7CB342, 0x8BC34A), (0x9E9D24, 0x9E9D24), (0xEF6C00, 0xFFA726), (0xAD1457, 0xEC407A),
        (0xAC24AA, 0xAB47BC), (0xC62828, 0xEF5350), (0x00796B, 0x26A69A), (0xF9A800, 0xFFF176),
    ]

    static func hash(_ key: String) -> Int {
        var h: UInt32 = 2166136261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Int(h % 0x7FFF_FFFF)
    }

    /// Personen-/Raumfarbe (Absendername, Zitat-Balken, Avatar)
    static func color(for key: String) -> Color {
        let c = avatarColors[hash(key) % avatarColors.count]
        return Color.dynamic(light: c.light, dark: c.dark)
    }

    static let bubbleRadius: CGFloat = {
        #if os(macOS)
        return 10
        #else
        return 16.5
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
    /// Liquid Glass ab iOS 26/macOS 26, sonst Material als Ersatz (nur noch für schwebende Elemente).
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
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
    }
}

/// Plattformübergreifendes Bild aus einer lokalen Datei.
struct LocalImage: View {
    let url: URL?
    var maxPixel = 600
    var contentMode: ContentMode = .fill
    @State private var loaded: (URL, PlatformImage)?

    var body: some View {
        // aus dem Speicher sofort, sonst im Hintergrund verkleinern (nie Dekodieren auf dem Main-Thread)
        let img = url.flatMap { u in loaded?.0 == u ? loaded?.1 : ImageLoader.shared.cached(u, maxPixel: maxPixel) }
        ZStack {
            if let img {
                #if os(iOS)
                Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode)
                #else
                Image(nsImage: img).resizable().aspectRatio(contentMode: contentMode)
                #endif
            } else {
                Rectangle().fill(.quaternary)
                if maxPixel > 1000 || url == nil { ProgressView().controlSize(.small) }
            }
        }
        .task(id: url) {
            guard let url, img == nil else { return }
            if let i = await ImageLoader.shared.load(url, maxPixel: maxPixel) { loaded = (url, i) }
        }
    }
}

/// Rundes Bild für Räume/Personen: eigenes Foto oder Initialen in Farbe auf leicht getöntem Kreis.
struct Avatar: View {
    @Environment(AppModel.self) private var model
    let title: String
    var image: String?
    var isGroup = false
    var size: CGFloat = 54
    var colorKey: String?
    /// Personen: Anfangsbuchstaben der ersten zwei Wörter; Räume: die ersten zwei Buchstaben des Namens
    var person = false

    var body: some View {
        let _ = model.revision
        ZStack {
            if let image, let url = model.store?.fileURL(image) {
                LocalImage(url: url, maxPixel: Int(size * 3))
            } else {
                let c = Theme.color(for: colorKey ?? title)
                Circle().fill(c.opacity(0.15))
                if initials.isEmpty {
                    Image(systemName: isGroup ? "person.3.fill" : "person.fill").font(.system(size: size * 0.34)).foregroundStyle(c)
                } else {
                    Text(initials).font(.system(size: size * 0.36, weight: .regular)).foregroundStyle(c)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    var initials: String { Self.initials(title, person: person) }

    static func initials(_ title: String, person: Bool) -> String {
        if person {
            let words = title.split(separator: " ").prefix(2)
            if words.count > 1 { return words.compactMap { $0.first(where: \.isLetter) ?? $0.first }.map { String($0).uppercased() }.joined() }
        }
        return String(title.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }
}

/// Vorschau eines Eintrags mit Symbol davor (Chat-Liste, Zitat, angeheftete Leiste).
struct PreviewText: View {
    let message: Message
    var prefix: String?
    var body: some View {
        let p = Text(prefix.map { $0 + ": " } ?? "")
        if let sym = message.kindSymbol {
            p + Text(Image(systemName: sym)) + Text(" " + message.preview)
        } else {
            p + Text(message.preview)
        }
    }
}

/// Kleine Status-Anzeige eigener Einträge: wartet (Uhr), Fehler (Dreieck), gesichert (Fach mit Pfeil).
struct StatusIcon: View {
    let message: Message
    var body: some View {
        if message.failed != nil {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Text("Fehler"))
        } else if message.pending {
            Image(systemName: "clock").accessibilityLabel(Text("wartet auf Abgleich"))
        } else {
            Image(systemName: "tray.and.arrow.down.fill").accessibilityLabel(Text("gesichert"))
        }
    }
}
