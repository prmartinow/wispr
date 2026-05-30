import AVFoundation

/// Records the mic to a temp WAV (PCM 16-bit / 48 kHz / mono — the contract format) and
/// emits a live level + elapsed time ~20×/sec for the HUD waveform. If an input device UID
/// is given, it's made the system default input first (mic picker).
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    private var timer: Timer?
    private var startedAt: Date?

    /// (level 0…1, elapsed seconds). Called on the main thread.
    var onMeter: ((CGFloat, TimeInterval) -> Void)?

    func start(inputUID: String?) throws {
        if let uid = inputUID, !uid.isEmpty { AudioDevices.setDefaultInput(uid: uid) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderError.couldNotStart }
        recorder = rec
        currentURL = url
        startedAt = Date()

        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let rec = recorder, let started = startedAt else { return }
        rec.updateMeters()
        // averagePower is dBFS (-160…0); map a useful speech band (-55…0) to 0…1.
        let db = rec.averagePower(forChannel: 0)
        let norm = max(0, min(1, (db + 55) / 55))
        onMeter?(CGFloat(norm), Date().timeIntervalSince(started))
    }

    @discardableResult
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        startedAt = nil
        return currentURL
    }

    enum RecorderError: Error { case couldNotStart }
}
