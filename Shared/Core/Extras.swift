import AVFoundation
import Foundation
import NaturalLanguage

/// Link auf einen Eintrag: `homethread://entry/<Raum>/<Eintrag>` – zum Verweisen von einer Notiz auf eine andere.
/// Gilt nur für dieses Konto (die Kennungen sagen niemand anderem etwas).
nonisolated enum EntryLink {
    static let scheme = "homethread"

    static func make(_ m: Message) -> URL {
        URL(string: "\(scheme)://entry/\(m.roomId)/\(m.id)")!
    }

    static func parse(_ url: URL) -> ChatRoute? {
        guard url.scheme?.lowercased() == scheme, url.host == "entry" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts.allSatisfy(isID) else { return nil }
        return ChatRoute(room: parts[0], jump: parts[1])
    }

    /// Kennungen bestehen nur aus Buchstaben, Ziffern, Binde- und Unterstrich
    private static func isID(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 80 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Fundstellen im Text (für anklickbare Links im Verlauf)
    static func ranges(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard text.contains(scheme + "://"), let re = try? NSRegularExpression(pattern: scheme + "://entry/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+") else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range, in: text), let u = URL(string: String(text[r])) else { return nil }
            return (r, u)
        }
    }
}

/// Vorlesen eines Eintrags (auf dem Gerät, ohne Netz). Sprache wird aus dem Text erkannt.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    /// Eintrag, der gerade vorgelesen wird
    private(set) var speaking: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Vorlesen starten; derselbe Eintrag noch einmal = stoppen.
    func toggle(id: String, text: String) {
        let same = speaking == id
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        guard !same, !text.isEmpty else { speaking = nil; return }
        let u = AVSpeechUtterance(string: text)
        if let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue, let v = AVSpeechSynthesisVoice(language: lang) { u.voice = v }
        speaking = id
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = nil }
    }
}

