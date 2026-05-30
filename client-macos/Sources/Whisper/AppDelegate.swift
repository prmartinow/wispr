import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let history = HistoryStore()
    private lazy var appState = AppState(settings: settings, history: history)
    private lazy var client = TranscriptionClient(settings: settings)
    private let capture = AudioStreamCapture()
    private var stream: StreamingClient?

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var hud: HUDController!
    private var hotKey: HotKeyManager!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var idleWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController(state: appState)
        setupStatusItem()

        Log.log("launch: server=\(settings.serverURL.absoluteString) tokenSet=\(!settings.token.isEmpty) "
            + "activation=\(settings.activation.rawValue) AXTrusted=\(AXIsProcessTrusted())")

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.log("mic permission granted=\(granted)")
        }
        ensureAccessibility()

        hotKey = HotKeyManager(keyCode: settings.hotKeyCode,
                               modifiers: settings.modifierFlags,
                               mode: settings.activation)
        hotKey.onToggle = { [weak self] in self?.toggle() }
        hotKey.onStart = { [weak self] in self?.startRecording() }
        hotKey.onStop = { [weak self] in self?.stopAndTranscribe() }
        hotKey.start()

        // Drive the menu-bar icon + HUD from the state machine.
        appState.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.render(phase) }
            .store(in: &cancellables)

        render(.idle)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reveal Log in Finder", action: #selector(revealLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateToggleTitle()
    }

    private func updateToggleTitle() {
        let shortcut = KeyName.describe(keyCode: settings.hotKeyCode, modifiers: settings.modifierFlags)
        let verb = settings.activation == .pushToTalk ? "Hold to Talk" : "Start / Stop Dictation"
        toggleItem.title = "\(verb)  (\(shortcut))"
    }

    private func render(_ phase: DictationPhase) {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?)
        switch phase {
        case .idle:         (symbol, tint) = ("mic", nil)
        case .recording:    (symbol, tint) = ("mic.fill", .systemRed)
        case .transcribing: (symbol, tint) = ("waveform", .systemYellow)
        case .inserted:     (symbol, tint) = ("checkmark.circle.fill", .systemGreen)
        case .error:        (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisper")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint

        phase == .idle ? hud.hide() : hud.show()
    }

    // MARK: - Dictation flow

    @objc private func toggleFromMenu() { toggle() }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    private func toggle() {
        if appState.phase == .transcribing { return } // serialized server-side
        appState.phase == .recording ? stopAndTranscribe() : startRecording()
    }

    private func startRecording() {
        guard !appState.isBusy else { return }
        idleWork?.cancel()
        capture.onMeter = { [weak self] level, elapsed in
            self?.appState.level = level
            self?.appState.elapsed = elapsed
        }
        // Open the live stream and forward each PCM frame to it. Capture also accumulates the
        // whole take, so a *transport* failure can fall back to batch POST /transcribe.
        let s = StreamingClient(settings: settings)
        capture.onFrame = { [weak s] frame in s?.sendFrame(frame) }
        do {
            try s.open()
            try capture.start(inputUID: settings.inputDeviceUID)
            stream = s
            appState.phase = .recording
            Log.log("record: started (streaming, input=\(settings.inputDeviceUID ?? "system default"))")
        } catch {
            s.cancel()
            Log.log("record: start FAILED \(error)")
            appState.phase = .error("Couldn’t start mic")
            scheduleIdle(after: 2)
        }
    }

    private func stopAndTranscribe() {
        guard appState.phase == .recording else { return }
        let pcm = capture.stop()
        let streamRef = stream
        stream = nil
        appState.level = 0
        appState.phase = .transcribing
        let t0 = Date()
        Log.log("transcribe: stop (\(pcm.count) bytes pcm, ~\(Int(appState.elapsed))s) — awaiting stream final")
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runTranscription(stream: streamRef, pcm: pcm, t0: t0)
            await MainActor.run {
                switch result {
                case .success(let text):
                    TextInserter.insert(text)
                    self.history.add(text)
                    self.appState.phase = .inserted
                    self.scheduleIdle(after: 1)
                case .failure(let fail):
                    self.appState.phase = .error(fail.message)
                    self.scheduleIdle(after: 2.5)
                }
            }
        }
    }

    private struct Fail: Error { let message: String }

    /// Stream first; on a *transport* failure fall back to batch with the accumulated PCM.
    /// A *semantic* server error (busy/backend) is surfaced without a batch retry.
    private func runTranscription(stream: StreamingClient?, pcm: Data, t0: Date) async -> Result<String, Fail> {
        if let stream {
            do {
                let text = try await stream.finish()
                Log.log("stream: final in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars: \"\(text.prefix(60))\"")
                return text.isEmpty ? .failure(Fail(message: "No speech detected")) : .success(text)
            } catch let e as StreamingClient.StreamError where e.isSemantic {
                Log.log("stream: server error \(e) — surfacing (no batch)")
                return .failure(Fail(message: e.displayMessage))
            } catch {
                Log.log("stream: transport failure \(error) — falling back to batch")
            }
        }
        guard !pcm.isEmpty else { return .failure(Fail(message: "No audio captured")) }
        do {
            let text = try await client.transcribe(wav: WAV.fromPCM(pcm))
            Log.log("batch fallback: OK in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
            return text.isEmpty ? .failure(Fail(message: "No speech detected")) : .success(text)
        } catch {
            Log.log("batch fallback: FAILED → \(error)")
            return .failure(Fail(message: describe(error)))
        }
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.appState.phase != .recording { self.appState.phase = .idle }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func describe(_ error: Error) -> String {
        if case let TranscriptionClient.ClientError.server(code, _) = error { return "Server: \(code)" }
        if case TranscriptionClient.ClientError.http(let status) = error { return "HTTP \(status)" }
        return "Transcription failed"
    }

    // MARK: - Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                onHotKeyChange: { [weak self] in self?.reconfigureHotKey() },
                setHotKeyEnabled: { [weak self] on in self?.hotKey.setEnabled(on) })
            settingsWindow = makeWindow(title: "Whisper Settings", content: view)
        }
        present(settingsWindow)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let view = HistoryView(history: history, onPaste: { [weak self] text in self?.pasteFromHistory(text) })
            historyWindow = makeWindow(title: "History", content: view)
        }
        present(historyWindow)
    }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func pasteFromHistory(_ text: String) {
        historyWindow?.orderOut(nil)
        // Let the previously focused app regain key focus, then paste into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            TextInserter.insert(text)
        }
    }

    private func reconfigureHotKey() {
        hotKey.update(keyCode: settings.hotKeyCode, modifiers: settings.modifierFlags, mode: settings.activation)
        updateToggleTitle()
    }

    // MARK: - Permissions

    private func ensureAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        // Prompt to add the app under Accessibility (needed for global hotkey + paste).
        // Literal key value of kAXTrustedCheckOptionPrompt, used to avoid SDK Unmanaged churn.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
