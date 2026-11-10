import SwiftUI
#if os(iOS)
import Photos
import UIKit
#else
import AppKit
#endif

/// Eine Aktion des Eintrags-Menüs. Dieselbe Liste speist das Kontextmenü (lange drücken bzw. Rechtsklick) und
/// auf dem Mac das Aufklapp-Menü neben der Bubble.
struct MessageAction: Identifiable {
    enum Kind {
        case run(() -> Void)
        case shareFile(URL)
        case shareText(String)
    }

    let id: String
    /// fertig übersetzt (das iPhone-Menü ist UIKit und braucht Text, keinen Schlüssel)
    let title: String
    let icon: String
    var destructive = false
    let kind: Kind
}

enum MessageMenuBuilder {
    /// Aktionen in Gruppen (Trennlinie dazwischen): Kopieren · Antworten/Weiterleiten/Bearbeiten/Merken/Anheften ·
    /// Sichern/Teilen · Details/Löschen
    @MainActor static func groups(row: TimelineRow, model: AppModel, actions: BubbleActions) -> [[MessageAction]] {
        let message = row.message
        var copy: [MessageAction] = [], main: [MessageAction] = [], out: [MessageAction] = [], end: [MessageAction] = []
        if message.kind == .text || message.kind == .checklist || message.kind == .poll {
            copy.append(MessageAction(id: "copy", title: String(localized: "Kopieren"), icon: "doc.on.doc",
                                      kind: .run { Clipboard.copy(model.store?.searchText(message) ?? message.body) }))
        }
        if message.kind == .image, let u = row.attachmentURL {
            copy.append(MessageAction(id: "copyImage", title: String(localized: "Kopieren"), icon: "doc.on.doc", kind: .run { Clipboard.copyImage(u) }))
        }
        if !message.pending && message.failed == nil {
            copy.append(MessageAction(id: "link", title: String(localized: "Link zum Eintrag kopieren"), icon: "link",
                                      kind: .run { Clipboard.copy(EntryLink.make(message).absoluteString) }))
        }
        if message.failed != nil {
            main.append(MessageAction(id: "retry", title: String(localized: "Erneut versuchen"), icon: "arrow.clockwise", kind: .run { model.retry(message) }))
        }
        main.append(MessageAction(id: "reply", title: String(localized: "Darauf antworten"), icon: "arrowshape.turn.up.left",
                                  kind: .run { actions.onReply(message) }))
        main.append(MessageAction(id: "forward", title: String(localized: "Weiterleiten …"), icon: "arrowshape.turn.up.right",
                                  kind: .run { actions.onForward(message) }))
        if message.kind == .text && row.mine {
            main.append(MessageAction(id: "edit", title: String(localized: "Bearbeiten"), icon: "pencil", kind: .run { actions.onEdit(message) }))
        }
        main.append(MessageAction(id: "star", title: row.starred ? String(localized: "Nicht mehr merken") : String(localized: "Merken"),
                                  icon: row.starred ? "star.slash" : "star", kind: .run { model.toggleStar(message) }))
        main.append(MessageAction(id: "pin", title: message.pinned ? String(localized: "Lösen") : String(localized: "Oben anheften"),
                                  icon: message.pinned ? "pin.slash" : "pin", kind: .run { model.togglePin(message) }))
        if message.kind == .poll && message.payload.closed != true && row.mine {
            main.append(MessageAction(id: "closePoll", title: String(localized: "Abstimmung beenden"), icon: "checkmark.seal",
                                      kind: .run { model.closePoll(message) }))
        }
        if message.attachment != nil, message.payload.missing != true {
            #if os(macOS)
            out.append(MessageAction(id: "save", title: String(localized: "Sichern unter …"), icon: "square.and.arrow.down",
                                     kind: .run { actions.onSave(message) }))
            #else
            if message.hasMedia {
                out.append(MessageAction(id: "save", title: String(localized: "In Fotos sichern"), icon: "square.and.arrow.down",
                                         kind: .run { actions.onSave(message) }))
            }
            #endif
        }
        if message.kind == .text || message.kind == .checklist || message.kind == .poll {
            let speaking = Speaker.shared.speaking == message.id
            out.append(MessageAction(id: "speak", title: speaking ? String(localized: "Vorlesen beenden") : String(localized: "Vorlesen"),
                                     icon: speaking ? "speaker.slash" : "speaker.wave.2",
                                     kind: .run { Speaker.shared.toggle(id: message.id, text: model.store?.searchText(message) ?? message.body) }))
        }
        if let item = row.attachmentURL {
            out.append(MessageAction(id: "share", title: String(localized: "Teilen …"), icon: "square.and.arrow.up", kind: .shareFile(item)))
        } else if message.kind == .text {
            out.append(MessageAction(id: "share", title: String(localized: "Teilen …"), icon: "square.and.arrow.up", kind: .shareText(message.body)))
        }
        end.append(MessageAction(id: "select", title: String(localized: "Auswählen …"), icon: "checkmark.circle", kind: .run { actions.onSelect(message) }))
        end.append(MessageAction(id: "details", title: String(localized: "Details"), icon: "info.circle", kind: .run { actions.onDetails(message) }))
        end.append(MessageAction(id: "delete", title: String(localized: "Löschen"), icon: "trash", destructive: true,
                                 kind: .run { actions.onDelete(message) }))
        return [copy, main, out, end].filter { !$0.isEmpty }
    }

