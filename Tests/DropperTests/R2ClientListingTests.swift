import Foundation
import XCTest
@testable import Dropper

final class R2ClientListingTests: XCTestCase {
    private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

        nonisolated(unsafe) static var handler: Handler?
        private static let lock = NSLock()

        static func setHandler(_ handler: Handler?) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (data, response) = try handler(request)
                client?.urlProtocol(self, didReceive: response,
                                    cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    override func tearDown() {
        URLProtocolStub.setHandler(nil)
        super.tearDown()
    }

    func testListContinuesPastFormerTenPageCap() async throws {
        URLProtocolStub.setHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let token = items?.first(where: { $0.name == "continuation-token" })?.value
            let page = token.flatMap(Int.init) ?? 0
            let truncated = page < 11
            let next = truncated
                ? "<NextContinuationToken>\(page + 1)</NextContinuationToken>" : ""
            let xml = """
                <ListBucketResult>
                  <Contents><Key>share/item-\(page)</Key><Size>\(page)</Size></Contents>
                  <IsTruncated>\(truncated)</IsTruncated>\(next)
                </ListBucketResult>
                """
            return (Data(xml.utf8), Self.response(for: url))
        }
        let client = makeClient()
        defer { client.finishTasksAndInvalidate() }

        let objects = try await client.list(prefix: "share/")

        XCTAssertEqual(objects.count, 12)
        XCTAssertEqual(objects.last?.key, "share/item-11")
    }

    func testListFoldersFollowsContinuationTokensAndDeduplicates() async throws {
        URLProtocolStub.setHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let token = items?.first(where: { $0.name == "continuation-token" })?.value
            let second = token == "next"
            let xml = second
                ? """
                  <ListBucketResult>
                    <CommonPrefixes><Prefix>share/bravo/</Prefix></CommonPrefixes>
                    <CommonPrefixes><Prefix>share/charlie/</Prefix></CommonPrefixes>
                    <IsTruncated>false</IsTruncated>
                  </ListBucketResult>
                  """
                : """
                  <ListBucketResult>
                    <CommonPrefixes><Prefix>share/alpha/</Prefix></CommonPrefixes>
                    <CommonPrefixes><Prefix>share/bravo/</Prefix></CommonPrefixes>
                    <IsTruncated>true</IsTruncated>
                    <NextContinuationToken>next</NextContinuationToken>
                  </ListBucketResult>
                  """
            return (Data(xml.utf8), Self.response(for: url))
        }
        let client = makeClient()
        defer { client.finishTasksAndInvalidate() }

        let folders = try await client.listFolders(prefix: "share/")

        XCTAssertEqual(folders, ["alpha", "bravo", "charlie"])
    }

    func testMalformedListingXMLIsSurfaced() async {
        URLProtocolStub.setHandler { request in
            let url = request.url ?? URL(string: "https://example.test")!
            return (Data("<ListBucketResult><Contents>".utf8), Self.response(for: url))
        }
        let client = makeClient()
        defer { client.finishTasksAndInvalidate() }

        do {
            _ = try await client.list(prefix: "share/")
            XCTFail("Expected malformed XML to fail")
        } catch let error as R2Client.R2Error {
            guard case .invalidListResponse = error else {
                return XCTFail("Unexpected R2 error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTruncatedListingWithoutNewTokenIsSurfaced() async {
        URLProtocolStub.setHandler { request in
            let url = request.url ?? URL(string: "https://example.test")!
            let xml = "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"
            return (Data(xml.utf8), Self.response(for: url))
        }
        let client = makeClient()
        defer { client.finishTasksAndInvalidate() }

        do {
            _ = try await client.list(prefix: "share/")
            XCTFail("Expected a missing continuation token to fail")
        } catch let error as R2Client.R2Error {
            guard case .invalidListResponse = error else {
                return XCTFail("Unexpected R2 error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> R2Client {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [URLProtocolStub.self]
        return R2Client(
            credentials: AWSCredentials(
                accessKeyId: "token-id", secretAccessKey: "derived-secret"),
            config: AppConfigSnapshot(
                accountID: "0123456789abcdef0123456789abcdef",
                bucket: "dropper", prefix: "share",
                publicBase: "https://example.test"),
            sessionConfiguration: sessionConfiguration)
    }

    private static func response(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
