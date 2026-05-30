import AppKit
import Carbon.HIToolbox

/// Inserts transcribed text into whatever app is focused.
/// Strategy: stash the text on the pasteboard, synthesize ⌘V. Requires the app to be
/// granted Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility)
/// so it may post key events into other applications.
enum TextInserter {
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
