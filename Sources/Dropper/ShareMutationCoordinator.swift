import Foundation

/// Explicit keyed locking is needed because actor methods are reentrant at
/// every network await. Different shares remain independent.
@MainActor
final class ShareMutationCoordinator {
    static let shared = ShareMutationCoordinator()

    private var locked = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func perform<T>(scope: String,
                    operation: () async throws -> T) async throws -> T {
        await acquire(scope)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            release(scope)
            return result
        } catch {
            release(scope)
            throw error
        }
    }

    private func acquire(_ scope: String) async {
        guard locked.contains(scope) else {
            locked.insert(scope)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[scope, default: []].append(continuation)
        }
    }

    private func release(_ scope: String) {
        if var queued = waiters[scope], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[scope] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            locked.remove(scope)
        }
    }
}
