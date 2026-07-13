import Foundation

/// The S3 credential pair SigV4 signs with. Always derived from the pasted
/// Cloudflare API token (see `ConfigStore.resolveCredentials`) — Dropper
/// never reads credentials from anywhere else.
struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String
}
