import Combine
import Foundation

/// A successful 31-day R2 page-view query. Every requested page key is
/// present in `countsByPageKey`, including pages with zero requests.
struct R2PageViewSnapshot: Equatable, Sendable {
    let countsByPageKey: [String: Int64]
    let interval: DateInterval
    let fetchedAt: Date

    func count(forPageKey key: String) -> Int64? {
        countsByPageKey[key]
    }
}

/// Errors are intentionally classified for the settings experience: only a
/// definite authorization failure should invite somebody to add an Analytics
/// token. Network, rate-limit, and Cloudflare service failures should retry.
enum R2ViewCountError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case authenticationFailed
    case transient(String)
    case api(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "The token does not have Account Analytics read access."
        case .authenticationFailed:
            return "Cloudflare did not accept the analytics token."
        case .transient(let message), .api(let message):
            return message
        case .invalidResponse:
            return "Cloudflare returned an invalid analytics response."
        }
    }
}

/// Queries Cloudflare's native R2 operations dataset. It counts successful
/// GetObject operations grouped by object name, then retains only the requested
/// Dropper `index.html` keys. The supplied token is never retained or logged.
struct R2ViewCountAPI: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let endpoint = URL(string: "https://api.cloudflare.com/client/v4/graphql")!
    private static let retention: TimeInterval = 31 * 24 * 60 * 60
    private let transport: Transport

    init(session: URLSession = .shared) {
        transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw R2ViewCountError.invalidResponse
            }
            return (data, http)
        }
    }

    /// Test seam kept internal to the app module.
    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func fetchPageViews(
        accountID: String,
        bucketName: String,
        pageKeys: [String],
        token: String,
        now: Date = Date()
    ) async throws -> R2PageViewSnapshot {
        let requestedPages = Set(pageKeys.filter(Self.isSharePageKey))
        let result = try await query(
            accountID: accountID, bucketName: bucketName,
            token: token, now: now, limit: 10_000,
            successfulGetsOnly: true)

        var counts = Dictionary(uniqueKeysWithValues:
            requestedPages.map { ($0, Int64(0)) })
        for group in result.groups {
            guard let objectName = group.dimensions.objectName,
                  requestedPages.contains(objectName) else { continue }
            counts[objectName, default: 0] += group.sum.requests
        }

        return R2PageViewSnapshot(
            countsByPageKey: counts,
            interval: DateInterval(start: result.start, end: now),
            fetchedAt: now)
    }

    /// A minimal one-row query used to test whether a token can read R2
    /// analytics without downloading the bucket's complete set of groups.
    func checkAccess(
        accountID: String,
        bucketName: String,
        token: String,
        now: Date = Date()
    ) async throws {
        _ = try await query(
            accountID: accountID, bucketName: bucketName,
            token: token, now: now, limit: 1,
            successfulGetsOnly: false)
    }

    private struct QueryResult {
        let groups: [OperationGroup]
        let start: Date
    }

    private func query(
        accountID: String,
        bucketName: String,
        token: String,
        now: Date,
        limit: Int,
        successfulGetsOnly: Bool
    ) async throws -> QueryResult {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw R2ViewCountError.authenticationFailed
        }

        let start = now.addingTimeInterval(-Self.retention)
        let variables: [String: Any] = [
            "accountTag": accountID,
            "bucketName": bucketName,
            "startDate": Self.timestamp(start),
            "endDate": Self.timestamp(now),
        ]
        let body: [String: Any] = [
            "query": Self.queryDocument(
                limit: limit, successfulGetsOnly: successfulGetsOnly),
            "variables": variables,
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let responseData: Data
        let response: HTTPURLResponse
        do {
            (responseData, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as R2ViewCountError {
            throw error
        } catch {
            throw R2ViewCountError.transient(error.localizedDescription)
        }

        let envelope = try? JSONDecoder().decode(GraphQLResponse.self, from: responseData)

        if response.statusCode == 401 {
            throw R2ViewCountError.authenticationFailed
        }
        if response.statusCode == 403 {
            throw R2ViewCountError.permissionDenied
        }

        if let errors = envelope?.errors, !errors.isEmpty {
            throw Self.classify(errors: errors, statusCode: response.statusCode)
        }

        if response.statusCode == 408 || response.statusCode == 429
            || (500...599).contains(response.statusCode) {
            throw R2ViewCountError.transient(
                HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        guard (200...299).contains(response.statusCode) else {
            throw R2ViewCountError.api(
                HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
        }
        guard let envelope, let data = envelope.data else {
            throw R2ViewCountError.invalidResponse
        }
        // An account-scoped query that returns no account cannot establish
        // access to the configured account, even if the HTTP request was 200.
        guard let account = data.viewer.accounts.first else {
            throw R2ViewCountError.permissionDenied
        }
        return QueryResult(groups: account.r2OperationsAdaptiveGroups, start: start)
    }

    private static func isSharePageKey(_ key: String) -> Bool {
        key == "index.html" || key.hasSuffix("/index.html")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func queryDocument(limit: Int,
                                      successfulGetsOnly: Bool) -> String {
        let operationFilters = successfulGetsOnly
            ? """

                  actionType: "GetObject"
                  actionStatus: "success"
              """
            : ""
        let dimensions = successfulGetsOnly ? "objectName" : "actionType"
        return """
        query DropperPageViews(
          $accountTag: string!
          $startDate: Time!
          $endDate: Time!
          $bucketName: string!
        ) {
          viewer {
            accounts(filter: { accountTag: $accountTag }) {
              r2OperationsAdaptiveGroups(
                limit: \(limit)
                filter: {
                  datetime_geq: $startDate
                  datetime_leq: $endDate
                  bucketName: $bucketName
                  \(operationFilters)
                  \(successfulGetsOnly ? "objectName_like: \"%/index.html\"" : "")
                }
              ) {
                sum { requests }
                dimensions { \(dimensions) }
              }
            }
          }
        }
        """
    }

    private static func classify(errors: [GraphQLError], statusCode: Int) -> R2ViewCountError {
        let message = errors.map(\.message).joined(separator: " ")
        let lower = message.lowercased()

        if errors.contains(where: { $0.extensions?.code?.lowercased() == "authz" }) {
            return .permissionDenied
        }
        if lower == "unauthorized" || lower.contains("invalid api token")
            || lower.contains("authentication failed") {
            return .authenticationFailed
        }
        if lower.contains("not authorized") || lower.contains("does not have access")
            || lower.contains("permission") || lower.contains("forbidden") {
            return .permissionDenied
        }
        if statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
            || lower.contains("try again later") || lower.contains("temporarily")
            || lower.contains("too many queries") || lower.contains("rate limiter")
            || lower.contains("internal server error") || lower.contains("timed out") {
            return .transient(message)
        }
        return .api(message)
    }

    private struct GraphQLResponse: Decodable {
        let data: ResponseData?
        let errors: [GraphQLError]?
    }

    private struct GraphQLError: Decodable {
        let message: String
        let extensions: Extensions?

        struct Extensions: Decodable {
            let code: String?
        }
    }

    private struct ResponseData: Decodable {
        let viewer: Viewer
    }

    private struct Viewer: Decodable {
        let accounts: [Account]
    }

    private struct Account: Decodable {
        let r2OperationsAdaptiveGroups: [OperationGroup]
    }

    private struct OperationGroup: Decodable {
        let sum: Sum
        let dimensions: Dimensions

        struct Sum: Decodable {
            let requests: Int64
        }

        struct Dimensions: Decodable {
            let objectName: String?
        }
    }
}

/// UI-ready state kept separate from ShareStore so view counts remain an
/// optional capability. A transient refresh failure preserves a prior snapshot;
/// permission and authentication failures clear it to prevent stale counts.
@MainActor
final class ShareViewCountState: ObservableObject {
    enum AccessState: Equatable {
        case unknown
        case available
        case permissionRequired
        case authenticationFailed
        case temporarilyUnavailable
    }

    @Published private(set) var accessState: AccessState = .unknown
    @Published private(set) var isLoading = false
    @Published private(set) var countsByPageKey: [String: Int64] = [:]
    @Published private(set) var lastError: R2ViewCountError?

    private struct Scope: Equatable {
        let accountID: String
        let bucketName: String
    }

    private let api: R2ViewCountAPI
    private let cacheLifetime: TimeInterval
    private var snapshot: R2PageViewSnapshot?
    private var scope: Scope?
    private var generation = 0

    init(api: R2ViewCountAPI = R2ViewCountAPI(),
         cacheLifetime: TimeInterval = 5 * 60) {
        self.api = api
        self.cacheLifetime = cacheLifetime
    }

    /// Returns nil until analytics are available. A real zero is returned for
    /// a page included in a successful query that had no matching requests.
    func count(forPageKey key: String) -> Int64? {
        snapshot?.count(forPageKey: key)
    }

    /// Invalidates any in-flight response and returns the optional analytics
    /// capability to its initial state after the primary R2 config changes.
    func reset() {
        generation += 1
        snapshot = nil
        scope = nil
        countsByPageKey = [:]
        lastError = nil
        accessState = .unknown
        isLoading = false
    }

    func load(
        accountID: String,
        bucketName: String,
        pageKeys: [String],
        token: String,
        force: Bool = false,
        now: Date = Date()
    ) async {
        let requested = Set(pageKeys.filter {
            $0 == "index.html" || $0.hasSuffix("/index.html")
        })
        let requestedScope = Scope(accountID: accountID, bucketName: bucketName)
        if !force, scope == requestedScope, let snapshot,
           requested.isSubset(of: Set(snapshot.countsByPageKey.keys)),
           now.timeIntervalSince(snapshot.fetchedAt) < cacheLifetime {
            accessState = .available
            return
        }

        generation += 1
        let requestGeneration = generation
        isLoading = true
        do {
            let fresh = try await api.fetchPageViews(
                accountID: accountID, bucketName: bucketName,
                pageKeys: Array(requested), token: token, now: now)
            guard requestGeneration == generation else { return }
            snapshot = fresh
            scope = requestedScope
            countsByPageKey = fresh.countsByPageKey
            lastError = nil
            accessState = .available
        } catch is CancellationError {
            guard requestGeneration == generation else { return }
        } catch let error as R2ViewCountError {
            guard requestGeneration == generation else { return }
            lastError = error
            if scope != requestedScope {
                snapshot = nil
                countsByPageKey = [:]
                scope = requestedScope
            }
            switch error {
            case .permissionDenied:
                snapshot = nil
                countsByPageKey = [:]
                accessState = .permissionRequired
            case .authenticationFailed:
                snapshot = nil
                countsByPageKey = [:]
                accessState = .authenticationFailed
            case .transient:
                accessState = .temporarilyUnavailable
            case .api, .invalidResponse:
                accessState = .temporarilyUnavailable
            }
        } catch {
            guard requestGeneration == generation else { return }
            lastError = .transient(error.localizedDescription)
            accessState = .temporarilyUnavailable
        }
        if requestGeneration == generation {
            isLoading = false
        }
    }

    /// Runs the cheap permission probe and updates only capability state. It
    /// does not replace a previously loaded counts snapshot.
    @discardableResult
    func checkAccess(
        accountID: String,
        bucketName: String,
        token: String,
        now: Date = Date()
    ) async -> AccessState {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        do {
            try await api.checkAccess(
                accountID: accountID, bucketName: bucketName,
                token: token, now: now)
            guard requestGeneration == generation else { return accessState }
            lastError = nil
            accessState = .available
        } catch is CancellationError {
            guard requestGeneration == generation else { return accessState }
            // Cancellation is not evidence that permissions are unavailable.
        } catch let error as R2ViewCountError {
            guard requestGeneration == generation else { return accessState }
            lastError = error
            switch error {
            case .permissionDenied: accessState = .permissionRequired
            case .authenticationFailed: accessState = .authenticationFailed
            case .transient, .api, .invalidResponse:
                accessState = .temporarilyUnavailable
            }
        } catch {
            guard requestGeneration == generation else { return accessState }
            lastError = .transient(error.localizedDescription)
            accessState = .temporarilyUnavailable
        }
        if requestGeneration == generation {
            isLoading = false
        }
        return accessState
    }
}
