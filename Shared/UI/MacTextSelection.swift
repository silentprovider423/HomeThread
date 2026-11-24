#if os(macOS)
import AppKit
import SwiftUI

/// Mac: Text über mehrere Einträge hinweg markieren – wie im Browser bzw. am Desktop-Messenger. Jede Text-Blase
/// meldet sich hier an; Klicken und Ziehen im Verlauf setzt Anfang und Ende (Eintrag + Zeichen), jede Blase färbt
/// ihren Teil blau, am oberen und unteren Rand scrollt der Verlauf beim Ziehen mit, ⌘C kopiert alles zusammen.
/// Doppelklick markiert ein Wort, Dreifachklick den ganzen Eintrag; Klick auf einen Link öffnet ihn.
@MainActor
final class MacTextSelection {
    struct Point: Equatable {
        var row: String
        var index: Int
    }

    private(set) var anchor: Point?
    private(set) var focus: Point?
    /// Reihenfolge der Einträge im Verlauf und ihr reiner Text (für die Bereiche und zum Kopieren)
    private var order: [String] = []
    private var position: [String: Int] = [:]
    private var texts: [String: String] = [:]
    private var views: [String: WeakText] = [:]
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// aus, solange die Mehrfachauswahl läuft (dann gehört der Klick dem Haken)
    var enabled = true {
        didSet { if !enabled { clear() } }
    }
    private var monitor: Any?
    private var dragging = false
    private var moved = false
    private var downPoint: NSPoint = .zero
    private var lastDrag: NSEvent?
    private var autoscroll: Timer?

    private final class WeakText { weak var view: SelectableTextView?; init(_ v: SelectableTextView) { view = v } }

    var hasSelection: Bool {
        guard let a = anchor, let f = focus else { return false }
        return a != f
    }

    // MARK: Einträge und Blasen

    func update(rows: [TimelineRow]) {
        order = rows.map(\.id)
        position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var t: [String: String] = [:]
        for r in rows where r.message.kind == .text { t[r.id] = String((r.rich?.value ?? AttributedString(r.message.body)).characters) }
        texts = t
        if let a = anchor, position[a.row] == nil { clear() }
    }

    func register(_ v: SelectableTextView, row: String) {
        views[row] = WeakText(v)
        v.applySelection(range(for: row))
    }

    func unregister(_ v: SelectableTextView, row: String) {
        if views[row]?.view === v { views[row] = nil }
    }

