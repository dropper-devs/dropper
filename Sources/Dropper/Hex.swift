import Foundation

extension Sequence where Element == UInt8 {
    /// Lowercase hex encoding of the bytes. The single hex encoder shared by
    /// share IDs, CSP nonces, SigV4 signatures, and the R2 secret derivation.
    var hexEncoded: String {
        var result = ""
        result.reserveCapacity(underestimatedCount * 2)
        for byte in self { result += String(format: "%02x", byte) }
        return result
    }
}
