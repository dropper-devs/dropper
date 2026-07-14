import Foundation

struct OnboardingConfiguration {
    let token: String
    let tokenID: String
    let accountID: String
    let domain: String
    let bucket: String

    var snapshot: AppConfigSnapshot {
        AppConfigSnapshot(
            accountID: accountID,
            bucket: bucket,
            prefix: "",
            publicBase: "https://\(domain)")
    }

    var credentials: AWSCredentials {
        AWSCredentials(
            accessKeyId: tokenID,
            secretAccessKey: ConfigStore.sha256Hex(token))
    }
}

struct OnboardingReadinessProbe {
    let run: () async throws -> Void
    let finish: () -> Void
}

enum OnboardingPersistenceError: LocalizedError {
    case keychain

    var errorDescription: String? {
        "Dropper couldn't save the token securely in your Keychain. "
            + "Please try setup again."
    }
}

struct OnboardingDependencies {
    let verifyToken: (String) async throws -> String
    let accounts: (String) async throws -> [CloudflareAPI.Account]
    let createBucket: (String, String, String) async throws -> Void
    let enablePublicURL: (String, String, String) async throws -> String
    let makeReadinessProbe: (OnboardingConfiguration) -> OnboardingReadinessProbe
    let persist: (OnboardingConfiguration) throws -> Void

    @MainActor static let live = OnboardingDependencies(
        verifyToken: { try await CloudflareAPI.verifyToken($0) },
        accounts: { try await CloudflareAPI.accounts($0) },
        createBucket: { token, accountID, bucket in
            try await CloudflareAPI.createBucket(
                token: token, accountID: accountID, name: bucket)
        },
        enablePublicURL: { token, accountID, bucket in
            try await CloudflareAPI.enablePublicURL(
                token: token, accountID: accountID, bucket: bucket)
        },
        makeReadinessProbe: { configuration in
            let client = R2Client(
                credentials: configuration.credentials,
                config: configuration.snapshot)
            return OnboardingReadinessProbe(
                run: { try await client.probeReadiness() },
                finish: { client.finishTasksAndInvalidate() })
        },
        persist: { configuration in
            guard Keychain.saveToken(configuration.token) else {
                throw OnboardingPersistenceError.keychain
            }
            let defaults = UserDefaults.standard
            defaults.set(configuration.tokenID, forKey: ConfigStore.keys.tokenID)
            defaults.set(configuration.accountID, forKey: ConfigStore.keys.account)
            defaults.set(configuration.bucket, forKey: ConfigStore.keys.bucket)
            defaults.set("", forKey: ConfigStore.keys.prefix)
            defaults.set(configuration.snapshot.publicBase,
                         forKey: ConfigStore.keys.publicBase)
        })
}

/// The four wizard panels, in order. The raw values index the bundled
/// `OnboardingArt` illustrations and drive the step dots.
enum Step: Int, CaseIterable {
    case welcome, account, storage, token

    var previous: Step { Step(rawValue: rawValue - 1) ?? self }
}