    /// Markierter Teil eines Eintrags (nil = nichts)
    func range(for row: String) -> NSRange? {
        guard hasSelection, let a = anchor, let f = focus, let pa = position[a.row], let pf = position[f.row],
              let pr = position[row], let len = texts[row].map({ ($0 as NSString).length }) else { return nil }
        let (s, e, ps, pe) = (pa, a.index) <= (pf, f.index) ? (a, f, pa, pf) : (f, a, pf, pa)
        guard pr >= ps, pr <= pe else { return nil }
        let from = pr == ps ? min(s.index, len) : 0
        let to = pr == pe ? min(e.index, len) : len
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    func clear() {
        guard anchor != nil || focus != nil else { return }
        anchor = nil
        focus = nil
        refresh()
    }

    private func set(anchor a: Point?, focus f: Point?) {
        anchor = a
        focus = f
        refresh()
    }

    private func refresh() {
        for (row, w) in views { w.view?.applySelection(range(for: row)) }
    }

    /// Markierter Text, Einträge durch Leerzeile getrennt
    var selectedText: String {
        guard hasSelection, let a = anchor, let f = focus, let pa = position[a.row], let pf = position[f.row] else { return "" }
        return order[min(pa, pf)...max(pa, pf)].compactMap { row -> String? in
            guard let r = range(for: row), let t = texts[row] else { return nil }
            return (t as NSString).substring(with: r)
        }.joined(separator: "\n\n")
    }

    // MARK: Maus und Tastatur

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] e in
            guard let self else { return e }
            // Ereignisse kommen immer auf dem Haupt-Thread an; true = selbst behandelt, nicht weitergeben
            nonisolated(unsafe) let event = e
            let swallow = MainActor.assumeIsolated { self.handle(event) }
            return swallow ? nil : e
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopAutoscroll()
    }

    private func handle(_ e: NSEvent) -> Bool {
        switch e.type {
        case .leftMouseDown:
            guard enabled, let (row, view) = textView(at: e), !e.modifierFlags.contains(.control) else {
                // Klick daneben hebt die Markierung auf (der Klick selbst geht normal weiter)
                if hasSelection, e.window === views.values.first(where: { $0.view != nil })?.view?.window { clear() }
                return false
            }
            let i = view.characterIndex(at: e.locationInWindow, clamp: true)
            view.window?.makeFirstResponder(nil)
            switch e.clickCount {
            case 2:
                let r = view.wordRange(at: i)
                set(anchor: Point(row: row, index: r.location), focus: Point(row: row, index: NSMaxRange(r)))
            case 3...:
                set(anchor: Point(row: row, index: 0), focus: Point(row: row, index: view.length))
            default:
                set(anchor: Point(row: row, index: i), focus: Point(row: row, index: i))
            }
            dragging = true
            moved = false
            downPoint = e.locationInWindow
            return true
        case .leftMouseDragged:
            guard dragging else { return false }
            if hypot(e.locationInWindow.x - downPoint.x, e.locationInWindow.y - downPoint.y) > 3 { moved = true }
            lastDrag = e
            extend(to: e)
            startAutoscrollIfNeeded(e)
            return true
        case .leftMouseUp:
            guard dragging else { return false }
            dragging = false
            stopAutoscroll()
            if !moved, e.clickCount <= 1, let (_, view) = textView(at: e),
               let url = view.link(at: view.characterIndex(at: e.locationInWindow, clamp: false)) {
                clear()
                openURL(url)
            }
            return true
        case .keyDown:
            guard hasSelection else { return false }
            if e.keyCode == 53 { clear(); return true }  // Esc
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "c", !inputHasSelection(e.window) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selectedText, forType: .string)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Eingabefeld hat selbst eine Markierung → ⌘C gehört ihm
    private func inputHasSelection(_ w: NSWindow?) -> Bool {
        guard let tv = w?.firstResponder as? NSTextView, tv.isEditable else { return false }
        return tv.selectedRange().length > 0
    }

    fileprivate func liveViews(in window: NSWindow?) -> [(String, SelectableTextView)] {
        views.compactMap { row, w in w.view.flatMap { $0.window === window && $0.window != nil ? (row, $0) : nil } }
    }

    private func textView(at e: NSEvent) -> (String, SelectableTextView)? {
        liveViews(in: e.window).first { _, v in v.isVisibleInScroll && v.bounds.contains(v.convert(e.locationInWindow, from: nil)) }
    }

    /// Ende der Markierung beim Ziehen: Blase unter der Maus, sonst die senkrecht nächste sichtbare
    private func extend(to e: NSEvent) {
        guard let a = anchor else { return }
        let candidates = liveViews(in: e.window).filter { $0.1.isVisibleInScroll }
        guard !candidates.isEmpty else { return }
        func distance(_ v: SelectableTextView) -> CGFloat {
            let p = v.convert(e.locationInWindow, from: nil)
            if p.y >= 0 && p.y <= v.bounds.height { return 0 }
            return p.y < 0 ? -p.y : p.y - v.bounds.height
        }
        guard let (row, view) = candidates.min(by: { distance($0.1) < distance($1.1) }) else { return }
        let f = Point(row: row, index: view.characterIndex(at: e.locationInWindow, clamp: true))
        if f != focus { set(anchor: a, focus: f) }
    }

    // MARK: Mitscrollen am Rand

    private func scrollView(for e: NSEvent) -> NSScrollView? {
        liveViews(in: e.window).lazy.compactMap { $0.1.enclosingScrollView }.first
    }

    private func edgeDelta(_ e: NSEvent, _ sv: NSScrollView) -> CGFloat {
        let p = sv.convert(e.locationInWindow, from: nil)
        let h = sv.bounds.height, edge: CGFloat = 36
        // NSScrollView ist nicht gespiegelt: y = 0 unten
        let fromBottom = sv.isFlipped ? h - p.y : p.y
        if fromBottom < edge { return min(40, (edge - fromBottom) * 0.8 + 4) }          // nach unten
        if fromBottom > h - edge { return -min(40, (fromBottom - (h - edge)) * 0.8 + 4) } // nach oben
        return 0
    }

    private func startAutoscrollIfNeeded(_ e: NSEvent) {
        guard let sv = scrollView(for: e), edgeDelta(e, sv) != 0 else { stopAutoscroll(); return }
        guard autoscroll == nil else { return }
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
    }

    private func autoscrollTick() {
        guard dragging, let e = lastDrag, let sv = scrollView(for: e) else { stopAutoscroll(); return }
        let d = edgeDelta(e, sv)
        guard d != 0, let doc = sv.documentView else { stopAutoscroll(); return }
        let clip = sv.contentView
        var o = clip.bounds.origin
        o.y = min(max(0, o.y + (clip.isFlipped ? d : -d)), max(0, doc.frame.height - clip.bounds.height))
        clip.scroll(to: o)
        sv.reflectScrolledClipView(clip)
        extend(to: e)
    }

    private func stopAutoscroll() {
        autoscroll?.invalidate()
        autoscroll = nil
    }
}

