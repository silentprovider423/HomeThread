import SwiftUI

/// Eingabeleiste: „+“ (Anhänge), Textfeld, Kamera/Mikro bzw. Ablegen-Pfeil; darüber Antwort- oder Bearbeiten-Leiste.
struct InputBar: View {
    enum Attach { case camera, photos, location, poll, checklist, file }

    @Environment(AppModel.self) private var model
    let roomId: String
    @Binding var text: String
    @Binding var replyTo: Message?
    @Binding var editing: Message?
    var onAttach: (Attach) -> Void
    @State private var recorder = VoiceRecorder()
    @State private var micDenied = false
    @FocusState private var focused: Bool

    @State private var showAttach = false
    @State private var pendingAttach: Attach?

    static let actions: [(Attach, LocalizedStringKey, String)] = {
        var a: [(Attach, LocalizedStringKey, String)] = []
        #if os(iOS)
        a.append((.camera, "Foto oder Video aufnehmen", "camera.fill"))
        #endif
        a += [(.photos, "Aus Fotos wählen", "photo.on.rectangle"), (.location, "Ort festhalten", "mappin.and.ellipse"),
              (.poll, "Abstimmung anlegen", "chart.bar.xaxis"), (.checklist, "Checkliste anlegen", "checklist"),
              (.file, "Datei anhängen", "doc.fill")]
        return a
    }()

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            Theme.panelGap.frame(height: 1)
            #else
            Theme.hairline.frame(height: 0.5)
            #endif
            VStack(spacing: 6) {
                if let r = replyTo { banner(title: String(localized: "Antwort auf"), text: r.preview, icon: "arrowshape.turn.up.left") { replyTo = nil } }
                if let e = editing {
                    banner(title: String(localized: "Bearbeiten"), text: e.preview, icon: "pencil") { editing = nil; text = "" }
                }
                if recorder.isRecording { recordingBar } else { inputRow }
            }
            #if os(macOS)
            .padding(.horizontal, 14).padding(.vertical, 10)
            #else
            .padding(.horizontal, 8).padding(.vertical, 6)
            #endif
        }
        .background(Theme.barBackground.ignoresSafeArea(edges: .bottom))
        .alert("Kein Zugriff auf das Mikrofon", isPresented: $micDenied) {
            Button("OK") {}
        } message: {
            Text("Erlaube den Mikrofonzugriff in den Einstellungen, um Sprachnotizen aufzunehmen.")
        }
        #if os(iOS)
        .sheet(isPresented: $showAttach, onDismiss: {
            if let a = pendingAttach { pendingAttach = nil; onAttach(a) }
        }) {
            AttachSheet { a in pendingAttach = a; showAttach = false }
                .presentationDetents([.height(CGFloat(Self.actions.count) * 52 + 130)])
                .presentationDragIndicator(.visible)
        }
        #endif
        .onChange(of: text) { _, t in if editing == nil { model.saveDraft(roomId, t) } }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editing == nil }

    private var inputRow: some View {
        #if os(macOS)
        HStack(alignment: .center, spacing: 14) {
            Menu {
                ForEach(Self.actions, id: \.2) { a in
                    Button { onAttach(a.0) } label: { Label(a.1, systemImage: a.2) }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .regular)).foregroundStyle(Theme.text1)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("input.attach")
            .accessibilityLabel(Text("Anhang"))

            TextField("Neue Nachricht…", text: $text, axis: .vertical)
                .lineLimit(1...10)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .accessibilityIdentifier("input.text")
                .onKeyPress(.return, phases: .down) { press in
                    if model.returnSends && !press.modifiers.contains(.shift) || press.modifiers.contains(.command) {
                        submit(); return .handled
                    }
                    return .ignored
                }

            Button {
                focused = true
                NSApp.orderFrontCharacterPalette(nil)
            } label: { barIcon("face.smiling") }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Emoji"))
            if isEmpty {
                Button(action: startRecording) { barIcon("mic") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("input.mic")
                    .accessibilityLabel(Text("Sprachnotiz aufnehmen"))
            } else {
                sendButton
            }
        }
        #else
        HStack(alignment: .bottom, spacing: 6) {
            Button { showAttach = true } label: {
                Image(systemName: "plus").font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("input.attach")
            .accessibilityLabel(Text("Anhang"))

            TextField("Neue Nachricht", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 7.5)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.chatBarField))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .accessibilityIdentifier("input.text")

            if isEmpty {
                Button { onAttach(.camera) } label: { barIcon("camera") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Kamera"))
                Button(action: startRecording) { barIcon("mic") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("input.mic")
                    .accessibilityLabel(Text("Sprachnotiz aufnehmen"))
            } else {
                sendButton
            }
        }
        #endif
    }

    private func barIcon(_ name: String) -> some View {
        #if os(macOS)
        Image(systemName: name).font(.system(size: 17)).foregroundStyle(Theme.text1)
            .frame(width: 28, height: 28).contentShape(Rectangle())
        #else
        Image(systemName: name).font(.system(size: 21)).foregroundStyle(Theme.accent)
            .frame(width: 34, height: 36).contentShape(Rectangle())
        #endif
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onAccent).frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent))
                .padding(3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("input.send")
        .accessibilityLabel(Text("Ablegen"))
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.title3).foregroundStyle(.red).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Verwerfen"))
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(Fmt.duration(recorder.elapsed)).monospacedDigit()
                Waveform(values: Array(recorder.levels.suffix(40))).frame(height: 24)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Theme.fieldBackground))
            Button {
                if let r = recorder.stop() {
                    model.sendVoice(room: roomId, url: r.url, duration: r.duration, wave: r.wave, replyTo: replyTo?.id)
                    replyTo = nil
                }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.onAccent).frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("input.voice.send")
            .accessibilityLabel(Text("Sprachnotiz ablegen"))
        }
    }

    private func banner(title: String, text: String, icon: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Schließen"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fieldBackground))
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let e = editing {
            model.editText(e, body: t)
            editing = nil
        } else {
            model.sendText(room: roomId, t, replyTo: replyTo?.id)
            replyTo = nil
        }
        text = ""
    }

    private func startRecording() {
        Task {
            if !(await recorder.start()) { micDenied = true }
        }
    }
}

#if os(iOS)
/// Anhang-Auswahl als Blatt von unten: Zeilen mit Symbol in Akzentfarbe, unten „Abbrechen“.
struct AttachSheet: View {
    var pick: (InputBar.Attach) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(InputBar.actions.enumerated()), id: \.offset) { i, a in
                    if i > 0 { Theme.hairline.frame(height: 0.5).padding(.leading, 54) }
                    Button { pick(a.0) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: a.2).font(.system(size: 19)).foregroundStyle(Theme.accent).frame(width: 26)
                            Text(a.1).foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.horizontal, 14).frame(height: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chatBarField))
            Button { dismiss() } label: {
                Text("Abbrechen").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chatBarField))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 22)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.chatBar)
    }
}
#endif
