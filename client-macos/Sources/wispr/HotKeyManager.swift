import AppKit
import Carbon.HIToolbox

// Carbon's hotkey handler is a bare C function pointer (no captured context); route to the
// live instance statically. One global hotkey, so this is fine.
private let wisprHotKeyHandler: EventHandlerUPP = { (_, eventRef, _) -> OSStatus in
    guard let eventRef else { return noErr }
    let kind = GetEventKind(eventRef)
    DispatchQueue.main.async { HotKeyManager.shared?.handle(kind: kind) }
    return noErr
}

/// Global hotkey via Carbon `RegisterEventHotKey` — the same mechanism superwispr and
/// Electron's globalShortcut use. Crucially it needs **no Accessibility and no Input
/// Monitoring** (unlike a CGEventTap), works across every app/surface, and consumes the
/// combo so it won't clash with the focused app. We register for both Pressed and Released
/// so push-to-talk (hold) works without an event tap.
///   - toggle:     Pressed → onToggle()
///   - pushToTalk: Pressed → onStart(); Released → onStop()
final class HotKeyManager {
    static weak var shared: HotKeyManager?

    var onToggle: () -> Void = {}
    var onStart: () -> Void = {}
    var onStop: () -> Void = {}

    private var keyCode: UInt32
    private var carbonModifiers: UInt32
    private var mode: ActivationMode
    private var enabled = true
    private var pttActive = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = Self.carbon(modifiers)
        self.mode = mode
    }

    func start() {
        HotKeyManager.shared = self
        installHandler()
        register()
        Log.log("HotKey: started mode=\(mode.rawValue) AXTrusted=\(AXIsProcessTrusted()) (hotkey itself needs no TCC)")
    }

    func stop() {
        unregister()
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: ActivationMode) {
        self.keyCode = UInt32(keyCode)
        self.carbonModifiers = Self.carbon(modifiers)
        self.mode = mode
        pttActive = false
        unregister()
        if enabled { register() }
        Log.log("HotKey: reconfigured keyCode=\(keyCode) carbonMods=\(carbonModifiers) mode=\(mode.rawValue)")
    }

    /// Pause/resume — used while the Settings recorder captures a new combo (so the live
    /// hotkey neither fires nor swallows the keystroke being recorded).
    func setEnabled(_ on: Bool) {
        enabled = on
        pttActive = false
        on ? register() : unregister()
    }

    // MARK: - Carbon plumbing

    private func installHandler() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), wisprHotKeyHandler, 2, &specs, nil, &handlerRef)
        if status != noErr { Log.log("HotKey: InstallEventHandler FAILED status=\(status)") }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x57485350) /* 'WHSP' */, id: 1)
        let status = RegisterEventHotKey(keyCode, carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.log("HotKey: RegisterEventHotKey(keyCode=\(keyCode) mods=\(carbonModifiers)) status=\(status) (0=ok)")
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    func handle(kind: UInt32) {
        guard enabled else { return }
        switch Int(kind) {
        case kEventHotKeyPressed:
            Log.log("HotKey: PRESSED (mode=\(mode.rawValue))")
            switch mode {
            case .toggle: onToggle()
            case .pushToTalk: if !pttActive { pttActive = true; onStart() }
            }
        case kEventHotKeyReleased:
            if mode == .pushToTalk, pttActive {
                pttActive = false
                Log.log("HotKey: RELEASED → stop")
                onStop()
            }
        default:
            break
        }
    }

    private static func carbon(_ m: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if m.contains(.command) { c |= UInt32(cmdKey) }
        if m.contains(.option) { c |= UInt32(optionKey) }
        if m.contains(.control) { c |= UInt32(controlKey) }
        if m.contains(.shift) { c |= UInt32(shiftKey) }
        return c
    }
}