#if DEBUG
extension MacTextSelection {
    /// Nur Debug (THREAD_SELECT_TEST=<datei>): echte Maus-Ereignisse nachspielen – in der obersten sichtbaren Text-Blase
    /// drücken, zur untersten ziehen, loslassen – und den markierten Text in die Datei schreiben.
    func debugDragAcross(to file: String) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let vis = liveViews(in: w).filter { $0.1.isVisibleInScroll }
            .map { ($0, $1, $1.convert(NSPoint(x: 4, y: 6), to: nil)) }
            .sorted { $0.2.y > $1.2.y }  // oben zuerst (Fensterkoordinaten wachsen nach oben)
        guard let top = vis.first, let bottom = vis.last, vis.count > 1 else { return }
        let start = top.1.convert(NSPoint(x: min(30, top.1.bounds.width / 2), y: 6), to: nil)
        let end = bottom.1.convert(NSPoint(x: bottom.1.bounds.width * 0.6, y: bottom.1.bounds.height - 4), to: nil)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let e = ev(.leftMouseDown, start) { NSApp.sendEvent(e) }
        for k in 1...10 {
            let t = CGFloat(k) / 10
            if let e = ev(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)) { NSApp.sendEvent(e) }
        }
        if let e = ev(.leftMouseUp, end) { NSApp.sendEvent(e) }
        try? "\(vis.count) Blasen sichtbar\n---\n\(selectedText)".write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Nur Debug: in der untersten Blase drücken, über den oberen Rand hinaus ziehen und dort halten (Mitscrollen)
    func debugDragUpward(to file: String) async {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let vis = liveViews(in: w).filter { $0.1.isVisibleInScroll }.map { ($0, $1, $1.convert(NSPoint(x: 4, y: 6), to: nil)) }
            .sorted { $0.2.y < $1.2.y }
        guard let bottom = vis.first, let sv = bottom.1.enclosingScrollView else { return }
        let start = bottom.1.convert(NSPoint(x: bottom.1.bounds.width * 0.8, y: bottom.1.bounds.height - 4), to: nil)
        let svTop = sv.convert(NSPoint(x: 0, y: sv.isFlipped ? 0 : sv.bounds.height), to: nil)
        let above = NSPoint(x: start.x, y: svTop.y - 10)
        func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let before = sv.contentView.bounds.origin.y
        if let e = ev(.leftMouseDown, start) { NSApp.sendEvent(e) }
        if let e = ev(.leftMouseDragged, above) { NSApp.sendEvent(e) }
        try? await Task.sleep(for: .seconds(1.5))
        let after = sv.contentView.bounds.origin.y
        if let e = ev(.leftMouseUp, above) { NSApp.sendEvent(e) }
        let parts = selectedText.components(separatedBy: "\n\n")
        try? "gescrollt um \(Int(abs(after - before))) pt, \(parts.count) Abschnitte markiert\nerster: \(parts.first ?? "")"
            .write(toFile: file, atomically: true, encoding: .utf8)
    }
}
#endif

