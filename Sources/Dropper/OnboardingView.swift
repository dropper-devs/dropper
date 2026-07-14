import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onConfigured: () -> Void
    let onFinished: () -> Void

    private var accent: Color { Brand.indigo }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingArt(step: model.step.rawValue)
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
        .background(Brand.backdrop)
        .preferredColorScheme(.dark)
        .onDisappear { model.cancel() }
    }

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == model.step ? accent : Color.white.opacity(0.18))
                    .frame(width: step == model.step ? 22 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.step)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome: welcome
        case .account: account
        case .storage: enableR2
        case .token: tokenStep
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
            if model.step != .welcome {
                Button("Back") { model.step = model.step.previous }
                    .disabled(model.isBusy)
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get Started") { model.step = .account }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .keyboardShortcut(.defaultAction)
            case .account:
                Button("I Have an Account") { model.step = .storage }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            case .storage:
                Button("R2 Is Enabled") { model.step = .token }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            case .token:
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
