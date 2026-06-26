import AppKit
import ApplicationServices
import AVFoundation
import Combine
import SwiftUI

private final class Counter { var n = 0 }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let history = HistoryStore()
    private let pending = PendingStore()
    private lazy var appState = AppState(settings: settings, history: history)
    private lazy var client = TranscriptionClient(settings: settings)
    private lazy var health = HealthMonitor(settings: settings)
    private lazy var endpoints = EndpointSelector(settings: settings)
    private let network = NetworkMonitor()
    private let capture = AudioStreamCapture()
    private var stream: StreamingClient?
    private var preparingStream: StreamingClient?

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
    private var pasteTarget: FocusedField.PasteTarget?
    private var escapeMonitors: [Any] = []
    private var startingRecording = false
    private var recordingStartedAt: Date?
    private let toggleStopDebounce: TimeInterval = 0.35
    private let preflightEndpointTimeout: TimeInterval = 3
    private let preflightHealthTimeout: TimeInterval = 4
    private let streamPrepareTimeout: TimeInterval = 12
    private let safetySaveMinPCMBytes = AudioStreamCapture.sampleRate * 2 * 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUDController(state: appState,
                            onStart: { [weak self] in self?.startRecording() },
                            onStop: { [weak self] in self?.stopAndTranscribe() },
                            onCancel: { [weak self] in self?.cancelRecording() })
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
            if status == .up { self.retryPending(auto: true) } // server recovered → drain buffered takes
        }
        health.start()

        endpoints.onChange = { [weak self] _ in self?.health.check() } // re-check health on switch
        endpoints.onReachable = { [weak self] _ in self?.health.check() } // first green probe may keep same URL
        endpoints.start()

        // Recover immediately when the network changes (Wi-Fi ↔ Ethernet) instead of waiting for the poll.
        network.onChange = { [weak self] in
            guard let self else { return }
            Log.log("network: path changed → re-probing endpoint + health")
            self.endpoints.select()
            self.health.check()
        }
        network.start()

        appState.$phase.receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.renderMenuBar(phase) }
            .store(in: &cancellables)

        renderMenuBar(.idle)
        hud.show() // persistent
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        idleWork?.cancel()
        removeEscapeMonitor()
        if appState.phase == .recording {
            recordingStartedAt = nil
            let pcm = capture.stop()
            stream?.cancel()
            stream = nil
            appState.level = 0
            if pcm.count >= safetySaveMinPCMBytes {
                pending.add(wav: WAV.fromPCM(pcm), reason: "App quit during recording — saved locally")
                Log.log("record: app quit during recording; saved local WAV (pending=\(pending.count), bytes=\(pcm.count))")
            } else {
                Log.log("record: app quit during short recording; discarded \(pcm.count) bytes")
            }
        } else if appState.phase == .preparing {
            preparingStream?.cancel()
            preparingStream = nil
            startingRecording = false
            Log.log("record: app quit while preparing; cancelled stream setup")
        } else if appState.phase == .transcribing {
            Log.log("transcribe: app quit while transcribing; relying on existing safety copy if this was a long take")
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
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
        pasteLastItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastAction), keyEquivalent: "")
        pasteLastItem.isHidden = true
        menu.addItem(pasteLastItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reveal Log in Finder", action: #selector(revealLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit wispr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateToggleTitle()
    }

    private func updateToggleTitle() {
        let shortcut = KeyName.describe(keyCode: settings.hotKeyCode, modifiers: settings.modifierFlags)
        let verb = settings.activation == .pushToTalk ? "Hold to Talk" : "Start / Stop Dictation"
        toggleItem.title = "\(verb)  (\(shortcut))"
    }

    private func refreshMenu() {
        let kind = settings.activeServerURL == settings.serverURL ? "LAN" : "remote"
        serverStatusItem.title = "Server: \(appState.serverStatus.label) · \(kind)"
        let n = appState.pendingCount
        pendingItem.isHidden = n == 0
        pendingItem.title = "Retry \(n) pending recording\(n == 1 ? "" : "s")"
        pasteLastItem.isHidden = appState.lastTranscript.isEmpty
    }

    private func renderMenuBar(_ phase: DictationPhase) {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?)
        switch phase {
        case .idle:         (symbol, tint) = ("waveform", nil)
        case .preparing:    (symbol, tint) = ("antenna.radiowaves.left.and.right", .systemYellow)
        case .recording:    (symbol, tint) = ("mic.fill", .systemRed)
        case .transcribing: (symbol, tint) = ("waveform", .systemYellow)
        case .inserted:     (symbol, tint) = ("checkmark.circle.fill", .systemGreen)
        case .copied:       (symbol, tint) = ("doc.on.clipboard.fill", .systemYellow)
        case .available:    (symbol, tint) = ("doc.text.fill", .systemYellow)
        case .error:        (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "wispr")
        image?.isTemplate = (tint == nil)
        button.image = image
        button.contentTintColor = tint
    }

    // MARK: - Dictation flow

    @objc private func toggleFromMenu() { toggle() }
    @objc private func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
    @objc private func retryPendingAction() { health.check(); retryPending(auto: false) }
    @objc private func copyLastAction() {
        guard !appState.lastTranscript.isEmpty else { return }
        TextInserter.copy(appState.lastTranscript)
        appState.phase = .copied
        scheduleIdle(after: 3)
    }

    private func toggle() {
        if retrying {
            Log.log("HotKey: ignored while pending retry is running")
            return
        }
        if appState.phase == .preparing {
            cancelPreparing()
            return
        }
        if appState.phase == .transcribing { return } // serialized server-side
        if startingRecording { return }
        if appState.phase == .recording,
           settings.activation == .toggle,
           let started = recordingStartedAt,
           Date().timeIntervalSince(started) < toggleStopDebounce {
            Log.log("HotKey: ignored immediate stop during recording debounce")
            return
        }
        appState.phase == .recording ? stopAndTranscribe() : startRecording()
    }

    private func startRecording() {
        if retrying {
            Log.log("record: ignored; pending retry in progress")
            return
        }
        guard !appState.isBusy, !startingRecording else { return }
        startingRecording = true
        idleWork?.cancel()
        appState.level = 0
        appState.elapsed = 0
        appState.phase = .preparing
        installEscapeMonitor() // Esc cancels while preparing or recording
        let frontmost = NSWorkspace.shared.frontmostApplication
        pasteTarget = FocusedField.capture(frontmost: frontmost)
        let target = FocusedField.targetSummary(pasteTarget)
        Log.log("record: preflight begin endpoint=\(settings.activeServerURL.absoluteString) cachedHealth=\(appState.serverStatus.label) input=\(settings.inputDeviceUID ?? "system default") target=\(target)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.endpoints.selectNow(timeout: self.preflightEndpointTimeout, reason: "preflight", log: true, preferCurrent: true)
            guard self.appState.phase == .preparing, self.startingRecording else { return }

            let status = await self.health.checkNow(reason: "preflight", timeout: self.preflightHealthTimeout)
            guard self.appState.phase == .preparing, self.startingRecording else { return }
            guard status.isReady else {
                self.failPreflight(status: status)
                return
            }

            let s = StreamingClient(settings: self.settings)
            s.onEarlyServerError = { [weak self, weak s] error in
                guard let self, let s else { return }
                DispatchQueue.main.async { self.stopRecordingAfterStreamError(error, stream: s) }
            }
            self.preparingStream = s
            let t0 = Date()
            do {
                try await s.prepare(timeout: self.streamPrepareTimeout)
                self.startCaptureAfterPrepare(stream: s, prepareStartedAt: t0)
            } catch {
                self.failPrepare(error, stream: s, prepareStartedAt: t0)
            }
        }
    }

    /// Abort the current recording without transcribing (HUD ✕ or Esc) — mirrors the dictate
    /// service's "Cancel dictation". Disconnecting the stream makes the server cancel + free the mic.
    private func cancelRecording() {
        if appState.phase == .preparing {
            cancelPreparing()
            return
        }
        guard appState.phase == .recording else { return }
        removeEscapeMonitor()
        recordingStartedAt = nil
        _ = capture.stop()
        stream?.cancel()
        stream = nil
        appState.level = 0
        appState.phase = .idle
        Log.log("record: cancelled by user (discarded, nothing transcribed)")
    }

    private func cancelPreparing() {
        guard appState.phase == .preparing || startingRecording else { return }
        preparingStream?.cancel()
        preparingStream = nil
        startingRecording = false
        removeEscapeMonitor()
        appState.level = 0
        appState.elapsed = 0
        appState.phase = .idle
        Log.log("record: preflight cancelled")
    }

    private func failPreflight(status: ServerStatus) {
        preparingStream?.cancel()
        preparingStream = nil
        startingRecording = false
        removeEscapeMonitor()
        let message = preflightMessage(for: status)
        appState.phase = .error(message)
        Log.log("record: preflight blocked status=\(status.label) endpoint=\(settings.activeServerURL.absoluteString) message=\(message)")
        scheduleIdle(after: 3)
    }

    private func startCaptureAfterPrepare(stream preparedStream: StreamingClient, prepareStartedAt: Date) {
        guard appState.phase == .preparing, preparingStream === preparedStream, startingRecording else {
            preparedStream.cancel()
            return
        }
        capture.onMeter = { [weak self] level, elapsed in
            self?.appState.level = level
            self?.appState.elapsed = elapsed
        }
        capture.onLimitReached = { [weak self] in
            guard let self, self.appState.phase == .recording else { return }
            Log.log("record: 10-minute cap reached; stopping automatically")
            self.stopAndTranscribe()
        }
        capture.onFrame = { [weak preparedStream] frame in preparedStream?.sendFrame(frame) }
        do {
            try capture.start(inputUID: settings.inputDeviceUID)
            stream = preparedStream
            preparingStream = nil
            startingRecording = false
            recordingStartedAt = Date()
            appState.phase = .recording
            Log.log("record: started after preflight in \(Int(Date().timeIntervalSince(prepareStartedAt) * 1000))ms (endpoint=\(settings.activeServerURL.absoluteString), input=\(settings.inputDeviceUID ?? "system default"))")
        } catch {
            preparedStream.cancel()
            preparingStream = nil
            startingRecording = false
            removeEscapeMonitor()
            Log.log("record: capture start FAILED after server ready — \(error)")
            appState.phase = .error(WisprError.mic("Microphone unavailable").userMessage)
            scheduleIdle(after: 2.5)
        }
    }

    private func failPrepare(_ error: Error, stream failedStream: StreamingClient, prepareStartedAt: Date) {
        guard appState.phase == .preparing, preparingStream === failedStream else { return }
        failedStream.cancel()
        preparingStream = nil
        startingRecording = false
        removeEscapeMonitor()
        let werr = WisprError.from(error)
        Log.log("record: stream preflight FAILED in \(Int(Date().timeIntervalSince(prepareStartedAt) * 1000))ms endpoint=\(settings.activeServerURL.absoluteString) error=\(werr.userMessage) raw=\(error)")
        health.check()
        appState.phase = .error(werr.userMessage)
        scheduleIdle(after: 3)
    }

    private func stopRecordingAfterStreamError(_ error: StreamingClient.StreamError, stream failedStream: StreamingClient) {
        guard appState.phase == .recording, stream === failedStream else { return }
        removeEscapeMonitor()
        recordingStartedAt = nil
        let pcm = capture.stop()
        failedStream.cancel()
        stream = nil
        appState.level = 0

        let werr = WisprError.from(error)
        if pcm.count >= safetySaveMinPCMBytes {
            let reason = werr.shouldBuffer ? werr.userMessage : "Recording stopped unexpectedly — saved locally"
            pending.add(wav: WAV.fromPCM(pcm), reason: reason)
            appState.pendingCount = pending.count
            refreshMenu()
            Log.log("buffered partial take after stream failure (pending=\(pending.count), bytes=\(pcm.count)) — \(werr.userMessage)")
        } else if pcm.count >= 16_000, werr.shouldBuffer {
            pending.add(wav: WAV.fromPCM(pcm), reason: werr.userMessage)
            appState.pendingCount = pending.count
            refreshMenu()
            Log.log("buffered short partial take for retry (pending=\(pending.count), bytes=\(pcm.count)) — \(werr.userMessage)")
        } else {
            Log.log("record: stopped early; stream failed while recording — \(werr.userMessage)")
        }
        appState.phase = .error(werr.userMessage)
        scheduleIdle(after: 3)
    }

    /// Esc cancels while recording. Global+local NSEvent monitors (we hold Accessibility); the
    /// monitor only lives during recording and only reacts to Esc, so it doesn't disturb typing.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        let handle: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.cancelRecording() } } // 53 = Esc
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { handle($0) }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handle($0); return $0 }
        escapeMonitors = [global, local].compactMap { $0 }
    }

    private func removeEscapeMonitor() {
        escapeMonitors.forEach { NSEvent.removeMonitor($0) }
        escapeMonitors = []
    }

    private func stopAndTranscribe() {
        if appState.phase == .preparing {
            cancelPreparing()
            return
        }
        guard appState.phase == .recording else { return }
        removeEscapeMonitor()
        recordingStartedAt = nil
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
        let safetyItem: PendingItem?
        if pcm.count >= safetySaveMinPCMBytes {
            safetyItem = pending.add(wav: WAV.fromPCM(pcm), reason: "Transcribing — safety copy")
            appState.pendingCount = pending.count
            refreshMenu()
            Log.log("transcribe: safety-saved local WAV before transcription (pending=\(pending.count), bytes=\(pcm.count))")
        } else {
            safetyItem = nil
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runTranscription(stream: streamRef, pcm: pcm, t0: t0)
            switch result {
            case .success(let text):
                await MainActor.run {
                    if let safetyItem {
                        self.pending.remove(safetyItem)
                        self.appState.pendingCount = self.pending.count
                        self.refreshMenu()
                        Log.log("transcribe: removed safety copy after success (pending=\(self.pending.count))")
                    }
                }
                await self.deliver(text)
            case .failure(let werr):
                await MainActor.run {
                    if let safetyItem {
                        if werr.shouldBuffer {
                            self.pending.update(safetyItem, reason: werr.userMessage)
                            self.appState.pendingCount = self.pending.count
                            self.refreshMenu()
                            Log.log("transcribe: kept safety copy for retry (pending=\(self.pending.count)) — \(werr.userMessage)")
                        } else if werr.isNoSpeech {
                            let discarded = self.pending.discardNoSpeech(safetyItem)
                            self.appState.pendingCount = self.pending.count
                            self.refreshMenu()
                            Log.log("transcribe: preserved no-speech safety copy outside retry (pending=\(self.pending.count)) — \(discarded?.path ?? "discard failed")")
                        } else {
                            self.pending.remove(safetyItem)
                            self.appState.pendingCount = self.pending.count
                            self.refreshMenu()
                            Log.log("transcribe: removed safety copy after terminal failure (pending=\(self.pending.count)) — \(werr.userMessage)")
                        }
                    } else if werr.shouldBuffer {
                        self.pending.add(wav: WAV.fromPCM(pcm), reason: werr.userMessage)
                        self.appState.pendingCount = self.pending.count
                        self.refreshMenu()
                        Log.log("buffered take for retry (pending=\(self.pending.count)) — \(werr.userMessage)")
                    } else if werr.isNoSpeech, pcm.count >= 16_000 {
                        let item = self.pending.add(wav: WAV.fromPCM(pcm), reason: werr.userMessage)
                        let discarded = self.pending.discardNoSpeech(item)
                        self.appState.pendingCount = self.pending.count
                        self.refreshMenu()
                        Log.log("transcribe: preserved short no-speech take outside retry (pending=\(self.pending.count)) — \(discarded?.path ?? "discard failed")")
                    }
                    self.appState.phase = .error(werr.userMessage)
                    self.scheduleIdle(after: 3)
                }
            }
        }
    }

    /// Stream first; on a *transport* failure fall back to batch. Semantic server errors are
    /// classified (busy/backend/etc.) so the caller can buffer or surface appropriately.
    private func runTranscription(stream: StreamingClient?, pcm: Data, t0: Date) async -> Result<String, WisprError> {
        if let stream {
            do {
                let text = try await stream.finish()
                Log.log("stream: final in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
                if !text.isEmpty { return .success(text) }
                Log.log("stream: empty final — falling back to batch")
            } catch let e as StreamingClient.StreamError where e.isSemantic {
                if case .server(let code, _) = e, code == "bad_request" || code == "max_duration" {
                    Log.log("stream: server error \(e.displayMessage) — falling back to batch")
                } else {
                    Log.log("stream: server error \(e.displayMessage) — not retrying via batch")
                    return .failure(WisprError.from(e))
                }
            } catch {
                Log.log("stream: transport failure — falling back to batch")
            }
        }
        guard !pcm.isEmpty else { return .failure(.noSpeech) }
        do {
            let text = try await client.transcribe(wav: WAV.fromPCM(pcm))
            Log.log("batch: OK in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
            if !text.isEmpty { return .success(text) }
            if pcmHasAudibleSignal(pcm) {
                Log.log("batch: empty transcript despite audible local audio — keeping for retry")
                return .failure(.transcriptionFailed)
            }
            return .failure(.noSpeech)
        } catch {
            return .failure(WisprError.from(error))
        }
    }

    private func pcmHasAudibleSignal(_ pcm: Data) -> Bool {
        let sampleCount = pcm.count / 2
        guard sampleCount > 0 else { return false }

        let windowSamples = max(1, AudioStreamCapture.sampleRate / 2)
        let activeRMS = 120.0
        var totalSquares = 0.0
        var windowSquares = 0.0
        var windowCount = 0
        var activeWindows = 0
        var maxAbs = 0

        func finishWindow() {
            guard windowCount > 0 else { return }
            let rms = sqrt(windowSquares / Double(windowCount))
            if rms >= activeRMS { activeWindows += 1 }
            windowSquares = 0
            windowCount = 0
        }

        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 1 < bytes.count {
                let sample = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                let value = Int(sample)
                let magnitude = value == Int(Int16.min) ? 32768 : Swift.abs(value)
                maxAbs = max(maxAbs, magnitude)
                let square = Double(value * value)
                totalSquares += square
                windowSquares += square
                windowCount += 1
                if windowCount >= windowSamples { finishWindow() }
                i += 2
            }
        }
        finishWindow()

        let totalRMS = sqrt(totalSquares / Double(sampleCount))
        return (activeWindows >= 2 && maxAbs >= 500) || (totalRMS >= activeRMS && maxAbs >= 700)
    }

    /// Paste, then confirm it landed. The target app/window/field was captured before
    /// recording; if it changed, leave the transcript on the clipboard for manual paste.
    @MainActor
    private func deliver(_ text: String) async {
        history.add(text)
        appState.lastTranscript = text
        refreshMenu()

        let targetSummary = FocusedField.targetSummary(pasteTarget)
        Log.log("deliver: target before refocus — \(targetSummary)")
        FocusedField.refocus(pasteTarget)
        var targetAppReady = FocusedField.frontmostMatches(pasteTarget)
        for _ in 0..<10 where !targetAppReady {
            try? await Task.sleep(nanoseconds: 100_000_000)
            targetAppReady = FocusedField.frontmostMatches(pasteTarget)
        }

        guard targetAppReady else {
            TextInserter.copy(text)
            appState.phase = .copied
            Log.log("deliver: target app changed — copied transcript for manual paste; target=\(targetSummary); current=\(FocusedField.currentSummary())")
            pasteTarget = nil
            scheduleIdle(after: 8)
            return
        }

        if !FocusedField.matchesCurrent(pasteTarget) {
            Log.log("deliver: target field/window changed inside same app; attempting insert anyway; target=\(targetSummary); current=\(FocusedField.currentSummary())")
        }

        // If no AX element is exposed (Electron/web apps like VS Code keep a11y lazy), force the
        // target app's accessibility tree on (AXManualAccessibility, like Wispr Flow) and re-query.
        // Then `el != nil` ⇒ a real field (verify it); `el == nil` ⇒ genuinely no field ⇒ keep the
        // ⌘V hint instead of falsely claiming insertion.
        var el = FocusedField.focusedElement()
        if el == nil, let pid = pasteTarget?.appPID, pid > 0 {
            FocusedField.enableElectronAccessibility(pid: pid)
            try? await Task.sleep(nanoseconds: 200_000_000)
            el = FocusedField.focusedElement()
        }
        // Always insert via ⌘V — reliable in native *and* Electron fields. (Direct AX "set value"
        // no-ops in Chromium but reports success, which is what left VS Code with nothing inserted.)
        // Then derive the message from verification: a readable editable field that took the text
        // ⇒ "inserted"; otherwise (no field, or unverifiable) keep it on the clipboard with the hint.
        let before = FocusedField.valueLength(el)
        let snapshot = PasteboardSnapshot.capture()
        TextInserter.copy(text)
        TextInserter.pasteKeystroke()
        try? await Task.sleep(nanoseconds: 220_000_000)
        let confirmed = el != nil && FocusedField.confirmInserted(el, expected: text, before: before)

        pasteTarget = nil
        if confirmed {
            snapshot.restore(ifPasteboardStillContains: text)
            appState.phase = .inserted
            Log.log("deliver: paste CONFIRMED (\(text.count) chars)")
            scheduleIdle(after: 0.4) // confirmed → return to interactive immediately (re-record fast)
        } else {
            appState.phase = .copied      // no field / unverifiable — transcript stays on clipboard
            Log.log("deliver: paste sent, not verified — kept on clipboard (⌘V hint); current=\(FocusedField.currentSummary())")
            scheduleIdle(after: 8)
        }
    }

    private func retryPending(auto: Bool) {
        guard !retrying, !appState.isBusy, appState.pendingCount > 0 else { return }
        retrying = true
        let restorePhase = appState.phase
        appState.phase = .transcribing
        let mode = auto ? "auto" : "manual"
        Log.log("retry: \(mode) draining \(appState.pendingCount) pending")
        Task { [weak self] in
            guard let self else { return }
            let recovered = Counter() // reference box (avoids capturing a mutated `var` concurrently)
            while let item = await MainActor.run(body: { self.pending.oldest() }) {
                guard let wav = await MainActor.run(body: { self.pending.wav(for: item) }) else {
                    await MainActor.run { self.pending.remove(item); self.appState.pendingCount = self.pending.count }
                    continue
                }
                do {
                    let text = try await self.client.transcribe(wav: wav)
                    if text.isEmpty {
                        Log.log("retry: empty transcript — keeping pending for later")
                        break
                    }
                    await MainActor.run {
                        self.history.add(text)
                        self.appState.lastTranscript = text
                        recovered.n += 1
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
                if recovered.n > 0 {
                    Log.log("retry: recovered \(recovered.n) → History + last transcript")
                    self.appState.phase = .available
                    self.scheduleIdle(after: 4)
                } else if self.appState.phase == .transcribing {
                    self.appState.phase = restorePhase
                }
            }
        }
    }

    private func scheduleIdle(after seconds: TimeInterval) {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.appState.phase != .preparing, self.appState.phase != .recording { self.appState.phase = .idle }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func preflightMessage(for status: ServerStatus) -> String {
        switch status {
        case .unknown: return "Server not ready"
        case .up: return "Server ready"
        case .loading: return "Server warming up"
        case .loggedOut: return "Dictation service logged out"
        case .backendDown: return "Backend down"
        case .serverOffline: return "Server has no internet"
        case .unauthorized: return "Unauthorized"
        case .unreachable: return "Server unreachable"
        }
    }

    // MARK: - Windows

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                onHotKeyChange: { [weak self] in self?.reconfigureHotKey() },
                setHotKeyEnabled: { [weak self] on in self?.hotKey.setEnabled(on) })
            settingsWindow = makeWindow(title: "wispr Settings", content: view)
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
        let snapshot = PasteboardSnapshot.capture()
        TextInserter.copy(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            TextInserter.pasteKeystroke()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                snapshot.restore(ifPasteboardStillContains: text)
            }
        }
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
