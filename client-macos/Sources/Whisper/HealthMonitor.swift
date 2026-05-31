import Foundation

enum ServerStatus: Equatable {
    case unknown, up, backendDown, unreachable
    var label: String {
        switch self {
        case .unknown:     return "checking…"
        case .up:          return "online"
        case .backendDown: return "backend down"
        case .unreachable: return "offline"
        }
    }
}

/// Polls `/healthz` so the UI can show server/backend state and so pending takes can be
/// auto-retried when the server comes back. Distinguishes "server up but Chromium/dictation service
/// down" (backendDown) from "can't reach the server at all" (unreachable).
final class HealthMonitor {
    private let settings: Settings
    private var timer: Timer?
    private(set) var status: ServerStatus = .unknown

    /// Called on the main thread whenever the status changes.
    var onChange: ((ServerStatus) -> Void)?

    init(settings: Settings) { self.settings = settings }

    func start() {
        check()
        let t = Timer(timeInterval: 25, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func check() {
        let url = settings.serverURL.appendingPathComponent("healthz")
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            let new: ServerStatus
            if let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                new = (o["browser"] as? String) == "up" ? .up : .backendDown
            } else {
                new = .unreachable
            }
            DispatchQueue.main.async {
                let changed = self.status != new
                self.status = new
                if changed { self.onChange?(new) }
            }
        }.resume()
    }
}
