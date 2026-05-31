import Foundation
import CryptoKit
import Security

/// Finds the pinned wispr client identity in the login Keychain. Used for mTLS on the remote path.
enum RemoteIdentity {
    struct Match {
        let identity: SecIdentity
        let certificates: [SecCertificate]
    }

    private static let allowedHost = "wispr.p12w.xyz"
    private static let expectedSubject = "mac-pierre"
    private static let expectedIssuer = "whisper-client-ca"
    private static let expectedFingerprint =
        "59EF34DC0F6DB6FD8346ADCC8BC3DAFC8A9C5169C89F694CAB1765EE4209774C"
    private static let expectedCAFingerprint =
        "FBF4A92CC93CA345C9E8ED8CA06ACDF2C6A4B4E2260F67C447B720114EB39FA3"

    static func find(for host: String) -> Match? {
        guard host.caseInsensitiveCompare(allowedHost) == .orderedSame else {
            Log.log("mTLS: refusing client cert for unexpected host \(host)")
            return nil
        }
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
            guard SecIdentityCopyCertificate(id, &certRef) == errSecSuccess, let cert = certRef,
                  let summary = SecCertificateCopySubjectSummary(cert) as String? else { continue }
            guard summary.caseInsensitiveCompare(expectedSubject) == .orderedSame else { continue }
            guard issuerCommonName(cert)?.caseInsensitiveCompare(expectedIssuer) == .orderedSame else { continue }
            guard sha256Fingerprint(cert) == expectedFingerprint else { continue }
            return Match(identity: id, certificates: certificateChain(leaf: cert))
        }
        Log.log("mTLS: no pinned identity found for \(allowedHost) (subject \(expectedSubject))")
        return nil
    }

    private static func sha256Fingerprint(_ cert: SecCertificate) -> String {
        let data = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func issuerCommonName(_ cert: SecCertificate) -> String? {
        let keys = [kSecOIDX509V1IssuerName] as CFArray
        guard let values = SecCertificateCopyValues(cert, keys, nil) as? [String: Any],
              let issuer = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let props = issuer[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        for prop in props {
            let label = prop[kSecPropertyKeyLabel as String] as? String
            if label == "Common Name" || label == "CN" || label == "2.5.4.3" {
                return prop[kSecPropertyKeyValue as String] as? String
            }
        }
        return nil
    }

    private static func certificateChain(leaf: SecCertificate) -> [SecCertificate] {
        guard let ca = findPinnedCA() else { return [leaf] }
        return [leaf, ca]
    }

    private static func findPinnedCA() -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let certs = result as? [SecCertificate] else { return nil }
        return certs.first {
            (SecCertificateCopySubjectSummary($0) as String? ?? "")
                .caseInsensitiveCompare(expectedIssuer) == .orderedSame
                && sha256Fingerprint($0) == expectedCAFingerprint
        }
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
        if let match = RemoteIdentity.find(for: challenge.protectionSpace.host) {
            completionHandler(.useCredential,
                              URLCredential(identity: match.identity,
                                            certificates: match.certificates,
                                            persistence: .forSession))
        } else {
            Log.log("mTLS: remote asked for a client cert but the pinned identity is unavailable")
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
