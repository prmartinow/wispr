import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let history = HistoryStore()
    private let pending = PendingStore()
    private lazy var appState = AppState(settings: settings, history: history)
    private lazy var client = TranscriptionClient(settings: settings)
    private lazy var health = HealthMonitor(settings: settings)
    private let capture = AudioStreamCapture()
    private var stream: StreamingClient?

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var serverStatusItem: NSMenuItem!
    private var pendingItem: NSMenuItem!
    private var pasteLastItem: NSMenuItem!
    private var hud: HUDController!
    private var hotKey: HotKeyManager!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var idleWork: DispatchWorkItem?
    private var retrying = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController(state: appState,
                            onStart: { [weak self] in self?.startRecording() },
                            onStop: { [weak self] in self?.stopAndTranscribe() })
        setupStatusItem()
        appState.pendingCount = pending.count

        Log.log("launch: server=\(settings.serverURL.absoluteString) tokenSet=\(!settings.token.isEmpty) "
            + "activation=\(settings.activation.rawValue) AXTrusted=\(AXIsProcessTrusted()) pending=\(pending.count)")

        AVCaptureDevice.requestAccess(for: .audio) { granted in Log.log("mic permission granted=\(granted)") }
        ensureAccessibility()

        hotKey = HotKeyManager(keyCode: settings.hotKeyCode, modifiers: settings.modifierFlags, mode: settings.activation)
        hotKey.onToggle = { [weak self] in self?.toggle() }
        hotKey.onStart = { [weak self] in self?.startRecording() }
        hotKey.onStop = { [weak self] in self?.stopAndTranscribe() }
        hotKey.start()

        health.onChange = { [weak self] status in
            guard let self else { return }
            self.appState.serverStatus = status
            self.refreshMenu()
            Log.log("health: \(status.label)")
            if status == .up { self.retryPending() } // server recovered → drain the buffer
        }
        health.start()

        appState.$phase.receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.renderMenuBar(phase) }
            .store(in: &cancellables)

        renderMenuBar(.idle)
        hud.show() // persistent
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        serverStatusItem = NSMenuItem(title: "Server: checking…", action: nil, keyEquivalent: "")
        serverStatusItem.isEnabled = false
        menu.addItem(serverStatusItem)
        pendingItem = NSMenuItem(title: "Retry pending", action: #selector(retryPendingAction), keyEquivalent: "")
        pendingItem.isHidden = true
        menu.addItem(pendingItem)
        pasteLastItem = NSMenuItem(title: "Paste Last Transcript", action: #selector(pasteLastAction), keyEquivalent: "")
        pasteLastItem.isHidden = true
        menu.addItem(pasteLastItem)
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

    private func refreshMenu() {
        serverStatusItem.title = "Server: \(appState.serverStatus.label)"
        let n = appState.pendingCount
        pendingItem.isHidden = n == 0
        pendingItem.title = "Retry \(n) pending recording\(n == 1 ? "" : "s")"
        pasteLastItem.isHidden = appState.lastTranscript.isEmpty
    }

    private func renderMenuBar(_ phase: DictationPhase) {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?)
        switch phase {
        case .idle:         (symbol, tint) = ("mic", nil)
        case .recording:    (symbol, tint) = ("mic.fill", .systemRed)
        case .transcribing: (symbol, tint) = ("waveform", .systemYellow)
        case .inserted:     (symbol, tint) = ("checkmark.circle.fill", .systemGreen)
        case .copied:       (symbol, tint) = ("doc.on.clipboard.fill", .systemYellow)
        case .error:        (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisper")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
    }

    // MARK: - Dictation flow

    @objc private func toggleFromMenu() { toggle() }
    @objc private func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
    @objc private func retryPendingAction() { health.check(); retryPending() }
    @objc private func pasteLastAction() { pasteAfterFocus(appState.lastTranscript) }

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
            appState.phase = .error(WhisperError.mic("Microphone unavailable").userMessage)
            scheduleIdle(after: 2.5)
        }
    }

    private func stopAndTranscribe() {
        guard appState.phase == .recording else { return }
        let pcm = capture.stop()
        let streamRef = stream
        stream = nil
        appState.level = 0

        // Guard against an accidental tap (well under a spoken word).
        if pcm.count < 16_000 {
            streamRef?.cancel()
            appState.phase = .error("No speech detected")
            scheduleIdle(after: 2)
            return
        }

        appState.phase = .transcribing
        let t0 = Date()
        Log.log("transcribe: stop (\(pcm.count) bytes pcm, ~\(Int(appState.elapsed))s)")
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runTranscription(stream: streamRef, pcm: pcm, t0: t0)
            await MainActor.run {
                switch result {
                case .success(let text):
                    self.deliver(text)
                case .failure(let werr):
                    if werr.shouldBuffer {
                        self.pending.add(wav: WAV.fromPCM(pcm), reason: werr.userMessage)
                        self.appState.pendingCount = self.pending.count
                        self.refreshMenu()
                        Log.log("buffered take for retry (pending=\(self.pending.count)) — \(werr.userMessage)")
                    }
                    self.appState.phase = .error(werr.userMessage)
                    self.scheduleIdle(after: 3)
                }
            }
        }
    }

    /// Stream first; on a *transport* failure fall back to batch. Semantic server errors are
    /// classified (busy/backend/etc.) so the caller can buffer or surface appropriately.
    private func runTranscription(stream: StreamingClient?, pcm: Data, t0: Date) async -> Result<String, WhisperError> {
        if let stream {
            do {
                let text = try await stream.finish()
                Log.log("stream: final in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
                return text.isEmpty ? .failure(.noSpeech) : .success(text)
            } catch let e as StreamingClient.StreamError where e.isSemantic {
                Log.log("stream: server error \(e.displayMessage) — not retrying via batch")
                return .failure(WhisperError.from(e))
            } catch {
                Log.log("stream: transport failure — falling back to batch")
            }
        }
        guard !pcm.isEmpty else { return .failure(.noSpeech) }
        do {
            let text = try await client.transcribe(wav: WAV.fromPCM(pcm))
            Log.log("batch: OK in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
            return text.isEmpty ? .failure(.noSpeech) : .success(text)
        } catch {
            return .failure(WhisperError.from(error))
        }
    }

    /// Insert into the focused field, or — if no editable field is focused — keep it on the
    /// clipboard and tell the user (Scenario 1).
    private func deliver(_ text: String) {
        history.add(text)
        appState.lastTranscript = text
        refreshMenu()
        if FocusedField.isEditable() {
            TextInserter.insert(text)
            appState.phase = .inserted
            Log.log("deliver: inserted into focused field")
            scheduleIdle(after: 1)
        } else {
            TextInserter.copy(text)
            appState.phase = .copied
            Log.log("deliver: no editable field — copied to clipboard")
            scheduleIdle(after: 4)
        }
    }

    private func retryPending() {
        guard !retrying, !appState.isBusy, appState.pendingCount > 0 else { return }
        retrying = true
        Log.log("retry: draining \(appState.pendingCount) pending")
        Task { [weak self] in
            guard let self else { return }
            var recovered = 0
            while let item = await MainActor.run(body: { self.pending.oldest() }) {
                guard let wav = await MainActor.run(body: { self.pending.wav(for: item) }) else {
                    await MainActor.run { self.pending.remove(item); self.appState.pendingCount = self.pending.count }
                    continue
                }
                do {
                    let text = try await self.client.transcribe(wav: wav)
                    await MainActor.run {
                        if !text.isEmpty {
                            self.history.add(text)
                            self.appState.lastTranscript = text
                            TextInserter.copy(text)
                            recovered += 1
                        }
                        self.pending.remove(item)
                        self.appState.pendingCount = self.pending.count
                        self.refreshMenu()
                    }
                } catch {
                    Log.log("retry: still failing — will try again later")
                    break
                }
            }
            await MainActor.run {
                self.retrying = false
                self.refreshMenu()
                if recovered > 0, !self.appState.isBusy {
                    Log.log("retry: recovered \(recovered) → last on clipboard + History")
                    self.appState.phase = .copied
                    self.scheduleIdle(after: 4)
                }
            }
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
            let view = HistoryView(history: history, onPaste: { [weak self] text in self?.pasteAfterFocus(text) })
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

    /// Put text on the clipboard, dismiss our windows, and paste into whatever regains focus.
    private func pasteAfterFocus(_ text: String) {
        guard !text.isEmpty else { return }
        historyWindow?.orderOut(nil)
        TextInserter.copy(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { TextInserter.insert(text) }
    }

    private func reconfigureHotKey() {
        hotKey.update(keyCode: settings.hotKeyCode, modifiers: settings.modifierFlags, mode: settings.activation)
        updateToggleTitle()
    }

    // MARK: - Permissions

    private func ensureAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        // Literal kAXTrustedCheckOptionPrompt value, to avoid SDK Unmanaged churn.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
