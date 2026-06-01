import AppKit
import ApplicationServices

/// Accessibility helpers for paste targeting + verification (Scenario 1, hardened).
/// We don't *gate* pasting on "is this editable" anymore — that produced false negatives
/// (e.g. Electron editors) and silently skipped the paste. Instead we always attempt the
/// paste and then **confirm** it by reading the field's value back.
enum FocusedField {
    struct PasteTarget {
        let appPID: pid_t
        let bundleIdentifier: String?
        let elementPID: pid_t?
        let role: String
        let windowTitle: String?
    }

    static func capture(frontmost app: NSRunningApplication?) -> PasteTarget? {
        let focused = focusedElement()
        return PasteTarget(
            appPID: app?.processIdentifier ?? focused.flatMap { pid(of: $0) } ?? 0,
            bundleIdentifier: app?.bundleIdentifier,
            elementPID: focused.flatMap { pid(of: $0) },
            role: focused.map { role($0) } ?? "",
            windowTitle: focused.flatMap { windowTitle(of: $0) }
        )
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
    }

    static func refocus(_ target: PasteTarget?) {
        guard let target, target.appPID > 0,
              let app = NSRunningApplication(processIdentifier: target.appPID),
              app != NSWorkspace.shared.frontmostApplication else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    static func matchesCurrent(_ target: PasteTarget?) -> Bool {
        guard let target, target.appPID > 0 else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == target.appPID else { return false }
        if let expectedBundle = target.bundleIdentifier,
           front.bundleIdentifier != expectedBundle { return false }
        guard let current = focusedElement() else { return false }
        if let expectedPID = target.elementPID, pid(of: current) != expectedPID { return false }
        if !target.role.isEmpty, role(current) != target.role { return false }
        if let expectedTitle = target.windowTitle,
           let currentTitle = windowTitle(of: current),
           !expectedTitle.isEmpty,
           !currentTitle.isEmpty,
           expectedTitle != currentTitle { return false }
        return true
    }

    static func insertDirect(_ text: String) -> Bool {
        guard let el = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    static func role(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    static func stringValue(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func pid(of el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    static func windowTitle(of el: AXUIElement) -> String? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &window) == .success,
              let w = window, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue((w as! AXUIElement), kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    static func valueLength(_ el: AXUIElement?) -> Int? {
        guard let el else { return nil }
        return stringValue(el)?.count
    }

    /// Did the text land? Confirmed if the value grew by ~the inserted length, or now contains
    /// the tail of what we pasted. If the value can't be read (some web fields), trust a standard
    /// editable role; otherwise treat as NOT pasted so we can warn + keep it on the clipboard.
    static func confirmInserted(_ el: AXUIElement?, expected: String, before: Int?) -> Bool {
        guard let el else { return false }
        if let after = valueLength(el), let b = before, after >= b + max(1, expected.count - 3) {
            return true
        }
        if let v = stringValue(el) {
            let tail = String(expected.suffix(min(16, expected.count)))
            return !tail.isEmpty && v.contains(tail)
        }
        return editableRoles.contains(role(el)) // value unreadable → trust standard editable roles
    }
}
