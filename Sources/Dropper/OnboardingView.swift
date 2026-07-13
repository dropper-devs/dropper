import SwiftUI
import AppKit
import UserNotifications

/// First-run wizard: walks a credential-less user from "no Cloudflare" to a
/// fully configured Dropper with one pasted token. Everything after the paste
/// is automated (verify, derive credentials, create bucket, enable public URL).
@MainActor
final class OnboardingModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case failed(String)
        case done
    }

    @Published var step = 0
    @Published var token = ""
    @Published var phase: Phase = .idle
    @Published var progress: [String] = []

    static let bucketName = "dropper"

    func connect(onConfigured: @escaping () -> Void) {
        let pasted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, phase != .running else { return }
        phase = .running
        progress = []

        Task {
            do {
                progress.append("Verifying token…")
                let tokenID = try await CloudflareAPI.verifyToken(pasted)

                progress.append("Finding your account…")
                let accounts = try await CloudflareAPI.accounts(pasted)
                guard let account = accounts.first else {
                    throw CloudflareAPI.APIFailure.message(
                        "The token can't see any account — create it as an "
                        + "Account API Token with Admin Read & Write.")
                }

                progress.append("Creating the \u{201C}\(Self.bucketName)\u{201D} bucket…")
                try await CloudflareAPI.createBucket(
                    token: pasted, accountID: account.id, name: Self.bucketName)

                progress.append("Enabling the public URL…")
                let domain = try await CloudflareAPI.enablePublicURL(
                    token: pasted, accountID: account.id, bucket: Self.bucketName)

                progress.append("Saving configuration…")
                Keychain.saveToken(pasted)
                let defaults = UserDefaults.standard
                defaults.set(tokenID, forKey: ConfigStore.keys.tokenID)
                defaults.set(account.id, forKey: ConfigStore.keys.account)
                defaults.set(Self.bucketName, forKey: ConfigStore.keys.bucket)
                defaults.set("", forKey: ConfigStore.keys.prefix)  // bucket root
                defaults.set("https://\(domain)", forKey: ConfigStore.keys.publicBase)

                progress.append("Done — you're set.")
                phase = .done
                token = ""
                onConfigured()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
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
            Text("Drop a file. Get a link.")
                .font(.system(size: 26, weight: .bold))
            Text("Dropper lives in your menu bar and turns anything you drop "
                 + "into a beautiful share page — stored in **your own** "
                 + "Cloudflare account. Your bucket, your domain, your data.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                bullet("person.crop.circle", "A free Cloudflare account.")
                bullet("creditcard",
                       "A payment method on file — **Cloudflare requires this "
                       + "to enable R2 storage**, not us. The free tier is "
                       + "real: 10 GB at $0, and Dropper typically stays "
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
                 + "requirement for the (genuinely free) free tier.")
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
                    .onSubmit { model.connect(onConfigured: onConfigured) }
                Button("Set Up") { model.connect(onConfigured: onConfigured) }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.token.isEmpty || model.phase == .running)
            }
            .padding(.top, 2)

            ForEach(model.progress, id: \.self) { line in
                Label(line, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if case let .failed(message) = model.phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                Text("If R2 isn't enabled yet, finish the previous step "
                     + "first. If the token was refused, re-create it with "
                     + "Admin Read & Write permissions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                    .disabled(model.phase == .running)
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
                    Button("Close") { onFinished() }
                        .buttonStyle(.bordered)
                        .disabled(model.phase == .running)
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                let content = UNMutableNotificationContent()
                content.title = "Couldn't open the browser"
                content.body = "The link was copied instead — paste it into any browser."
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString,
                                          content: content, trigger: nil)) { _ in }
            }
        }
    }
}
