import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon. Default ⌘⌥Space toggles dictation.
/// Carbon's handler is a bare C function pointer (no captured context), so the active
/// instance is held statically — fine for one global hotkey.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private static var active: GlobalHotKey?

    init?(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.onPress = onPress
        GlobalHotKey.active = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, _ in
            GlobalHotKey.active?.onPress()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x57485350), id: 1) // 'WHSP'
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
