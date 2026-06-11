import AVFoundation

/// Live mic capture via AVAudioEngine. Converts each buffer to the contract wire format
/// (raw PCM **s16le / 48 kHz / mono**) and emits ~real-time frames for streaming, while also
/// accumulating the whole take so a failed stream can fall back to batch `POST /transcribe`.
final class AudioStreamCapture {
    static let maxSeconds = 600
    static let sampleRate = 48_000
    static let maxPCMBytes = sampleRate * 2 * maxSeconds

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var startedAt: Date?
    private var limitReached = false

    /// All captured PCM (s16le mono 48k), for the batch fallback.
    private(set) var pcm = Data()

    /// One ~frame of s16le PCM, ready to send over the WebSocket.
    var onFrame: ((Data) -> Void)?
    /// (level 0…1, elapsed seconds) for the HUD waveform. Called on the main thread.
    var onMeter: ((CGFloat, TimeInterval) -> Void)?
    /// Called once when the 10-minute capture budget is reached.
    var onLimitReached: (() -> Void)?

    func start(inputUID: String?) throws {
        if let uid = inputUID, !uid.isEmpty { AudioDevices.setDefaultInput(uid: uid) }
        pcm.removeAll(keepingCapacity: false)
        limitReached = false
        startedAt = Date()

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else { throw CaptureError.noInput }

        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                   channels: 1, interleaved: true)!
        targetFormat = target
        converter = AVAudioConverter(from: hwFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 4800, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    @discardableResult
    func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        startedAt = nil
        return pcm
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let target = targetFormat, let started = startedAt else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let err { Log.log("capture: convert error \(err.code)"); return }

        let n = Int(out.frameLength)
        guard n > 0, let samples = out.int16ChannelData else { return }

        let frame = Data(bytes: samples[0], count: n * 2) // mono int16
        let remaining = Self.maxPCMBytes - pcm.count
        guard remaining > 0 else {
            triggerLimitOnce()
            return
        }
        let boundedFrame = frame.count <= remaining ? frame : Data(frame.prefix(remaining))
        pcm.append(boundedFrame)
        onFrame?(boundedFrame)
        if boundedFrame.count < frame.count || pcm.count >= Self.maxPCMBytes {
            triggerLimitOnce()
        }

        // Level for the HUD, computed from the converted samples (no float-channel dependency).
        var sum = 0.0
        let p = samples[0]
        for i in 0..<n { let v = Double(p[i]) / 32768.0; sum += v * v }
        let rms = sqrt(sum / Double(n))
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0.0, min(1.0, (db + 55.0) / 55.0))
        let elapsed = Date().timeIntervalSince(started)
        DispatchQueue.main.async { self.onMeter?(CGFloat(level), elapsed) }
    }

    private func triggerLimitOnce() {
        guard !limitReached else { return }
        limitReached = true
        DispatchQueue.main.async { self.onLimitReached?() }
    }

    enum CaptureError: Error { case noInput }
}

/// Wraps raw PCM in a minimal RIFF/WAVE header for the batch fallback.
enum WAV {
    static func fromPCM(_ pcm: Data, sampleRate: Int = 48_000, channels: Int = 1, bits: Int = 16) -> Data {
        let blockAlign = channels * bits / 8
        let byteRate = sampleRate * blockAlign
        var d = Data()
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
        ascii("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
