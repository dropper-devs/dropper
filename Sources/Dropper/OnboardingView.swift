import SwiftUI
import AppKit

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

    @Published var step = 0
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
                if Task.isCancelled || R2ReadinessWaiter.isCancellation(error) {
                    phase = .idle
                    return
                }
                pendingConfiguration = nil
                readinessStatus = nil
                failureHelp = Self.help(for: error)
                phase = .failed(error.localizedDescription)
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
                if Task.isCancelled || R2ReadinessWaiter.isCancellation(error) {
                    phase = .idle
                    return
                }
                pendingConfiguration = nil
                readinessStatus = nil
                failureHelp = Self.help(for: error)
                phase = .failed(error.localizedDescription)
            }
        }
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
            logReadinessFailure(error, host: pending.snapshot.endpoint.host)
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

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onConfigured: () -> Void
    let onFinished: () -> Void

    private var accent: Color { OnboardingArt.indigo }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingArt(step: model.step)
                .frame(height: 168)

            stepDots
                .padding(.top, 14)

            ScrollView(.vertical) {
                stepBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
            }

            // Dynamic progress and error copy scroll above this footer, so
            // the navigation button can never be pushed outside the window.
            footer
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .frame(minWidth: 500, idealWidth: 520, maxWidth: .infinity,
               minHeight: 500, idealHeight: 700, maxHeight: .infinity)
        .background(Color(red: 0.078, green: 0.082, blue: 0.102))
        .preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index == model.step ? accent : Color.white.opacity(0.18))
                    .frame(width: index == model.step ? 22 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case 0: welcome
        case 1: account
        case 2: enableR2
        default: tokenStep
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop a file. Get a link.")
                    .font(.system(size: 26, weight: .bold))
                Text("Share it beautifully.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text("Dropper lives in your menu bar and turns anything you drop "
                 + "into a beautiful share page — stored in **your own** "
                 + "Cloudflare account. Your bucket, your account, your data.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                bullet("person.crop.circle", "A free Cloudflare account.")
                bullet("creditcard",
                       "A payment method on file — **Cloudflare requires this "
                       + "to enable R2 storage**, not us. The free tier "
                       + "provides 10 GB at $0, and Dropper typically stays "
                       + "well inside it.")
                bullet("clock", "About three minutes.")
            }
            .padding(.top, 2)
        }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Cloudflare account")
                .font(.system(size: 24, weight: .bold))
            Text("Create a free account, or sign in if you already have one.")
                .foregroundStyle(.secondary)
            linkButton("Open Cloudflare Sign-Up",
                       url: "https://dash.cloudflare.com/sign-up")
            Button("I already have an account — open sign-in") {
                open("https://dash.cloudflare.com/login")
            }
            .buttonStyle(.link)
            .tint(accent)
        }
    }

    private var enableR2: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enable R2 storage")
                .font(.system(size: 24, weight: .bold))
            Text("Open R2 in your dashboard. The first visit asks for a "
                 + "payment method and an enable click — Cloudflare's "
                 + "requirement for its free tier.")
                .foregroundStyle(.secondary)
            linkButton("Open R2 in the Dashboard",
                       url: "https://dash.cloudflare.com/?to=/:account/r2")
            Text("Come back here once R2 shows its overview page.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private var tokenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One token — Dropper does the rest")
                .font(.system(size: 24, weight: .bold))
            Text("Paste an API token and Dropper creates your "
                 + "\u{201C}\(OnboardingModel.bucketName)\u{201D} bucket, "
                 + "enables its public URL, and configures itself.")
                .foregroundStyle(.secondary)
            linkButton("Open the R2 Token Page",
                       url: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens")
            VStack(alignment: .leading, spacing: 8) {
                bullet("1.circle", "Click **Create API Token**.")
                bullet("2.circle", "Permissions: **Admin Read & Write** "
                       + "(account-wide — a bucket-scoped token can't create "
                       + "the bucket).")
                bullet("3.circle", "Copy the **Token value**, paste it below.")
            }

            HStack {
                SecureField("Paste your API token", text: $model.token)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canEditToken)
                    .onSubmit { model.submit(onConfigured: onConfigured) }
                Button(model.submitTitle) {
                    model.submit(onConfigured: onConfigured)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
            }
            .padding(.top, 2)

            ForEach(model.progress, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let status = model.readinessStatus {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if model.phase == .storageNotReady {
                Label("Your storage was created, but Cloudflare's secure "
                      + "connection isn't ready yet.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text("Wait a minute, then try the connection again. If it "
                     + "keeps happening, check your VPN or security software "
                     + "and make sure Date & Time is set automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                if let help = model.failureHelp {
                    Text(help)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if model.phase == .done {
                Label("Dropper is ready — drop a file on the menu bar icon.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.step > 0 {
                Button("Back") { model.step -= 1 }
                    .disabled(model.isBusy)
            }
            Spacer()
            switch model.step {
            case 0:
                Button("Get Started") { model.step = 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.defaultAction)
            case 1:
                Button("I Have an Account") { model.step = 2 }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            case 2:
                Button("R2 Is Enabled") { model.step = 3 }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            default:
                if model.phase == .done {
                    Button("Finish") { onFinished() }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.isBusy ? "Cancel" : "Close") {
                        if model.isBusy { model.cancel() }
                        onFinished()
                    }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    // MARK: - Bits

    private func bullet(_ icon: String, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 18)
                .padding(.top, 1)
            Text(.init(markdown))
        }
        .font(.callout)
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button {
            open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.square")
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(accent)
    }

    private func open(_ url: String) {
        guard let target = URL(string: url) else { return }
        // Failures surface as a notification, never a modal alert — a modal
        // can appear behind other windows in an accessory app and silently
        // block ALL interaction (drops, the dropdown) until dismissed.
        NSWorkspace.shared.open(
            target, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                copyToClipboard(url)
                postNotification(
                    title: "Couldn't open the browser",
                    body: "The link was copied instead — paste it into any browser.")
            }
        }
    }
}
