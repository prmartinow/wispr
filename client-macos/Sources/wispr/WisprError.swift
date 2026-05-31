import Foundation

/// Every pipeline failure, classified into something the UI can act on:
/// a user message, whether to **buffer** the take for retry, and whether it's the user's to fix.
enum WisprError: Error {
    case unreachable          // can't reach the server (process down / network)
    case unauthorized         // 401 — token wrong/rotated
    case busy                 // server busy (one composer at a time)
    case backendUnavailable   // Chromium/dictation service down (503 / browser:down)
    case transcriptionFailed  // backend errored or returned nothing (possibly UI/HTML drift)
    case timeout
    case noSpeech
    case mic(String)
    case other(String)

    var userMessage: String {
        switch self {
        case .unreachable:        return "Server offline — saved, will retry"
        case .unauthorized:       return "Unauthorized — set token in Settings"
        case .busy:               return "Server busy — try again"
        case .backendUnavailable: return "Backend down — saved, will retry"
        case .transcriptionFailed:return "Transcription failed — saved, will retry"
        case .timeout:            return "Timed out — saved, will retry"
        case .noSpeech:           return "No speech detected"
        case .mic(let m):         return m
        case .other(let m):       return m
        }
    }

    /// Save the recording to the retry queue (transient backend/transport issues).
    var shouldBuffer: Bool {
        switch self {
        case .unreachable, .backendUnavailable, .transcriptionFailed, .timeout: return true
        default: return false
        }
    }

    static func from(_ error: Error) -> WisprError {
        if let w = error as? WisprError { return w }

        if let s = error as? StreamingClient.StreamError {
            switch s {
            case .server(let code, _): return fromCode(code)
            case .badURL:              return .other("Bad server URL")
            case .transport, .noFinal: return .unreachable
            }
        }
        if let c = error as? TranscriptionClient.ClientError {
            switch c {
            case .server(let code, _): return fromCode(code)
            case .http(let status):
                if status == 401 { return .unauthorized }
                if status == 503 { return .backendUnavailable }
                if status == 504 { return .timeout }
                return .transcriptionFailed
            case .badResponse: return .transcriptionFailed
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            case .userAuthenticationRequired: return .unauthorized
            default: return .unreachable
            }
        }
        return .other("Failed: \(error.localizedDescription)")
    }

    private static func fromCode(_ code: String) -> WisprError {
        switch code {
        case "unauthorized":        return .unauthorized
        case "busy":                return .busy
        case "backend_unavailable": return .backendUnavailable
        case "transcription_timeout": return .timeout
        default:                    return .transcriptionFailed
        }
    }
}
