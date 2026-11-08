import MapKit
import QuickLook
import SwiftUI

/// Zusammenhang, den jede Bubble braucht (einmal je Raum abgefragt).
struct BubbleContext {
    var reactions: [String: [ReactionCount]]
    var starred: Set<String>
    var byID: [String: Message]
    var isGroup: Bool
}

struct MessageBubble: View {
    @Environment(AppModel.self) private var model
    let message: Message
    let ctx: BubbleContext
    var highlighted = false
    var compactTop = false
    var onReply: (Message) -> Void = { _ in }
    var onJump: (String) -> Void = { _ in }
    var onEdit: (Message) -> Void = { _ in }
    var onOpenMedia: (Message) -> Void = { _ in }
    @State private var dragX: CGFloat = 0
    @State private var confirmDelete = false

    var mine: Bool { message.authorId == model.me }
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
        HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                bubble
                if let r = ctx.reactions[message.id], !r.isEmpty { reactionPills(r) }
            }
            if !mine { Spacer(minLength: 40) }
        }
        #if os(macOS)
        .padding(.horizontal, 14)
        .padding(.top, compactTop ? 4 : 8)
        #else
        .padding(.horizontal, 8)
        .padding(.top, compactTop ? 2 : 6)
        #endif
        .offset(x: dragX)
        .overlay(alignment: .leading) {
            if dragX > 20 {
                Image(systemName: "arrowshape.turn.up.left.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                    .opacity(min(1, dragX / 55)).padding(.leading, 4)
            }
        }
        #if os(iOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in
                    if abs(v.translation.width) > abs(v.translation.height) * 1.5, v.translation.width > 0 {
                        dragX = min(80, v.translation.width)
                    }
                }
                .onEnded { _ in
                    if dragX >= 55 { onReply(message) }
                    withAnimation(.spring(duration: 0.25)) { dragX = 0 }
                }
        )
        #endif
        .confirmationDialog("Eintrag auf allen Geräten löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { model.deleteMessage(message) }
        }
        .id(message.id)
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                if ctx.isGroup && !mine {
                    Text(model.user(message.authorId)?.displayName ?? String(localized: "Person"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.color(for: message.authorId))
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
        .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
        #if os(iOS)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous))
        #endif
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bubble.\(message.kind.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(Self.rich(message.body))
                .textSelection(.enabled)
                .font(Self.textFont)
                .foregroundStyle(Theme.text1Bubble)
                .tint(Theme.link)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bubble.text.\(message.body.prefix(40))")
        case .image, .video:
            MediaThumb(message: message).onTapGesture { onOpenMedia(message) }
            if !message.body.isEmpty { Text(message.body).padding(.horizontal, 8) }
        case .voice: VoiceBubble(message: message)
        case .file: FileBubble(message: message)
        case .location: LocationBubble(message: message)
        case .poll: PollBubble(message: message)
        case .checklist: ChecklistBubble(message: message)
        }
    }

    private var meta: some View {
        HStack(spacing: 4) {
            if ctx.starred.contains(message.id) { Image(systemName: "star.fill").foregroundStyle(Theme.star) }
            if let d = message.deviceId, d != model.myDevice {
                Image(systemName: model.devices[d]?.platform == "mac" ? "laptopcomputer" : "iphone")
                    .accessibilityLabel(Text("von anderem Gerät"))
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
        let q = ctx.byID[id] ?? model.store?.message(id)
        return Button { onJump(id) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(quoteColor(q)).frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.flatMap { model.user($0.authorId)?.displayName } ?? String(localized: "Eintrag"))
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
        guard let q, ctx.isGroup, q.authorId != model.me else { return Theme.accent }
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

    /// Links (auch nackte Adressen) und einfache Hervorhebungen (**fett**, _kursiv_) anzeigen, Text sonst unverändert lassen.
    static func rich(_ s: String) -> AttributedString {
        if let c = richCache.object(forKey: s as NSString) { return c.value }
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        let plain = String(a.characters)
        if plain.contains("."), let det = linkDetector {
            var from = a.startIndex
            for m in det.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = m.url, let r = Range(m.range, in: plain), from < a.endIndex,
                      let ar = a[from...].range(of: String(plain[r])) else { continue }
                if a[ar].link == nil { a[ar].link = url }
                from = ar.upperBound
            }
        }
        richCache.setObject(RichBox(value: a), forKey: s as NSString)
        return a
    }

    private final class RichBox { let value: AttributedString; init(value: AttributedString) { self.value = value } }
    nonisolated(unsafe) private static let richCache: NSCache<NSString, RichBox> = { let c = NSCache<NSString, RichBox>(); c.countLimit = 3000; return c }()
    nonisolated(unsafe) private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static let quickReactions = ["👍", "👎", "❤️", "😂", "😢", "🙏"]
    static let moreReactions = ["🎉", "🔥", "✅", "❓", "👀", "💡", "⭐️", "😮"]

    @ViewBuilder
    private var menu: some View {
        ControlGroup {
            ForEach(Self.quickReactions, id: \.self) { e in
                Button(e) { model.toggleReaction(message, emoji: e) }
            }
        }
        .controlGroupStyle(.palette)
        Menu {
            ForEach(Self.moreReactions, id: \.self) { e in Button(e) { model.toggleReaction(message, emoji: e) } }
        } label: { Label("Weitere Reaktionen", systemImage: "face.smiling") }
        Divider()
        Button { model.toggleStar(message) } label: {
            ctx.starred.contains(message.id) ? Label("Nicht mehr merken", systemImage: "star.slash") : Label("Merken", systemImage: "star")
        }
        if message.failed != nil {
            Button { model.retry(message) } label: { Label("Erneut versuchen", systemImage: "arrow.clockwise") }
        }
        Button { onReply(message) } label: { Label("Darauf antworten", systemImage: "arrowshape.turn.up.left") }
        if message.kind == .text && mine {
            Button { onEdit(message) } label: { Label("Bearbeiten", systemImage: "pencil") }
        }
        Button { model.togglePin(message) } label: {
            message.pinned ? Label("Lösen", systemImage: "pin.slash") : Label("Oben anheften", systemImage: "pin")
        }
        Divider()
        if message.kind == .text || message.kind == .checklist || message.kind == .poll {
            Button { Clipboard.copy(model.store?.searchText(message) ?? message.body) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        if message.kind == .image, let a = message.attachment, let u = model.store?.fileURL(a) {
            Button { Clipboard.copyImage(u) } label: { Label("Kopieren", systemImage: "doc.on.doc") }
        }
        if let item = shareItem {
            ShareLink(item: item) { Label("Teilen …", systemImage: "square.and.arrow.up") }
        } else if message.kind == .text {
            ShareLink(item: message.body) { Label("Teilen …", systemImage: "square.and.arrow.up") }
        }
        if message.kind == .poll && message.payload.closed != true && mine {
            Button { model.closePoll(message) } label: { Label("Abstimmung beenden", systemImage: "checkmark.seal") }
        }
        Divider()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
    }

    private var shareItem: URL? {
        guard let a = message.attachment else { return nil }
        return model.store?.fileURL(a)
    }
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
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let _ = model.revision
        let w = CGFloat(max(1, message.payload.w ?? 4)), h = CGFloat(max(1, message.payload.h ?? 3))
        let ratio = min(max(w / h, 0.6), 1.8)
        ZStack {
            LocalImage(url: (message.thumb ?? message.attachment).flatMap { model.store?.fileURL($0) }, maxPixel: 700)
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
    @State private var player = VoicePlayer.shared

    var body: some View {
        let _ = model.revision
        let url = message.attachment.flatMap { model.store?.fileURL($0) }
        let playing = player.playingID == message.id
        HStack(spacing: 10) {
            Button {
                if let url { player.toggle(id: message.id, url: url) }
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34)).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(url == nil)
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

    var body: some View {
        let _ = model.revision
        let votes = model.store?.votes(message: message.id) ?? [:]
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
    @State private var newItem = ""
    @State private var hideDone = false
    @FocusState private var adding: Bool

    var body: some View {
        let _ = model.revision
        let items = model.store?.items(message: message.id) ?? []
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
