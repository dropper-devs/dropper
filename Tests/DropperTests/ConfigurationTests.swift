import Foundation
import XCTest
@testable import Dropper

final class ConfigurationTests: XCTestCase {
    func testValidationNormalizesSafeConfiguration() throws {
        let config = try AppConfigSnapshot.validated(
            accountID: " 0123456789ABCDEF0123456789ABCDEF ",
            bucket: " dropper-pages ",
            prefix: "/team/shares/",
            publicBase: " https://files.example.test/share/ ")

        XCTAssertEqual(config.accountID, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(config.bucket, "dropper-pages")
        XCTAssertEqual(config.prefix, "team/shares")
        XCTAssertEqual(config.publicBase, "https://files.example.test/share")
        XCTAssertEqual(
            config.endpoint?.absoluteString,
            "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com")
    }

    func testValidationRejectsUnsafeOrMalformedConfiguration() {
        let validAccount = "0123456789abcdef0123456789abcdef"

        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: "not/an/account", bucket: "dropper",
            prefix: "share", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "Invalid_Bucket",
            prefix: "share", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "share/../private", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "share/bad\nname", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "team?draft/shares", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "team#draft/shares", publicBase: "https://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "share", publicBase: "http://example.test"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "share", publicBase: "https://user@example.test/?query=yes"))
        XCTAssertThrowsError(try AppConfigSnapshot.validated(
            accountID: validAccount, bucket: "dropper",
            prefix: "share", publicBase: "https://example.test/%2e%2e/private"))
    }

    func testInvalidAccountCannotCreateEndpointOrReadinessRequest() {
        let config = AppConfigSnapshot(
            accountID: "bad/account", bucket: "dropper",
            prefix: "share", publicBase: "https://example.test")
        XCTAssertNil(config.endpoint)

        let client = R2Client(
            credentials: AWSCredentials(accessKeyId: "id", secretAccessKey: "secret"),
            config: config)
        defer { client.finishTasksAndInvalidate() }
        XCTAssertThrowsError(try client.readinessRequest())
    }

    func testCredentialSaveDoesNotReplaceTokenIDWhenKeychainFails() throws {
        let suiteName = "ConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("working-token-id", forKey: ConfigStore.keys.tokenID)

        XCTAssertThrowsError(try ConfigStore.savePrimaryCredentials(
            token: "replacement", tokenID: "replacement-token-id",
            defaults: defaults, keychainSave: { _ in false }))
        XCTAssertEqual(
            defaults.string(forKey: ConfigStore.keys.tokenID),
            "working-token-id")
    }
}
