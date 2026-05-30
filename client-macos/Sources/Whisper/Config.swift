import Foundation

/// Runtime configuration, read from the environment so secrets stay out of the binary.
///   WHISPER_SERVER_URL  base URL of the home server (default: the RPC node on the LAN)
///   WHISPER_TOKEN       bearer token shared with the server (server/.env on the server)
struct Config {
    static let defaultServerURL = "http://wispr.local:8080"

    let serverURL: URL
    let bearerToken: String

    static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let urlString = env["WHISPER_SERVER_URL"] ?? defaultServerURL
        let url = URL(string: urlString) ?? URL(string: defaultServerURL)!
        return Config(serverURL: url, bearerToken: env["WHISPER_TOKEN"] ?? "")
    }
}
