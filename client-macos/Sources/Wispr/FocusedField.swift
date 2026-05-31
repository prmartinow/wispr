import ApplicationServices

/// Accessibility helpers for paste targeting + verification (Scenario 1, hardened).
/// We don't *gate* pasting on "is this editable" anymore — that produced false negatives
/// (e.g. Electron editors) and silently skipped the paste. Instead we always attempt the
/// paste and then **confirm** it by reading the field's value back.
enum FocusedField {
    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        return (f as! AXUIElement)
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
