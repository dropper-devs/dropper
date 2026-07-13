import Foundation
import CryptoKit

/// AWS Signature v4 signing for S3-compatible requests (R2, region "auto").
/// Uses UNSIGNED-PAYLOAD so large files never need to be hashed locally.
enum SigV4 {
    static func sign(request: inout URLRequest, credentials: AWSCredentials,
                     region: String = "auto", service: String = "s3", now: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }

        let iso = isoTimestamp(now)          // 20260711T120000Z
        let date = String(iso.prefix(8))     // 20260711
        let payloadHash = "UNSIGNED-PAYLOAD"

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(iso, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical headers: host + x-amz-* + content-type if present, sorted.
        var headers: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", iso),
        ]
        for name in ["Content-Type", "Cache-Control", "Content-Disposition"] {
            if let value = request.value(forHTTPHeaderField: name) {
                headers.append((name.lowercased(), value.trimmingCharacters(in: .whitespaces)))
            }
        }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI(url),
            canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(date)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            iso,
            scope,
            hexSHA256(canonicalRequest),
        ].joined(separator: "\n")

        // Signing key: HMAC chain over date/region/service.
        var key = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), Data(date.utf8))
        key = hmac(key, Data(region.utf8))
        key = hmac(key, Data(service.utf8))
        key = hmac(key, Data("aws4_request".utf8))
        let signature = hmac(key, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
    }

    /// RFC 3986 unreserved characters — the only bytes SigV4 leaves bare.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// The canonical query encoding (sorted, unreserved-only) from DECODED
    /// pairs. Request builders must put this exact string on the wire so the
    /// signature always matches — there is deliberately no second encoder.
    static func canonicalQueryString(_ pairs: [(String, String)]) -> String {
        pairs
            .map { (percentEncode($0.0), percentEncode($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// Percent-encode each path segment S3-style (RFC 3986, '/' preserved).
    static func canonicalURI(_ url: URL) -> String {
        // URL.path strips trailing slashes; URLComponents preserves them —
        // and folder-marker keys must sign with the slash they're sent with.
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
            ?? url.path
        let path = rawPath.isEmpty ? "/" : rawPath
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            percentEncode(String(segment))
        }.joined(separator: "/")
    }

    private static func canonicalQuery(_ url: URL) -> String {
        // queryItems hands back decoded names/values — exactly what
        // canonicalQueryString expects.
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty else { return "" }
        return canonicalQueryString(items.map { ($0.name, $0.value ?? "") })
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    private static func hexSHA256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
