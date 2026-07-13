import Foundation

struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String

    /// Minimal ~/.aws/credentials INI parser — just enough to pull one profile.
    static func load(profile: String) -> AWSCredentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/credentials")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }

        var current = ""
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard current == profile, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        guard let id = values["aws_access_key_id"], let secret = values["aws_secret_access_key"],
              !id.isEmpty, !secret.isEmpty else { return nil }
        return AWSCredentials(accessKeyId: id, secretAccessKey: secret)
    }
}
