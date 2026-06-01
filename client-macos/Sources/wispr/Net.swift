import Foundation
import CryptoKit
import Security

/// Finds the pinned wispr client identity in the login Keychain and pins the LAN server CA.
enum RemoteIdentity {
    struct Match {
        let identity: SecIdentity
        let certificates: [SecCertificate]
    }

    private static let allowedClientCertHosts: Set<String> = ["wispr.p12w.xyz", "wispr.local"]
    private static let lanHost = "wispr.local"
    private static let expectedSubject = "mac-pierre"
    private static let expectedIssuer = "whisper-client-ca"
    private static let expectedFingerprint =
        "E3867388B0B29016EF27FB4C5F5818CF1079CF258A9403481E24C4398EB89F6D"
    private static let expectedCAFingerprint =
        "075891D212B0B06743329DE1E7D76E95193C9B0BDA3E05673C7CA4CF30B8AD95"
    private static let expectedLANServerFingerprint =
        "D67D706DCD0C765E1C50D16F77886DF35104A7A306C90F9FD99A87DE7788C81C"

    static func find(for host: String) -> Match? {
        guard allowedClientCertHosts.contains(host.lowercased()) else {
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
        Log.log("mTLS: no pinned identity found for \(host) (subject \(expectedSubject))")
        return nil
    }

    static func serverTrustCredential(for host: String, trust: SecTrust) -> URLCredential? {
        guard host.caseInsensitiveCompare(lanHost) == .orderedSame else { return nil }
        guard !expectedLANServerFingerprint.isEmpty else {
            Log.log("mTLS: refusing LAN trust because server fingerprint is not configured")
            return nil
        }
        guard let ca = findPinnedCA() else {
            Log.log("mTLS: refusing LAN trust because pinned CA is unavailable")
            return nil
        }

        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            Log.log("mTLS: LAN server trust failed \(error.map { String(describing: $0) } ?? "unknown")")
            return nil
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              sha256Fingerprint(leaf) == expectedLANServerFingerprint else {
            Log.log("mTLS: LAN server fingerprint mismatch")
            return nil
        }
        return URLCredential(trust: trust)
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

/// URLSession delegate that presents the pinned client certificate on both LAN and remote mTLS.
final class MTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let credential = RemoteIdentity.serverTrustCredential(for: challenge.protectionSpace.host, trust: trust) {
            completionHandler(.useCredential, credential)
            return
        }

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

/// One shared session for the whole app (handles mTLS on LAN and remote).
enum Net {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 780 // long: 10-minute batch fallback + backend margin
        cfg.timeoutIntervalForResource = 900
        return URLSession(configuration: cfg, delegate: MTLSDelegate(), delegateQueue: nil)
    }()
}
