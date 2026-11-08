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
                        let prev = i > 0 ? messages[i - 1] : nil
                        if prev == nil || !Calendar.current.isDate(prev!.createdAt, inSameDayAs: m.createdAt) {
                            DayPill(date: m.createdAt).padding(.vertical, 8)
                        }
                        if let f = firstUnreadSeq, m.seq == f {
                            NewFromOtherDeviceLine(count: messages.filter { $0.seq >= f && $0.deviceId != model.myDevice }.count)
                        }
                        MessageBubble(message: m, ctx: ctx, highlighted: highlight == m.id,
                                      compactTop: prev.map { $0.authorId == m.authorId && m.createdAt.timeIntervalSince($0.createdAt) < 1800 } ?? false,
                                      onReply: { replyTo = $0; editing = nil },
                                      onJump: { jump(to: $0, proxy) },
                                      onEdit: { editing = $0; replyTo = nil; text = $0.body },
                                      onOpenMedia: { sheet = .media($0) })
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.vertical, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.chatBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if searching { searchBar(hits: hits, proxy: proxy) }
                    if !pinned.isEmpty && !searching { pinnedBar(pinned, proxy: proxy) }
                }
            }
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
        .navigationTitle(room.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationSubtitle(room.subtitle)
        #endif
        .toolbar { toolbar(room) }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in importPhotos(items) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { for u in urls { model.sendFile(room: roomId, url: u, replyTo: replyTo?.id) }; replyTo = nil }
        }
        .sheet(item: $sheet) { s in sheetView(s) }
        #if os(iOS)
        .navigationDestination(isPresented: $showInfoPush) {
            RoomInfoView(roomId: roomId, onJump: { id in showInfoPush = false; scrollTarget = id })
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

    @ToolbarContentBuilder
    private func toolbar(_ room: Room) -> some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            Button { openInfo() } label: {
                HStack(spacing: 8) {
                    Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 32, colorKey: room.id)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(room.title).font(.headline).lineLimit(1)
                        Text(room.subtitle)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.header")
        }
        #else
        ToolbarItem(placement: .navigation) {
            Button { openInfo() } label: {
                Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 28, colorKey: room.id)
            }
            .buttonStyle(.plain)
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation { searching.toggle(); if !searching { query = ""; highlight = nil } } } label: {
                Label("Im Chat suchen", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("chat.search")
        }
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button { openInfo() } label: { Label("Infos", systemImage: "info.circle") }
                .keyboardShortcut("i", modifiers: .command)
        }
        #endif
    }

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
        .padding(.horizontal, 12).padding(.vertical, 8)
        .htGlass(in: Capsule())
        .padding(.horizontal, 10).padding(.top, 6)
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
                Image(systemName: "pin.fill").foregroundStyle(Theme.pinned).rotationEffect(.degrees(45))
                VStack(alignment: .leading, spacing: 1) {
                    Text(pinned.count > 1 ? String(localized: "Angeheftet (\(pinIndex % pinned.count + 1)/\(pinned.count))") : String(localized: "Angeheftet"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    PreviewText(message: m).font(.caption).lineLimit(1).foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .htGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10).padding(.top, 6)
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

struct DayPill: View {
    let date: Date
    var body: some View {
        Text(Fmt.dayPill(date))
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .htGlass(in: Capsule())
    }
}

struct NewFromOtherDeviceLine: View {
    let count: Int
    var body: some View {
        HStack {
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1)
            Text("Neu von anderem Gerät (\(count))").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent).fixedSize()
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