/// First-run wizard: walks a credential-less user from "no Cloudflare" to a
/// fully configured Dropper with one pasted token. Everything after the paste
/// is automated (verify, derive credentials, create bucket, enable public URL).
@MainActor
final class OnboardingModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case waitingForStorage
        case storageNotReady
        case failed(String)
        case done
    }

    @Published var step: Step = .welcome
    @Published var token = ""
    @Published var phase: Phase = .idle
    @Published var progress: [String] = []
    @Published private(set) var readinessStatus: String?
    @Published private(set) var failureHelp: String?

    static let bucketName = "dropper"

    private let dependencies: OnboardingDependencies
    private let readinessWaiter: R2ReadinessWaiter
    private var pendingConfiguration: OnboardingConfiguration?
    private var setupTask: Task<Void, Never>?

    init(
        dependencies: OnboardingDependencies? = nil,
        readinessWaiter: R2ReadinessWaiter = R2ReadinessWaiter()
    ) {
        self.dependencies = dependencies ?? .live
        self.readinessWaiter = readinessWaiter
    }

    var isBusy: Bool {
        phase == .running || phase == .waitingForStorage
    }

    var canEditToken: Bool {
        !isBusy && phase != .storageNotReady && phase != .done
    }

    var canSubmit: Bool {
        guard !isBusy else { return false }
        if phase == .storageNotReady { return pendingConfiguration != nil }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phase != .done
    }

    var submitTitle: String {
        switch phase {
        case .storageNotReady: "Try Connection Again"
        case .failed: "Try Setup Again"
        default: "Set Up"
        }
    }

    func submit(onConfigured: @escaping () -> Void) {
        if phase == .storageNotReady {
            retryConnection(onConfigured: onConfigured)
        } else {
            connect(onConfigured: onConfigured)
        }
    }

    func connect(onConfigured: @escaping () -> Void) {
        let pasted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, !isBusy, setupTask == nil else { return }
        pendingConfiguration = nil
        phase = .running
        progress = []
        readinessStatus = nil
        failureHelp = nil

        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.setupTask = nil }
            do {
                progress.append("Verifying token…")
                let tokenID = try await dependencies.verifyToken(pasted)
                try Task.checkCancellation()

                progress.append("Finding your account…")
                let accounts = try await dependencies.accounts(pasted)
                try Task.checkCancellation()
                guard let account = accounts.first else {
                    throw CloudflareAPI.APIFailure.message(
                        "The token can't see any account — create it as an "
                        + "Account API Token with Admin Read & Write.")
                }

                progress.append("Creating the \u{201C}\(Self.bucketName)\u{201D} bucket…")
                try await dependencies.createBucket(
                    pasted, account.id, Self.bucketName)
                try Task.checkCancellation()

                progress.append("Enabling the public URL…")
                let domain = try await dependencies.enablePublicURL(
                    pasted, account.id, Self.bucketName)
                try Task.checkCancellation()

                let pending = OnboardingConfiguration(
                    token: pasted, tokenID: tokenID,
                    accountID: account.id, domain: domain,
                    bucket: Self.bucketName)
                pendingConfiguration = pending
                guard try await confirmReadiness(pending) else { return }
                try Task.checkCancellation()
                try finish(pending, onConfigured: onConfigured)
            } catch {
                handleSetupError(error)
            }
        }
    }

    func cancel() {
        setupTask?.cancel()
        token = ""
        pendingConfiguration = nil
        readinessStatus = nil
        failureHelp = nil
        phase = .idle
    }

    /// Test seam for awaiting the unstructured task without exposing it.
    func waitForCurrentOperation() async {
        let task = setupTask
        await task?.value
    }

    private func retryConnection(onConfigured: @escaping () -> Void) {
        guard let pending = pendingConfiguration,
              phase == .storageNotReady, setupTask == nil else { return }

        setupTask = Task { [weak self] in
            guard let self else { return }
            defer { self.setupTask = nil }
            do {
                guard try await confirmReadiness(pending) else { return }
                try Task.checkCancellation()
                try finish(pending, onConfigured: onConfigured)
            } catch {
                handleSetupError(error)
            }
        }
    }

    /// Shared failure handling for `connect` and `retryConnection`: cancellation
    /// resets silently to `.idle`, otherwise the pending configuration is cleared
    /// and the error surfaces with contextual help.
    private func handleSetupError(_ error: Error) {
        if Task.isCancelled || error.isCancellation {
            phase = .idle
            return
        }
        pendingConfiguration = nil
        readinessStatus = nil
        failureHelp = Self.help(for: error)
        phase = .failed(error.localizedDescription)
    }

    /// Returns false after the bounded grace period so the same prepared
    /// configuration can be retried without recreating the bucket or token.
    private func confirmReadiness(_ pending: OnboardingConfiguration) async throws -> Bool {
        phase = .waitingForStorage
        readinessStatus = "Confirming your secure storage connection…"
        let probe = dependencies.makeReadinessProbe(pending)
        defer { probe.finish() }

        do {
            try await readinessWaiter.wait(
                probe: probe.run,
                onRetry: { [weak self] _, _ in
                    await MainActor.run {
                        self?.readinessStatus =
                            "Cloudflare is finishing your secure storage setup…"
                    }
                })
            readinessStatus = nil
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            readinessStatus = nil
            logReadinessFailure(error, host: pending.snapshot.endpoint?.host)
            guard R2ReadinessWaiter.isRetryable(error) else { throw error }
            phase = .storageNotReady
            return false
        }
    }

    private func finish(
        _ pending: OnboardingConfiguration,
        onConfigured: @escaping () -> Void
    ) throws {
        progress.append("Saving configuration…")
        try dependencies.persist(pending)

        pendingConfiguration = nil
        progress.append("Done — you're set.")
        phase = .done
        token = ""
        onConfigured()
    }

    private func logReadinessFailure(_ error: Error, host: String?) {
        var codes: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let candidate = current, depth < 8 {
            codes.append("\(candidate.domain):\(candidate.code)")
            if let sslCode = candidate.userInfo[
                "_kCFNetworkCFStreamSSLErrorOriginalValue"
            ] {
                codes.append("TLS:\(sslCode)")
            }
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if case let R2Client.R2Error.badStatus(status, _) = error {
            codes.append("HTTP:\(status)")
        }
        let message = "Dropper setup: R2 readiness failed "
            + "host=\(host ?? "unknown") codes=\(codes.joined(separator: " <- "))"
        NSLog("%@", message)
    }

    private static func help(for error: Error) -> String {
        if error is OnboardingPersistenceError {
            return "Make sure Dropper is allowed to use your login Keychain, then try again."
        }
        if R2ReadinessWaiter.urlErrorCode(in: error) != nil {
            return "Check your internet connection, VPN or security software, "
                + "and make sure Date & Time is set automatically."
        }
        return "Make sure R2 is enabled and the token uses Admin Read & Write, "
            + "then try again."
    }
}
