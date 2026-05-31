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
        Net.session.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let new = Self.classify(status: (resp as? HTTPURLResponse)?.statusCode, data: data)
            DispatchQueue.main.async {
                let changed = self.status != new
                self.status = new
                if changed { self.onChange?(new) }
            }
        }.resume()
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
}