    #if os(iOS)
    /// iPhone: Menü beim langen Drücken – oben die Reaktionen als Leiste, darunter die Aktionen.
    @MainActor static func uiMenu(row: TimelineRow, model: AppModel, actions: BubbleActions, presenter: UIView?) -> UIMenu {
        let message = row.message
        let mine = Set(row.reactions.filter(\.mine).map(\.emoji))
        func palette(_ emojis: ArraySlice<String>) -> UIMenu {
            UIMenu(options: [.displayInline, .displayAsPalette], children: emojis.map { e in
                UIAction(title: e, image: Reactions.image(e), state: mine.contains(e) ? .on : .off) { _ in model.toggleReaction(message, emoji: e) }
            })
        }
        var moreRows: [UIMenuElement] = stride(from: 0, to: Reactions.more.count, by: 6).map { palette(Reactions.more[$0..<min($0 + 6, Reactions.more.count)]) }
        moreRows.append(UIAction(title: String(localized: "Alle Emojis …"), image: UIImage(systemName: "magnifyingglass")) { _ in actions.onPickEmoji(message) })
        let more = UIMenu(title: String(localized: "Weitere Reaktionen"), image: UIImage(systemName: "face.smiling"), children: moreRows)
        var children: [UIMenuElement] = [palette(Reactions.quick[...]), more]
        for group in groups(row: row, model: model, actions: actions) {
            children.append(UIMenu(options: .displayInline, children: group.map { a in
                UIAction(title: a.title, image: UIImage(systemName: a.icon), attributes: a.destructive ? .destructive : []) { _ in
                    switch a.kind {
                    case .run(let run): run()
                    case .shareFile(let url): share([url], from: presenter)
                    case .shareText(let text): share([text], from: presenter)
                    }
                }
            }))
        }
        return UIMenu(children: children)
    }

    @MainActor private static func share(_ items: [Any], from view: UIView?) {
        guard let view, var top = view.window?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        top.present(vc, animated: true)
    }
    #endif
}

/// Reaktionen: Schnellleiste oben im Menü und die weitere Auswahl
enum Reactions {
    static let quick = ["👍", "👎", "❤️", "😂", "😢", "🙏"]
    static let more = ["😮", "🎉", "🔥", "✅", "❌", "❓", "❗️", "👀", "💡", "⭐️", "🙌", "👏", "💪", "🤔", "😅", "😍", "🥳", "😴",
                       "🤝", "☕️", "🍀", "📌", "⏰", "💤"]

    #if os(iOS)
    /// Emoji als Bild: die Reaktionsleiste des Systemmenüs zeigt nur Bilder, keinen Emoji-Text
    static func image(_ emoji: String) -> UIImage {
        if let i = cache.object(forKey: emoji as NSString) { return i }
        let font = UIFont(name: "AppleColorEmoji", size: 26) ?? UIFont.systemFont(ofSize: 26)
        let size = (emoji as NSString).size(withAttributes: [.font: font])
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            (emoji as NSString).draw(at: .zero, withAttributes: [.font: font])
        }.withRenderingMode(.alwaysOriginal)
        cache.setObject(img, forKey: emoji as NSString)
        return img
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()
    #endif
}

