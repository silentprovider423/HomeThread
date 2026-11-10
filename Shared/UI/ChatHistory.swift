import SwiftUI

/// Wunsch an den Verlauf, zu einem Eintrag zu scrollen (`token` macht gleiche Ziele wiederholbar).
struct ScrollRequest: Equatable {
    var id: String
    var token = UUID()
    var animated = true
}

#if os(iOS)
import UIKit

/// Verlauf als UITableView (wie Threema): Zellen-Wiederverwendung, Diffable Data Source, Höhen-Cache je Eintrag,
/// Nachladen älterer Seiten ohne Sprung (Scroll-Anker), Wischen zum Antworten. Die Bubbles bleiben SwiftUI
/// (UIHostingConfiguration) und bekommen vorbereitete Zeilen – kein Datenbankzugriff beim Scrollen.
struct ChatHistory: UIViewRepresentable {
    let model: AppModel
    let timeline: ChatTimeline
    /// nur damit SwiftUI bei neuen Ständen `updateUIView` aufruft
    let version: Int
    var highlight: String?
    var scrollRequest: ScrollRequest?
    var actions: BubbleActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatTableView {
        let t = ChatTableView(frame: .zero, style: .plain)
        context.coordinator.attach(t)
        return t
    }

    func updateUIView(_ t: ChatTableView, context: Context) {
        let c = context.coordinator
        c.model = model
        c.timeline = timeline
        c.actions = actions
        // erst übernehmen, wenn die erste Seite gelesen ist (sonst wäre die leere Tabelle schon „positioniert“)
        if timeline.loaded && timeline.version != c.appliedVersion { c.applyTimeline() }
        c.update(highlight: highlight)
        if let r = scrollRequest, r.token != c.lastScrollToken {
            c.lastScrollToken = r.token
            c.scroll(to: r.id, animated: r.animated)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate, UIGestureRecognizerDelegate {
        var model: AppModel?
        var timeline: ChatTimeline?
        var actions = BubbleActions()
        var appliedVersion = -1
        var lastScrollToken: UUID?
        private var highlight: String?
        private weak var table: ChatTableView?
        private var dataSource: UITableViewDiffableDataSource<Int, String>?
        private var rows: [String: TimelineRow] = [:]
        private var heights: [String: CGFloat] = [:]
        private var heightWidth: CGFloat = 0
        private var positioned = false
        private let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.circle.fill"))
        private let detailsArrow = UIImageView(image: UIImage(systemName: "info.circle.fill"))
        private var swipeCell: UITableViewCell?
        private var swipeID: String?

        #if DEBUG
        private let openedAt = CACurrentMediaTime()
        #endif

        func attach(_ t: ChatTableView) {
            table = t
            t.separatorStyle = .none
            t.backgroundColor = .clear
            t.allowsSelection = false
            t.keyboardDismissMode = .interactive
            t.rowHeight = UITableView.automaticDimension
            t.estimatedRowHeight = 70
            t.selfSizingInvalidation = .enabledIncludingConstraints
            t.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
            t.alpha = 0
            for k in MessageKind.allCases { t.register(UITableViewCell.self, forCellReuseIdentifier: k.rawValue) }
            t.delegate = self
            t.onWidthChange = { [weak self] in self?.heights.removeAll() }
            dataSource = UITableViewDiffableDataSource(tableView: t) { [weak self] tv, ip, id in
                guard let self, let row = self.rows[id] else { return UITableViewCell() }
                let cell = tv.dequeueReusableCell(withIdentifier: row.message.kind.rawValue, for: ip)
                self.configure(cell, row)
                return cell
            }
            dataSource?.defaultRowAnimation = .fade
            // Wischen nach rechts = antworten (wie im Messenger); hat Vorrang vor dem senkrechten Scrollen nur bei waagrechter Bewegung
            let pan = UIPanGestureRecognizer(target: self, action: #selector(swipe(_:)))
            pan.delegate = self
            t.addGestureRecognizer(pan)
            replyArrow.tintColor = UIColor(Theme.accent)
            replyArrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
            replyArrow.alpha = 0
            t.addSubview(replyArrow)
            detailsArrow.tintColor = UIColor(Theme.accent)
            detailsArrow.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
            detailsArrow.alpha = 0
            t.addSubview(detailsArrow)
        }

        private func configure(_ cell: UITableViewCell, _ row: TimelineRow) {
            guard let model else { return }
            let hl = highlight == row.id
            let actions = self.actions
            cell.backgroundConfiguration = .clear()
            cell.contentConfiguration = UIHostingConfiguration {
                TimelineRowView(row: row, highlighted: hl, actions: actions).environment(model)
            }
            .margins(.all, 0)
            .minSize(height: 1)
        }

        // MARK: Daten übernehmen

        func applyTimeline() {
            guard let timeline, let table, let dataSource else { return }
            #if DEBUG
            let t0 = CACurrentMediaTime()
            defer { FrameMonitor.shared.note("apply.\(timeline.change) rows=\(timeline.rows.count) changed=\(timeline.changed.count)", since: t0) }
            #endif
            appliedVersion = timeline.version
            applying = true
            defer { applying = false }
            let new = timeline.rows
            let wasNearBottom = table.isNearBottom
            let oldLast = rows.isEmpty ? nil : dataSource.snapshot().itemIdentifiers.last
            rows = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in timeline.changed { heights[id] = nil }
            var snap = NSDiffableDataSourceSnapshot<Int, String>()
            snap.appendSections([0])
            snap.appendItems(new.map(\.id))
            // nur sichtbare Zeilen neu konfigurieren: für unsichtbare baut UITableView sonst extra eine Zelle samt SwiftUI-Messung
            // (beim Voranstellen ~40–60 ms für die bisher erste Zeile); sie holen sich den neuen Stand beim nächsten Anzeigen
            let visible = Set((table.indexPathsForVisibleRows ?? []).compactMap { dataSource.itemIdentifier(for: $0) })
            let reconf = timeline.changed.filter { visible.contains($0) }
            if !reconf.isEmpty { snap.reconfigureItems(reconf) }

            switch timeline.change {
            case .initial:
                UIView.performWithoutAnimation { dataSource.apply(snap, animatingDifferences: false) }
                positionInitially()
            case .prepend:
                // Scroll-Anker: oberste sichtbare Zeile bleibt an derselben Stelle
                // ohne Layout zwischen apply und restore: sonst baut die Tabelle erst Zellen für die neuen Zeilen an der alten Stelle
                // (teure SwiftUI-Messung) und gleich danach wieder die alten → Hänger beim Hochscrollen.
                // Direkt danach aber layouten (an der neuen Stelle = vorhandene Zellen): sonst schiebt das aufgeschobene Layout
                // der Einfüge-Aktualisierung den Offset wieder zurück → Sprung um die ganze neue Seite.
                let anchor = captureAnchor()
                UIView.performWithoutAnimation {
                    dataSource.apply(snap, animatingDifferences: false)
                    restore(anchor)
                    table.layoutIfNeeded()
                    restore(anchor)
                }
            case .update:
                let newLast = new.last?.id
                UIView.performWithoutAnimation { dataSource.apply(snap, animatingDifferences: false) }
                if !positioned { positionInitially() } else if newLast != oldLast, let newLast,
                   wasNearBottom || rows[newLast]?.mine == true {
                    scrollToBottom(animated: true)
                }
            }
        }

        private func positionInitially() {
            guard let table else { return }
            if let id = pendingScroll {
                pendingScroll = nil
                scroll(to: id, animated: false)
            } else {
                // zweimal: nach der ersten Runde kennen die untersten Zellen ihre echte Höhe
                for _ in 0..<3 {
                    table.layoutIfNeeded()
                    table.scrollToBottom(animated: false)
                }
            }
            positioned = true
            UIView.animate(withDuration: 0.12) { table.alpha = 1 }
            #if DEBUG
            FrameMonitor.shared.note("open.visible", since: openedAt)
            if let v = ProcessInfo.processInfo.environment["THREAD_PERF_AUTOSCROLL"], let speed = Double(v), autoLink == nil {
                startAutoScroll(speed: speed)
            }
            #endif
        }

        #if DEBUG
        // Leistungsmessung: gleichmäßig bis zum ersten Eintrag hochscrollen (pt/s), Nachladen läuft wie beim Wischen mit.
        // Ohne XCTest-Abfragen während des Scrollens – die bauen bei jeder Abfrage alle geladenen Zeilen auf.
        private var autoLink: CADisplayLink?
        private var autoSpeed = 0.0, autoLast = 0.0, autoStart = 0.0
        private var autoStalls = 0

        private func startAutoScroll(speed: Double) {
            autoSpeed = speed
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))  // erst nach den Öffnen-Prüfungen des Tests (XCTest-Abfragen blockieren)
                let l = CADisplayLink(target: self, selector: #selector(autoTick(_:)))
                l.add(to: .main, forMode: .common)
                autoLink = l
                autoStart = CACurrentMediaTime()
                FrameMonitor.shared.autoScrolling = true
            }
        }

        @objc private func autoTick(_ l: CADisplayLink) {
            guard let table, let timeline else { return }
            defer { autoLast = l.timestamp }
            guard autoLast > 0 else { return }
            let top = -table.adjustedContentInset.top
            let y = max(top, table.contentOffset.y - autoSpeed * (l.timestamp - autoLast))
            table.contentOffset.y = y
            guard y <= top else { return }
            if timeline.hasOlder { autoStalls += 1; return }  // oben angeschlagen, ältere Seite noch nicht da
            l.invalidate()
            autoLink = nil
            FrameMonitor.shared.autoScrolling = false
            FrameMonitor.shared.note("autoscroll.done rows=\(timeline.rows.count) stalls=\(autoStalls)", since: autoStart)
        }
        #endif

        private var pendingScroll: String?
        /// während `apply` meldet die Tabelle noch den alten Offset (vor dem Anker) → kein Nachladen auslösen
        private var applying = false

        private func captureAnchor() -> (id: String, delta: CGFloat)? {
            guard let table, let dataSource else { return nil }
            let visible = table.indexPathsForVisibleRows ?? []
            guard let ip = visible.first(where: { table.rectForRow(at: $0).maxY > table.contentOffset.y + table.adjustedContentInset.top })
                    ?? visible.first, let id = dataSource.itemIdentifier(for: ip) else { return nil }
            return (id, table.rectForRow(at: ip).minY - table.contentOffset.y)
        }

        private func restore(_ a: (id: String, delta: CGFloat)?) {
            guard let a, let table, let ip = dataSource?.indexPath(for: a.id) else { return }
            let y = table.rectForRow(at: ip).minY - a.delta
            table.contentOffset = CGPoint(x: 0, y: y)
        }

        func update(highlight new: String?) {
            guard new != highlight else { return }
            let old = highlight
            highlight = new
            guard let dataSource else { return }
            var snap = dataSource.snapshot()
            let ids = [old, new].compactMap { $0 }.filter { snap.indexOfItem($0) != nil }
            guard !ids.isEmpty else { return }
            snap.reconfigureItems(ids)
            dataSource.apply(snap, animatingDifferences: false)
        }

        // MARK: Scrollen

        func scroll(to id: String, animated: Bool) {
            guard let table, let dataSource else { return }
            guard positioned else { pendingScroll = id; return }
            guard let ip = dataSource.indexPath(for: id) else { return }
            let near = (table.indexPathsForVisibleRows ?? []).contains { abs($0.row - ip.row) < 15 }
            if animated && near {
                table.scrollToRow(at: ip, at: .middle, animated: true)
            } else {
                // weit weg: erst ohne Animation hinspringen, dann mit gemessenen Höhen genau ausrichten
                for _ in 0..<3 {
                    table.scrollToRow(at: ip, at: .middle, animated: false)
                    table.layoutIfNeeded()
                }
            }
        }

        func scrollToBottom(animated: Bool) {
            table?.scrollToBottom(animated: animated)
        }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            guard positioned, !applying, let timeline, timeline.hasOlder else { return }
            // rechtzeitig vor dem oberen Rand nachladen (Threema: 1.500 pt), Daten liegen lokal → kein Warten
            if sv.contentOffset.y + sv.adjustedContentInset.top < 2500 { timeline.loadOlder() }
        }

        // MARK: Höhen

        func tableView(_ tv: UITableView, estimatedHeightForRowAt ip: IndexPath) -> CGFloat {
            guard let id = dataSource?.itemIdentifier(for: ip), let row = rows[id] else { return 70 }
            if heightWidth != tv.bounds.width { heightWidth = tv.bounds.width; heights.removeAll() }
            return heights[id] ?? Self.estimate(row, width: tv.bounds.width)
        }

        func tableView(_ tv: UITableView, willDisplay cell: UITableViewCell, forRowAt ip: IndexPath) {
            if let id = dataSource?.itemIdentifier(for: ip) { heights[id] = cell.bounds.height }
        }

        func tableView(_ tv: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt ip: IndexPath) {
            if let id = dataSource?.itemIdentifier(for: ip), cell.bounds.height > 1 { heights[id] = cell.bounds.height }
        }

        /// Schätzung ohne Layout (für Zeilen, die noch nie angezeigt wurden): je Art aus Textlänge bzw. Metadaten.
        static func estimate(_ r: TimelineRow, width: CGFloat) -> CGFloat {
            let m = r.message
            var h: CGFloat = r.compactTop ? 2 : 6
            if r.dayPill != nil { h += 41 }
            if r.unreadCount != nil { h += 38 }
            if r.authorName != nil { h += 18 }
            if m.replyTo != nil { h += 50 }
            if !r.reactions.isEmpty { h += 33 }
            let textW = max(120, min(320, width - 56) - 24)
            func lines(_ s: String) -> CGFloat {
                let perLine = max(10, textW / 8.6)
                return s.split(separator: "\n", omittingEmptySubsequences: false)
                    .reduce(0) { $0 + max(1, ceil(CGFloat($1.count) / perLine)) }
            }
            switch m.kind {
            case .text: h += lines(m.body) * 22 + 14 + 17
            case .image, .video:
                let w = CGFloat(max(1, m.payload.w ?? 4)), hh = CGFloat(max(1, m.payload.h ?? 3))
                h += 250 / min(max(w / hh, 0.6), 1.8) + 4 + 20 + (m.body.isEmpty ? 0 : lines(m.body) * 22 + 6)
            case .voice: h += 72
            case .file: h += 82
            case .location: h += 212
            case .poll: h += 92 + CGFloat(m.payload.options?.count ?? 2) * 46
            case .checklist: h += 104 + CGFloat(r.items.count) * 32
            }
            return ceil(h)
        }

        // MARK: Wischen zum Antworten

        // MARK: Menü beim langen Drücken (Reaktionsleiste + Aktionen)

        func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard let id = dataSource?.itemIdentifier(for: indexPath), rows[id] != nil else { return nil }
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
                guard let self, let row = self.rows[id], let model = self.model else { return nil }
                return MessageMenuBuilder.uiMenu(row: row, model: model, actions: self.actions, presenter: self.table)
            }
        }

        func tableView(_ tableView: UITableView, previewForHighlightingContextMenuWithConfiguration c: UIContextMenuConfiguration) -> UITargetedPreview? {
            menuPreview(c)
        }

        func tableView(_ tableView: UITableView, previewForDismissingContextMenuWithConfiguration c: UIContextMenuConfiguration) -> UITargetedPreview? {
            menuPreview(c)
        }

        /// Nur die Bubble anheben, nicht die ganze Zeile
        private func menuPreview(_ c: UIContextMenuConfiguration) -> UITargetedPreview? {
            guard let id = c.identifier as? String, let ip = dataSource?.indexPath(for: id), let cell = table?.cellForRow(at: ip),
                  cell.window != nil else { return nil }
            let p = UIPreviewParameters()
            p.backgroundColor = .clear
            if let f = BubbleFrames.frames[id], !f.isEmpty {
                p.visiblePath = UIBezierPath(roundedRect: f, cornerRadius: Theme.bubbleRadius)
            }
            return UITargetedPreview(view: cell.contentView, parameters: p)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer, let v = pan.view else { return false }
            let vel = pan.velocity(in: v)
            return abs(vel.x) > abs(vel.y) * 1.5
        }

        @objc private func swipe(_ g: UIPanGestureRecognizer) {
            guard let table else { return }
            switch g.state {
            case .began:
                let p = g.location(in: table)
                guard let ip = table.indexPathForRow(at: p), let cell = table.cellForRow(at: ip) else { return }
                swipeCell = cell
                swipeID = dataSource?.itemIdentifier(for: ip)
            case .changed:
                guard let cell = swipeCell else { return }
                // nach rechts = antworten, nach links = Details
                let x = min(80, max(-80, g.translation(in: table).x))
                cell.contentView.transform = CGAffineTransform(translationX: x, y: 0)
                replyArrow.sizeToFit()
                replyArrow.center = CGPoint(x: 4 + replyArrow.bounds.width / 2, y: cell.frame.maxY - 26)
                replyArrow.alpha = x > 20 ? min(1, x / 55) : 0
                table.bringSubviewToFront(replyArrow)
                detailsArrow.sizeToFit()
                detailsArrow.center = CGPoint(x: table.bounds.width - 4 - detailsArrow.bounds.width / 2, y: cell.frame.maxY - 26)
                detailsArrow.alpha = x < -20 ? min(1, -x / 55) : 0
                table.bringSubviewToFront(detailsArrow)
            default:
                guard let cell = swipeCell else { return }
                let x = g.translation(in: table).x
                if g.state == .ended, x >= 55, let id = swipeID, let m = rows[id]?.message {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    actions.onReply(m)
                } else if g.state == .ended, x <= -55, let id = swipeID, let m = rows[id]?.message {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    actions.onDetails(m)
                }
                UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                    cell.contentView.transform = .identity
                    self.replyArrow.alpha = 0
                    self.detailsArrow.alpha = 0
                }
                swipeCell = nil
                swipeID = nil
            }
        }
    }
}

