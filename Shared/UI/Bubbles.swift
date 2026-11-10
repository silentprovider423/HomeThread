import MapKit
import QuickLook
import SwiftUI

/// Aktionen einer Bubble (vom Chat bereitgestellt).
struct BubbleActions {
    var onReply: (Message) -> Void = { _ in }
    var onJump: (String) -> Void = { _ in }
    var onEdit: (Message) -> Void = { _ in }
    var onOpenMedia: (Message) -> Void = { _ in }
    /// Löschen bestätigen (ein Dialog im Chat statt einem je Bubble)
    var onDelete: (Message) -> Void = { _ in }
    var onForward: (Message) -> Void = { _ in }
    var onDetails: (Message) -> Void = { _ in }
    /// Bild/Video/Datei sichern (iPhone: Fotos, Mac: „Sichern unter“)
    var onSave: (Message) -> Void = { _ in }
}

/// Eine Zeile des Verlaufs: (iPhone) Datums-Pille bei Tageswechsel, ggf. „Neu von anderem Gerät“, dann die Bubble.
struct TimelineRowView: View {
    let row: TimelineRow
    var highlighted = false
    var actions = BubbleActions()

    var body: some View {
        VStack(spacing: 0) {
            if let pill = row.dayPill {
                DayPill(text: pill).padding(.top, 12).padding(.bottom, 4)
            }
            if let n = row.unreadCount { NewFromOtherDeviceLine(count: n) }
            MessageBubble(row: row, highlighted: highlighted, actions: actions)
        }
        #if os(iOS)
        .coordinateSpace(.named("row"))
        #endif
        .tint(Theme.accent)
        .id(row.id)
    }
}