/// Text einer Blase am Mac: zeichnet selbst (für die Markierung über mehrere Blasen), Links anklickbar.
final class SelectableTextView: NSTextView {
    private var highlighted: NSRange?
    var length: Int { (string as NSString).length }

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        setAccessibilityRole(.staticText)
    }

    /// sichtbar im Verlauf (nicht in einem längst weggescrollten, noch vorgehaltenen Bereich)
    var isVisibleInScroll: Bool { !visibleRect.isEmpty }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override var acceptsFirstResponder: Bool { false }

    func setContent(_ s: NSAttributedString) {
        guard textStorage?.isEqual(to: s) != true else { return }
        textStorage?.setAttributedString(s)
        highlighted = nil
    }

    func applySelection(_ r: NSRange?) {
        guard let lm = layoutManager, r != highlighted else { return }
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        if let r, NSMaxRange(r) <= length {
            lm.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: r)
        }
        highlighted = r
        needsDisplay = true
    }

    /// Zeichen an einer Fensterstelle; `clamp` = Punkte über/unter/neben dem Text auf Anfang/Ende ziehen
    func characterIndex(at windowPoint: NSPoint, clamp: Bool) -> Int {
        guard let lm = layoutManager, let tc = textContainer else { return 0 }
        let p = convert(windowPoint, from: nil)
        if clamp {
            if p.y < 0 { return 0 }
            if p.y > bounds.height { return length }
        }
        lm.ensureLayout(for: tc)
        let q = NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), max(0, bounds.height - 1)))
        var fraction: CGFloat = 0
        let i = lm.characterIndex(for: q, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(length, i + (fraction > 0.5 ? 1 : 0))
    }

    func wordRange(at i: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        return selectionRange(forProposedRange: NSRange(location: min(i, length - 1), length: 0), granularity: .selectByWord)
    }

    func link(at i: Int) -> URL? {
        guard i < length, let v = textStorage?.attribute(.link, at: i, effectiveRange: nil) else { return nil }
        return (v as? URL) ?? (v as? String).flatMap(URL.init(string:))
    }

    /// Höhe und benötigte Breite bei höchstens `width`
    func fittingSize(width: CGFloat) -> CGSize {
        guard let lm = layoutManager, let tc = textContainer else { return .zero }
        tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        return CGSize(width: min(width, ceil(used.width) + 1), height: ceil(used.height))
    }
}

/// SwiftUI-Hülle der Blasen-Texte am Mac
struct SelectableBubbleText: NSViewRepresentable {
    let row: String
    let text: AttributedString
    let selection: MacTextSelection?

    func makeNSView(context: Context) -> SelectableTextView {
        let v = SelectableTextView()
        v.linkTextAttributes = [.foregroundColor: NSColor(Theme.link), .cursor: NSCursor.pointingHand]
        v.setContent(Self.convert(text))
        v.setAccessibilityLabel(String(text.characters))
        selection?.register(v, row: row)
        return v
    }

    func updateNSView(_ v: SelectableTextView, context: Context) {
        v.setContent(Self.convert(text))
        selection?.register(v, row: row)
    }

    static func dismantleNSView(_ v: SelectableTextView, coordinator: ()) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: SelectableTextView, context: Context) -> CGSize? {
        v.fittingSize(width: proposal.width ?? 560)
    }

    /// Formatierten Text (fett, kursiv, Links) in AppKit-Attribute übersetzen
    static func convert(_ a: AttributedString) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let out = NSMutableAttributedString()
        let color = NSColor(Theme.text1Bubble), link = NSColor(Theme.link)
        for run in a.runs {
            let s = String(a[run.range].characters)
            var font = base
            if let i = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if i.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if i.contains(.emphasized) { traits.insert(.italic) }
                if i.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
                if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let url = run.link {
                attrs[.link] = url
                attrs[.foregroundColor] = link
            }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        return out
    }
}

private struct MacTextSelectionKey: EnvironmentKey {
    static let defaultValue: MacTextSelection? = nil
}

extension EnvironmentValues {
    var macTextSelection: MacTextSelection? {
        get { self[MacTextSelectionKey.self] }
        set { self[MacTextSelectionKey.self] = newValue }
    }
}
#endif