/// Tabelle, die beim Ändern der Höhe (Tastatur, Eingabeleiste) unten bleibt, wenn sie unten war.
final class ChatTableView: UITableView {
    private var lastSize: CGSize = .zero
    var onWidthChange: (() -> Void)?

    var isNearBottom: Bool { distanceFromBottom(height: bounds.height) < 80 }

    private func distanceFromBottom(height: CGFloat) -> CGFloat {
        contentSize.height + adjustedContentInset.bottom - (contentOffset.y + height)
    }

    func scrollToBottom(animated: Bool) {
        let n = numberOfSections > 0 ? numberOfRows(inSection: 0) : 0
        guard n > 0 else { return }
        scrollToRow(at: IndexPath(row: n - 1, section: 0), at: .bottom, animated: animated)
    }

    override func layoutSubviews() {
        let size = bounds.size
        let stick = lastSize.height > 0 && size.height != lastSize.height && distanceFromBottom(height: lastSize.height) < 80
        if lastSize.width > 0 && size.width != lastSize.width { onWidthChange?() }
        lastSize = size
        super.layoutSubviews()
        if stick { scrollToBottom(animated: false) }
    }
}

#else

/// Mac: Verlauf als SwiftUI-Liste mit Scroll-Anker (`scrollPosition`) – gleiche vorbereitete Zeilen, gleiches
/// Fenster-Laden wie auf dem iPhone; beim Voranstellen älterer Seiten bleibt die oberste sichtbare Zeile stehen.
struct ChatHistory: View {
    let model: AppModel
    let timeline: ChatTimeline
    let version: Int
    var highlight: String?
    var scrollRequest: ScrollRequest?
    var actions: BubbleActions
    @State private var position = ScrollPosition(idType: String.self)
    @State private var positioned = false
    @State private var lastShown: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(timeline.rows) { row in
                    TimelineRowView(row: row, highlighted: highlight == row.id, actions: actions)
                        .onAppear { if row.id == timeline.rows.first?.id && positioned { timeline.loadOlder() } }
                }
            }
            .scrollTargetLayout()
            .padding(.top, 8).padding(.bottom, 12)
        }
        .scrollPosition($position, anchor: .top)
        .defaultScrollAnchor(.bottom)
        .onChange(of: version) { _, _ in
            if !positioned, let last = timeline.lastID {
                position.scrollTo(id: last, anchor: .bottom)
                positioned = true
                lastShown = last
            } else if timeline.change == .update, let last = timeline.lastID, last != lastShown {
                lastShown = last
                withAnimation { position.scrollTo(id: last, anchor: .bottom) }
            }
        }
        .onChange(of: scrollRequest) { _, r in
            guard let r else { return }
            if r.animated { withAnimation { position.scrollTo(id: r.id, anchor: .center) } } else { position.scrollTo(id: r.id, anchor: .center) }
        }
    }
}
#endif