/// Bubble eines Eintrags. Alle Daten kommen vorbereitet aus `TimelineRow` – kein Datenbankzugriff beim Zeichnen.
struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let row: TimelineRow
    var highlighted = false
    var actions = BubbleActions()
    #if os(macOS)
    @State private var hover = false
    @State private var showMenu = false
    #endif

    var message: Message { row.message }
    var mine: Bool { row.mine }
    #if os(macOS)
    static let padV: CGFloat = 8, padH: CGFloat = 10
    static let textFont = Font.system(size: 14)
    #else
    static let padV: CGFloat = 7, padH: CGFloat = 12
    static let textFont = Font.body
    #endif
    var maxWidth: CGFloat {
        #if os(macOS)
        return 560
        #else
        return 320
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                bubble
                if !row.reactions.isEmpty { reactionPills(row.reactions) }
            }
            if !mine { Spacer(minLength: 40) }
        }
        #if os(macOS)
        .padding(.horizontal, 14)
        .padding(.top, row.compactTop ? 4 : 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        #else
        .padding(.horizontal, 8)
        .padding(.top, row.compactTop ? 2 : 6)
        #endif
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if let name = row.authorName {
                    Text(name).font(.caption.weight(.semibold)).foregroundStyle(Theme.color(for: message.authorId))
                }
                if let r = message.replyTo { quote(r) }
                content
            }
            meta
        }
        .padding(.vertical, message.hasMedia ? 2 : Self.padV)
        .padding(.horizontal, message.hasMedia ? 2 : Self.padH)
        .background(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                .fill(highlighted ? (mine ? Theme.ownBubbleSelected : Theme.otherBubbleSelected) : (mine ? Theme.ownBubble : Theme.otherBubble))
        )
        .overlay(alignment: .topTrailing) {
            if message.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.pinned)
                    .padding(5).rotationEffect(.degrees(45))
            }
        }
        #if os(macOS)
        // Pfeil direkt neben der sichtbaren Bubble (innen), unabhängig von ihrer Breite
        .overlay(alignment: mine ? .topLeading : .topTrailing) { menuButton.offset(x: mine ? -28 : 28, y: 3) }
        #if DEBUG
        // Nur Debug (THREAD_MENU=<Text>): Menü dieses Eintrags fest neben der Bubble zeigen – für Bildschirmfotos ohne Maus
        .overlay(alignment: .topLeading) {
            if model.debugMenu == message.body {
                MessageMenuPopover(groups: actionGroups, mine: Set(row.reactions.filter(\.mine).map(\.emoji)), react: { _ in }, close: {})
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
                    .fixedSize()
                    .offset(x: -290, y: -120)
            }
        }
        #endif
        #endif
        .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
        // iPhone: das Menü (lange drücken) stellt die Tabelle des Verlaufs, siehe `ChatHistory`; dafür merkt sich die
        // Bubble ihren Platz in der Zeile (ändert sich nur beim Umbruch, nicht beim Scrollen)
        #if os(macOS)
        .contextMenu { menu }
        #else
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("row")) } action: { BubbleFrames.frames[row.id] = $0 }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bubble.\(message.kind.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(row.rich?.value ?? AttributedString(message.body))
                .textSelection(.enabled)
                .font(Self.textFont)
                .foregroundStyle(Theme.text1Bubble)
                .tint(Theme.link)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bubble.text.\(message.body.prefix(40))")
        case .image, .video:
            MediaThumb(row: row).onTapGesture { actions.onOpenMedia(message) }
            if !message.body.isEmpty { Text(message.body).padding(.horizontal, 8) }
        case .voice: VoiceBubble(message: message, url: row.attachmentURL, ref: row.attachmentRef)
        case .file: FileBubble(message: message)
        case .location: LocationBubble(message: message)
        case .poll: PollBubble(message: message, votes: row.votes)
        case .checklist: ChecklistBubble(message: message, items: row.items)
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if row.starred { Image(systemName: "star.fill").foregroundStyle(Theme.star) }
            if let sym = row.deviceSymbol {
                Image(systemName: sym).accessibilityLabel(Text("von anderem Gerät"))
            }
            Text(stampText).monospacedDigit()
            if message.failed != nil {
                Button { model.retry(message) } label: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Erneut versuchen"))
            } else if mine && message.pending {
                Image(systemName: "clock").accessibilityLabel(Text("wartet auf Abgleich"))
            }
        }
        #if os(macOS)
        .font(.system(size: 12))
        #else
        .font(.caption2)
        #endif
        .foregroundStyle(Theme.metaText)
        .padding(.horizontal, message.hasMedia ? 8 : 0)
        .padding(.bottom, message.hasMedia ? 4 : 0)
    }

    /// Mac: Datum + Uhrzeit wie am Desktop („14. Okt., 20:13“), iPhone: Uhrzeit; bearbeitet mit Vorsatz „Bearbeitet“.
    private var stampText: String {
        #if os(macOS)
        let t = Fmt.stamp(message.editedAt ?? message.createdAt)
        #else
        let t = Fmt.time(message.editedAt ?? message.createdAt)
        #endif
        return message.editedAt != nil ? String(localized: "Bearbeitet \(t)") : t
    }

    private func quote(_ id: String) -> some View {
        let q = row.quote
        return Button { actions.onJump(id) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(quoteColor(q)).frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.quoteAuthor ?? (q != nil && q?.authorId == model.me ? model.session?.user.displayName : nil) ?? String(localized: "Eintrag"))
                        .font(.caption.weight(.bold)).foregroundStyle(quoteColor(q))
                    Group {
                        if let q, !q.deleted { PreviewText(message: q) } else {
                            Text(q == nil ? String(localized: "Eintrag nicht gefunden") : String(localized: "Gelöschter Eintrag"))
                        }
                    }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, message.hasMedia ? 8 : 0)
        .padding(.top, message.hasMedia ? 6 : 0)
    }

    private func quoteColor(_ q: Message?) -> Color {
        guard let q, row.isGroup, q.authorId != model.me else { return Theme.accent }
        return Theme.color(for: q.authorId)
    }

    private func reactionPills(_ r: [ReactionCount]) -> some View {
        HStack(spacing: 4) {
            ForEach(r) { x in
                Button { model.toggleReaction(message, emoji: x.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(x.emoji)
                        if x.count > 1 { Text("\(x.count)").font(.caption2.monospacedDigit()) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(minWidth: 20)
                    .background(Capsule().fill(x.mine ? Theme.reactionPillMine : Theme.reactionPill))
                    .overlay(Capsule().strokeBorder(Theme.reactionBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reaction.\(x.emoji)")
            }
        }
        .font(.callout)
    }

    var actionGroups: [[MessageAction]] { MessageMenuBuilder.groups(row: row, model: model, actions: actions) }

    #if os(macOS)
    /// Rechtsklick: gleiche Aktionen wie im Aufklapp-Menü, Reaktionen als Untermenü
    @ViewBuilder
    private var menu: some View {
        Menu {
            ForEach(Reactions.quick + Reactions.more, id: \.self) { e in Button(e) { model.toggleReaction(message, emoji: e) } }
        } label: { Label("Reagieren", systemImage: "face.smiling") }
        ForEach(Array(actionGroups.enumerated()), id: \.offset) { _, group in
            Divider()
            ForEach(group) { MessageActionButton(action: $0) }
        }
    }
    #endif

    #if os(macOS)
    /// Mac: Pfeil neben der Bubble (erscheint beim Überfahren) – öffnet Reaktionen und Aktionen
    private var menuButton: some View {
        Button { showMenu = true } label: {
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.otherBubble))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hover || showMenu || model.debugMenu == message.body ? 1 : 0)
        .help(Text("Aktionen"))
        .accessibilityLabel(Text("Aktionen"))
        .accessibilityIdentifier("bubble.menu")
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            MessageMenuPopover(groups: actionGroups, mine: Set(row.reactions.filter(\.mine).map(\.emoji)),
                               react: { model.toggleReaction(message, emoji: $0); showMenu = false },
                               close: { showMenu = false })
        }
    }
    #endif

}

/// Zwischenablage für iPhone und Mac.
enum Clipboard {
    static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
    }

    static func copyImage(_ url: URL) {
        #if os(iOS)
        if let i = UIImage(contentsOfFile: url.path) { UIPasteboard.general.image = i }
        #else
        if let i = NSImage(contentsOf: url) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([i]) }
        #endif
    }
}

