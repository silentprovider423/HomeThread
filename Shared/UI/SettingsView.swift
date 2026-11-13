import SwiftUI

/// Einstellungen: Konto, Geräte, Passwort, Darstellung, Abgleich, Speicher, Über.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false
    @State private var showPassword = false
    @State private var cacheSize = 0

    var body: some View {
        Form {
            if let s = model.session {
                Section("Konto") {
                    HStack(spacing: 12) {
                        Avatar(title: s.user.displayName, size: 48, colorKey: s.user.id, person: true)
                        VStack(alignment: .leading) {
                            Text(s.user.displayName).font(.headline)
                            Text("@\(s.user.username)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Server", value: URL(string: s.server)?.host ?? s.server)
                    Button("Passwort ändern …") { showPassword = true }
                }
                Section {
                    NavigationLink { DevicesView() } label: {
                        Label("Geräte", systemImage: "laptopcomputer.and.iphone")
                    }
                    .accessibilityIdentifier("settings.devices")
                } footer: {
                    Text("Jedes Gerät hat eine eigene Anmeldung. Ein verlorenes Gerät kannst du hier abmelden.")
                }
            }
            Section("Darstellung") {
                Picker(selection: Bindable(model).appearance) {
                    Text("Automatisch").tag(0)
                    Text("Hell").tag(1)
                    Text("Dunkel").tag(2)
                } label: { Label("Darstellung", systemImage: "circle.lefthalf.filled") }
                #if os(macOS)
                Toggle("Mit ↩ ablegen (sonst ⌘↩)", isOn: Bindable(model).returnSends)
                #else
                Picker(selection: Bindable(model).quickReaction) {
                    Text("Aus").tag("")
                    ForEach(["👍", "❤️", "😂", "✅", "⭐️", "🙏"], id: \.self) { Text($0).tag($0) }
                } label: { Label("Doppeltippen reagiert mit", systemImage: "hand.tap") }
                .accessibilityIdentifier("settings.quickReaction")
                #endif
            }
            Section {
                LabeledContent("Status", value: model.statusText)
                if let d = model.lastSync {
                    LabeledContent("Zuletzt abgeglichen", value: d.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("Wartende Änderungen", value: "\(model.pending)")
                Button("Jetzt abgleichen") { model.syncSoon() }.accessibilityIdentifier("settings.syncNow")
            } header: {
                Text("Abgleich")
            } footer: {
                Text("Alles liegt zuerst auf diesem Gerät. Bei Verbindung gleicht die App alle 15 Sekunden mit deinem Server ab.")
            }
            Section {
                LabeledContent("Heruntergeladene Dateien", value: Fmt.size(cacheSize))
                Button("Heruntergeladene Dateien entfernen") {
                    model.store?.clearDownloadedFiles()
                    cacheSize = model.store?.cacheSize() ?? 0
                    model.revision += 1
                }
            } header: {
                Text("Speicher")
            } footer: {
                Text("Fotos, Videos und Dateien bleiben auf dem Server und werden bei Bedarf neu geladen. Noch nicht hochgeladene bleiben erhalten.")
            }
            Section("Über") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Text("HomeThread ist ein unabhängiges Open-Source-Projekt (GPLv3-Lizenz). Es verschickt nichts an andere – Chats und Gruppen sind Notiz-Räume auf deinem eigenen Server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.session != nil {
                Section {
                    Button("Abmelden", role: .destructive) { confirmSignOut = true }
                        .accessibilityIdentifier("settings.signout")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        .onAppear { cacheSize = model.store?.cacheSize() ?? 0 }
        .confirmationDialog("Abmelden?", isPresented: $confirmSignOut) {
            Button("Abmelden", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Alles bleibt auf deinem Server. Auf diesem Gerät werden die lokalen Daten gelöscht; noch nicht abgeglichene Änderungen gehen verloren.")
        }
        .sheet(isPresented: $showPassword) { ChangePasswordView() }
    }
}

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: DeviceInfo?
    @State private var newName = ""

    var body: some View {
        let list = model.devices.values.sorted { $0.lastSeen > $1.lastSeen }
        List {
            ForEach(list) { d in
                HStack(spacing: 12) {
                    Image(systemName: d.platform == "mac" ? "laptopcomputer" : d.platform == "ios" ? "iphone" : "desktopcomputer")
                        .font(.title2).foregroundStyle(Theme.accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.body.weight(d.current ? .semibold : .regular))
                        Text(d.current ? String(localized: "Dieses Gerät") : String(localized: "Zuletzt aktiv: \(d.lastSeen.formatted(date: .abbreviated, time: .shortened))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if !d.current {
                        Button("Abmelden", role: .destructive) { Task { await model.revoke(d) } }
                    }
                    Button("Umbenennen") { renaming = d; newName = d.name }.tint(.gray)
                }
                .contextMenu {
                    Button("Umbenennen") { renaming = d; newName = d.name }
                    if !d.current { Button("Abmelden", role: .destructive) { Task { await model.revoke(d) } } }
                }
            }
        }
        .navigationTitle("Geräte")
        .refreshable { await model.refreshUsersAndDevices() }
        .task { await model.refreshUsersAndDevices() }
        .alert("Gerät umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { if let d = renaming { Task { await model.rename(d, to: newName) } } }
        }
    }
}

struct ChangePasswordView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var code = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                SecureField("Aktuelles Passwort", text: $current)
                SecureField("Neues Passwort (mind. 12 Zeichen)", text: $new1)
                SecureField("Neues Passwort wiederholen", text: $new2)
                TextField("Code aus der Authenticator-App", text: $code)
                if let message { Text(message).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Passwort ändern")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        busy = true
                        Task {
                            do {
                                try await model.changePassword(current: current, new: new1, code: code.filter(\.isNumber))
                                dismiss()
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }
                    .disabled(busy || new1.count < 12 || new1 != new2 || code.count < 6 || current.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 400, height: 300)
        #endif
    }
}