/// Alle Emojis für die Reaktions-Auswahl: aus den Unicode-Eigenschaften des Systems gebaut (keine eigene Liste zum
/// Pflegen), grob in Abschnitte sortiert und über den Unicode-Namen durchsuchbar – dazu deutsche Suchwörter.
nonisolated enum EmojiCatalog {
    struct Emoji: Hashable, Sendable {
        let value: String
        /// Unicode-Name, klein („thumbs up sign“)
        let name: String
    }

    struct Section: Sendable {
        let id: String
        let emojis: [Emoji]
    }

    /// Abschnitte in Anzeigereihenfolge; ein Zeichen landet im ersten passenden
    private static let layout: [(id: String, ranges: [ClosedRange<UInt32>])] = [
        ("smileys", [0x1F600...0x1F64A, 0x1F910...0x1F917, 0x1F920...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9D0, 0x1FAE0...0x1FAEF,
                     0x2639...0x263A, 0x1F47B...0x1F47F, 0x1F480...0x1F480, 0x1F4A9...0x1F4A9, 0x1F63A...0x1F640]),
        ("hearts", [0x2763...0x2764, 0x1F493...0x1F49F, 0x1F5A4...0x1F5A4, 0x1F90D...0x1F90E, 0x1F9E1...0x1F9E1, 0x1FA75...0x1FA77, 0x1F48B...0x1F48C,
                    0x1F4A0...0x1F4AF]),
        ("people", [0x1F440...0x1F487, 0x1F48F...0x1F491, 0x1F590...0x1F596, 0x1F64B...0x1F64F, 0x1F90C...0x1F90F, 0x1F918...0x1F91F,
                    0x1F930...0x1F93F, 0x1F9B5...0x1F9B9, 0x1F9BB...0x1F9BB, 0x1F9CD...0x1F9CF, 0x1F9D1...0x1F9DF, 0x1FAC3...0x1FAC5,
                    0x1FAF0...0x1FAF8, 0x261D...0x261D, 0x270A...0x270D, 0x1F574...0x1F57A, 0x1F6B4...0x1F6B6, 0x1F3C2...0x1F3CC]),
        ("nature", [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1FAB0...0x1FABF, 0x1F300...0x1F344, 0x2600...0x2604, 0x26A1...0x26A1, 0x2744...0x2744,
                    0x1F490...0x1F490, 0x26C4...0x26C8, 0x2B50...0x2B50, 0x1F525...0x1F525, 0x1F4A7...0x1F4A8, 0x1F54A...0x1F54A, 0x1F577...0x1F578,
                    0x1FACE...0x1FACF]),
        ("food", [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADB, 0x2615...0x2615]),
        ("travel", [0x1F380...0x1F3FA, 0x1F680...0x1F6FF, 0x26BD...0x26BE, 0x26F0...0x26FA, 0x2708...0x2709, 0x1FA70...0x1FA7C, 0x1FA80...0x1FA88,
                    0x1F3D4...0x1F3F0, 0x1F5FA...0x1F5FF, 0x2693...0x2693]),
        ("objects", [0x1F4B0...0x1F4FF, 0x1F56F...0x1F5F3, 0x1F9E0...0x1F9FF, 0x1FA90...0x1FAAF, 0x231A...0x23FA, 0x260E...0x260E, 0x2702...0x2712,
                     0x1F500...0x1F53D, 0x1F550...0x1F567]),
        ("symbols", [0x203C...0x3299, 0x1F000...0x1FAFF]),
    ]

    static let sections: [Section] = {
        var buckets: [[Emoji]] = Array(repeating: [], count: layout.count)
        var seen = Set<UInt32>()
        // Bausteine, die allein nichts darstellen: Hautfarben, Flaggen-Buchstaben, Haar-Bausteine
        let skip: [ClosedRange<UInt32>] = [0x1F3FB...0x1F3FF, 0x1F1E6...0x1F1FF, 0x1F9B0...0x1F9B3]
        for (i, section) in layout.enumerated() {
            for range in section.ranges {
                for v in range where !seen.contains(v) {
                    guard let s = Unicode.Scalar(v), s.properties.isEmoji, !skip.contains(where: { $0.contains(v) }),
                          let name = s.properties.name else { continue }
                    seen.insert(v)
                    // Zeichen, die das System sonst als Text zeichnet (❤ ☀ ✔), mit Emoji-Auswahlzeichen
                    let value = s.properties.isEmojiPresentation ? String(s) : String(s) + "\u{FE0F}"
                    buckets[i].append(Emoji(value: value, name: name.lowercased()))
                }
            }
        }
        return zip(layout, buckets).map { Section(id: $0.0.id, emojis: $0.1) }.filter { !$0.emojis.isEmpty }
    }()

    /// Deutsche Suchwörter → englische Namensteile (Unicode-Namen gibt es nur auf Englisch)
    private static let german: [String: [String]] = [
        "herz": ["heart"], "daumen": ["thumbs"], "lach": ["laugh", "joy", "grin", "smil"], "lächel": ["smil"], "wein": ["cry", "tear", "wine"],
        "trän": ["tear", "cry"], "traurig": ["sad", "cry", "frown", "pensive", "disappoint"], "wut": ["angry", "pouting", "rage"],
        "wütend": ["angry", "pouting"], "kuss": ["kiss"], "liebe": ["heart", "love", "kiss"], "feuer": ["fire"], "stern": ["star"],
        "haken": ["check"], "kreuz": ["cross"], "frage": ["question"], "ausruf": ["exclamation"], "auge": ["eye"], "hand": ["hand"],
        "klatsch": ["clapping"], "bete": ["folded hands"], "danke": ["folded hands"], "muskel": ["biceps"], "stark": ["biceps"],
        "sonne": ["sun"], "mond": ["moon"], "regen": ["rain", "umbrella"], "schnee": ["snow"], "wolke": ["cloud"], "blitz": ["voltage", "lightning"],
        "blume": ["flower", "blossom", "tulip", "rose"], "baum": ["tree"], "hund": ["dog"], "katze": ["cat"], "vogel": ["bird"], "fisch": ["fish"],
        "kaffee": ["hot beverage"], "tee": ["teacup", "hot beverage"], "bier": ["beer"], "pizza": ["pizza"], "kuchen": ["cake"], "apfel": ["apple"],
        "essen": ["fork", "food", "pizza", "burger"], "auto": ["automobile", "car"], "flugzeug": ["airplane"], "zug": ["train"], "fahrrad": ["bicycle"],
        "haus": ["house"], "uhr": ["clock", "watch"], "wecker": ["alarm"], "geld": ["money", "banknote", "dollar", "euro"], "buch": ["book"],
        "brief": ["envelope"], "telefon": ["telephone", "phone"], "handy": ["mobile phone"], "musik": ["music", "note"], "kamera": ["camera"],
        "idee": ["bulb"], "licht": ["bulb"], "lampe": ["bulb"], "schlüssel": ["key"], "schloss": ["lock"], "glocke": ["bell"],
        "geschenk": ["present", "gift"], "party": ["party", "confetti"], "feier": ["party", "confetti"], "müde": ["sleep", "tired", "yawn"],
        "schlaf": ["sleep", "zzz"], "krank": ["thermometer", "mask", "nauseated", "sneezing"], "teufel": ["imp", "devil"], "geist": ["ghost"],
        "totenkopf": ["skull"], "rakete": ["rocket"], "flagge": ["flag"], "pfeil": ["arrow"], "warn": ["warning"], "verbot": ["prohibited", "no entry"],
        "stopp": ["stop", "octagonal"], "grün": ["green"], "rot": ["red"], "blau": ["blue"], "gelb": ["yellow"], "schwarz": ["black"], "weiß": ["white"],
        "kreis": ["circle"], "quadrat": ["square"], "nadel": ["pushpin", "pin"], "stift": ["pencil", "pen"], "notiz": ["memo", "notebook"],
        "kalender": ["calendar"], "mülleimer": ["wastebasket"], "lupe": ["magnifying"], "werkzeug": ["hammer", "wrench", "tool"],
        "einkauf": ["shopping"], "arzt": ["health worker", "stethoscope", "hospital"], "pille": ["pill"], "sport": ["ball", "running", "weight"],
        "ok": ["ok"], "cool": ["sunglasses"], "denk": ["thinking"], "schock": ["scream", "astonished"], "top": ["thumbs up", "top"],
    ]

    /// Suche über den Unicode-Namen; deutsche Wortanfänge werden übersetzt. Leere Suche = alles.
    static func search(_ query: String) -> [Emoji] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sections.flatMap(\.emojis) }
        var terms = [q]
        for (de, en) in german where de.hasPrefix(q) || q.hasPrefix(de) { terms += en }
        return sections.flatMap(\.emojis).filter { e in e.value.hasPrefix(q) || terms.contains { e.name.contains($0) } }
    }

    // MARK: Zuletzt benutzt

    private static let recentKey = "emoji.recent"

    static var recent: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func noteUsed(_ emoji: String) {
        var r = recent.filter { $0 != emoji }
        r.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(r.prefix(21)), forKey: recentKey)
    }
}
