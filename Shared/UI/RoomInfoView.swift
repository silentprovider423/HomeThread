import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Text-Datei für „Chat als Datei sichern“.
nonisolated struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(_ text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Raum-/Gruppen-Info: Bild, Name, Personen, Medien, Gemerkt, Abstimmungen, Aktionen.
struct RoomInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let roomId: String
    var onJump: (String) -> Void = { _ in }
    /// iPhone: Schnellaktion „Suchen“ startet die Suche im Chat
    var onSearch: (() -> Void)?
    @State private var editingName = false
    @State private var name = ""
    @State private var about = ""
    @State private var photo: PhotosPickerItem?
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var addPerson = false
    @State private var showAllMembers = false
    @State private var exportDoc: TextDocument?

    var body: some View {
        let _ = model.revision
        if let store = model.store, let room = store.room(roomId) {
            let members = store.members(room: roomId)
            let isOwner = members.first { $0.userId == model.me }?.isOwner ?? (room.createdBy == model.me)
            List {
                header(room)
                quickActions(room)
                Section {
                    TextField("Beschreibung (optional)", text: $about, axis: .vertical)
                        .onSubmit { model.setRoomAbout(roomId, about: about) }
                        .onChange(of: about) { _, v in if v.hasSuffix("\n") { about = String(v.dropLast()); model.setRoomAbout(roomId, about: about) } }
                }
                if room.kind == .group {
                    Section {
                        ForEach(showAllMembers ? members : Array(members.prefix(5))) { m in
                            HStack(spacing: 12) {
                                Avatar(title: m.displayName, size: 36, colorKey: m.userId, person: true)
                                VStack(alignment: .leading) {
                                    Text(m.userId == model.me ? String(localized: "Du (\(m.displayName))") : m.displayName)
                                    Text("@\(m.username)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if m.isOwner { Text("Ersteller").font(.caption).foregroundStyle(.secondary) }
                            }
                            .swipeActions {
                                if isOwner && m.userId != model.me {
                                    Button("Entfernen", role: .destructive) { model.removeMember(roomId, userId: m.userId) }
                                }
                            }
                        }
                        if members.count > 5 && !showAllMembers {
                            Button("Alle anzeigen") { showAllMembers = true }
                        }
                        if isOwner {
                            Button { addPerson = true } label: { Label("Person hinzufügen", systemImage: "person.badge.plus") }
                                .accessibilityIdentifier("info.addPerson")
                        }
                    } header: {
                        Text("Personen (\(members.count))")
                    }
                }
                Section("Inhalte") {
                    NavigationLink { MediaGrid(roomId: roomId, onJump: onJump) } label: {
                        Label("Medien & Dateien", systemImage: "photo.stack")
                    }
                    .accessibilityIdentifier("info.media")
                    NavigationLink { MessageList(title: "Gemerkt", messages: store.starredMessages().filter { $0.roomId == roomId }, onJump: onJump) } label: {
                        Label("Gemerkt", systemImage: "star")
                    }
                    NavigationLink { MessageList(title: "Abstimmungen", messages: store.messages(room: roomId, kinds: [.poll]), onJump: onJump) } label: {
                        Label("Abstimmungen", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink { MessageList(title: "Checklisten", messages: store.messages(room: roomId, kinds: [.checklist]), onJump: onJump) } label: {
                        Label("Checklisten", systemImage: "checklist")
                    }
                    NavigationLink { MessageList(title: "Orte", messages: store.messages(room: roomId, kinds: [.location]), onJump: onJump) } label: {
                        Label("Orte", systemImage: "mappin.and.ellipse")
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { room.pinned }, set: { model.setRoomState(roomId, pinned: $0) })) {
                        Label("In der Liste oben anheften", systemImage: "pin")
                    }
                    Toggle(isOn: Binding(get: { room.archived }, set: { model.setRoomState(roomId, archived: $0) })) {
                        Label("Archiviert", systemImage: "archivebox")
                    }
                    Button {
                        model.setRoomKind(roomId, kind: room.kind == .group ? .chat : .group)
                    } label: {
                        Label(room.kind == .group ? "In Chat umwandeln" : "In Gruppe umwandeln", systemImage: room.kind == .group ? "bubble.left" : "person.3")
                    }
                    .disabled(room.kind == .group && members.count > 1)
                    Button {
                        exportDoc = model.exportText(room: roomId).flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(TextDocument.init)
                    } label: { Label("Chat als Datei sichern", systemImage: "square.and.arrow.down") }
                }
                Section {
                    Button("Alle Einträge löschen", role: .destructive) { confirmClear = true }
                    if isOwner {
                        Button(room.kind == .group ? "Gruppe mit allen Einträgen löschen" : "Chat mit allen Einträgen löschen", role: .destructive) {
                            confirmDelete = true
                        }
                        .accessibilityIdentifier("info.delete")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle(room.kind == .group ? "Gruppen-Info" : "Chat-Info")
            .onAppear { name = room.title; about = room.about }
            .onDisappear { if about != room.about { model.setRoomAbout(roomId, about: about) } }
            .onChange(of: photo) { _, item in
                Task {
                    if let d = try? await item?.loadTransferable(type: Data.self) { model.setRoomAvatar(roomId, image: d) }
                    photo = nil
                }
            }
            .confirmationDialog("Alle Einträge löschen?", isPresented: $confirmClear) {
                Button("Alle Einträge löschen", role: .destructive) { model.clearRoom(roomId) }
            } message: { Text("Die Einträge werden auf allen Geräten und auf dem Server gelöscht.") }
            .confirmationDialog("Wirklich löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) { model.deleteRoom(roomId); dismiss() }
            } message: { Text("Der Raum und alle Einträge werden auf allen Geräten und auf dem Server gelöscht.") }
            .sheet(isPresented: $addPerson) { AddPersonSheet(roomId: roomId, existing: Set(members.map(\.userId))) }
            .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc,
                          contentType: .plainText, defaultFilename: room.title) { _ in exportDoc = nil }
        } else {
            ContentUnavailableView("Gelöscht", systemImage: "trash")
        }
    }

    private func header(_ room: Room) -> some View {
        Section {
            VStack(spacing: 10) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 120, colorKey: room.id)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.circle.fill").font(.title).symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Theme.accent)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Bild ändern"))
                if room.avatar != nil {
                    Button("Bild entfernen") { model.setRoomAvatar(roomId, image: nil) }.font(.caption).buttonStyle(.borderless)
                }
                if editingName {
                    HStack {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(saveName)
                            .accessibilityIdentifier("info.name")
                        Button("Fertig", action: saveName)
                    }
                } else {
                    Button { editingName = true } label: {
                        HStack(spacing: 6) {
                            Text(room.title).font(.title2.bold()).foregroundStyle(.primary)
                            Image(systemName: "pencil").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("info.rename")
                }
                Text(room.kind == .group ? room.subtitle : String(localized: "Chat · nur für dich"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Angelegt am \(room.createdAt.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    /// Reihe runder Schnellaktionen unter dem Kopf (Suchen, Anheften, Archivieren).
    private func quickActions(_ room: Room) -> some View {
        Section {
            HStack(spacing: 10) {
                if let onSearch {
                    quick("Suchen", "magnifyingglass", action: onSearch)
                }
                quick(room.pinned ? "Lösen" : "Anheften", room.pinned ? "pin.slash.fill" : "pin.fill") {
                    model.setRoomState(roomId, pinned: !room.pinned)
                }
                quick(room.archived ? "Zurückholen" : "Archivieren", "archivebox.fill") {
                    model.setRoomState(roomId, archived: !room.archived)
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func quick(_ title: LocalizedStringKey, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.accent)
                Text(title).font(.caption).foregroundStyle(Theme.accent).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.infoTile))
            .contentShape(Rectangle())
        }
    }

    private func saveName() {
        model.renameRoom(roomId, title: name)
        editingName = false
    }
}

struct AddPersonSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let roomId: String
    let existing: Set<String>

    var body: some View {
        NavigationStack {
            let candidates = model.users.filter { !existing.contains($0.id) }
            List {
                if candidates.isEmpty {
                    Text("Keine weiteren Personen auf deinem Server.").foregroundStyle(.secondary)
                }
                ForEach(candidates) { u in
                    Button {
                        model.addMember(roomId, user: u)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(title: u.displayName, size: 36, colorKey: u.id, person: true)
                            Text(u.displayName)
                        }
                    }
                }
            }
            .navigationTitle("Person hinzufügen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { await model.refreshUsersAndDevices() }
        }
        #if os(macOS)
        .frame(width: 380, height: 380)
        #endif
    }
}

/// Raster aller Fotos/Videos und Liste der Dateien und Sprachnotizen eines Raums.
struct MediaGrid: View {
    @Environment(AppModel.self) private var model
    let roomId: String
    var onJump: (String) -> Void
    @State private var viewing: Message?

    var body: some View {
        let _ = model.revision
        let media = model.store?.messages(room: roomId, kinds: [.image, .video]) ?? []
        let files = model.store?.messages(room: roomId, kinds: [.file, .voice]) ?? []
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                ForEach(media) { m in
                    LocalImage(url: (m.thumb ?? m.attachment).flatMap { model.store?.fileURL($0) }, maxPixel: 300)
                        .frame(minWidth: 100, minHeight: 100).aspectRatio(1, contentMode: .fill).clipped()
                        .overlay(alignment: .bottomLeading) {
                            if m.kind == .video { Image(systemName: "video.fill").foregroundStyle(.white).padding(5).shadow(radius: 2) }
                        }
                        .onTapGesture { viewing = m }
                }
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dateien & Sprachnotizen").font(.headline).padding(.top, 16)
                    ForEach(files) { m in
                        Button { onJump(m.id) } label: {
                            HStack {
                                Image(systemName: m.kind == .voice ? "waveform" : "doc")
                                Text(m.preview).lineLimit(1)
                                Spacer()
                                Text(m.createdAt.formatted(date: .numeric, time: .omitted)).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            if media.isEmpty && files.isEmpty {
                ContentUnavailableView("Keine Medien", systemImage: "photo.stack").padding(.top, 60)
            }
        }
        .navigationTitle("Medien & Dateien")
        .sheet(item: $viewing) { MediaViewer(message: $0) }
    }
}

/// Einfache Liste von Einträgen (Gemerkt, Abstimmungen …); Tippen springt in den Chat.
struct MessageList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let messages: [Message]
    var showRoom = false
    var onJump: (String) -> Void

    var body: some View {
        List(messages) { m in
            Button {
                onJump(m.id)
                dismiss()
            } label: {
                MessageRow(message: m, showRoom: showRoom)
            }
            .buttonStyle(.plain)
        }
        .overlay { if messages.isEmpty { ContentUnavailableView(title, systemImage: "tray") } }
        .navigationTitle(title)
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: Message
    var showRoom = true

    var body: some View {
        let room = showRoom ? model.store?.room(message.roomId) : nil
        HStack(alignment: .top, spacing: 12) {
            if let room {
                Avatar(title: room.title, image: room.avatar, isGroup: room.kind == .group, size: 40, colorKey: room.id)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    if let room { Text(room.title).font(.subheadline.weight(.semibold)).lineLimit(1) }
                    Spacer()
                    Text(Fmt.listDate(message.createdAt)).font(.caption).foregroundStyle(.secondary)
                }
                PreviewText(message: message).font(.subheadline).foregroundStyle(showRoom ? .secondary : .primary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