#if os(iOS)
/// Platz der Bubble innerhalb ihrer Zeile – damit das Menü nur die Bubble anhebt, nicht die ganze Zeile
@MainActor enum BubbleFrames {
    static var frames: [String: CGRect] = [:]
}
#endif

/// Knopf einer Aktion im Kontextmenü
struct MessageActionButton: View {
    let action: MessageAction

    var body: some View {
        switch action.kind {
        case .run(let run):
            Button(role: action.destructive ? .destructive : nil, action: run) { Label(action.title, systemImage: action.icon) }
        case .shareFile(let url):
            ShareLink(item: url) { Label(action.title, systemImage: action.icon) }
        case .shareText(let text):
            ShareLink(item: text) { Label(action.title, systemImage: action.icon) }
        }
    }
}

#if os(macOS)
/// Mac: Aufklapp-Menü neben der Bubble – oben die Reaktionen, darunter die Aktionen in Gruppen.
struct MessageMenuPopover: View {
    let groups: [[MessageAction]]
    /// eigene Reaktionen an diesem Eintrag (hervorgehoben)
    let mine: Set<String>
    let react: (String) -> Void
    /// volle Emoji-Auswahl mit Suche öffnen
    var pickEmoji: () -> Void = {}
    let close: () -> Void
    @State private var showMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Reactions.quick, id: \.self) { emojiButton($0) }
                Button { withAnimation(.easeOut(duration: 0.12)) { showMore.toggle() } } label: {
                    Image(systemName: showMore ? "face.smiling.inverse" : "face.smiling")
                        .font(.system(size: 17)).foregroundStyle(Theme.text2)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("Weitere Reaktionen"))
                .accessibilityIdentifier("menu.moreReactions")
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            if showMore {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7), spacing: 2) {
                    ForEach(Reactions.more, id: \.self) { emojiButton($0) }
                }
                .padding(.horizontal, 8).padding(.bottom, 4)
                Button { close(); pickEmoji() } label: {
                    Label("Alle Emojis …", systemImage: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("menu.allEmojis")
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Divider().padding(.vertical, 4)
                ForEach(group) { a in MessageMenuRow(action: a, close: close) }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 244)
    }

    private func emojiButton(_ e: String) -> some View {
        Button { react(e) } label: {
            Text(e).font(.system(size: 20))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(mine.contains(e) ? Theme.reactionPillMine : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menu.reaction.\(e)")
    }
}

private struct MessageMenuRow: View {
    let action: MessageAction
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        Group {
            switch action.kind {
            case .run(let run):
                Button { close(); run() } label: { label }
            case .shareFile(let url):
                ShareLink(item: url) { label }
            case .shareText(let text):
                ShareLink(item: text) { label }
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityIdentifier("menu.\(action.id)")
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon).font(.system(size: 13))
                .foregroundStyle(action.destructive ? Color.red : Theme.accent).frame(width: 18)
            Text(verbatim: action.title).font(.system(size: 14)).foregroundStyle(action.destructive ? Color.red : Theme.text1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(hover ? Theme.otherBubble : .clear)
        .contentShape(Rectangle())
    }
}
#endif

/// „Weiterleiten“: Eintrag als Kopie in einen anderen Chat legen.
struct ForwardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// ein Eintrag oder (Mehrfachauswahl) mehrere, in der Reihenfolge des Verlaufs
    let messages: [Message]
    var onDone: (Room) -> Void = { _ in }
    @State private var query = ""

    var body: some View {
        let rooms = (model.summaries(archived: false) + model.summaries(archived: true)).map(\.room)
            .filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        NavigationStack {
            List {
                Section {
                    TextField("Suchen", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("forward.search")
                }
                Section {
                    ForEach(rooms) { r in
                        Button { forward(to: r) } label: {
                            HStack(spacing: 12) {
                                Avatar(title: r.title, image: r.avatar, isGroup: r.kind == .group, size: 36, colorKey: r.id)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.title).foregroundStyle(.primary).lineLimit(1)
                                    if r.archived { Text("Archiviert").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("forward.room.\(r.title)")
                    }
                    if rooms.isEmpty { Text("Kein Chat gefunden").foregroundStyle(.secondary) }
                } footer: {
                    Text("Die Auswahl wird als Kopie in den gewählten Chat gelegt. Das Original bleibt, wo es ist.")
                }
            }
            .navigationTitle("Weiterleiten an")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 400, height: 480)
        #endif
    }

    private func forward(to room: Room) {
        dismiss()
        Task {
            var ok = false
            for m in messages { if await model.forward(m, to: room.id) { ok = true } }
            if ok { onDone(room) }
        }
    }
}

/// „Details“ eines Eintrags: Art, Verfasser, Gerät, Zeiten, Abgleich, Inhalt und Merkmale.
struct MessageDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let message: Message

    var body: some View {
        // frisch aus der Ablage, falls sich seit dem Öffnen etwas geändert hat
        let m = model.store?.message(message.id) ?? message
        let reactions = model.store?.reactions(room: m.roomId, me: model.me)[m.id] ?? []
        let starred = model.store?.starredIDs(room: m.roomId).contains(m.id) ?? false
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Art", value: Self.kindTitle(m.kind))
                    LabeledContent("Verfasser", value: m.authorId == model.me ? String(localized: "Ich") : (model.user(m.authorId)?.displayName ?? "–"))
                    if let d = m.deviceId, let name = model.devices[d]?.name { LabeledContent("Gerät", value: name) }
                }
                Section {
                    LabeledContent("Erstellt", value: m.createdAt.formatted(date: .complete, time: .standard))
                    if let e = m.editedAt { LabeledContent("Bearbeitet", value: e.formatted(date: .complete, time: .standard)) }
                    LabeledContent("Abgleich", value: status(m))
                }
                content(m)
                Section {
                    LabeledContent("Angeheftet", value: m.pinned ? String(localized: "Ja") : String(localized: "Nein"))
                    LabeledContent("Gemerkt", value: starred ? String(localized: "Ja") : String(localized: "Nein"))
                    if !reactions.isEmpty {
                        LabeledContent("Reaktionen", value: reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji }.joined(separator: "  "))
                    }
                }
                if let history = m.payload.history, !history.isEmpty {
                    Section {
                        ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, e in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Date(timeIntervalSince1970: e.at).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(verbatim: e.body).textSelection(.enabled)
                            }
                            .accessibilityIdentifier("details.version")
                        }
                    } header: {
                        Text("Frühere Fassungen (\(history.count))")
                    } footer: {
                        Text("Jedes Bearbeiten hebt die vorherige Fassung auf, höchstens die letzten 20.")
                    }
                }
                Section {
                    LabeledContent("Kennung") { Text(verbatim: m.id).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 440, height: 520)
        #endif
    }

    private func status(_ m: Message) -> String {
        if let f = m.failed { return String(localized: "Fehlgeschlagen") + (f.isEmpty ? "" : " (\(f))") }
        return m.pending ? String(localized: "Wartet auf Abgleich") : String(localized: "Abgeglichen")
    }

    @ViewBuilder
    private func content(_ m: Message) -> some View {
        let p = m.payload
        switch m.kind {
        case .text:
            Section {
                LabeledContent("Zeichen", value: m.body.count.formatted())
                LabeledContent("Wörter", value: m.body.split(whereSeparator: { $0.isWhitespace }).count.formatted())
            }
        case .image, .video, .file, .voice:
            Section {
                if let n = p.filename { LabeledContent("Dateiname", value: n) }
                if let s = p.size, s > 0 { LabeledContent("Größe", value: Fmt.size(s)) }
                if let t = p.mime { LabeledContent("Typ", value: t) }
                if let w = p.w, let h = p.h, w > 0 { LabeledContent("Abmessungen", value: "\(w) × \(h)") }
                if let d = p.duration { LabeledContent("Dauer", value: Fmt.duration(d)) }
            }
        case .location:
            Section {
                if let n = p.name, !n.isEmpty { LabeledContent("Ort", value: n) }
                if let lat = p.lat, let lon = p.lon { LabeledContent("Koordinaten", value: "\(lat), \(lon)") }
            }
        case .poll:
            Section {
                LabeledContent("Antworten", value: (p.options?.count ?? 0).formatted())
                LabeledContent("Beendet", value: p.closed == true ? String(localized: "Ja") : String(localized: "Nein"))
            }
        case .checklist:
            let items = model.store?.items(message: m.id) ?? []
            Section {
                LabeledContent("Punkte", value: "\(items.count { $0.done }) / \(items.count)")
            }
        }
    }

    static func kindTitle(_ k: MessageKind) -> String {
        switch k {
        case .text: String(localized: "Text")
        case .voice: String(localized: "Sprachnotiz")
        case .image: String(localized: "Foto")
        case .video: String(localized: "Video")
        case .file: String(localized: "Datei")
        case .location: String(localized: "Ort")
        case .poll: String(localized: "Abstimmung")
        case .checklist: String(localized: "Checkliste")
        }
    }
}

