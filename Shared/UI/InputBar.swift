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

    var body: some View {
        VStack(spacing: 6) {
            if let r = replyTo { banner(title: String(localized: "Antwort auf"), text: r.preview, icon: "arrowshape.turn.up.left") { replyTo = nil } }
            if let e = editing {
                banner(title: String(localized: "Bearbeiten"), text: e.preview, icon: "pencil") { editing = nil; text = "" }
            }
            if recorder.isRecording { recordingBar } else { inputRow }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .alert("Kein Zugriff auf das Mikrofon", isPresented: $micDenied) {
            Button("OK") {}
        } message: {
            Text("Erlaube den Mikrofonzugriff in den Einstellungen, um Sprachnotizen aufzunehmen.")
        }
        .onChange(of: text) { _, t in if editing == nil { model.saveDraft(roomId, t) } }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                #if os(iOS)
                Button { onAttach(.camera) } label: { Label("Foto oder Video aufnehmen", systemImage: "camera") }
                #endif
                Button { onAttach(.photos) } label: { Label("Aus Fotos wählen", systemImage: "photo.on.rectangle") }
                Button { onAttach(.location) } label: { Label("Ort festhalten", systemImage: "mappin.and.ellipse") }
                Button { onAttach(.poll) } label: { Label("Abstimmung anlegen", systemImage: "chart.bar.xaxis") }
                Button { onAttach(.checklist) } label: { Label("Checkliste anlegen", systemImage: "checklist") }
                Button { onAttach(.file) } label: { Label("Datei anhängen", systemImage: "paperclip") }
            } label: {
                Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 36, height: 36)
                    .htGlass(in: Circle(), interactive: true)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityIdentifier("input.attach")
            .accessibilityLabel(Text("Anhang"))

            TextField("Notiz schreiben …", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .htGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("input.text")
                #if os(macOS)
                .onKeyPress(.return, phases: .down) { press in
                    if model.returnSends && !press.modifiers.contains(.shift) || press.modifiers.contains(.command) {
                        submit(); return .handled
                    }
                    return .ignored
                }
                #endif

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editing == nil {
                #if os(iOS)
                Button { onAttach(.camera) } label: {
                    Image(systemName: "camera").font(.title3).frame(width: 36, height: 36).htGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Kamera"))
                #endif
                Button(action: startRecording) {
                    Image(systemName: "mic").font(.title3).frame(width: 36, height: 36).htGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("input.mic")
                .accessibilityLabel(Text("Sprachnotiz aufnehmen"))
            } else {
                Button(action: submit) {
                    Image(systemName: editing == nil ? "arrow.up" : "checkmark").font(.headline.weight(.bold))
                        .foregroundStyle(.white).frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("input.send")
                .accessibilityLabel(Text("Ablegen"))
            }
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.title3).foregroundStyle(.red).frame(width: 36, height: 36)
                    .htGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Verwerfen"))
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(Fmt.duration(recorder.elapsed)).monospacedDigit()
                Waveform(values: Array(recorder.levels.suffix(40))).frame(height: 24)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .htGlass(in: Capsule())
            Button {
                if let r = recorder.stop() {
                    model.sendVoice(room: roomId, url: r.url, duration: r.duration, wave: r.wave, replyTo: replyTo?.id)
                    replyTo = nil
                }
            } label: {
                Image(systemName: "arrow.up").font(.headline.weight(.bold)).foregroundStyle(.white).frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("input.voice.send")
            .accessibilityLabel(Text("Sprachnotiz ablegen"))
        }
    }

    private func banner(title: String, text: String, icon: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Schließen"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .htGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
