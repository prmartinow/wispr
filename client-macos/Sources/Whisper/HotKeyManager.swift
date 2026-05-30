import AppKit
import CoreGraphics

/// Global hotkey via a CGEventTap (not NSEvent monitors, which are best-effort and miss
/// events in some apps / on the desktop). The tap reliably sees every key event across all
/// surfaces, gives key-up (needed for push-to-talk), and lets us **consume** the matched
/// combo so it never reaches the focused app — avoiding shortcut conflicts.
/// Requires Accessibility permission (already needed for paste).
///   - toggle:     keyDown on the combo → onToggle(); event consumed
///   - pushToTalk: keyDown on the combo → onStart(); keyUp of the key → onStop(); consumed
final class HotKeyManager {
    var onToggle: () -> Void = {}
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    private var keyCode: Int64
    private var requiredFlags: CGEventFlags
    private var mode: ActivationMode
    private var enabled = true
    private var pttActive = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = Int64(keyCode)
        self.requiredFlags = Self.cgFlags(from: modifiers)
        self.mode = mode
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            NSLog("Whisper: failed to create event tap (grant Accessibility, then relaunch)")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; runLoopSource = nil; pttActive = false
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = Int64(keyCode)
        self.requiredFlags = Self.cgFlags(from: modifiers)
        self.mode = mode
        pttActive = false
    }

    /// Pause/resume — used while the Settings shortcut recorder captures a new combo.
    func setEnabled(_ on: Bool) { enabled = on; if !on { pttActive = false } }

    // MARK: - Tap callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap on timeout/user-input races; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard comboMatches(code: code, flags: event.flags) else { return pass }
            if isRepeat { return nil } // swallow auto-repeat of our combo
            switch mode {
            case .toggle:
                DispatchQueue.main.async { self.onToggle() }
            case .pushToTalk:
                if !pttActive { pttActive = true; DispatchQueue.main.async { self.onStart() } }
            }
            return nil // consume

        case .keyUp:
            // Modifiers may already be up on key-up, so match the key alone.
            if mode == .pushToTalk, pttActive, code == keyCode {
                pttActive = false
                DispatchQueue.main.async { self.onStop() }
                return nil
            }
            // Consume the combo's key-up too, to avoid a dangling key-up in the focused app.
            if comboMatches(code: code, flags: event.flags) { return nil }
            return pass

        default:
            return pass
        }
    }

    private func comboMatches(code: Int64, flags: CGEventFlags) -> Bool {
        guard code == keyCode else { return false }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(relevant) == requiredFlags.intersection(relevant)
    }

    private static func cgFlags(from m: NSEvent.ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.shift) { f.insert(.maskShift) }
        return f
    }
}
