import Foundation
import Security

/// Finds the whisper client identity in the login Keychain (imported once via
/// `security import mac-client.p12 -A -P <passphrase>`). Used for mTLS on the remote path.
enum RemoteIdentity {
    static func find() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        for id in identities {
            var certRef: SecCertificate?
            if SecIdentityCopyCertificate(id, &certRef) == errSecSuccess, let cert = certRef,
               let summary = SecCertificateCopySubjectSummary(cert) as String?,
               summary.lowercased().contains("whisper") {
                return id
            }
        }
        return identities.first
    }
}

/// URLSession delegate that presents the client certificate when the remote (Caddy mTLS)
/// asks for one. LAN never challenges, so this is a no-op there.
final class MTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let identity = RemoteIdentity.find() {
            completionHandler(.useCredential,
                              URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        } else {
            Log.log("mTLS: remote asked for a client cert but none is imported")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// One shared session for the whole app (handles mTLS on the remote path; LAN unaffected).
enum Net {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300 // long: dictation latency ≈ clip length
        return URLSession(configuration: cfg, delegate: MTLSDelegate(), delegateQueue: nil)
    }()
}
