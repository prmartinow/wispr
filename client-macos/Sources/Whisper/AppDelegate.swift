import AppKit
import AVFoundation
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let config = Config.load()
    private let recorder = AudioRecorder()
    private var client: TranscriptionClient!
    private var hotKey: GlobalHotKey?
    private var isRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        client = TranscriptionClient(config: config)
        setupStatusItem()
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { NSLog("Whisper: microphone access denied") }
        }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_Space),
                              modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggle()
        }
        if hotKey == nil { NSLog("Whisper: failed to register global hotkey") }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Start / Stop Dictation  (⌘⌥Space)",
                     action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        let server = NSMenuItem(title: "Server: \(config.serverURL.absoluteString)",
                                action: nil, keyEquivalent: "")
        server.isEnabled = false
        menu.addItem(server)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Whisper",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateIcon() {
        statusItem.button?.title = isRecording ? "🔴" : "🎙️"
    }

    @objc private func toggleFromMenu() { toggle() }

    // MARK: - Dictation flow

    private func toggle() {
        isRecording ? stopAndTranscribe() : startRecording()
    }

    private func startRecording() {
        do {
            try recorder.start()
            isRecording = true
            updateIcon()
        } catch {
            NSLog("Whisper: record start failed: \(error)")
        }
    }

    private func stopAndTranscribe() {
        let url = recorder.stop()
        isRecording = false
        updateIcon()
        guard let url else { return }
        Task {
            do {
                let text = try await client.transcribe(audioURL: url)
                await MainActor.run { TextInserter.insert(text) }
            } catch {
                NSLog("Whisper: transcribe failed: \(error)")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