// MARK: - Inhalte der Bubbles

struct MediaThumb: View {
    let row: TimelineRow

    var body: some View {
        let message = row.message
        let w = CGFloat(max(1, message.payload.w ?? 4)), h = CGFloat(max(1, message.payload.h ?? 3))
        let ratio = min(max(w / h, 0.6), 1.8)
        ZStack {
            // feste Größe aus den Metadaten, Bild verkleinert im Hintergrund (Vorschau oder Original)
            MessageImage(url: row.thumbURL, ref: row.thumbRef, maxPixel: 750)
            if message.kind == .video {
                Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
                if let d = message.payload.duration {
                    Text(Fmt.duration(d)).font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.5)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(8)
                }
            }
        }
        .frame(width: 250, height: 250 / ratio)
        .clipShape(RoundedRectangle(cornerRadius: Theme.bubbleRadius - 2, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityLabel(Text(message.kind == .video ? "Video" : "Foto"))
    }
}

struct VoiceBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let url: URL?
    /// noch nicht geladen: beim Antippen holen und dann abspielen
    var ref: FileRef?
    @State private var player = VoicePlayer.shared
    @State private var loading = false

    var body: some View {
        let playing = player.playingID == message.id
        HStack(spacing: 10) {
            Button {
                if let url { player.toggle(id: message.id, url: url); return }
                guard let ref, !loading else { return }
                loading = true
                Task {
                    if let u = await model.file(ref) { player.toggle(id: message.id, url: u) }
                    loading = false
                }
            } label: {
                if loading {
                    ProgressView().frame(width: 34, height: 34)
                } else {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(Theme.accent)
                }
            }
            .buttonStyle(.plain)
            .disabled(url == nil && ref == nil)
            .accessibilityLabel(Text(playing ? "Pause" : "Abspielen"))
            Waveform(values: message.payload.wave ?? Array(repeating: 0.3, count: 30), progress: playing ? player.progress : 0)
                .frame(width: 150, height: 26)
            Text(Fmt.duration(message.payload.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct Waveform: View {
    let values: [Double]
    var progress: Double = 0

    var body: some View {
        GeometryReader { g in
            let n = max(values.count, 1)
            let bw = max(1.5, g.size.width / CGFloat(n) - 2)
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    Capsule()
                        .fill(Double(i) / Double(n) < progress ? Theme.accent : Color.secondary.opacity(0.5))
                        .frame(width: bw, height: max(3, g.size.height * v))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

struct FileBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    @State private var preview: URL?
    @State private var loading = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.15)).frame(width: 40, height: 48)
                    if loading { ProgressView().controlSize(.small) } else {
                        Image(systemName: missing ? "doc.badge.ellipsis" : "doc.fill").font(.title3)
                            .foregroundStyle(missing ? Color.secondary : Theme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.payload.filename ?? String(localized: "Datei")).font(.callout.weight(.medium)).lineLimit(2)
                    if missing {
                        Text("Nicht mehr verfügbar").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(Fmt.size(message.payload.size ?? 0)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .quickLookPreview($preview)
    }

    private var missing: Bool { message.attachment == nil && message.payload.missing == true }

    private func open() {
        guard let a = message.attachment else { return }
        loading = true
        Task {
            preview = await model.ensureFile(id: a, name: message.payload.filename ?? "datei", mime: message.payload.mime ?? "application/octet-stream")
            loading = false
        }
    }
}

struct LocationBubble: View {
    @Environment(\.openURL) private var openURL
    let message: Message

    var body: some View {
        let lat = message.payload.lat ?? 0, lon = message.payload.lon ?? 0
        VStack(alignment: .leading, spacing: 6) {
            MapSnapshot(lat: lat, lon: lon)
                .frame(width: 240, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Label(message.payload.name?.isEmpty == false ? message.payload.name! : String(format: "%.5f, %.5f", lat, lon),
                  systemImage: "mappin.and.ellipse")
                .font(.callout).lineLimit(2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let q = (message.payload.name ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(q)") { openURL(u) }
        }
    }
}

/// Statisches Kartenbild (MKMapSnapshotter) statt einer lebenden Karte je Bubble – leichter beim Scrollen.
struct MapSnapshot: View {
    let lat: Double
    let lon: Double
    @Environment(\.colorScheme) private var scheme
    @State private var image: PlatformImage?
    private static let cache = NSCache<NSString, PlatformImage>()

    var body: some View {
        ZStack {
            if let image {
                #if os(iOS)
                Image(uiImage: image).resizable().scaledToFill()
                #else
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                Rectangle().fill(.quaternary)
            }
            Image(systemName: "mappin.circle.fill").font(.system(size: 30)).symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.accent).shadow(radius: 2)
        }
        .task(id: "\(lat),\(lon),\(scheme == .dark)") { await load() }
    }

    private func load() async {
        let key = "\(lat),\(lon),\(scheme == .dark)" as NSString
        if let c = Self.cache.object(forKey: key) { image = c; return }
        let o = MKMapSnapshotter.Options()
        o.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), latitudinalMeters: 700, longitudinalMeters: 700)
        o.size = CGSize(width: 480, height: 280)
        #if os(iOS)
        o.traitCollection = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        #else
        o.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        #endif
        guard let snap = try? await MKMapSnapshotter(options: o).start() else { return }
        Self.cache.setObject(snap.image, forKey: key)
        image = snap.image
    }
}

struct PollBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let votes: [String: [String]]

    var body: some View {
        let mineVote = Set(votes[model.me] ?? [])
        let closed = message.payload.closed == true
        let showCounts = closed || message.payload.showInterim != false
        let options = message.payload.options ?? []
        let counts = Dictionary(uniqueKeysWithValues: options.map { o in (o.id, votes.values.filter { $0.contains(o.id) }.count) })
        let maxCount = counts.values.max() ?? 0
        let voters = votes.values.filter { !$0.isEmpty }.count
        VStack(alignment: .leading, spacing: 8) {
            Label(message.payload.question ?? "", systemImage: "chart.bar.xaxis").font(.callout.weight(.semibold))
            ForEach(options) { o in
                Button {
                    guard !closed else { return }
                    var s = mineVote
                    if message.payload.multi == true {
                        if s.contains(o.id) { s.remove(o.id) } else { s.insert(o.id) }
                    } else {
                        s = s.contains(o.id) ? [] : [o.id]
                    }
                    model.vote(message, choices: options.map(\.id).filter { s.contains($0) })
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: mineVote.contains(o.id) ? (message.payload.multi == true ? "checkmark.square.fill" : "checkmark.circle.fill")
                                  : (message.payload.multi == true ? "square" : "circle"))
                                .foregroundStyle(mineVote.contains(o.id) ? Theme.accent : .secondary)
                            Text(o.text).frame(maxWidth: .infinity, alignment: .leading)
                            if closed && maxCount > 0 && counts[o.id] == maxCount {
                                Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.caption)
                            }
                            if showCounts { Text("\(counts[o.id] ?? 0)").monospacedDigit().foregroundStyle(.secondary) }
                        }
                        if showCounts {
                            GeometryReader { g in
                                Capsule().fill(.secondary.opacity(0.2))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Theme.accent)
                                            .frame(width: g.size.width * CGFloat(counts[o.id] ?? 0) / CGFloat(max(1, voters)))
                                    }
                            }
                            .frame(height: 5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("poll.option.\(o.text)")
            }
            HStack {
                Text(closed ? String(localized: "Beendet · \(voters) Stimme(n)") : (message.payload.multi == true
                     ? String(localized: "Mehrere Antworten möglich") : String(localized: "Tippen zum Abstimmen")))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !closed && message.authorId == model.me {
                    Button("Beenden") { model.closePoll(message) }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        .accessibilityIdentifier("poll.close")
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
    }
}

struct ChecklistBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let items: [ChecklistItem]
    @State private var newItem = ""
    @State private var hideDone = false
    @FocusState private var adding: Bool

    var body: some View {
        let done = items.filter(\.done).count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(message.body.isEmpty ? String(localized: "Checkliste") : message.body, systemImage: "checklist")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(done)/\(items.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ForEach(items.filter { !hideDone || !$0.done }) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { model.toggleItem(i) } label: {
                        Image(systemName: i.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(i.done ? Theme.accent : .secondary).font(.title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("check.\(i.text)")
                    Text(i.text).strikethrough(i.done).foregroundStyle(i.done ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    Button(role: .destructive) { model.deleteItem(i) } label: { Label("Punkt löschen", systemImage: "trash") }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).font(.title3)
                TextField("Punkt hinzufügen", text: $newItem)
                    .textFieldStyle(.plain)
                    .focused($adding)
                    .onSubmit {
                        model.addItem(message, text: newItem)
                        newItem = ""
                        adding = true
                    }
                    .accessibilityIdentifier("check.add")
            }
            if done > 0 {
                Button(hideDone ? "Erledigte zeigen" : "Erledigte ausblenden") { hideDone.toggle() }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
    }
}
