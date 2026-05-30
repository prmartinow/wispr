import AppKit

/// Global hotkey supporting both activation modes. Uses NSEvent monitors (not Carbon)
/// because push-to-talk needs key-up, which RegisterEventHotKey doesn't deliver.
/// Requires Accessibility permission (already needed for paste).
///   - toggle:     keyDown on the combo → onToggle()
///   - pushToTalk: keyDown on the combo → onStart(); keyUp of the key → onStop()
final class HotKeyManager {
    var onToggle: () -> Void = {}
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
    private var mode: ActivationMode

    private var globalMon: Any?
    private var localMon: Any?
    private var pttActive = false

    private let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mode = mode
    }

    func start() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        globalMon = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.handle(e) }
        localMon = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            self?.handle(e); return e
        }
    }

    func stop() {
        [globalMon, localMon].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        globalMon = nil; localMon = nil; pttActive = false
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mode = mode
        pttActive = false
    }

    private func comboMatches(_ e: NSEvent) -> Bool {
        e.keyCode == keyCode
            && e.modifierFlags.intersection(relevant) == modifiers.intersection(relevant)
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            guard !e.isARepeat else { return }
            switch mode {
            case .toggle:
                if comboMatches(e) { onToggle() }
            case .pushToTalk:
                if comboMatches(e) && !pttActive { pttActive = true; onStart() }
            }
        case .keyUp:
            // Modifiers may already be released on key-up, so match the key alone.
            if mode == .pushToTalk, pttActive, e.keyCode == keyCode {
                pttActive = false; onStop()
            }
        default:
            break
        }
    }
}
