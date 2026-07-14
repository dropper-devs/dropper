import SwiftUI
import AppKit

/// Settings: paste a Cloudflare API token once, pick the bucket/folder, done.
struct SettingsView: View {
    @ObservedObject var viewCounts: ShareViewCountState

    // Editable copies; persisted only on Save.
    @State private var token = ""
    @State private var tokenStatus: String?
    @State private var hasStoredToken = Keychain.loadToken() != nil
    @State private var accountID: String
    @State private var bucket: String
    @State private var prefix: String
    @State private var publicBase: String

    // Folder browser
    @State private var browsing = false
    @State private var browsePath = ""       // "" = bucket root
    @State private var folders: [String] = []
    @State private var browseError: String?
    @State private var newFolderName = ""
    @State private var convertHEIC = ConfigStore.convertHEIC()
    @State private var convertAIFF = ConfigStore.convertAIFF()
    @State private var convertMOV = ConfigStore.convertMOV()
    @State private var hasStoredAnalyticsToken = Keychain.loadAnalyticsToken() != nil
    @State private var showingViewCountSetup = false

    let onSave: () -> Void
    let onViewCountsChanged: () -> Void
    let onClose: () -> Void

    init(viewCounts: ShareViewCountState,
         onSave: @escaping () -> Void,
         onViewCountsChanged: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        let snapshot = ConfigStore.snapshot()
        _viewCounts = ObservedObject(wrappedValue: viewCounts)
        _accountID = State(initialValue: snapshot.accountID)
        _bucket = State(initialValue: snapshot.bucket)
        _prefix = State(initialValue: snapshot.prefix)
        _publicBase = State(initialValue: snapshot.publicBase)
        self.onSave = onSave
        self.onViewCountsChanged = onViewCountsChanged
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tokenSection
                    Divider()
                    fieldsSection
                    Divider()
                    viewCountsSection
                    Divider()
                    conversionsSection
                    Divider()
                    folderSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 460, minHeight: 0)
        .sheet(isPresented: $showingViewCountSetup) {
            ViewCountSetupSheet(
                accountID: accountID.trimmingCharacters(in: .whitespaces),
                bucketName: bucket.trimmingCharacters(in: .whitespaces),
                onEnabled: viewCountsEnabled)
        }
        .task {
            await checkViewCountAccess()
        }
    }

    // MARK: - Token

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cloudflare API token").font(.headline)
            Text(hasStoredToken
                 ? "A token is stored in the Keychain. Paste a new one to replace it."
                 : "Paste an R2 API token — the S3 credentials are derived from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("Token", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") { connect() }
                    .disabled(token.isEmpty)
            }
            if let tokenStatus {
                Text(tokenStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        tokenStatus = "Verifying…"
        let pasted = token
        Task {
            do {
                let tokenID = try await CloudflareAPI.verifyToken(pasted)
                Keychain.saveToken(pasted)
                UserDefaults.standard.set(tokenID, forKey: ConfigStore.keys.tokenID)
                hasStoredToken = true
                var status = "Token verified — credentials derived and stored."
                // Best effort: fill the account ID from the token's scope.
                if let accounts = try? await CloudflareAPI.accounts(pasted),
                   let first = accounts.first {
                    accountID = first.id
                    status += " Account: \(first.name)."
                }
                tokenStatus = status
                token = ""
                viewCounts.reset()
                await checkViewCountAccess(force: true)
                if viewCounts.accessState == .available {
                    onViewCountsChanged()
                }
            } catch {
                tokenStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            GridRow {
                Text("Account ID")
                TextField("", text: $accountID).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Bucket")
                TextField("", text: $bucket).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("Public URL")
                TextField("https://…", text: $publicBase).textFieldStyle(.roundedBorder)
            }
        }
        .font(.callout)
    }

    // MARK: - View Counts

    private var viewCountsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("View Counts").font(.headline)
            Text("See page views from the last 31 days beside each share.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !hasStoredToken && !hasStoredAnalyticsToken {
                Text("Connect your Cloudflare token before enabling view counts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if viewCounts.isLoading && viewCounts.accessState == .unknown {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Checking your Cloudflare token…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                viewCountAccessStatus
            }
        }
    }

    @ViewBuilder
    private var viewCountAccessStatus: some View {
        switch viewCounts.accessState {
        case .unknown:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Checking your Cloudflare token…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

        case .available:
            Label("Enabled", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Text(hasStoredAnalyticsToken
                 ? "Using a separate read-only Cloudflare token."
                 : "Your existing Cloudflare token includes analytics access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasStoredAnalyticsToken {
                HStack {
                    Button("Replace Token…") { showingViewCountSetup = true }
                    Button("Remove Token", role: .destructive) {
                        removeAnalyticsToken()
                    }
                }
            }

        case .permissionRequired:
            if hasStoredAnalyticsToken {
                Text("The saved analytics token no longer has access.")
                    .font(.callout)
                Button("Replace Token…") { showingViewCountSetup = true }
            } else {
                Text("Your current Cloudflare token doesn’t include analytics access.")
                    .font(.callout)
                Text("Add a separate read-only token to enable view counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Enable View Counts…") { showingViewCountSetup = true }
            }

        case .authenticationFailed:
            if hasStoredAnalyticsToken {
                Text("The saved analytics token is no longer valid.")
                    .font(.callout)
                Button("Replace Token…") { showingViewCountSetup = true }
            } else {
                Text("Cloudflare couldn’t verify the current token.")
                    .font(.callout)
                Button("Try Again") { retryViewCountAccess() }
            }

        case .temporarilyUnavailable:
            Text("Cloudflare couldn’t be reached. Dropper will try again automatically.")
                .font(.callout)
            Button("Try Again") { retryViewCountAccess() }
        }
    }

    private func analyticsToken() -> String? {
        Keychain.loadAnalyticsToken() ?? Keychain.loadToken()
    }

    private func checkViewCountAccess(force: Bool = false) async {
        guard force || viewCounts.accessState == .unknown else { return }
        guard !viewCounts.isLoading, let token = analyticsToken() else { return }
        await viewCounts.checkAccess(
            accountID: accountID.trimmingCharacters(in: .whitespaces),
            bucketName: bucket.trimmingCharacters(in: .whitespaces),
            token: token)
    }

    private func retryViewCountAccess() {
        Task {
            await checkViewCountAccess(force: true)
            if viewCounts.accessState == .available {
                onViewCountsChanged()
            }
        }
    }

    private func viewCountsEnabled() {
        hasStoredAnalyticsToken = true
        viewCounts.reset()
        onViewCountsChanged()
    }

    private func removeAnalyticsToken() {
        Keychain.deleteAnalyticsToken()
        hasStoredAnalyticsToken = false
        viewCounts.reset()
        Task {
            await checkViewCountAccess(force: true)
            if viewCounts.accessState == .available {
                onViewCountsChanged()
            }
        }
    }

    private var conversionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Convert HEIC images to JPEG", isOn: $convertHEIC)
                .toggleStyle(.checkbox)
            Toggle("Convert AIFF audio to WAV", isOn: $convertAIFF)
                .toggleStyle(.checkbox)
            Toggle("Convert videos to web-safe MP4", isOn: $convertMOV)
                .toggleStyle(.checkbox)
        }
        .font(.callout)
    }

    // MARK: - Folder

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upload folder:").font(.headline)
                Text(prefix.isEmpty ? "(bucket root)" : prefix)
                    .font(.callout.monospaced())
                Spacer()
                Button(browsing ? "Hide browser" : "Browse…") {
                    browsing.toggle()
                    if browsing {
                        browsePath = prefix
                        loadFolders()
                    }
                }
            }
            Text("Changing the folder starts a fresh list — existing uploads stay in the old folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if browsing { browser }
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    browsePath = browsePath.split(separator: "/").dropLast()
                        .joined(separator: "/")
                    loadFolders()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(browsePath.isEmpty)
                .help("Up one level")

                Text(browsePath.isEmpty ? "(bucket root)" : browsePath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                Button("Use this folder") {
                    prefix = browsePath
                    browsing = false
                }
            }

            Group {
                if let browseError {
                    Text(browseError).font(.caption).foregroundStyle(.red)
                } else if folders.isEmpty {
                    Text("No subfolders").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder")
                            Text(folder)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            browsePath = browsePath.isEmpty
                                ? folder : "\(browsePath)/\(folder)"
                            loadFolders()
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.3)))

            HStack {
                TextField("New folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                Button("Create") { createFolder() }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func browseClient() -> R2Client? {
        guard let credentials = ConfigStore.resolveCredentials() else { return nil }
        let config = AppConfigSnapshot(accountID: accountID, bucket: bucket,
                                       prefix: "", publicBase: publicBase)
        return R2Client(credentials: credentials, config: config)
    }

    private func loadFolders() {
        guard let client = browseClient() else {
            browseError = "No credentials — connect a token first."
            return
        }
        browseError = nil
        let listPrefix = browsePath.isEmpty ? "" : "\(browsePath)/"
        Task {
            do {
                folders = try await client.listFolders(prefix: listPrefix)
            } catch {
                browseError = error.localizedDescription
                folders = []
            }
        }
    }

    private func createFolder() {
        guard let client = browseClient() else { return }
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        let path = browsePath.isEmpty ? name : "\(browsePath)/\(name)"
        Task {
            do {
                try await client.createFolder(path: path)
                newFolderName = ""
                loadFolders()
            } catch {
                browseError = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    private func save() {
        let d = UserDefaults.standard
        d.set(accountID.trimmingCharacters(in: .whitespaces), forKey: ConfigStore.keys.account)
        d.set(bucket.trimmingCharacters(in: .whitespaces), forKey: ConfigStore.keys.bucket)
        d.set(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              forKey: ConfigStore.keys.prefix)
        d.set(publicBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              forKey: ConfigStore.keys.publicBase)
        d.set(convertHEIC, forKey: ConfigStore.keys.convertHEIC)
        d.set(convertAIFF, forKey: ConfigStore.keys.convertAIFF)
        d.set(convertMOV, forKey: ConfigStore.keys.convertMOV)
        onSave()
        onClose()
    }
}

/// Optional post-setup flow. Cloudflare pre-fills the one read-only
/// permission; the person still reviews and creates the token themselves.
private struct ViewCountSetupSheet: View {
    private static let tokenPage = URL(string:
        "https://dash.cloudflare.com/?to=/:account/api-tokens"
        + "&permissionGroupKeys=%5B%7B%22key%22%3A%22account_analytics%22%2C%22type%22%3A%22read%22%7D%5D"
        + "&name=Dropper%20View%20Counts")!

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var checking = false
    @State private var errorMessage: String?

    let accountID: String
    let bucketName: String
    let onEnabled: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enable View Counts")
                .font(.title2.weight(.semibold))

            Text("Dropper needs a separate Cloudflare token with read-only access to Account Analytics. It cannot upload, change, or delete anything.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open Cloudflare and create the preconfigured token.")
                Text("2. Select your account, then create the token.")
                Text("3. Copy the token once and paste it below.")
            }
            .font(.callout)

            Button("Open Cloudflare Token Page") {
                NSWorkspace.shared.open(Self.tokenPage)
            }

            SecureField("Analytics token", text: $token)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Cloudflare analytics token")

            if checking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Checking analytics access…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(checking)
                Button("Verify & Enable") { verify() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking
                              || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(checking)
    }

    private func verify() {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !checking else { return }
        checking = true
        errorMessage = nil

        Task {
            do {
                try await R2ViewCountAPI().checkAccess(
                    accountID: accountID,
                    bucketName: bucketName,
                    token: candidate)
                Keychain.saveAnalyticsToken(candidate)
                token = ""
                checking = false
                onEnabled()
                dismiss()
            } catch is CancellationError {
                checking = false
            } catch let error as R2ViewCountError {
                checking = false
                switch error {
                case .permissionDenied:
                    errorMessage = "This token doesn’t have Account Analytics: Read access to this account."
                case .authenticationFailed:
                    errorMessage = "Cloudflare didn’t accept this token. Paste the token value shown after creation."
                case .transient:
                    errorMessage = "Couldn’t reach Cloudflare. Your token hasn’t been saved; try again."
                case .api, .invalidResponse:
                    errorMessage = "Cloudflare couldn’t verify analytics access. Your token hasn’t been saved."
                }
            } catch {
                checking = false
                errorMessage = "Cloudflare couldn’t verify analytics access. Your token hasn’t been saved."
            }
        }
    }
}
