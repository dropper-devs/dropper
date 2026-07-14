import Foundation
import XCTest
@testable import Dropper

final class R2ViewCountsTests: XCTestCase {
    private actor RequestRecorder {
        private(set) var requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            requests.append(request)
        }

        func first() -> URLRequest? { requests.first }
        func count() -> Int { requests.count }
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.cloudflare.com/client/v4/graphql")!,
            statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testFetchBatchesSuccessfulGetObjectsAndKeepsOnlyRequestedPages() async throws {
        let recorder = RequestRecorder()
        let response = #"{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[{"sum":{"requests":4},"dimensions":{"objectName":"share/alpha/index.html"}},{"sum":{"requests":3},"dimensions":{"objectName":"share/alpha/index.html"}},{"sum":{"requests":90},"dimensions":{"objectName":"share/alpha/movie.mp4"}},{"sum":{"requests":8},"dimensions":{"objectName":"share/unrequested/index.html"}}]}]}}}"#
        let api = R2ViewCountAPI { request in
            await recorder.record(request)
            return (Data(response.utf8), Self.response(200))
        }
        let now = Date(timeIntervalSince1970: 1_768_000_000)

        let snapshot = try await api.fetchPageViews(
            accountID: "account-123", bucketName: "dropper",
            pageKeys: ["share/alpha/index.html", "share/zero/index.html"],
            token: "secret-token", now: now)

        XCTAssertEqual(snapshot.count(forPageKey: "share/alpha/index.html"), 7)
        XCTAssertEqual(snapshot.count(forPageKey: "share/zero/index.html"), 0)
        XCTAssertNil(snapshot.count(forPageKey: "share/alpha/movie.mp4"))
        XCTAssertNil(snapshot.count(forPageKey: "share/unrequested/index.html"))
        XCTAssertEqual(snapshot.interval.duration, 31 * 24 * 60 * 60, accuracy: 0.01)

        let recordedRequest = await recorder.first()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer secret-token")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertTrue(query.contains(#"actionType: "GetObject""#))
        XCTAssertTrue(query.contains(#"actionStatus: "success""#))
        XCTAssertTrue(query.contains(#"objectName_like: "%/index.html""#))
        XCTAssertTrue(query.contains("dimensions { objectName }"))
        XCTAssertTrue(query.contains("sum { requests }"))
        XCTAssertTrue(query.contains("limit: 10000"))
        let variables = try XCTUnwrap(object["variables"] as? [String: Any])
        XCTAssertEqual(variables["accountTag"] as? String, "account-123")
        XCTAssertEqual(variables["bucketName"] as? String, "dropper")
    }

    func testHTTP200GraphQLAuthorizationErrorRequiresPermissionSetup() async {
        let response = #"{"data":null,"errors":[{"message":"not authorized for that account","path":["R2PermissionProbe","viewer","accounts","0","r2OperationsAdaptiveGroups"],"extensions":{"code":"authz","timestamp":"2026-07-14T00:00:00Z"}}]}"#
        let api = R2ViewCountAPI { _ in
            (Data(response.utf8), Self.response(200))
        }

        do {
            try await api.checkAccess(
                accountID: "account", bucketName: "bucket", token: "token")
            XCTFail("Expected permission failure")
        } catch let error as R2ViewCountError {
            XCTAssertEqual(error, .permissionDenied)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTP200GraphQLServiceErrorIsTransient() async {
        let response = #"{"data":null,"errors":[{"message":"unable to execute query, please try again later"}]}"#
        let api = R2ViewCountAPI { _ in
            (Data(response.utf8), Self.response(200))
        }

        do {
            try await api.checkAccess(
                accountID: "account", bucketName: "bucket", token: "token")
            XCTFail("Expected transient failure")
        } catch let error as R2ViewCountError {
            guard case .transient = error else {
                return XCTFail("Expected transient error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPStatusSeparatesAuthenticationPermissionAndTransientFailures() async {
        for (status, expected) in [
            (401, R2ViewCountError.authenticationFailed),
            (403, R2ViewCountError.permissionDenied),
            (503, R2ViewCountError.transient("service unavailable")),
        ] {
            let api = R2ViewCountAPI { _ in
                (Data(), Self.response(status))
            }
            do {
                try await api.checkAccess(
                    accountID: "account", bucketName: "bucket", token: "token")
                XCTFail("Expected status \(status) to fail")
            } catch let error as R2ViewCountError {
                switch (error, expected) {
                case (.transient, .transient): break
                default: XCTAssertEqual(error, expected)
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testStateCachesSuccessfulBatchAndDistinguishesZeroFromUnavailable() async {
        let recorder = RequestRecorder()
        let response = #"{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[]}]}}}"#
        let api = R2ViewCountAPI { request in
            await recorder.record(request)
            return (Data(response.utf8), Self.response(200))
        }
        let state = ShareViewCountState(api: api, cacheLifetime: 300)
        let now = Date(timeIntervalSince1970: 1_768_000_000)

        XCTAssertNil(state.count(forPageKey: "share/a/index.html"))
        await state.load(
            accountID: "account", bucketName: "bucket",
            pageKeys: ["share/a/index.html"], token: "token", now: now)
        XCTAssertEqual(state.accessState, .available)
        XCTAssertEqual(state.count(forPageKey: "share/a/index.html"), 0)

        await state.load(
            accountID: "account", bucketName: "bucket",
            pageKeys: ["share/a/index.html"], token: "token",
            now: now.addingTimeInterval(299))
        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testStateShowsSetupOnlyForDefinitePermissionFailure() async {
        let response = #"{"data":null,"errors":[{"message":"authz — not authorized for that account"}]}"#
        let api = R2ViewCountAPI { _ in
            (Data(response.utf8), Self.response(200))
        }
        let state = ShareViewCountState(api: api)

        await state.load(
            accountID: "account", bucketName: "bucket",
            pageKeys: ["share/a/index.html"], token: "token")

        XCTAssertEqual(state.accessState, .permissionRequired)
        XCTAssertNil(state.count(forPageKey: "share/a/index.html"))
    }

    @MainActor
    func testResetClearsCachedCapabilityAndCounts() async {
        let response = #"{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[{"sum":{"requests":2},"dimensions":{"objectName":"share/a/index.html"}}]}]}}}"#
        let api = R2ViewCountAPI { _ in
            (Data(response.utf8), Self.response(200))
        }
        let state = ShareViewCountState(api: api)
        await state.load(
            accountID: "account", bucketName: "bucket",
            pageKeys: ["share/a/index.html"], token: "token")

        state.reset()

        XCTAssertEqual(state.accessState, .unknown)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.countsByPageKey.isEmpty)
        XCTAssertNil(state.lastError)
        XCTAssertNil(state.count(forPageKey: "share/a/index.html"))
    }

    func testAccessProbeUsesOneRowLimit() async throws {
        let recorder = RequestRecorder()
        let response = #"{"data":{"viewer":{"accounts":[{"r2OperationsAdaptiveGroups":[]}]}}}"#
        let api = R2ViewCountAPI { request in
            await recorder.record(request)
            return (Data(response.utf8), Self.response(200))
        }

        try await api.checkAccess(
            accountID: "account", bucketName: "bucket", token: "token")

        let recordedRequest = await recorder.first()
        let request = try XCTUnwrap(recordedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(object["query"] as? String)
        XCTAssertTrue(query.contains("limit: 1"))
        XCTAssertTrue(query.contains("dimensions { actionType }"))
        XCTAssertFalse(query.contains(#"actionType: "GetObject""#))
        XCTAssertFalse(query.contains("actionStatus"))
        XCTAssertFalse(query.contains("objectName_like"))
    }
}
