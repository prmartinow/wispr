import Network

/// Fires when the network path changes (Wi-Fi ↔ Ethernet, interface up/down) so the app can
/// immediately re-probe the endpoint + health instead of waiting for the ~20–30 s poll — which
/// is what left it "stuck, can't reach the service" after switching to Ethernet.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wispr.network.monitor")
    private var debounce: DispatchWorkItem?
    private var started = false

    /// Called on the main thread, coalesced, on each path change.
    var onChange: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.started else { self.started = true; return } // skip the initial callback
                self.debounce?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.onChange?() }
                self.debounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
