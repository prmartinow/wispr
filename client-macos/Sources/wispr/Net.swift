import Foundation
import CryptoKit
import Security

/// Loads the pinned wispr client identity from private app-support files and pins the LAN CA.
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
    private static let identityLock = NSLock()
    private static var cachedIdentity: Match?
    private static let caLock = NSLock()
    private static var cachedCA: SecCertificate?

    static func find(for host: String) -> Match? {
        guard allowedClientCertHosts.contains(host.lowercased()) else {
            Log.log("mTLS: refusing client cert for unexpected host \(host)")
            return nil
        }
        identityLock.lock()
        defer { identityLock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        cachedIdentity = loadPrivateIdentity(for: host)
        return cachedIdentity
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
        caLock.lock()
        defer { caLock.unlock() }
        if let cachedCA { return cachedCA }
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.caURL)
        guard let data = try? Data(contentsOf: PrivateMTLSStore.caURL),
              let der = certificateDER(from: data),
              let ca = SecCertificateCreateWithData(nil, der as CFData) else {
            Log.log("mTLS: pinned CA file is unavailable")
            return nil
        }
        guard sha256Fingerprint(ca) == expectedCAFingerprint else {
            Log.log("mTLS: pinned CA fingerprint mismatch")
            return nil
        }
        cachedCA = ca
        return ca
    }

    private static func certificateDER(from data: Data) -> Data? {
        guard let pem = String(data: data, encoding: .utf8),
              pem.contains("BEGIN CERTIFICATE") else { return data }
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        return Data(base64Encoded: body)
    }

    private static func loadPrivateIdentity(for host: String) -> Match? {
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.p12URL)
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.p12PassURL)
        guard let p12 = try? Data(contentsOf: PrivateMTLSStore.p12URL),
              let pass = try? String(contentsOf: PrivateMTLSStore.p12PassURL)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !pass.isEmpty else {
            Log.log("mTLS: private identity files missing for \(host)")
            return nil
        }

        var imported: CFArray?
        let opts = [kSecImportExportPassphrase as String: pass]
        let status = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &imported)
        guard status == errSecSuccess,
              let items = imported as? [[String: Any]],
              let rawIdentity = items.first?[kSecImportItemIdentity as String] else {
            Log.log("mTLS: failed to load private identity status=\(status)")
            return nil
        }
        let identity = rawIdentity as! SecIdentity

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let cert = certRef,
              let summary = SecCertificateCopySubjectSummary(cert) as String? else {
            Log.log("mTLS: private identity has no certificate")
            return nil
        }
        guard summary.caseInsensitiveCompare(expectedSubject) == .orderedSame,
              issuerCommonName(cert)?.caseInsensitiveCompare(expectedIssuer) == .orderedSame,
              sha256Fingerprint(cert) == expectedFingerprint else {
            Log.log("mTLS: private identity did not match pinned certificate")
            return nil
        }
        return Match(identity: identity, certificates: certificateChain(leaf: cert))
    }
}

enum PrivateMTLSStore {
    private static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wispr", isDirectory: true)
    }

    static var p12URL: URL { dir.appendingPathComponent("client.p12") }
    static var p12PassURL: URL { dir.appendingPathComponent("client.p12.pass") }
    static var caURL: URL { dir.appendingPathComponent("ca.crt") }
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
