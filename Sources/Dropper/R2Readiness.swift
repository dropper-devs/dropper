import Foundation

/// Waits for a newly enabled R2 S3 endpoint to become usable. Cloudflare's
/// bucket-management API can finish before the account-specific S3 endpoint
/// is ready to complete a TLS handshake, so onboarding verifies the real
/// signed endpoint before it saves the configuration.
struct R2ReadinessWaiter {
    typealias Sleeper = (Duration) async throws -> Void

    static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15),
    ]

    let retryDelays: [Duration]
    private let sleep: Sleeper

    init(
        retryDelays: [Duration] = Self.defaultRetryDelays,
        sleep: @escaping Sleeper = { duration in
            try await Task<Never, Never>.sleep(for: duration)
        }
    ) {
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    /// Probes immediately, then retries only failures that can reasonably be
    /// transient. The probe is invoked again for every attempt so its SigV4
    /// date and signature are always fresh.
    @MainActor
    func wait(
        probe: () async throws -> Void,
        onRetry: (_ nextAttempt: Int, _ delay: Duration) async -> Void = { _, _ in }
    ) async throws {
        for attempt in 0...retryDelays.count {
            try Task.checkCancellation()
            do {
                try await probe()
                return
            } catch {
                if Task.isCancelled || error.isCancellation {
                    throw CancellationError()
                }
                guard Self.isRetryable(error), attempt < retryDelays.count else {
                    throw error
                }
                let delay = retryDelays[attempt]
                await onRetry(attempt + 2, delay)
                try await sleep(delay)
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let code = urlErrorCode(in: error) {
            switch code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .secureConnectionFailed:
                return true
            default:
                return false
            }
        }

        guard let r2Error = error as? R2Client.R2Error else { return false }
        switch r2Error {
        case .invalidConfiguration, .invalidListResponse:
            return false
        case let .badStatus(status, body):
            // This waiter is used immediately after bucket creation. Give a
            // just-created bucket a brief 404 propagation grace period; a
            // persistent 404 still reaches the user after the bounded wait.
            if status == 404 || status == 408 || status == 429 {
                return true
            }
            if [500, 502, 503, 504].contains(status)
                || (520...524).contains(status) {
                return true
            }
            // R2 documents ClientDisconnect as a retryable S3 error even
            // though it is carried in an HTTP 400 response.
            return status == 400 && body.contains("ClientDisconnect")
        }
    }

    /// Retained for tests; the URL-error chain walk now lives on `Error`.
    static func urlErrorCode(in error: Error) -> URLError.Code? {
        error.urlErrorCode
    }
}
