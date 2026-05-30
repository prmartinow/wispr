import AppKit
import Security

enum ActivationMode: String, CaseIterable, Identifiable {
    case toggle
    case pushToTalk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .toggle: return "Toggle — press to start / stop"
        case .pushToTalk: return "Push-to-talk — hold to record"
        }
    }
}

/// Persisted user settings. Scalars live in UserDefaults; the bearer token lives in the
/// Keychain. Initial values fall back to env vars (WHISPER_SERVER_URL / WHISPER_TOKEN)
/// then to the LAN defaults, so the app works out of the box and is configurable in the UI.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    private enum K {
        static let serverURL = "whisper.serverURL"
        static let activation = "whisper.activation"
        static let keyCode = "whisper.hotkey.keyCode"
        static let modifiers = "whisper.hotkey.modifiers"
        static let inputUID = "whisper.input.uid"
    }

    @Published var serverURLString: String { didSet { d.set(serverURLString, forKey: K.serverURL) } }
    @Published var activation: ActivationMode { didSet { d.set(activation.rawValue, forKey: K.activation) } }
    @Published var hotKeyCode: UInt16 { didSet { d.set(Int(hotKeyCode), forKey: K.keyCode) } }
    @Published var hotKeyModifiers: UInt { didSet { d.set(Int(hotKeyModifiers), forKey: K.modifiers) } }
    @Published var inputDeviceUID: String? { didSet { d.set(inputDeviceUID, forKey: K.inputUID) } }

    init() {
        let env = ProcessInfo.processInfo.environment
        serverURLString = d.string(forKey: K.serverURL)
            ?? env["WHISPER_SERVER_URL"] ?? "http://wispr.local:8090"
        activation = ActivationMode(rawValue: d.string(forKey: K.activation) ?? "") ?? .toggle
        hotKeyCode = UInt16((d.object(forKey: K.keyCode) as? Int) ?? 49) // 49 = Space
        let defaultMods = UInt(NSEvent.ModifierFlags([.command, .option]).rawValue)
        hotKeyModifiers = UInt((d.object(forKey: K.modifiers) as? Int).map(UInt.init) ?? defaultMods)
        inputDeviceUID = d.string(forKey: K.inputUID)

        // Seed the Keychain token from the env on first run if empty.
        if token.isEmpty, let t = env["WHISPER_TOKEN"], !t.isEmpty { token = t }
    }

    var serverURL: URL {
        URL(string: serverURLString) ?? URL(string: "http://wispr.local:8090")!
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: hotKeyModifiers) }

    /// Bearer token, stored in the login Keychain (never in the plist).
    var token: String {
        get { Keychain.get(account: "bearerToken") ?? "" }
        set { Keychain.set(newValue, account: "bearerToken") }
    }
}

enum Keychain {
    private static let service = "co.quandefi.whisper"

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
