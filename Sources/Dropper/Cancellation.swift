import Foundation

extension Error {
    /// Cancellation arrives two ways: `CancellationError` from `Task` checks,
    /// and `URLError.cancelled` from a `URLSession` task torn down mid-flight
    /// (sometimes wrapped in one or more `NSError`s). The single predicate
    /// every cancellation check goes through.
    var isCancellation: Bool {
        self is CancellationError || urlErrorCode == .cancelled
    }

    /// Foundation sometimes wraps its URL error in one or more `NSError`s.
    /// Walk that chain (bounded) so a wrapped code (e.g. -1200) is still seen.
    var urlErrorCode: URLError.Code? {
        var current: NSError? = self as NSError
        var depth = 0
        while let candidate = current, depth < 8 {
            if candidate.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: candidate.code)
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}
