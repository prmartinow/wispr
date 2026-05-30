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
    private let recorder = AudioRecorder()

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
        recorder.onMeter = { [weak self] level, elapsed in
            self?.appState.level = level
            self?.appState.elapsed = elapsed
        }
        do {
            try recorder.start(inputUID: settings.inputDeviceUID)
            appState.phase = .recording
            Log.log("record: started (input=\(settings.inputDeviceUID ?? "system default"))")
        } catch {
            Log.log("record: start FAILED \(error)")
            appState.phase = .error("Couldn’t start mic")
            scheduleIdle(after: 2)
        }
    }

    private func stopAndTranscribe() {
        guard appState.phase == .recording else { return }
        let url = recorder.stop()
        appState.level = 0
        guard let url else { appState.phase = .idle; return }
        appState.phase = .transcribing
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        let t0 = Date()
        Log.log("transcribe: POST \(url.lastPathComponent) (\(bytes ?? -1) bytes, ~\(Int(appState.elapsed))s)")
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.client.transcribe(audioURL: url)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                Log.log("transcribe: OK in \(ms)ms → \(text.count) chars: \"\(text.prefix(60))\"")
                await MainActor.run {
                    TextInserter.insert(text)
                    self.history.add(text)
                    self.appState.phase = .inserted
                    self.scheduleIdle(after: 1)
                }
            } catch {
                Log.log("transcribe: FAILED after \(Int(Date().timeIntervalSince(t0)))s → \(error)")
                await MainActor.run {
                    self.appState.phase = .error(self.describe(error))
                    self.scheduleIdle(after: 2.5)
                }
            }
            try? FileManager.default.removeItem(at: url)
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
