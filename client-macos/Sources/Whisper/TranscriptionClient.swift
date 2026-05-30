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
    private let config: Config
    private let session: URLSession

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        // Dictation latency ≈ clip length and requests are serialized server-side,
        // so allow headroom over the ≤30 s prototype clip cap.
        cfg.timeoutIntervalForRequest = 90
        self.session = URLSession(configuration: cfg)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let endpoint = config.serverURL.appendingPathComponent("transcribe")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.bearerToken)", forHTTPHeaderField: "Authorization")

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
