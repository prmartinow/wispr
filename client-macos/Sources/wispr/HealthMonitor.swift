import Foundation

/// Server readiness, derived from the deep `/healthz` (browser / dictationService / mic / internet).
enum ServerStatus: Equatable {
    case unknown
    case up            // dictationService ready — safe to dictate
    case loading       // browser up but dictation service still warming up
    case loggedOut     // dictation service logged out — needs a human to log in
    case backendDown   // Chromium/mic not available
    case serverOffline // server reachable but it has no internet
    case unauthorized  // bearer token missing or wrong
    case unreachable   // can't reach the server at all

    var label: String {
        switch self {
        case .unknown:       return "checking…"
        case .up:            return "online"
        case .loading:       return "warming up…"
        case .loggedOut:     return "dictation service logged out"
        case .backendDown:   return "backend down"
        case .serverOffline: return "server has no internet"
        case .unauthorized:  return "unauthorized"
        case .unreachable:   return "unreachable"
        }
    }

    /// Safe to record right now (everything green).
    var isReady: Bool { self == .up }
}

/// Polls `/healthz` so the UI reflects server/backend state and pending takes can auto-retry
/// when the server recovers. Reads the deep fields the server added in robustness pass 1/2.
final class HealthMonitor {
    private let settings: Settings
    private var timer: Timer?
    private(set) var status: ServerStatus = .unknown

    /// Called on the main thread whenever the status changes.
    var onChange: ((ServerStatus) -> Void)?

    init(settings: Settings) { self.settings = settings }

    func start() {
        check()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func check() {
        let url = settings.activeServerURL.appendingPathComponent("healthz")
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        Net.session.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            let new = Self.classify(status: (resp as? HTTPURLResponse)?.statusCode, data: data)
            if new == .unreachable, let error {
                Log.log("health: request failed \(url.absoluteString) — \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                let changed = self.status != new
                self.status = new
                if changed { self.onChange?(new) }
            }
        }.resume()
    }

    func checkNow(reason: String, timeout: TimeInterval = 6) async -> ServerStatus {
        let url = settings.activeServerURL.appendingPathComponent("healthz")
        let t0 = Date()
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")

        let status: ServerStatus
        let summary: String
        do {
            let (data, resp) = try await Net.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode
            status = Self.classify(status: code, data: data)
            summary = Self.summary(status: code, data: data, error: nil)
        } catch {
            status = .unreachable
            summary = "error=\(error.localizedDescription)"
        }

        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        Log.log("health: \(reason) \(url.absoluteString) -> \(status.label) \(summary) in \(elapsedMs)ms")
        await MainActor.run {
            let changed = self.status != status
            self.status = status
            if changed { self.onChange?(status) }
        }
        return status
    }

    static func classify(status code: Int?, data: Data?) -> ServerStatus {
        if code == 401 { return .unauthorized }
        guard code == 200, let data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreachable
        }
        let browser = o["browser"] as? String
        let dictationService = o["dictationService"] as? String
        let internet = o["internet"] as? String
        if browser != "up" { return .backendDown }
        if dictationService == "logged_out" { return .loggedOut }
        if dictationService == "loading" || dictationService == "no-tab" { return .loading }
        if internet == "down" { return .serverOffline }
        if dictationService == "ready" { return .up }
        return .backendDown
    }

    private static func summary(status code: Int?, data: Data?, error: Error?) -> String {
        if let error { return "error=\(error.localizedDescription)" }
        guard let data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "http=\(code ?? 0)"
        }
        let browser = o["browser"] as? String ?? "?"
        let dictationService = o["dictationService"] as? String ?? "?"
        let mic = o["mic"] as? String ?? "?"
        let internet = o["internet"] as? String ?? "?"
        let busy = (o["busy"] as? Bool).map(String.init) ?? "?"
        let last = (o["lastDictation"] as? [String: Any]).flatMap { last -> String? in
            guard let ok = last["ok"] as? Bool else { return nil }
            let ms = last["ms"] as? Int ?? 0
            let err = last["error"] as? String
            return "last.ok=\(ok) last.ms=\(ms)" + (err.map { " last.error=\($0)" } ?? "")
        } ?? "last=nil"
        return "http=\(code ?? 0) browser=\(browser) dictationService=\(dictationService) mic=\(mic) internet=\(internet) busy=\(busy) \(last)"
    }
}
