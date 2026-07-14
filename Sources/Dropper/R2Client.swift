import Foundation

struct R2Object: Sendable {
    let key: String
    let lastModified: Date
    let size: Int64
}

/// Uploads, lists, and deletes objects in R2 (S3 API) with SigV4 signing.
final class R2Client: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Double) -> Void

    private let credentials: AWSCredentials
    let config: AppConfigSnapshot
    private let sessionConfiguration: URLSessionConfiguration
    /// Path-style base for every request (https://<endpoint>/<bucket>),
    /// validated once — config is immutable for the client's lifetime.
    private let requestBase: Result<URL, R2Error>
    private lazy var session: URLSession = {
        let cfg = sessionConfiguration
        cfg.timeoutIntervalForRequest = 120        // inactivity timeout
        cfg.timeoutIntervalForResource = 4 * 3600  // total ceiling for huge videos
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var progressHandlers: [Int: ProgressHandler] = [:]
    private let lock = NSLock()

    init(credentials: AWSCredentials, config: AppConfigSnapshot,
         sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.credentials = credentials
        self.config = config
        self.sessionConfiguration = sessionConfiguration
        do {
            let validated = try AppConfigSnapshot.validated(
                accountID: config.accountID, bucket: config.bucket,
                prefix: config.prefix, publicBase: config.publicBase)
            if let endpoint = validated.endpoint {
                requestBase = .success(endpoint.appendingPathComponent(validated.bucket))
            } else {
                requestBase = .failure(.invalidConfiguration("The R2 endpoint is invalid."))
            }
        } catch {
            requestBase = .failure(.invalidConfiguration(error.localizedDescription))
        }
    }

    enum R2Error: LocalizedError, Sendable {
        case badStatus(Int, String)
        case invalidConfiguration(String)
        case invalidListResponse(String)

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, body):
                return "R2 returned HTTP \(code): \(body.prefix(200))"
            case let .invalidConfiguration(message):
                return message
            case let .invalidListResponse(message):
                return "R2 returned an invalid object listing: \(message)"
            }
        }
    }

    // MARK: - Upload

    /// PUT a local file to `key` in the bucket. `progress` is called on an
    /// arbitrary queue with 0...1.
    func put(fileURL: URL, key: String, contentType: String,
             cacheControl: String,
             progress: @escaping ProgressHandler) async throws {
        var request = try makeRequest(method: "PUT", key: key)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(cacheControl, forHTTPHeaderField: "Cache-Control")
        SigV4.sign(request: &request, credentials: credentials)
        try await upload(request: request, fileURL: fileURL, progress: progress)
    }

    /// PUT in-memory data (the generated HTML) to `key`.
    func put(data: Data, key: String, contentType: String, cacheControl: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await put(fileURL: tmp, key: key, contentType: contentType,
                      cacheControl: cacheControl, progress: { _ in })
    }

    // MARK: - List / Delete

    /// All objects under `prefix`, paging through ListObjectsV2 as needed.
    func list(prefix: String) async throws -> [R2Object] {
        var objects: [R2Object] = []
        try await listPages(query: [
            ("list-type", "2"), ("max-keys", "1000"), ("prefix", prefix),
        ]) { objects.append(contentsOf: $0.objects) }
        return objects
    }

    /// Immediate subfolders of `prefix` ("" = bucket root) via a delimiter
    /// listing. Returns folder names without the trailing slash.
    func listFolders(prefix: String) async throws -> [String] {
        var prefixes: [String] = []
        try await listPages(query: [
            ("list-type", "2"), ("max-keys", "1000"),
            ("prefix", prefix), ("delimiter", "/"),
        ]) { prefixes.append(contentsOf: $0.commonPrefixes) }
        return Set(prefixes).compactMap { full in
            let name = String(full.dropFirst(prefix.count))
            return name.hasSuffix("/") ? String(name.dropLast()) : name
        }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// One paginated ListObjectsV2 walk: signs and sends each page, guards
    /// against a truncated response that fails to advance the continuation
    /// token, and hands every parsed page to `accumulate`.
    private func listPages(query baseQuery: [(String, String)],
                           accumulate: (ListResponseParser.Page) -> Void) async throws {
        var continuation: String? = nil
        var seenContinuations = Set<String>()
        while true {
            var query = baseQuery
            if let continuation { query.append(("continuation-token", continuation)) }
            var request = try makeRequest(method: "GET", key: nil, query: query)
            SigV4.sign(request: &request, credentials: credentials)
            let data = try await send(request: request)
            let page = try ListResponseParser.parse(data)
            accumulate(page)
            guard page.isTruncated else { break }
            guard let next = page.nextToken, !next.isEmpty,
                  seenContinuations.insert(next).inserted else {
                throw R2Error.invalidListResponse(
                    "the response was truncated without a new continuation token")
            }
            continuation = next
        }
    }

    /// "Creates" a folder by writing the zero-byte marker key S3 browsers use.
    func createFolder(path: String) async throws {
        try await put(data: Data(), key: "\(path)/",
                      contentType: "application/x-directory", cacheControl: "no-store")
    }

    /// GET a small object (the share manifests).
    func get(key: String) async throws -> Data {
        var request = try makeRequest(method: "GET", key: key)
        SigV4.sign(request: &request, credentials: credentials)
        return try await send(request: request)
    }

    /// A tiny signed ListObjectsV2 request used by onboarding to prove that
    /// the account-specific R2 TLS endpoint, credentials, and bucket are all
    /// ready. It reads at most one key and never mutates storage.
    func probeReadiness() async throws {
        _ = try await send(request: readinessRequest())
    }

    /// Temporary clients (such as onboarding's readiness probe) must release
    /// URLSession's strong reference to its delegate when their work is done.
    func finishTasksAndInvalidate() {
        removeAllProgressHandlers()
        session.finishTasksAndInvalidate()
    }

    /// Replaced application clients must release URLSession's strong delegate
    /// reference immediately; their old credentials should not remain alive.
    func invalidateAndCancel() {
        removeAllProgressHandlers()
        session.invalidateAndCancel()
    }

    /// Internal so the request's method, destination, and signing can be
    /// verified without making a network request in unit tests.
    func readinessRequest() throws -> URLRequest {
        var request = try makeRequest(method: "GET", key: nil, query: [
            ("list-type", "2"), ("max-keys", "1"),
        ])
        // Combined with onboarding's 30 seconds of backoff, six probes at
        // five seconds each keep the entire automatic grace period near one
        // minute even if every request reaches its timeout.
        request.timeoutInterval = 5
        SigV4.sign(request: &request, credentials: credentials)
        return request
    }

    func delete(key: String) async throws {
        var request = try makeRequest(method: "DELETE", key: key)
        SigV4.sign(request: &request, credentials: credentials)
        _ = try await send(request: request)
    }

    // MARK: - Requests

    private func makeRequest(method: String, key: String?,
                             query: [(String, String)] = []) throws -> URLRequest {
        var url = try requestBase.get()
        if let key { url.appendPathComponent(key) }
        if !query.isEmpty {
            // The wire query IS the SigV4 canonical form, so the signature
            // always matches what's sent.
            guard var components = URLComponents(
                url: url, resolvingAgainstBaseURL: false) else {
                throw R2Error.invalidConfiguration("The R2 request URL is invalid.")
            }
            components.percentEncodedQuery = SigV4.canonicalQueryString(query)
            guard let queryURL = components.url else {
                throw R2Error.invalidConfiguration("The R2 request query is invalid.")
            }
            url = queryURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    /// Data-task request for GET/DELETE; returns the body, throws on non-2xx.
    private func send(request: URLRequest) async throws -> Data {
        let box = SessionTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200...299).contains(status) {
                        cont.resume(returning: data ?? Data())
                    } else {
                        let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        cont.resume(throwing: R2Error.badStatus(status, body))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private func upload(request: URLRequest, fileURL: URL,
                        progress: @escaping ProgressHandler) async throws {
        let box = SessionTaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.uploadTask(with: request, fromFile: fileURL) {
                    [weak self, box] data, response, error in
                    if let identifier = box.taskIdentifier {
                        self?.removeProgressHandler(for: identifier)
                    }
                    if let error { cont.resume(throwing: error); return }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 200 {
                        cont.resume()
                    } else {
                        let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        cont.resume(throwing: R2Error.badStatus(status, body))
                    }
                }
                lock.lock()
                progressHandlers[task.taskIdentifier] = progress
                lock.unlock()
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let handler = progressHandlers[task.taskIdentifier]
        lock.unlock()
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        removeProgressHandler(for: task.taskIdentifier)
    }

    private func removeProgressHandler(for identifier: Int) {
        lock.lock()
        progressHandlers.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func removeAllProgressHandlers() {
        lock.lock()
        progressHandlers.removeAll()
        lock.unlock()
    }
}

/// Bridges Swift Task cancellation to the underlying URLSession task, safe
/// against the cancel racing the task's creation.
private final class SessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    var taskIdentifier: Int? {
        lock.lock()
        defer { lock.unlock() }
        return task?.taskIdentifier
    }

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// Minimal ListObjectsV2 XML parser: Contents/{Key,LastModified,Size},
/// CommonPrefixes, IsTruncated, NextContinuationToken.
private final class ListResponseParser: NSObject, XMLParserDelegate {
    struct Page {
        var objects: [R2Object] = []
        var commonPrefixes: [String] = []
        var isTruncated = false
        var nextToken: String?
    }

    private var page = Page()
    private var text = ""
    private var key = ""
    private var modified = ""
    private var size = ""
    private var inContents = false
    private var inCommonPrefixes = false
    private var sawListBucketResult = false

    // ISO8601DateFormatter is documented thread-safe; shared instances avoid
    // re-allocating Foundation's costliest formatter on every listing page.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ data: Data) throws -> Page {
        let delegate = ListResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw R2Client.R2Error.invalidListResponse(
                parser.parserError?.localizedDescription ?? "malformed XML")
        }
        guard delegate.sawListBucketResult else {
            throw R2Client.R2Error.invalidListResponse("missing ListBucketResult")
        }
        return delegate.page
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "ListBucketResult" {
            sawListBucketResult = true
        } else if name == "Contents" {
            inContents = true
            key = ""; modified = ""; size = ""
        } else if name == "CommonPrefixes" {
            inCommonPrefixes = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "Key" where inContents: key = value
        case "LastModified" where inContents: modified = value
        case "Size" where inContents: size = value
        case "Prefix" where inCommonPrefixes: page.commonPrefixes.append(value)
        case "CommonPrefixes": inCommonPrefixes = false
        case "IsTruncated": page.isTruncated = value == "true"
        case "NextContinuationToken": page.nextToken = value
        case "Contents":
            inContents = false
            let date = Self.isoFractional.date(from: modified)
                ?? Self.iso.date(from: modified) ?? .distantPast
            page.objects.append(R2Object(key: key, lastModified: date, size: Int64(size) ?? 0))
        default: break
        }
    }
}
