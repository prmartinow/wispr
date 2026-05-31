import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Inserts transcribed text into whatever app is focused.
/// Strategy: stash the text on the pasteboard, synthesize ⌘V. Requires the app to be
/// granted Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility)
/// so it may post key events into other applications. (The hotkey does NOT need this — only
/// the paste does — so a stale Accessibility grant shows up as "transcript in History but no
/// paste", which the log makes obvious.)
enum TextInserter {
    /// Put text on the clipboard without pasting (used when no editable field is focused).
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Synthesize ⌘V into whatever is focused (clipboard must already hold the text).
    static func pasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func insert(_ text: String) {
        Log.log("paste: \(text.count) chars, AXTrusted=\(AXIsProcessTrusted())")
        copy(text)
        pasteKeystroke()
    }
}
