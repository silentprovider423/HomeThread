import SwiftUI

/// Anmelden: Server-Adresse, Benutzername, Passwort, Code aus der Authenticator-App → Geräte-Token im Schlüsselbund.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lastServer") private var server = ""
    @AppStorage("lastUser") private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showReset = false
    @FocusState private var focus: Field?

    enum Field { case server, user, password, code }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    AppMark(size: 84)
                    Text("HomeThread").font(.largeTitle.bold())
                    Text("Deine Notizen als Chats – nur auf deinen Geräten und deinem Server.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 30)

                if let reason = model.signedOutReason {
                    Label(reason, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 0) {
                    field("Server-Adresse", text: $server, prompt: "https://thread.example.org", f: .server)
                        .textContentType(.URL)
                    Divider()
                    field("Benutzername", text: $username, prompt: "", f: .user)
                        .textContentType(.username)
                    Divider()
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .code }
                        .padding(.vertical, 13).padding(.horizontal, 14)
                        .accessibilityIdentifier("login.password")
                    Divider()
                    TextField("Code aus der Authenticator-App", text: $code)
                        .textContentType(.oneTimeCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($focus, equals: .code)
                        .onSubmit(signIn)
                        .padding(.vertical, 13).padding(.horizontal, 14)
                        .accessibilityIdentifier("login.code")
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("login.error")
                }

                Button(action: signIn) {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Anmelden").bold()
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                }
                .htGlassButton(prominent: true)
                .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty || code.count < 6)
                .accessibilityIdentifier("login.submit")

                Button("Passwort vergessen?") { showReset = true }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)

                Text("Die App spricht nur mit deinem Server. Es werden keine Nachrichten an andere verschickt.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showReset) { ResetPasswordView(server: server, username: username) }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>, prompt: String, f: Field) -> some View {
        TextField(title, text: text, prompt: prompt.isEmpty ? nil : Text(verbatim: prompt))
            .focused($focus, equals: f)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(f == .server ? .URL : .default)
            #endif
            .submitLabel(.next)
            .onSubmit { focus = f == .server ? .user : .password }
            .padding(.vertical, 13).padding(.horizontal, 14)
            .accessibilityIdentifier(f == .server ? "login.server" : "login.user")
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await model.login(server: server, username: username, password: password, code: code.filter(\.isNumber))
                password = ""
            } catch {
                self.error = error.localizedDescription
                code = ""
            }
            busy = false
        }
    }
}

/// Passwort mit dem Authenticator-Code neu setzen (danach sind alle Geräte abgemeldet).
struct ResetPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: String
    @State var username: String
    @State private var code = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var busy = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server-Adresse", text: $server).autocorrectionDisabled()
                    TextField("Benutzername", text: $username).autocorrectionDisabled()
                }
                Section {
                    TextField("Code aus der Authenticator-App", text: $code)
                    SecureField("Neues Passwort (mind. 12 Zeichen)", text: $new1)
                    SecureField("Neues Passwort wiederholen", text: $new2)
                } footer: {
                    Text("Nach drei falschen Codes ist das Zurücksetzen 10 Minuten gesperrt. Danach sind alle Geräte abgemeldet.")
                }
                if let message { Text(message).foregroundStyle(done ? Color.secondary : .red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Passwort zurücksetzen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(done ? "Fertig" : "Setzen") {
                        if done { dismiss(); return }
                        reset()
                    }
                    .disabled(busy || (!done && (new1.count < 12 || new1 != new2 || code.count < 6)))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func reset() {
        busy = true
        Task {
            do {
                let c = APIClient(base: try APIClient.normalize(server))
                try await c.resetPassword(username: username.lowercased(), code: code.filter(\.isNumber), newPassword: new1)
                message = String(localized: "Passwort geändert. Bitte mit dem neuen Passwort anmelden (nächsten Code abwarten).")
                done = true
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Eigenes App-Zeichen: Sprechblase mit Faden (kein fremdes Logo).
struct AppMark: View {
    var size: CGFloat = 60
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x14858F), Color(hex: 0x0A4F57)], startPoint: .top, endPoint: .bottom))
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
