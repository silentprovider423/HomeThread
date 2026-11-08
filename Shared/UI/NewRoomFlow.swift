import PhotosUI
import SwiftUI

/// „Neuer Chat“ (Name + Bild) bzw. „Neue Gruppe“ (Personen wählen → Name + Bild → Erstellen).
struct NewRoomFlow: View {
    enum Mode: String, Identifiable { case chat, group; var id: String { rawValue } }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var onCreated: (String) -> Void = { _ in }

    @State private var step = 0
    @State private var picked: Set<String> = []
    @State private var title = ""
    @State private var imageData: Data?
    @State private var photo: PhotosPickerItem?
    @State private var query = ""
    @FocusState private var nameFocused: Bool

    var others: [UserInfo] { model.users.filter { $0.id != model.me } }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .group && step == 0 { memberPicker } else { nameStep }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .group && step == 0 {
                        Button(picked.isEmpty ? "Überspringen" : "Weiter") { step = 1 }
                            .accessibilityIdentifier("newroom.next")
                    } else {
                        Button("Erstellen", action: create)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("newroom.create")
                    }
                }
            }
        }
        .task { if model.users.isEmpty { await model.refreshUsersAndDevices() } }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private var memberPicker: some View {
        List {
            Section {
                if others.isEmpty {
                    Text("Auf deinem Server gibt es noch keine weiteren Personen. Du kannst die Gruppe trotzdem als Themen-Raum für dich anlegen und später Personen hinzufügen.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(others.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) }) { u in
                    Button {
                        if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(title: u.displayName, size: 40, colorKey: u.id, person: true)
                            VStack(alignment: .leading) {
                                Text(u.displayName)
                                Text("@\(u.username)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: picked.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(u.id) ? Theme.accent : .secondary).font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Personen auswählen")
            }
        }
        .searchable(text: $query, prompt: Text("Suchen"))
        .navigationTitle("Neue Gruppe")
    }

    private var nameStep: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            if let imageData, let cg = Media.cgImage(data: imageData, maxPixel: 400) {
                                Image(decorative: cg, scale: 1).resizable().scaledToFill().frame(width: 110, height: 110).clipShape(Circle())
                            } else {
                                Avatar(title: title.isEmpty ? (mode == .group ? "" : "?") : title, isGroup: mode == .group, size: 110,
                                       colorKey: title)
                            }
                            Image(systemName: "camera.circle.fill").font(.title).symbolRenderingMode(.multicolor)
                                .foregroundStyle(.white, Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Bild wählen"))
                    Spacer()
                }
                .listRowBackground(Color.clear)
                if imageData != nil {
                    Button("Bild entfernen", role: .destructive) { imageData = nil; photo = nil }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                TextField(mode == .group ? "Name der Gruppe" : "Name des Chats", text: $title)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .accessibilityIdentifier("newroom.name")
            } footer: {
                Text(mode == .group
                     ? "Gruppen sind Themen-Räume. Personen deines Servers kannst du jederzeit hinzufügen."
                     : "Ein Chat ist ein Notiz-Raum nur für dich – auf allen deinen Geräten.")
            }
            if mode == .group && !picked.isEmpty {
                Section("Personen") {
                    ForEach(others.filter { picked.contains($0.id) }) { u in Text(u.displayName) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(mode == .group ? "Neue Gruppe" : "Neuer Chat")
        .onChange(of: photo) { _, item in
            Task { imageData = try? await item?.loadTransferable(type: Data.self) }
        }
        .onAppear { nameFocused = true }
    }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let members = others.filter { picked.contains($0.id) }
        if let id = model.createRoom(kind: mode == .group ? .group : .chat, title: t, avatarImage: imageData, members: members) {
            dismiss()
            onCreated(id)
        }
    }
}
