import Foundation
import CryptoKit
import Security

/// Resolved configuration snapshot — immutable, safe to hand to R2Client and
/// background tasks. Values come from UserDefaults with the compiled-in
/// defaults (the original hardcoded setup) as fallback.
struct AppConfigSnapshot {
    let accountID: String
    let bucket: String
    let prefix: String      // "" means bucket root
    let publicBase: String

    var endpoint: URL { URL(string: "https://\(accountID).r2.cloudflarestorage.com")! }

    /// Key for a path inside the configured folder.
    func key(_ relative: String) -> String {
        prefix.isEmpty ? relative : "\(prefix)/\(relative)"
    }

    /// Listing prefix for the configured folder ("" or "folder/").
    var listPrefix: String { prefix.isEmpty ? "" : "\(prefix)/" }
}

/// Thread-safe (nonisolated) storage helpers shared by the UI model and CLI.
enum ConfigStore {
    static let keys = (account: "accountID", bucket: "bucket", prefix: "prefix",
                       publicBase: "publicBase", tokenID: "cfTokenID",
                       convertHEIC: "convertHEIC", convertAIFF: "convertAIFF",
                       convertMOV: "convertMOV")

    /// HEIC -> JPEG conversion on upload; default ON (HEIC breaks in most
    /// non-Apple browsers).
    static func convertHEIC() -> Bool {
        UserDefaults.standard.object(forKey: keys.convertHEIC) as? Bool ?? true
    }

    /// AIFF -> WAV conversion on upload; default ON (AIFF doesn't play in
    /// Chrome/Firefox; the repack is lossless).
    static func convertAIFF() -> Bool {
        UserDefaults.standard.object(forKey: keys.convertAIFF) as? Bool ?? true
    }

    /// Video -> web-safe MP4 conversion on upload; default ON (HEVC/ProRes
    /// don't decode in Chrome/Firefox; H.264 .mov is losslessly remuxed).
    static func convertMOV() -> Bool {
        UserDefaults.standard.object(forKey: keys.convertMOV) as? Bool ?? true
    }

    static func snapshot() -> AppConfigSnapshot {
        let d = UserDefaults.standard
        return AppConfigSnapshot(
            accountID: d.string(forKey: keys.account) ?? Config.defaultAccountID,
            bucket: d.string(forKey: keys.bucket) ?? Config.bucket,
            prefix: d.string(forKey: keys.prefix) ?? Config.keyPrefix,
            publicBase: d.string(forKey: keys.publicBase) ?? Config.publicBase)
    }

    /// Keychain token (pasted once) wins; falls back to ~/.aws/credentials.
    /// DROPPER_NO_KEYCHAIN=1 skips the Keychain — reading it can block on a
    /// user authorization prompt, which deadlocks headless/test invocations.
    static func resolveCredentials() -> AWSCredentials? {
        if ProcessInfo.processInfo.environment["DROPPER_NO_KEYCHAIN"] != "1",
           let token = Keychain.loadToken(),
           let tokenID = UserDefaults.standard.string(forKey: keys.tokenID) {
            return AWSCredentials(accessKeyId: tokenID,
                                  secretAccessKey: sha256Hex(token))
        }
        return AWSCredentials.load(profile: Config.awsProfile)
    }

    /// The R2 S3 secret is defined as the SHA-256 of the API token value.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "com.temeculadsp.dropper"
    private static let account = "cloudflare-api-token"

    static func saveToken(_ token: String) {
        deleteToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Cloudflare REST API (Bearer token)

enum CloudflareAPI {
    struct Account: Decodable, Identifiable {
        let id: String
        let name: String
    }

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let result: T?
        struct APIError: Decodable { let message: String }
        let errors: [APIError]?
    }

    enum APIFailure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(m) = self { return m }
            return nil
        }
    }

    private static func request<T: Decodable>(
        _ method: String, _ path: String, token: String,
        body: [String: Any]? = nil, as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.success, let result = envelope.result else {
            throw APIFailure.message(envelope.errors?.first?.message ?? "Cloudflare API error")
        }
        return result
    }

    private static func get<T: Decodable>(_ path: String, token: String,
                                          as type: T.Type) async throws -> T {
        try await request("GET", path, token: token, as: type)
    }

    /// Returns the token's ID — which doubles as the S3 Access Key ID.
    ///
    /// Cloudflare has two token kinds and two verify endpoints: user tokens
    /// verify at /user/tokens/verify, but Account API Tokens — the kind the
    /// R2 dashboard's token page creates, i.e. exactly what the wizard tells
    /// people to make — are rejected there and must verify through their
    /// account. Try user first, then fall back.
    static func verifyToken(_ token: String) async throws -> String {
        struct Verify: Decodable { let id: String; let status: String }
        func check(_ v: Verify) throws -> String {
            guard v.status == "active" else {
                throw APIFailure.message("Token status: \(v.status)")
            }
            return v.id
        }
        do {
            return try check(await get("/user/tokens/verify", token: token, as: Verify.self))
        } catch {
            guard let account = try? await accounts(token).first else { throw error }
            return try check(await get("/accounts/\(account.id)/tokens/verify",
                                       token: token, as: Verify.self))
        }
    }

    /// Accounts the token can see (may fail for narrowly scoped tokens).
    static func accounts(_ token: String) async throws -> [Account] {
        try await get("/accounts", token: token, as: [Account].self)
    }

    /// The bucket's managed r2.dev public domain, if public access is enabled.
    static func managedDomain(token: String, accountID: String,
                              bucket: String) async throws -> (domain: String, enabled: Bool) {
        struct Managed: Decodable { let domain: String; let enabled: Bool }
        let m = try await get("/accounts/\(accountID)/r2/buckets/\(bucket)/domains/managed",
                              token: token, as: Managed.self)
        return (m.domain, m.enabled)
    }

    /// Creates an R2 bucket; an "already exists" response counts as success
    /// (the wizard is safe to re-run).
    static func createBucket(token: String, accountID: String,
                             name: String) async throws {
        struct Created: Decodable { let name: String }
        do {
            _ = try await request("POST", "/accounts/\(accountID)/r2/buckets",
                                  token: token, body: ["name": name], as: Created.self)
        } catch let APIFailure.message(message)
            where message.lowercased().contains("already exists") {
            // Fine — re-running setup against an existing bucket.
        }
    }

    /// Turns on the bucket's public r2.dev URL and returns its domain.
    static func enablePublicURL(token: String, accountID: String,
                                bucket: String) async throws -> String {
        struct Managed: Decodable { let domain: String; let enabled: Bool }
        let m = try await request(
            "PUT", "/accounts/\(accountID)/r2/buckets/\(bucket)/domains/managed",
            token: token, body: ["enabled": true], as: Managed.self)
        return m.domain
    }
}
