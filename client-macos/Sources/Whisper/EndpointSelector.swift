import Foundation

/// Picks the active endpoint: prefer **LAN** (`wispr.local:8090`, fast, no mTLS — also covers
/// WireGuard since the same IP routes over the tunnel); fall back to the **remote** mTLS URL
/// (`https://whisper.p12w.xyz`) when LAN isn't reachable. Re-evaluates at launch, periodically,
/// and on demand. Sets `settings.activeServerURL`, which the clients read per request.
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
        let lan = settings.serverURL
        let remote = settings.remoteURL
        let token = settings.token
        Task { [weak self] in
            guard let self else { return }
            if await Self.reachable(lan, token: token) { await self.setActive(lan); return }
            if let remote, await Self.reachable(remote, token: token) { await self.setActive(remote); return }
            await self.setActive(lan) // neither reachable → keep LAN; the client buffers takes
        }
    }

    @MainActor private func setActive(_ url: URL) {
        guard settings.activeServerURL != url else { return }
        settings.activeServerURL = url
        Log.log("endpoint: active → \(url.absoluteString)")
        onChange?(url)
    }

    static func reachable(_ base: URL, token: String) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("healthz"))
        req.timeoutInterval = 2.5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await Net.session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
