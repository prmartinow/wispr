import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    /// Re-applies hotkey/activation to the live HotKeyManager when changed.
    var onHotKeyChange: () -> Void
    /// Pause/resume the global hotkey while capturing a new shortcut (so it doesn't fire).
    var setHotKeyEnabled: (Bool) -> Void

    @State private var token: String = ""
    @State private var devices: [AudioInputDevice] = []
    @State private var testResult: String = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $settings.serverURLString)
                    .textFieldStyle(.roundedBorder)
                SecureField("Bearer token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: token) { settings.token = $0 }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(testing)
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("OK") ? .green : .secondary)
                        .lineLimit(1)
                }
            }

            Section("Dictation") {
                Picker("Activation", selection: $settings.activation) {
                    ForEach(ActivationMode.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.activation) { _ in onHotKeyChange() }

                HStack {
                    Text("Shortcut")
                    Spacer()
                    ShortcutRecorder(
                        keyCode: $settings.hotKeyCode,
                        modifiersRaw: $settings.hotKeyModifiers,
                        onChange: onHotKeyChange,
                        setHotKeyEnabled: setHotKeyEnabled)
                }
                Text("Tip: include ⌘/⌥/⌃ so the shortcut doesn't clash with normal typing.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Microphone", selection: micBinding) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { d in Text(d.name).tag(Optional(d.uid)) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .onAppear {
            token = settings.token
            devices = AudioDevices.inputs()
        }
    }

    private var micBinding: Binding<String?> {
        Binding(
            get: { settings.inputDeviceUID },
            set: { uid in
                settings.inputDeviceUID = uid
                if let uid { AudioDevices.setDefaultInput(uid: uid) }
            })
    }

    private func test() {
        testing = true
        testResult = ""
        let client = TranscriptionClient(settings: settings)
        Task {
            let r = await client.health()
            await MainActor.run { testResult = r; testing = false }
        }
    }
}

/// Click to capture the next key combo (used as the global dictation shortcut).
struct ShortcutRecorder: View {
    @Binding var keyCode: UInt16
    @Binding var modifiersRaw: UInt
    var onChange: () -> Void
    var setHotKeyEnabled: (Bool) -> Void

    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(capturing ? "Press shortcut…" : KeyName.describe(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiersRaw))) {
            capturing ? stop() : startCapture()
        }
        .frame(minWidth: 150)
    }

    private func startCapture() {
        capturing = true
        setHotKeyEnabled(false) // don't let the live hotkey fire while we capture
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            // Ignore lone modifier key presses (cmd/opt/ctrl/shift).
            if [54, 55, 56, 58, 59, 60, 61, 62].contains(Int(e.keyCode)) { return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require ≥1 modifier — a modifier-less global hotkey would be swallowed everywhere.
            guard !mods.isEmpty else { return nil }
            keyCode = e.keyCode
            modifiersRaw = mods.rawValue
            onChange()
            stop()
            return nil
        }
    }

    private func stop() {
        capturing = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        setHotKeyEnabled(true)
    }
}

enum KeyName {
    static func describe(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + key(keyCode)
    }

    private static func key(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
            34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
            12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
            16: "Y", 6: "Z",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        ]
        return map[code] ?? "key\(code)"
    }
}
