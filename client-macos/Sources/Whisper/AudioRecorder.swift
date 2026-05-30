import AVFoundation

/// Records the microphone to a temp WAV file in exactly the format the server's
/// fake-mic dictate path expects: PCM 16-bit, 48 kHz, mono (see CONTRACT.md).
/// 48 kHz / mono / s16 matches the server agent's validated
/// `ffmpeg -ac 1 -ar 48000 -sample_fmt s16` clip, so the upload feeds Chromium's
/// `--use-file-for-fake-audio-capture` with no server-side transcoding.
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?

    func start() throws {
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
        guard rec.record() else { throw RecorderError.couldNotStart }
        recorder = rec
        currentURL = url
    }

    /// Stops recording and returns the finished WAV file URL.
    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return currentURL
    }

    enum RecorderError: Error { case couldNotStart }
}
