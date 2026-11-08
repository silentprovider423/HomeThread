import AVFoundation
import Foundation
import Observation

/// Sprachnotiz aufnehmen (AAC/m4a) mit Pegel für die Wellenform.
@Observable
final class VoiceRecorder: NSObject {
    var isRecording = false
    var elapsed: Double = 0
    var levels: [Double] = []
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var url: URL?

    func start() async -> Bool {
        #if os(iOS)
        let ok = await AVAudioApplication.requestRecordPermission()
        guard ok else { return false }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        #else
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        guard ok else { return false }
        #endif
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sprachnotiz-\(newID()).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return false }
        r.isMeteringEnabled = true
        guard r.record() else { return false }
        recorder = r
        url = u
        levels = []
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        return true
    }

    private func tick() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        let db = Double(r.averagePower(forChannel: 0))
        levels.append(max(0, min(1, (db + 50) / 50)))
        elapsed = r.currentTime
    }

    /// Stoppt und liefert Datei, Dauer und Wellenform (höchstens 48 Werte).
    func stop() -> (url: URL, duration: Double, wave: [Double])? {
        timer?.invalidate()
        timer = nil
        let d = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url, d > 0.4 else { return nil }
        return (url, d, Self.downsample(levels, to: 48))
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
    }

    static func downsample(_ v: [Double], to n: Int) -> [Double] {
        guard v.count > n else { return v.map { ($0 * 100).rounded() / 100 } }
        let step = Double(v.count) / Double(n)
        return (0..<n).map { i in
            let a = Int(Double(i) * step), b = max(a + 1, Int(Double(i + 1) * step))
            let slice = v[a..<min(b, v.count)]
            return ((slice.max() ?? 0) * 100).rounded() / 100
        }
    }
}

/// Spielt immer nur eine Sprachnotiz gleichzeitig.
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    var playingID: String?
    var progress: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.play()
        player = p
        playingID = id
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
