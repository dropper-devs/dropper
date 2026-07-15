import Foundation
import CryptoKit

/// Resolved configuration snapshot — immutable, safe to hand to R2Client and
/// background tasks. Values come from UserDefaults with the compiled-in
/// defaults (the original hardcoded setup) as fallback.
struct AppConfigSnapshot: Sendable {
    let accountID: String
    let bucket: String
    let prefix: String      // "" means bucket root
    let publicBase: String

    /// Invalid user-edited account IDs never become network destinations.
    /// Callers surface the validation error rather than force-unwrapping a URL.
    var endpoint: URL? {
        guard Self.isValidAccountID(accountID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(accountID.lowercased()).r2.cloudflarestorage.com"
        return components.url
    }

    /// Key for a path inside the configured folder.
    func key(_ relative: String) -> String {
        prefix.isEmpty ? relative : "\(prefix)/\(relative)"
    }

    /// Listing prefix for the configured folder ("" or "folder/").
    var listPrefix: String { prefix.isEmpty ? "" : "\(prefix)/" }

    static func validated(accountID: String, bucket: String,
                          prefix: String, publicBase: String) throws -> Self {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard isValidAccountID(accountID) else {
            throw AppConfigurationError.invalidAccountID
        }

        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBucket(bucket) else {
            throw AppConfigurationError.invalidBucket
        }

        let prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard isValidPrefix(prefix) else {
            throw AppConfigurationError.invalidPrefix
        }

        let publicBase = publicBase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let publicURL = URL(string: publicBase),
              publicURL.scheme?.lowercased() == "https",
              publicURL.host?.isEmpty == false,
              publicURL.user == nil, publicURL.password == nil,
              publicURL.query == nil, publicURL.fragment == nil,
              isValidPublicPath(publicURL.path) else {
            throw AppConfigurationError.invalidPublicURL
        }

        return Self(accountID: accountID, bucket: bucket, prefix: prefix,
                    publicBase: publicURL.absoluteString
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static func isValidAccountID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy(isHexDigit)
    }

    private static func isValidBucket(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...63).contains(bytes.count),
              let first = bytes.first, let last = bytes.last,
              isLowercaseLetterOrDigit(first), isLowercaseLetterOrDigit(last) else {
            return false
        }
        return bytes.allSatisfy { isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "a")...UInt8(ascii: "f"),
             UInt8(ascii: "A")...UInt8(ascii: "F"):
            return true
        default:
            return false
        }
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"):
            return true
        default:
            return false
        }
    }

    private static func isValidPrefix(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              value.rangeOfCharacter(
                from: CharacterSet(charactersIn: "?#%\\")) == nil
        else { return false }
        guard !value.isEmpty else { return true }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isValidPublicPath(_ path: String) -> Bool {
        guard !path.contains("//"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        return path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

enum AppConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidAccountID
    case invalidBucket
    case invalidPrefix
    case invalidPublicURL

    var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            return "Enter the 32-character hexadecimal Cloudflare account ID."
        case .invalidBucket:
            return "Bucket names must be 3–63 lowercase letters, numbers, or hyphens, and cannot begin or end with a hyphen."
        case .invalidPrefix:
            return "The upload folder cannot contain empty, dot-directory, or URL-delimiter path components."
        case .invalidPublicURL:
            return "Enter a valid HTTPS public URL without credentials, a query, or a fragment."
        }
    }
}

/// Thread-safe (nonisolated) storage helpers used by the application.
enum ConfigStore {
    static let keys = (account: "accountID", bucket: "bucket", prefix: "prefix",
                       publicBase: "publicBase", tokenID: "cfTokenID",
                       convertHEIC: "convertHEIC", convertAIFF: "convertAIFF",
                       convertMOV: "convertMOV", imageGallery: "imageGallery",
                       notchVisible: "DropPillVisible")

    /// Conversion toggles default ON: the source formats don't play in most
    /// non-Apple browsers (HEIC images; AIFF audio in Chrome/Firefox; HEVC/
    /// ProRes video), and each conversion is a lossless repack where possible.
    static func convertHEIC() -> Bool { boolSetting(keys.convertHEIC) }
    static func convertAIFF() -> Bool { boolSetting(keys.convertAIFF) }
    static func convertMOV() -> Bool { boolSetting(keys.convertMOV) }
    static func imageGallery() -> Bool {
        boolSetting(keys.imageGallery, default: false)
    }
    static func notchVisible() -> Bool {
        boolSetting(keys.notchVisible, default: true)
    }

    /// Reads a user toggle, returning its fallback until explicitly set.
    private static func boolSetting(_ key: String, default fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static func snapshot() -> AppConfigSnapshot {
        let d = UserDefaults.standard
        return AppConfigSnapshot(
            accountID: d.string(forKey: keys.account) ?? Config.defaultAccountID,
            bucket: d.string(forKey: keys.bucket) ?? Config.bucket,
            prefix: d.string(forKey: keys.prefix) ?? Config.keyPrefix,
            publicBase: d.string(forKey: keys.publicBase) ?? Config.publicBase)
    }

    static func validatedSnapshot() throws -> AppConfigSnapshot {
        let current = snapshot()
        return try AppConfigSnapshot.validated(
            accountID: current.accountID, bucket: current.bucket,
            prefix: current.prefix, publicBase: current.publicBase)
    }

    /// S3 credentials derived from the Keychain token (pasted once) — the
    /// only credential source. DROPPER_NO_KEYCHAIN=1 skips the Keychain —
    /// reading it can block on a user authorization prompt, which deadlocks
    /// headless/test invocations.
    static func resolveCredentials() -> AWSCredentials? {
        guard ProcessInfo.processInfo.environment["DROPPER_NO_KEYCHAIN"] != "1",
              let token = Keychain.loadToken(),
              let tokenID = UserDefaults.standard.string(forKey: keys.tokenID)
        else { return nil }
        return AWSCredentials(accessKeyId: tokenID,
                              secretAccessKey: sha256Hex(token))
    }

    /// The R2 S3 secret is defined as the SHA-256 of the API token value.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).hexEncoded
    }

    /// Save the secret before its matching public token ID. A Keychain failure
    /// leaves the previously working credential pair untouched.
    static func savePrimaryCredentials(
        token: String,
        tokenID: String,
        defaults: UserDefaults = .standard,
        keychainSave: (String) -> Bool = Keychain.saveToken
    ) throws {
        guard keychainSave(token) else { throw CredentialPersistenceError.keychain }
        defaults.set(tokenID, forKey: keys.tokenID)
    }
}

enum CredentialPersistenceError: LocalizedError, Sendable {
    case keychain

    var errorDescription: String? {
        "Dropper couldn't save the token securely in your Keychain."
    }
}
