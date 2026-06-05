import Foundation

/// Picks the active endpoint: prefer direct LAN HTTPS/mTLS, then remote mTLS.
/// Re-evaluates at launch, periodically, and on demand. Sets `settings.activeServerURL`,
/// which the clients read per request.
final class EndpointSelector {
    private let settings: Settings
    private var timer: Timer?
    var onChange: ((URL) -> Void)?

    init(settings: Settings) { self.settings = settings }

    func start() {
        select()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.select() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func select() {
        Task { [weak self] in
            _ = await self?.selectNow(reason: "timer", log: false)
        }
    }

    @discardableResult
    func selectNow(timeout: TimeInterval = 6, reason: String, log: Bool = false, preferCurrent: Bool = false) async -> URL {
        let lan = settings.serverURL
        let remote = settings.remoteURL
        let token = settings.token
        let active = settings.activeServerURL
        if preferCurrent,
           active != lan,
           await Self.reachable(active, token: token, timeout: timeout, reason: reason, log: log) {
            return active
        }
        if await Self.reachable(lan, token: token, timeout: timeout, reason: reason, log: log) {
            await setActive(lan)
            return lan
        }
        if let remote, await Self.reachable(remote, token: token, timeout: timeout, reason: reason, log: log) {
            await setActive(remote)
            return remote
        }
        await setActive(lan) // neither reachable → keep LAN; callers can surface the failure
        return lan
    }

    @MainActor private func setActive(_ url: URL) {
        guard settings.activeServerURL != url else { return }
        settings.activeServerURL = url
        Log.log("endpoint: active → \(url.absoluteString)")
        onChange?(url)
    }

    static func reachable(_ base: URL, token: String, timeout: TimeInterval = 6, reason: String = "select", log: Bool = false) async -> Bool {
        guard EndpointPolicy.allowed(base), !token.isEmpty else { return false }
        let t0 = Date()
        var req = URLRequest(url: base.appendingPathComponent("healthz"))
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await Net.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code == 200
            if log {
                Log.log("endpoint: \(reason) probe \(base.absoluteString) -> http=\(code) ok=\(ok) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            return ok
        } catch {
            if log {
                Log.log("endpoint: \(reason) probe \(base.absoluteString) -> error=\(error.localizedDescription) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            }
            return false
        }
    }
}
