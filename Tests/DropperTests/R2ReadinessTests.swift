import Foundation
import XCTest
@testable import Dropper

@MainActor
final class R2ReadinessTests: XCTestCase {
    func testImmediateSuccessDoesNotSleepOrAnnounceRetry() async throws {
        var probes = 0
        var sleeps: [Duration] = []
        var retries = 0
        let waiter = R2ReadinessWaiter(
            retryDelays: [.seconds(1)],
            sleep: { sleeps.append($0) })

        try await waiter.wait(
            probe: { probes += 1 },
            onRetry: { _, _ in retries += 1 })

        XCTAssertEqual(probes, 1)
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertEqual(retries, 0)
    }

    func testTLSFailuresBackOffThenSucceed() async throws {
        var probes = 0
        var sleeps: [Duration] = []
        var announcedAttempts: [Int] = []
        let waiter = R2ReadinessWaiter(
            retryDelays: [.seconds(1), .seconds(2), .seconds(4)],
            sleep: { sleeps.append($0) })

        try await waiter.wait(
            probe: {
                probes += 1
                if probes < 3 { throw URLError(.secureConnectionFailed) }
            },
            onRetry: { attempt, _ in announcedAttempts.append(attempt) })

        XCTAssertEqual(probes, 3)
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(2)])
        XCTAssertEqual(announcedAttempts, [2, 3])
    }

    func testRetryExhaustionRethrowsFinalError() async {
        var probes = 0
        var sleeps: [Duration] = []
        let waiter = R2ReadinessWaiter(
            retryDelays: [.seconds(1), .seconds(2)],
            sleep: { sleeps.append($0) })

        do {
            try await waiter.wait {
                probes += 1
                throw URLError(.secureConnectionFailed)
            }
            XCTFail("Expected the readiness check to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .secureConnectionFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(probes, 3)
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(2)])
    }

    func testAuthenticationFailureStopsImmediately() async {
        var probes = 0
        var sleeps = 0
        let waiter = R2ReadinessWaiter(
            retryDelays: [.seconds(1), .seconds(2)],
            sleep: { _ in sleeps += 1 })

        do {
            try await waiter.wait {
                probes += 1
                throw R2Client.R2Error.badStatus(403, "AccessDenied")
            }
            XCTFail("Expected the readiness check to fail")
        } catch let error as R2Client.R2Error {
            guard case let .badStatus(status, _) = error else {
                return XCTFail("Unexpected R2 error")
            }
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(probes, 1)
        XCTAssertEqual(sleeps, 0)
    }

    func testCertificateTrustFailureIsNeverRetried() async {
        XCTAssertFalse(R2ReadinessWaiter.isRetryable(
            URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(R2ReadinessWaiter.isRetryable(
            URLError(.serverCertificateHasBadDate)))
        XCTAssertFalse(R2ReadinessWaiter.isRetryable(
            URLError(.serverCertificateHasUnknownRoot)))
        XCTAssertFalse(R2ReadinessWaiter.isRetryable(
            URLError(.serverCertificateNotYetValid)))
    }

    func testOnboardingTransientHTTPFailuresAreRetriedNarrowly() {
        for status in [404, 408, 429, 500, 503, 520, 524] {
            XCTAssertTrue(R2ReadinessWaiter.isRetryable(
                R2Client.R2Error.badStatus(status, "")),
                "Expected HTTP \(status) to be retryable")
        }
        for status in [400, 401, 403, 409, 501, 505, 511, 525, 526] {
            XCTAssertFalse(R2ReadinessWaiter.isRetryable(
                R2Client.R2Error.badStatus(status, "")),
                "Expected HTTP \(status) to fail immediately")
        }
        XCTAssertTrue(R2ReadinessWaiter.isRetryable(
            R2Client.R2Error.badStatus(
                400, "<Error><Code>ClientDisconnect</Code></Error>")))
    }

    func testOfflineAndCancellationDoNotBackOff() async {
        XCTAssertFalse(R2ReadinessWaiter.isRetryable(
            URLError(.notConnectedToInternet)))

        var sleeps = 0
        let waiter = R2ReadinessWaiter(
            retryDelays: [.seconds(1)],
            sleep: { _ in sleeps += 1 })
        do {
            try await waiter.wait { throw URLError(.cancelled) }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(sleeps, 0)
    }

    func testWrappedTLSFailureIsRecognized() {
        let wrapped = NSError(
            domain: "Dropper.TestWrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.secureConnectionFailed)])

        XCTAssertEqual(
            R2ReadinessWaiter.urlErrorCode(in: wrapped),
            .secureConnectionFailed)
        XCTAssertTrue(R2ReadinessWaiter.isRetryable(wrapped))
    }

    func testDefaultBackoffHasSixAttemptsAcrossThirtySeconds() {
        XCTAssertEqual(
            R2ReadinessWaiter.defaultRetryDelays,
            [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)])
    }

    func testReadinessRequestIsSignedNonMutatingAndMinimal() throws {
        let config = AppConfigSnapshot(
            accountID: "0123456789abcdef0123456789abcdef",
            bucket: "dropper", prefix: "", publicBase: "https://example.test")
        let client = R2Client(
            credentials: AWSCredentials(
                accessKeyId: "token-id", secretAccessKey: "derived-secret"),
            config: config)

        let request = client.readinessRequest()
        let url = try XCTUnwrap(request.url)
        let query = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(url.host, "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
        XCTAssertEqual(url.path, "/dropper")
        XCTAssertEqual(values["list-type"]!, "2")
        XCTAssertEqual(values["max-keys"]!, "1")
        XCTAssertEqual(request.timeoutInterval, 5)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("AWS4-HMAC-SHA256 Credential=token-id/") == true)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-amz-date"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-amz-content-sha256"),
            "UNSIGNED-PAYLOAD")
    }
}
