import Foundation

/// Live streaming dictation over `WS /v1/stream` (see contract/stream.md):
/// `{start}` → binary PCM frames (s16le/48k/mono) → `{stop}` → `{final}`.
/// Auth is the bearer token on the upgrade request. On any *transport* failure the caller
/// falls back to batch; *semantic* server errors (busy/backend) are surfaced as-is.
final class StreamingClient {
    enum StreamError: Error {
        case badURL
        case transport(Error)          // couldn't connect / socket dropped → batch fallback
        case server(code: String, message: String) // semantic error from the server
        case noReady
        case noFinal
        case cancelled

        var isSemantic: Bool { if case .server = self { return true } else { return false } }
        var displayMessage: String {
            switch self {
            case .server(let code, _):
                switch code {
                case "busy": return "Server busy — try again"
                case "backend_unavailable": return "Dictation backend down"
                case "transcription_error": return "Transcription failed"
                default: return "Server: \(code)"
                }
            case .noReady: return "Dictation did not become ready"
            case .cancelled: return "Cancelled"
            default: return "Streaming failed"
            }
        }
    }

    private let settings: Settings
    private let session = Net.makeSession()
    private var task: URLSessionWebSocketTask?

    // Final/error may arrive before finish() is awaited (e.g. an early `busy`); stash it.
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyResult: Result<Void, Error>?
    private var settled = false
    private var finishRequested = false
    var onEarlyServerError: ((StreamError) -> Void)?

    // Hold frames until the server says `ready`, then flush — otherwise audio sent during the
    // server's start→ready window (dictation engaging) is dropped and the start is lost.
    private let maxPreReadyBytes = 2 * 1024 * 1024
    private let lock = NSLock()
    private var ready = false
    private var preReady: [Data] = []
    private var preReadyBytes = 0
    private var loggedPreReadyDrop = false
    private var openedAt = Date()

    init(settings: Settings) {
        self.settings = settings
    }

    /// Open the socket, send `{start}`, and wait until the server has clicked the dictation
    /// button and is ready to receive audio. The Mac mic is only started after this returns.
    func prepare(timeout: TimeInterval = 12) async throws {
        try open()
        try await waitUntilReady(timeout: timeout)
    }

    private func open() throws {
        guard EndpointPolicy.allowed(settings.activeServerURL) else { throw StreamError.badURL }
        guard var comps = URLComponents(url: settings.activeServerURL, resolvingAgainstBaseURL: false)
        else { throw StreamError.badURL }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/v1/stream"
        guard let url = comps.url else { throw StreamError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 780
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        openedAt = Date()
        Log.log("stream: opening \(url.absoluteString)")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receiveLoop()
        sendText(#"{"type":"start"}"#)
    }

    private func waitUntilReady(timeout seconds: TimeInterval) async throws {
        let timeout = DispatchWorkItem { [weak self] in
            self?.settleReady(.failure(StreamError.noReady))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let readyResult {
                lock.unlock()
                resumeReady(with: readyResult, cont: cont)
            } else {
                readyContinuation = cont
                lock.unlock()
            }
        }
    }

    func sendFrame(_ data: Data) {
        lock.lock()
        if ready {
            lock.unlock()
            rawSend(data)
        } else {
            preReady.append(data) // flushed on `ready`
            preReadyBytes += data.count
            while preReadyBytes > maxPreReadyBytes, !preReady.isEmpty {
                let dropped = preReady.removeFirst()
                preReadyBytes -= dropped.count
                if !loggedPreReadyDrop {
                    loggedPreReadyDrop = true
                    Log.log("stream: pre-ready buffer cap reached; dropping oldest audio frames")
                }
            }
            lock.unlock()
        }
    }

    private func rawSend(_ data: Data) {
        task?.send(.data(data)) { err in if let err { Log.log("stream: frame send error \(err.localizedDescription)") } }
    }

    /// Send `{stop}` and await the `{final}` transcript.
    func finish() async throws -> String {
        finishRequested = true
        sendText(#"{"type":"stop"}"#)
        let timeout = DispatchWorkItem { [weak self] in
            self?.settle(.failure(StreamError.noFinal))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            if let pending {
                resume(with: pending, cont: cont)
            } else {
                continuation = cont
            }
        }
    }

    /// Abort (client cancelled before stop). Server frees the mic on disconnect.
    func cancel() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.finishTasksAndInvalidate()
        settleReady(.failure(StreamError.cancelled))
    }

    // MARK: - Internals

    private func sendText(_ s: String) {
        task?.send(.string(s)) { err in if let err { Log.log("stream: text send error \(err.localizedDescription)") } }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                let streamError = StreamError.transport(err)
                Log.log("stream: receive failed after \(Int(Date().timeIntervalSince(self.openedAt) * 1000))ms — \(err.localizedDescription)")
                self.settleReady(.failure(streamError))
                self.settle(.failure(streamError))
            case .success(let message):
                if case let .string(text) = message { self.handle(text: text) }
                self.receiveLoop()
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            lock.lock()
            ready = true
            let buffered = preReady
            preReady.removeAll()
            preReadyBytes = 0
            lock.unlock()
            Log.log("stream: ready in \(Int(Date().timeIntervalSince(openedAt) * 1000))ms (flushing \(buffered.count) buffered frames)")
            for f in buffered { rawSend(f) }
            settleReady(.success(()))
        case "final":
            settle(.success(obj["text"] as? String ?? ""))
        case "error":
            let code = obj["code"] as? String ?? "error"
            let message = obj["message"] as? String ?? ""
            let error = StreamError.server(code: code, message: message)
            Log.log("stream: server error before finish code=\(code) message=\(message) ready=\(ready)")
            settleReady(.failure(error))
            settle(.failure(error))
        default:
            break // ignore unknown (forward-compat)
        }
    }

    private func settleReady(_ result: Result<Void, Error>) {
        lock.lock()
        if let cont = readyContinuation {
            readyContinuation = nil
            lock.unlock()
            resumeReady(with: result, cont: cont)
            return
        }
        guard readyResult == nil else {
            lock.unlock()
            return
        }
        readyResult = result
        lock.unlock()
    }

    private func settle(_ result: Result<String, Error>) {
        guard !settled else { return }
        settled = true
        lock.lock()
        preReady.removeAll()
        preReadyBytes = 0
        lock.unlock()
        if let cont = continuation {
            continuation = nil
            resume(with: result, cont: cont)
        } else {
            pending = result
        }
        if case .failure(let err) = result,
           !finishRequested,
           let streamErr = err as? StreamError,
           streamErr.isSemantic {
            onEarlyServerError?(streamErr)
        }
        task = nil
        session.finishTasksAndInvalidate()
    }

    private func resume(with result: Result<String, Error>, cont: CheckedContinuation<String, Error>) {
        switch result {
        case .success(let text): cont.resume(returning: text)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    private func resumeReady(with result: Result<Void, Error>, cont: CheckedContinuation<Void, Error>) {
        switch result {
        case .success: cont.resume()
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
