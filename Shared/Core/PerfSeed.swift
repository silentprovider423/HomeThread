#if DEBUG
import CoreGraphics
import Foundation

/// Nur Debug-Builds: synthetische Leistungsdaten (nie echte Daten), ausschließlich in der lokalen Datenbank des
/// angemeldeten Testkontos. Nichts davon geht an den Server (keine Warteschlange), `THREAD_RESET=1` löscht alles wieder.
///   THREAD_PERF_SEED=1   Raum „Perf 2000“ mit 2.000 gemischten Einträgen + 517 kleine Räume (= 518 Räume)
enum PerfSeed {
    static let roomTitle = "Perf 2000"
    static let roomID = "perf-room-2000"

    /// Deterministischer Zufall, damit jeder Lauf dieselben Daten hat.
    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ r: Range<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func dbl() -> Double { Double(next() % 1_000_000) / 1_000_000 }
        mutating func chance(_ p: Double) -> Bool { dbl() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[int(0..<a.count)] }
    }

    static let words = ["Einkauf", "Milch", "morgen", "Termin", "bitte", "noch", "Danke", "Rechnung", "Paket", "abholen", "Idee",
                        "Urlaub", "Wohnung", "Auto", "Werkstatt", "Liste", "Garten", "Geschenk", "Pizza", "Kino", "Arzt", "Bahn",
                        "später", "heute", "Foto", "schau", "mal", "hier", "wichtig", "fertig", "Angebot", "Preis", "Größe"]

    /// eBay-artiger Link mit 500+ Zeichen ohne Leerzeichen
    static func longURL(_ r: inout RNG) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var s = "https://www.ebay.de/itm/\(r.int(100_000_000..<999_999_999))?_trkparms=amclksrc%3DITM%26aid%3D1110006%26algo%3DHOMESPLICE.SIM"
        while s.count < 500 + r.int(0..<400) {
            s += "%26" + String((0..<r.int(3..<9)).map { _ in alphabet[r.int(0..<alphabet.count)] }) + "%3D"
                + String((0..<r.int(4..<24)).map { _ in alphabet[r.int(0..<alphabet.count)] })
        }
        return s + "&_trksid=p4429486.c101224.m1851&itmprp=cksum%3A\(r.int(100_000..<999_999))"
    }

    static func sentence(_ r: inout RNG, _ n: Int) -> String {
        (0..<n).map { _ in r.pick(words) }.joined(separator: " ")
    }

    /// Synthetisches Foto (Verlauf + Flächen) als JPEG
    static func jpeg(width: Int, height: Int, seed: Int) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let hue = Double(seed % 7) / 7
        let colors = [CGColor(red: hue, green: 0.4, blue: 1 - hue, alpha: 1), CGColor(red: 1 - hue, green: 0.8, blue: 0.3, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        var r = RNG(s: UInt64(seed + 99))
        for _ in 0..<60 {
            ctx.setFillColor(CGColor(red: r.dbl(), green: r.dbl(), blue: r.dbl(), alpha: 0.6))
            ctx.fillEllipse(in: CGRect(x: r.int(0..<width), y: r.int(0..<height), width: r.int(50..<900), height: r.int(50..<900)))
        }
        guard let img = ctx.makeImage() else { return nil }
        return Media.jpeg(img, quality: 0.9)
    }

    static func run(_ model: AppModel) {
        guard let store = model.store else { return }
        if store.db.one("SELECT 1 FROM rooms WHERE id=?", roomID) != nil { return }
        let me = model.me
        let others = ["perf-anna", "perf-ben"]
        var r = RNG(s: 2000)
        let start = Date().addingTimeInterval(-120 * 86400).timeIntervalSince1970

        // Fotos: 4 Originale mit 12 MP (2 quer, 2 hoch) und ihre Vorschauen (480 px)
        var imgs: [(id: String, thumb: String, w: Int, h: Int)] = []
        for i in 0..<4 {
            let (w, h) = i % 2 == 0 ? (4032, 3024) : (3024, 4032)
            guard let full = jpeg(width: w, height: h, seed: i), let th = Media.cgImage(data: full, maxPixel: 480).flatMap({ Media.jpeg($0, quality: 0.7) })
            else { continue }
            let id = "perf-img-\(i)", tid = "perf-thumb-\(i)"
            let tmp = FileManager.default.temporaryDirectory
            try? full.write(to: tmp.appendingPathComponent(id))
            try? th.write(to: tmp.appendingPathComponent(tid))
            _ = try? store.importFile(tmp.appendingPathComponent(id), id: id, name: "foto.jpg", mime: "image/jpeg", move: true, uploaded: true)
            _ = try? store.importFile(tmp.appendingPathComponent(tid), id: tid, name: "thumb.jpg", mime: "image/jpeg", move: true, uploaded: true)
            imgs.append((id, tid, w, h))
        }

        try? store.db.transaction {
            try store.db.run("INSERT INTO rooms(id, kind, title, about, created_by, created_at, updated_at, pending) VALUES(?,?,?,?,?,?,?,0)",
                             roomID, "group", roomTitle, "", me, start, start)
            for (uid, name) in [(me, "Ich"), ("perf-anna", "Anna"), ("perf-ben", "Ben")] {
                try store.db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color) VALUES(?,?,?,?,?,?)",
                                 roomID, uid, uid == me ? "owner" : "member", name, name.lowercased(), 0)
            }
            var ids: [String] = []
            var t = start
            let n = 2000
            for i in 1...n {
                t += Double(r.int(60..<10_000))
                let id = String(format: "perf-msg-%04d", i)
                let author = r.chance(0.5) ? me : r.pick(others)
                let device: String? = i > n - 20 ? "perf-dev-other" : (r.chance(0.2) ? "perf-dev-mac" : model.myDevice)
                var kind = "text", body = "", payload = Payload(), attachment: String?, thumb: String?
                let x = i == 1 ? 0 : r.dbl()
                switch x {
                case ..<0.45: body = "Eintrag \(String(format: "%04d", i)): " + sentence(&r, r.int(2..<14))
                case ..<0.57: body = r.chance(0.5) ? longURL(&r) : sentence(&r, r.int(2..<6)) + " " + longURL(&r)
                case ..<0.67: body = (0..<r.int(3..<12)).map { _ in sentence(&r, r.int(3..<10)) }.joined(separator: "\n")
                case ..<0.77:
                    kind = "image"
                    let im = imgs[r.int(0..<imgs.count)]
                    attachment = im.id
                    thumb = r.chance(0.67) ? im.thumb : nil
                    payload.w = im.w; payload.h = im.h; payload.mime = "image/jpeg"; payload.size = 3_000_000
                    if r.chance(0.3) { body = sentence(&r, r.int(2..<8)) }
                case ..<0.82:
                    kind = "file"
                    payload.filename = "Dokument_\(i)_" + r.pick(words) + ".pdf"; payload.mime = "application/pdf"
                    payload.size = r.int(20_000..<9_000_000)
                    if r.chance(0.3) { payload.missing = true } else { attachment = "perf-file-\(i)" }
                case ..<0.87:
                    kind = "checklist"
                    body = "Liste " + r.pick(words)
                    for k in 0..<r.int(3..<9) {
                        try store.db.run("INSERT INTO items(id, message_id, room_id, text, done, position) VALUES(?,?,?,?,?,?)",
                                         "\(id)-it\(k)", id, roomID, sentence(&r, r.int(1..<5)), r.chance(0.4), Double(k))
                    }
                case ..<0.90:
                    kind = "poll"
                    payload.question = sentence(&r, r.int(3..<7)) + "?"
                    payload.options = (0..<r.int(2..<5)).map { PollOption(id: "o\($0)", text: sentence(&r, r.int(1..<4))) }
                    payload.showInterim = true
                    payload.multi = r.chance(0.3)
                    for u in [me] + others where r.chance(0.6) {
                        try store.db.run("INSERT INTO votes(message_id, user_id, choices) VALUES(?,?,?)", id, u, "[\"o0\"]")
                    }
                case ..<0.92:
                    kind = "voice"
                    payload.duration = Double(r.int(2..<90))
                    payload.wave = (0..<30).map { _ in 0.15 + r.dbl() * 0.85 }
                case ..<0.925:
                    kind = "location"
                    payload.lat = 48.70 + r.dbl() * 0.1; payload.lon = 9.65 + r.dbl() * 0.1; payload.name = "Ort " + r.pick(words)
                default: body = r.pick(["Ok", "👍", "Ja", "Mach ich", "Danke!", "Gute Idee"])
                }
                let reply: String? = !ids.isEmpty && r.chance(0.1) ? ids[r.int(max(0, ids.count - 300)..<ids.count)] : nil
                let edited: Double? = kind == "text" && r.chance(0.08) ? t + 120 : nil
                let pinned = [300, 1200, 1900].contains(i)
                try store.db.run("""
                    INSERT INTO messages(id, room_id, author_id, device_id, kind, body, payload, reply_to, attachment, thumb, created_at,
                      edited_at, pinned, deleted, seq, pending) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,0)
                    """, id, roomID, author, device, kind, body, payload.json, reply, attachment, thumb, t, edited, pinned, i)
                if store.ftsAvailable { try store.db.run("INSERT INTO fts(id, room_id, body) VALUES(?,?,?)", id, roomID, body) }
                if r.chance(0.1) {
                    for u in ([me] + others) where r.chance(0.5) {
                        try store.db.run("INSERT OR REPLACE INTO reactions(message_id, user_id, emoji, active, room_id) VALUES(?,?,?,1,?)",
                                         id, u, r.pick(["👍", "❤️", "😂", "🎉"]), roomID)
                    }
                }
                if r.chance(0.02) { try store.db.run("INSERT OR REPLACE INTO stars(message_id, active, room_id) VALUES(?,1,?)", id, roomID) }
                ids.append(id)
            }
            // angeheftet → steht oben in der Chat-Liste
            try store.db.run("INSERT OR REPLACE INTO roomstate(room_id, pinned, archived, muted) VALUES(?,1,0,0)", roomID)
            // Lesestand: die letzten 20 Einträge sind „neu von anderem Gerät“
            store.set("read:\(roomID)", String(n - 20))

            // 517 weitere Räume mit je 3–15 kurzen Einträgen (Chat-Liste mit 518 Räumen)
            for k in 1...517 {
                let rid = String(format: "perf-room-%03d", k)
                let rt = start + Double(r.int(0..<10_000_000))
                try store.db.run("INSERT INTO rooms(id, kind, title, about, created_by, created_at, updated_at, pending) VALUES(?,?,?,?,?,?,?,0)",
                                 rid, k % 3 == 0 ? "group" : "chat", String(format: "Perf Raum %03d ", k) + r.pick(words), "", me, rt, rt)
                try store.db.run("INSERT OR REPLACE INTO members(room_id, user_id, role, display_name, username, color) VALUES(?,?,?,?,?,?)",
                                 rid, me, "owner", "Ich", "ich", 0)
                var mt = rt
                for j in 0..<r.int(3..<16) {
                    mt += Double(r.int(60..<200_000))
                    try store.db.run("""
                        INSERT INTO messages(id, room_id, author_id, device_id, kind, body, payload, created_at, deleted, seq, pending)
                        VALUES(?,?,?,?,?,?,?,?,0,?,0)
                        """, "\(rid)-m\(j)", rid, me, model.myDevice, "text", sentence(&r, r.int(2..<12)), "{}", mt, j + 1)
                }
                store.set("read:\(rid)", r.chance(0.1) ? "0" : "99")
            }
        }
        model.revision += 1
    }
}
#endif