/// Bilder und Videos sichern: iPhone in die Fotomediathek, Mac über „Sichern unter“.
enum MediaSaver {
    #if os(iOS)
    static func saveToPhotos(_ url: URL, video: Bool) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if video { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
            }
            return true
        } catch {
            return false
        }
    }
    #else
    @MainActor static func saveAs(_ url: URL, name: String) -> Bool {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        guard p.runModal() == .OK, let dest = p.url else { return false }
        try? FileManager.default.removeItem(at: dest)
        return (try? FileManager.default.copyItem(at: url, to: dest)) != nil
    }
    #endif
}

/// Alle Emojis mit Suche (Unicode-Namen, deutsche Suchwörter), „Zuletzt benutzt“ oben.
struct EmojiPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private static func title(_ id: String) -> LocalizedStringKey {
        switch id {
        case "smileys": "Smileys"
        case "hearts": "Herzen"
        case "people": "Hände & Menschen"
        case "nature": "Tiere & Natur"
        case "food": "Essen & Trinken"
        case "travel": "Aktivität & Reisen"
        case "objects": "Dinge"
        default: "Symbole"
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 40), spacing: 4)]

    var body: some View {
        let hits = query.trimmingCharacters(in: .whitespaces).isEmpty ? nil : EmojiCatalog.search(query)
        let recent = EmojiCatalog.recent
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Emoji suchen", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("emoji.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Suche leeren"))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16).padding(.bottom, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                        if let hits {
                            if hits.isEmpty {
                                Text("Kein Emoji gefunden").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                            } else {
                                grid(hits.map(\.value))
                            }
                        } else {
                            if !recent.isEmpty { section("Zuletzt benutzt", recent) }
                            ForEach(EmojiCatalog.sections, id: \.id) { s in section(Self.title(s.id), s.emojis.map(\.value)) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            .navigationTitle("Reaktion wählen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        .onAppear { searching = true }
        #endif
    }

    private func section(_ title: LocalizedStringKey, _ emojis: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            grid(emojis)
        }
    }

    private func grid(_ emojis: [String]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(emojis, id: \.self) { e in
                Button {
                    EmojiCatalog.noteUsed(e)
                    onPick(e)
                    dismiss()
                } label: {
                    Text(e).font(.system(size: 28)).frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("emoji.\(e)")
            }
        }
    }
}

/// Leiste unten im Chat während der Mehrfachauswahl: Anzahl, Kopieren, Weiterleiten, Löschen, Abbrechen.
struct SelectionBar: View {
    let count: Int
    var onCopy: () -> Void
    var onForward: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button("Abbrechen", action: onCancel).accessibilityIdentifier("select.cancel")
            Spacer()
            Text("\(count) ausgewählt").font(.subheadline.weight(.semibold)).monospacedDigit()
                .accessibilityIdentifier("select.count")
            Spacer()
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .help(Text("Kopieren")).accessibilityLabel(Text("Kopieren")).accessibilityIdentifier("select.copy")
            Button(action: onForward) { Image(systemName: "arrowshape.turn.up.right") }
                .help(Text("Weiterleiten …")).accessibilityLabel(Text("Weiterleiten …")).accessibilityIdentifier("select.forward")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .help(Text("Löschen")).accessibilityLabel(Text("Löschen")).accessibilityIdentifier("select.delete")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .font(.body)
        .disabled(false)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.barBackground)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 0.5) }
    }
}
