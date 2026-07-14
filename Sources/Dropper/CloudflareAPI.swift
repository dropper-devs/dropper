import Foundation

/// Minimal Cloudflare REST API client (Bearer token). Used by onboarding and
/// settings to verify a token and manage the R2 bucket + its public domain.
enum CloudflareAPI {
    struct Account: Decodable, Identifiable, Sendable {
        let id: String
        let name: String
    }

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let result: T?
        struct APIError: Decodable { let message: String }
        let errors: [APIError]?
    }

    enum APIFailure: LocalizedError, Sendable {
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
