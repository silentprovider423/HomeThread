import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Ein Raum: Bubbles mit Datums-Pillen, angeheftete Leiste oben, Suche im Chat, Eingabeleiste unten.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let roomId: String
    /// Mac: Info rechts als Inspector
    var showInfo: Binding<Bool>?
    /// Beim Öffnen zu diesem Eintrag springen (aus Suche/Gemerkt)
    var jumpTo: String?

    @State private var text = ""
    @State private var replyTo: Message?
    @State private var editing: Message?
    @State private var limit = 200
    @State private var highlight: String?
    @State private var searching = false
    @State private var query = ""
    @State private var hitIndex = 0
    @State private var pinIndex = 0
    @State private var sheet: Sheet?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showInfoPush = false
    @State private var firstUnreadSeq: Int?
    @State private var scrollTarget: String?
    @State private var confirmDeleteRoom = false

    enum Sheet: Identifiable {
        case poll, checklist, location, camera, media(Message)
        var id: String {
            switch self {
            case .poll: return "poll"
            case .checklist: return "checklist"
            case .location: return "location"
            case .camera: return "camera"
            case .media(let m): return "media.\(m.id)"
            }
        }
    }

    var body: some View {
        let _ = model.revision
        if let room = model.store?.room(roomId) {
            chat(room)
        } else {
            ContentUnavailableView("Chat nicht gefunden", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        }
    }

    private func chat(_ room: Room) -> some View {
        let store = model.store!
        let messages = store.messages(room: roomId, limit: limit)
        let total = store.messageCount(room: roomId)
        let ctx = BubbleContext(reactions: store.reactions(room: roomId, me: model.me), starred: store.starredIDs(room: roomId),
                                byID: Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) }), isGroup: room.kind == .group && room.memberCount > 1)
        let pinned = messages.filter(\.pinned).sorted { $0.createdAt > $1.createdAt }
        let hits = searching && !query.isEmpty ? store.search(query, room: roomId) : []

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if total > messages.count {
                        Button("Frühere Einträge laden") { limit += 300 }.font(.footnote).padding(.vertical, 10)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        row(i, m, messages, ctx, proxy)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.chatBackground)
            .safeAreaInset(edge: .top, spacing: 0) { topBars(room, hits: hits, pinned: pinned, proxy: proxy) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                InputBar(roomId: roomId, text: $text, replyTo: $replyTo, editing: $editing) { a in
                    switch a {
                    case .camera: sheet = .camera
                    case .photos: showPhotos = true
                    case .location: sheet = .location
                    case .poll: sheet = .poll
                    case .checklist: sheet = .checklist
                    case .file: showFiles = true
                    }
                }
            }
            .onChange(of: messages.last?.id) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                model.markSeen(roomId)
            }
            .onChange(of: scrollTarget) { _, t in
                if let t { jump(to: t, proxy); scrollTarget = nil }
            }
        }
        #if os(iOS)
        .navigationTitle(room.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar(room) }
        #endif
        .confirmationDialog("Wirklich löschen?", isPresented: $confirmDeleteRoom) {
            Button("Löschen", role: .destructive) { model.deleteRoom(roomId) }
        } message: { Text("Der Raum und alle Einträge werden auf allen Geräten und auf dem Server gelöscht.") }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in importPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { model.sendFile(room: roomId, url: u, replyTo: replyTo?.id) }; replyTo = nil }
        }
        .sheet(item: $sheet) { s in sheetView(s) }
        #if os(iOS)
        .navigationDestination(isPresented: $showInfoPush) {
            RoomInfoView(roomId: roomId, onJump: { id in showInfoPush = false; scrollTarget = id },
                         onSearch: { showInfoPush = false; searching = true })
        }
        #endif
        .onAppear {
            if text.isEmpty, let d = model.store?.get("draft:\(roomId)") { text = d }
            let read = Int(model.store?.get("read:\(roomId)") ?? "0") ?? 0
            firstUnreadSeq = messages.first { $0.seq > read && $0.deviceId != model.myDevice && !$0.pending }?.seq
            model.markSeen(roomId)
            if model.debugShowInfo { model.debugShowInfo = false; openInfo() }
            if let j = jumpTo {
                Task { try? await Task.sleep(for: .milliseconds(350)); scrollTarget = j }
            }
        }
        .onDisappear { model.markSeen(roomId) }
    }

    /// Eine Zeile des Verlaufs: (iPhone) Datums-Pille bei Tageswechsel, ggf. „Neu von anderem Gerät“, dann die Bubble.
    @ViewBuilder
    private func row(_ i: Int, _ m: Message, _ messages: [Message], _ ctx: BubbleContext, _ proxy: ScrollViewProxy) -> some View {
        let prev = i > 0 ? messages[i - 1] : nil
        #if os(iOS)
        if prev == nil || !Calendar.current.isDate(prev!.createdAt, inSameDayAs: m.createdAt) {
            DayPill(date: m.createdAt).padding(.top, 12).padding(.bottom, 4)
        }
        #endif
        if let f = firstUnreadSeq, m.seq == f {
            NewFromOtherDeviceLine(count: messages.filter { $0.seq >= f && $0.deviceId != model.myDevice }.count)
        }
        let compact = prev.map { $0.authorId == m.authorId && m.createdAt.timeIntervalSince($0.createdAt) < 1800 } ?? false
        MessageBubble(message: m, ctx: ctx, highlighted: highlight == m.id, compactTop: compact,
                      onReply: { replyTo = $0; editing = nil },
                      onJump: { jump(to: $0, proxy) },
                      onEdit: { editing = $0; replyTo = nil; text = $0.body },
                      onOpenMedia: { sheet = .media($0) })
    }

    /// Oben über dem Verlauf: (Mac) Kopfzeile, Suche im Chat, angeheftete Einträge.
    private func topBars(_ room: Room, hits: [Message], pinned: [Message], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macHeader(room)
            #endif
            if searching { searchBar(hits: hits, proxy: proxy) }
            if !pinned.isEmpty && !searching { pinnedBar(pinned, proxy: proxy) }
        }
    }

    /// Unterzeile wie im Messenger: „Ich“ bzw. die Mitglieder („Ich, Anna, Ben“).
    private func subtitle(_ room: Room) -> String {
        guard room.memberCount > 1, let store = model.store else { return room.subtitle }
        let names = store.members(room: roomId).map { $0.userId == model.me ? String(localized: "Ich") : $0.displayName }
        return names.count > 6 ? room.subtitle : names.joined(separator: ", ")
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private func toolbar(_ room: Room) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { openInfo() } label: {
                HStack(spacing: 8) {
                    Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 36, colorKey: room.id)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(room.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text(subtitle(room)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.header")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation { searching.toggle(); if !searching { query = ""; highlight = nil } } } label: {
                Label("Im Chat suchen", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("chat.search")
        }
    }
    #else
    /// Mac-Kopfzeile wie am Desktop-Messenger: Avatar, Name, Unterzeile; rechts Suchen, Infos und „…“.
    private func macHeader(_ room: Room) -> some View {
        HStack(spacing: 12) {
            Button { openInfo() } label: {
                HStack(spacing: 12) {
                    Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 40, colorKey: room.id)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.title).font(.system(size: 16)).foregroundStyle(Theme.text1).lineLimit(1)
                        Text(subtitle(room)).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.header")
            Spacer()
            headerButton("magnifyingglass", "Im Chat suchen") {
                withAnimation { searching.toggle(); if !searching { query = ""; highlight = nil } }
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("chat.search")
            headerButton("sidebar.right", "Infos") { openInfo() }
                .keyboardShortcut("i", modifiers: .command)
            Menu {
                Button { openInfo() } label: { Label("Details", systemImage: "info.circle") }
                Button { model.setRoomState(roomId, pinned: !room.pinned) } label: {
                    Label(room.pinned ? "Lösen" : "Anheften", systemImage: room.pinned ? "pin.slash" : "pin")
                }
                Button { model.setRoomState(roomId, archived: !room.archived) } label: {
                    Label(room.archived ? "Zurückholen" : "Archivieren", systemImage: "archivebox")
                }
                Divider()
                Button(role: .destructive) { confirmDeleteRoom = true } label: { Label("Löschen", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text1).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(Text("Weitere"))
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Theme.chatBackground)
        .overlay(alignment: .bottom) { Theme.panelGap.frame(height: 1) }
    }

    private func headerButton(_ icon: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text1)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
    #endif

    private func openInfo() {
        if let showInfo { showInfo.wrappedValue.toggle() } else { showInfoPush = true }
    }

    private func searchBar(hits: [Message], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("In diesem Chat suchen", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { step(hits, 0, proxy) }
                .onChange(of: query) { _, _ in hitIndex = 0; if let f = hits.first { highlightAndJump(f.id, proxy) } }
                .accessibilityIdentifier("chat.search.field")
            if !query.isEmpty {
                Text(hits.isEmpty ? "0" : "\(hitIndex + 1)/\(hits.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { step(hits, 1, proxy) } label: { Image(systemName: "chevron.up") }.disabled(hits.count < 2)
                Button { step(hits, -1, proxy) } label: { Image(systemName: "chevron.down") }.disabled(hits.count < 2)
            }
            Button("Fertig") { searching = false; query = ""; highlight = nil }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.searchField))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.barBackground)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
    }

    private func step(_ hits: [Message], _ d: Int, _ proxy: ScrollViewProxy) {
        guard !hits.isEmpty else { return }
        hitIndex = (hitIndex + d + hits.count) % hits.count
        highlightAndJump(hits[hitIndex].id, proxy)
    }

    private func highlightAndJump(_ id: String, _ proxy: ScrollViewProxy) {
        highlight = id
        ensureLoaded(id)
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    private func jump(to id: String, _ proxy: ScrollViewProxy) {
        ensureLoaded(id)
        highlight = id
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlight == id && !searching { withAnimation { highlight = nil } }
        }
    }

    /// Ältere Einträge nachladen, bis der gesuchte dabei ist.
    private func ensureLoaded(_ id: String) {
        guard let store = model.store, let m = store.message(id) else { return }
        let newer = store.db.one("SELECT COUNT(*) AS n FROM messages WHERE room_id=? AND deleted=0 AND created_at>=?", roomId, m.createdAt)?.int("n") ?? 0
        if newer > limit { limit = newer + 50 }
    }

    private func pinnedBar(_ pinned: [Message], proxy: ScrollViewProxy) -> some View {
        let m = pinned[min(pinIndex, pinned.count - 1)]
        return Button {
            jump(to: m.id, proxy)
            pinIndex = (pinIndex + 1) % pinned.count
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(Theme.pinned).frame(width: 2, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pinned.count > 1 ? String(localized: "Angeheftet (\(pinIndex % pinned.count + 1)/\(pinned.count))") : String(localized: "Angeheftet"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    PreviewText(message: m).font(.caption).lineLimit(1).foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.pinned).rotationEffect(.degrees(45))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.barBackground)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.pinned")
    }

    @ViewBuilder
    private func sheetView(_ s: Sheet) -> some View {
        switch s {
        case .poll:
            PollComposer { q, o, multi, interim in model.sendPoll(room: roomId, question: q, options: o, multi: multi, showInterim: interim) }
        case .checklist:
            ChecklistComposer { t, items in model.sendChecklist(room: roomId, title: t, items: items) }
        case .location:
            LocationPicker { lat, lon, name in model.sendLocation(room: roomId, lat: lat, lon: lon, name: name) }
        case .camera:
            #if os(iOS)
            CameraPicker(onImage: { model.sendImage(room: roomId, data: $0, replyTo: replyTo?.id); replyTo = nil },
                         onVideo: { u in Task { await model.sendVideo(room: roomId, url: u, replyTo: replyTo?.id); replyTo = nil } })
                .ignoresSafeArea()
            #else
            EmptyView()
            #endif
        case .media(let m):
            MediaViewer(message: m)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let reply = replyTo?.id
        replyTo = nil
        Task {
            for item in items {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
                   let movie = try? await item.loadTransferable(type: MovieFile.self) {
                    await model.sendVideo(room: roomId, url: movie.url, replyTo: reply)
                } else if let data = try? await item.loadTransferable(type: Data.self) {
                    model.sendImage(room: roomId, data: data, replyTo: reply)
                }
            }
            photoItems = []
        }
    }
}

/// Video aus der Fotomediathek als Datei übernehmen.
nonisolated struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { f in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString).\(f.file.pathExtension.isEmpty ? "mov" : f.file.pathExtension)")
            try FileManager.default.copyItem(at: f.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

/// iPhone: Datums-Pille je Tag (unscharfer Grund, fett, mittig).
struct DayPill: View {
    let date: Date
    var body: some View {
        Text(Fmt.dayPill(date))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 3.5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12.5, style: .continuous))
            .background(Theme.systemPill, in: RoundedRectangle(cornerRadius: 12.5, style: .continuous))
    }
}

/// Hinweis mitten im Verlauf: ab hier neu von einem anderen Gerät (dunkle Pille wie Systemhinweise).
struct NewFromOtherDeviceLine: View {
    let count: Int
    var body: some View {
        Text("Neu von anderem Gerät (\(count))")
            #if os(macOS)
            .font(.system(size: 12))
            .foregroundStyle(Theme.text1)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.systemPill))
            #else
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Theme.systemPill))
            #endif
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
