import AppKit

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

enum EndpointPolicy {
    static let lanURLString = "https://wispr.local:8443"
    static let remoteURLString = "https://wispr.p12w.xyz"

    private static let legacyLANURLStrings: Set<String> = [
        "http://wispr.local:8090",
        "http://wispr.local:8090",
    ]

    static func migrateLAN(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacyLANURLStrings.contains(s) ? lanURLString : s
    }

    static func allowed(_ url: URL) -> Bool {
        allowedLAN(url) || allowedRemote(url)
    }

    static func allowedLAN(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "wispr.local"
            && (url.port ?? 443) == 8443
    }

    static func allowedRemote(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "wispr.p12w.xyz"
            && (url.port ?? 443) == 443
    }
}

/// Persisted user settings. Scalars live in UserDefaults; the bearer token lives in a
/// private 0600 app-support file so macOS Keychain ACL prompts cannot freeze the menu app
/// before launch. Initial values fall back to env vars (WISPR_SERVER_URL / WISPR_TOKEN)
/// then to the LAN defaults, so the app works out of the box and is configurable in the UI.
final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    private enum K {
        static let serverURL = "wispr.serverURL"
        static let activation = "wispr.activation"
        static let keyCode = "wispr.hotkey.keyCode"
        static let modifiers = "wispr.hotkey.modifiers"
        static let inputUID = "wispr.input.uid"
        static let remoteURL = "wispr.remoteURL"
    }

    @Published var serverURLString: String { didSet { d.set(serverURLString, forKey: K.serverURL) } }
    @Published var remoteURLString: String { didSet { d.set(remoteURLString, forKey: K.remoteURL) } }
    @Published var activation: ActivationMode { didSet { d.set(activation.rawValue, forKey: K.activation) } }
    @Published var hotKeyCode: UInt16 { didSet { d.set(Int(hotKeyCode), forKey: K.keyCode) } }
    @Published var hotKeyModifiers: UInt { didSet { d.set(Int(hotKeyModifiers), forKey: K.modifiers) } }
    @Published var inputDeviceUID: String? { didSet { d.set(inputDeviceUID, forKey: K.inputUID) } }

    /// The endpoint currently in use, chosen by EndpointSelector (LAN preferred, remote fallback).
    /// Not persisted — re-derived at launch.
    @Published var activeServerURL: URL

    init() {
        let env = ProcessInfo.processInfo.environment
        let initialServer = EndpointPolicy.migrateLAN(d.string(forKey: K.serverURL)
            ?? env["WISPR_SERVER_URL"] ?? EndpointPolicy.lanURLString)
        if d.string(forKey: K.serverURL) != initialServer {
            d.set(initialServer, forKey: K.serverURL)
        }
        serverURLString = initialServer
        remoteURLString = d.string(forKey: K.remoteURL) ?? env["WISPR_REMOTE_URL"] ?? EndpointPolicy.remoteURLString
        let parsedInitial = URL(string: initialServer)
        let initialURL = parsedInitial.flatMap { EndpointPolicy.allowedLAN($0) ? $0 : nil }
            ?? URL(string: EndpointPolicy.lanURLString)!
        activeServerURL = initialURL
        activation = ActivationMode(rawValue: d.string(forKey: K.activation) ?? "") ?? .toggle
        // Default ⌘⇧1: ⌘⌥Space collides with Finder's "Search This Mac"; ⌘⇧1/2 are unbound
        // (screenshot shortcuts are ⌘⇧3/4/5). keyCode 18 = "1".
        hotKeyCode = UInt16((d.object(forKey: K.keyCode) as? Int) ?? 18)
        let defaultMods = UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue)
        hotKeyModifiers = UInt((d.object(forKey: K.modifiers) as? Int).map(UInt.init) ?? defaultMods)
        inputDeviceUID = d.string(forKey: K.inputUID)

        // Seed/refresh the private token file from the env before any network checks.
        if let t = env["WISPR_TOKEN"], !t.isEmpty { token = t }
    }

    var serverURL: URL {
        let migrated = EndpointPolicy.migrateLAN(serverURLString)
        if let url = URL(string: migrated), EndpointPolicy.allowedLAN(url) { return url }
        return URL(string: EndpointPolicy.lanURLString)!
    }

    /// Optional off-LAN endpoint (e.g. https://wispr.p12w.xyz), reached over mTLS.
    var remoteURL: URL? {
        let s = remoteURLString.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let url = URL(string: s), EndpointPolicy.allowedRemote(url) else { return nil }
        return url
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: hotKeyModifiers) }

    /// Bearer token, stored in a private app-support file (never in the plist).
    var token: String {
        get { PrivateTokenStore.get() ?? "" }
        set { PrivateTokenStore.set(newValue) }
    }
}

enum PrivateTokenStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wispr", isDirectory: true)
            .appendingPathComponent("token")
    }

    static func get() -> String? {
        PrivateFiles.lockDownIfPresent(url)
        guard let data = try? Data(contentsOf: url),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    static func set(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? PrivateFiles.write(Data(trimmed.utf8), to: url)
    }
}
