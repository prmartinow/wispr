import Foundation

/// Talks to the server's `POST /transcribe` per contract/transcribe.md.
struct TranscriptionResult: Decodable {
    let text: String
    let engine: String?
    let duration_ms: Int?
    let audio_duration_ms: Int?
}

struct ServerError: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

final class TranscriptionClient {
    private let settings: Settings
    private var session: URLSession { Net.session } // shared session (handles mTLS on remote)

    init(settings: Settings) {
        self.settings = settings
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await transcribe(wav: try Data(contentsOf: audioURL))
    }

    /// Batch transcription of in-memory WAV bytes (used as the streaming fallback).
    func transcribe(wav audio: Data) async throws -> String {
        guard EndpointPolicy.allowed(settings.activeServerURL) else { throw ClientError.badEndpoint }
        let endpoint = settings.activeServerURL.appendingPathComponent("transcribe")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 780
        req.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

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
        guard EndpointPolicy.allowed(settings.activeServerURL) else { return "bad endpoint" }
        let endpoint = settings.activeServerURL.appendingPathComponent("healthz")
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
        case badEndpoint
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
