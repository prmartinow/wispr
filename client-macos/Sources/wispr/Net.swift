import Foundation
import CryptoKit
import Security

/// Loads the pinned wispr client identity from private app-support files and pins the LAN CA.
enum RemoteIdentity {
    struct Match {
        let identity: SecIdentity
        let certificates: [SecCertificate]
        // Keeps PKCS#12-imported key material alive when the file fallback is used.
        let retainedImport: CFArray?
    }

    private static let identityLock = NSLock()
    private static var cachedIdentity: Match?
    private static let caLock = NSLock()
    private static var cachedCA: SecCertificate?

    static func find(for host: String) -> Match? {
        guard configuredHosts(from: PrivateMTLSStore.clientCertHostsURL,
                              fallback: EndpointPolicy.configuredClientCertHosts())
            .contains(host.lowercased()) else {
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
        guard configuredHosts(from: PrivateMTLSStore.lanHostsURL,
                              fallback: EndpointPolicy.configuredLANHosts())
            .contains(host.lowercased()) else { return nil }
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
        return URLCredential(trust: trust)
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
        if let keychainIdentity = loadKeychainIdentity() {
            Log.log("mTLS: using keychain identity for \(host)")
            return keychainIdentity
        }

        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.p12URL)
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.p12PassURL)
        if let p12 = try? Data(contentsOf: PrivateMTLSStore.p12URL),
           let pass = try? String(contentsOf: PrivateMTLSStore.p12PassURL)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pass.isEmpty {
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
                  let cert = certRef else {
                Log.log("mTLS: private identity has no certificate")
                return nil
            }
            if let expected = expectedClientFingerprint(), sha256Fingerprint(cert) != expected {
                Log.log("mTLS: private identity fingerprint mismatch for \(host)")
                return nil
            }
            return Match(identity: identity, certificates: [cert], retainedImport: imported)
        }

        Log.log("mTLS: private identity files missing for \(host)")
        return nil
    }

    private static func loadKeychainIdentity() -> Match? {
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.keychainLabelURL)
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.clientCertFingerprintURL)
        let expectedLabel = (try? String(contentsOf: PrivateMTLSStore.keychainLabelURL))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedFingerprint = expectedClientFingerprint()
        guard (expectedLabel?.isEmpty == false) || (expectedFingerprint?.isEmpty == false) else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess else {
            Log.log("mTLS: keychain identity search failed status=\(status)")
            return nil
        }
        let identities = (raw as? [SecIdentity]) ?? (raw.map { [$0 as! SecIdentity] } ?? [])
        for identity in identities {
            var certRef: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
                  let cert = certRef else { continue }
            let label = SecCertificateCopySubjectSummary(cert) as String?
            if let expectedLabel, !expectedLabel.isEmpty,
               label?.caseInsensitiveCompare(expectedLabel) != .orderedSame {
                continue
            }
            if let expectedFingerprint, !expectedFingerprint.isEmpty,
               sha256Fingerprint(cert) != expectedFingerprint {
                continue
            }
            return Match(identity: identity, certificates: [cert], retainedImport: nil)
        }
        Log.log("mTLS: no keychain identity matched private pin files")
        return nil
    }

    private static func sha256Fingerprint(_ cert: SecCertificate) -> String {
        let data = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private static func expectedClientFingerprint() -> String? {
        PrivateFiles.lockDownIfPresent(PrivateMTLSStore.clientCertFingerprintURL)
        let value = (try? String(contentsOf: PrivateMTLSStore.clientCertFingerprintURL))?
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return value?.isEmpty == false ? value : nil
    }

    private static func configuredHosts(from url: URL, fallback: Set<String>) -> Set<String> {
        PrivateFiles.lockDownIfPresent(url)
        guard let raw = try? String(contentsOf: url) else { return fallback }
        let fileHosts = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return fallback.union(fileHosts)
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
    static var lanHostsURL: URL { dir.appendingPathComponent("lan-hosts") }
    static var clientCertHostsURL: URL { dir.appendingPathComponent("client-cert-hosts") }
    static var keychainLabelURL: URL { dir.appendingPathComponent("keychain-label") }
    static var clientCertFingerprintURL: URL { dir.appendingPathComponent("client-cert-sha256") }
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
                                            certificates: nil,
                                            persistence: .none))
        } else {
            Log.log("mTLS: remote asked for a client cert but the pinned identity is unavailable")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// URLSession helpers for mTLS calls. Health/upload calls use short-lived sessions so
/// a startup permission prompt or failed TLS attempt cannot poison later probes.
enum Net {
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 780 // long: 10-minute batch fallback + backend margin
        cfg.timeoutIntervalForResource = 900
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg, delegate: MTLSDelegate(), delegateQueue: nil)
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: body)
    }

    @discardableResult
    static func dataTask(with request: URLRequest,
                         completion: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        let session = makeSession()
        let task = session.dataTask(with: request) { data, response, error in
            completion(data, response, error)
            session.finishTasksAndInvalidate()
        }
        return task
    }
}
