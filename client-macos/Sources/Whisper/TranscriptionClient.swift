import Foundation

/// Talks to the server's `POST /transcribe` per contract/transcribe.md.
struct TranscriptionResult: Decodable {
    let text: String
    let engine: String?
    let duration_ms: Int?
}

struct ServerError: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

final class TranscriptionClient {
    private let settings: Settings
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        let cfg = URLSessionConfiguration.default
        // The server holds the connection with no data until dictation finishes, and
        // dictation plays the clip in real time (latency ≈ clip length + ~5–20 s). So this
        // is effectively a total cap: keep it well above any sane clip so the client never
        // abandons a request mid-flight (an abandoned request leaves the server's single
        // composer/mic busy and breaks the *next* dictation too).
        cfg.timeoutIntervalForRequest = 300
        self.session = URLSession(configuration: cfg)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let endpoint = settings.serverURL.appendingPathComponent("transcribe")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audio = try Data(contentsOf: audioURL)
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        body.appendString("\r\n")
        body.appendString("--\(boundary)--\r\n")

        let (data, resp) = try await session.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else { throw ClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw ClientError.server(code: err.error.code, message: err.error.message)
            }
            throw ClientError.http(status: http.statusCode)
        }
        return try JSONDecoder().decode(TranscriptionResult.self, from: data).text
    }

    /// Lightweight reachability/auth probe for the Settings "Test" button.
    func health() async -> String {
        let endpoint = settings.serverURL.appendingPathComponent("healthz")
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 6
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            return code == 200 ? "OK — \(body)" : "HTTP \(code)"
        } catch {
            return "unreachable: \(error.localizedDescription)"
        }
    }

    enum ClientError: Error {
        case badResponse
        case http(status: Int)
        case server(code: String, message: String)
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