#if DEBUG && os(iOS)
import QuartzCore
import UIKit

/// Nur Debug: misst Hänger (Hitches) beim Scrollen wie Apples „Hitch Time Ratio“ – im Simulator liefert XCTest dafür keine Werte.
/// Ein Scroll-Vorgang = Bilder, in denen die Run-Loop im Tracking-Modus läuft (Ziehen + Ausrollen). Je Vorgang eine Zeile in
/// Documents/perf-hitches.txt: Kennung (THREAD_PERF_TAG), Bilder, Dauer, Hitch-Zeit.
final class FrameMonitor: NSObject {
    static let shared = FrameMonitor()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, dur = 0.0, hitch = 0.0, idle = 0, worst = 0.0
    /// Arbeit des Main-Threads je Run-Loop-Durchgang während des Scrollens; über 8,3 ms = Hänger auf 120-Hz-Displays (iPhone 13 Pro)
    private var busyStart: CFTimeInterval = 0, busy = 0.0, over120 = 0.0, longest = 0.0
    private var observer: CFRunLoopObserver?
    private let tag = ProcessInfo.processInfo.environment["THREAD_PERF_TAG"] ?? "-"
    /// Programmatisches Scrollen (THREAD_PERF_AUTOSCROLL) zählt wie Ziehen/Ausrollen – ohne XCTest-Abfragen dazwischen
    var autoScrolling = false
    private var measuring: Bool { autoScrolling || RunLoop.current.currentMode == .tracking }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                   true, 0) { [weak self] _, act in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if act == .afterWaiting { self.busyStart = now; return }
            guard self.busyStart > 0, self.measuring else { return }
            let b = now - self.busyStart
            self.busy += b
            self.longest = max(self.longest, b)
            if b > 1.0 / 120 { self.over120 += b - 1.0 / 120 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let delta = l.timestamp - last
        let expected = max(1.0 / 120, l.targetTimestamp - l.timestamp)
        if measuring {
            idle = 0
            frames += 1
            dur += delta
            if delta > expected * 1.5 { hitch += delta - expected; worst = max(worst, delta) }
        } else if frames > 0 {
            idle += 1
            if idle > 10 { flush() }
        }
    }

    /// Nur während der Leistungsmessung: Dauer eines Vorgangs auf dem Main-Thread (z. B. neue Seite übernehmen) nach
    /// Documents/perf-events.txt, um lange Bilder einer Ursache zuzuordnen.
    func note(_ what: String, since t0: CFTimeInterval) {
        guard link != nil else { return }
        let line = String(format: "%@ %@ ms=%.1f\n", tag, what, (CACurrentMediaTime() - t0) * 1000)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf-events.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func flush() {
        let line = String(format: "%@ frames=%d dur=%.3f hitch_ms=%.1f worst_ms=%.1f busy_ms=%.1f over120_ms=%.1f longest_ms=%.1f\n",
                          tag, frames, dur, hitch * 1000, worst * 1000, busy * 1000, over120 * 1000, longest * 1000)
        frames = 0; dur = 0; hitch = 0; idle = 0; worst = 0; busy = 0; over120 = 0; longest = 0
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("perf-hitches.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
#endif
