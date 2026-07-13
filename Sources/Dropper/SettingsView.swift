import SwiftUI

/// Settings: paste a Cloudflare API token once, pick the bucket/folder, done.
struct SettingsView: View {
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

    let onSave: () -> Void
    let onClose: () -> Void

    init(onSave: @escaping () -> Void, onClose: @escaping () -> Void) {
        let snapshot = ConfigStore.snapshot()
        _accountID = State(initialValue: snapshot.accountID)
        _bucket = State(initialValue: snapshot.bucket)
        _prefix = State(initialValue: snapshot.prefix)
        _publicBase = State(initialValue: snapshot.publicBase)
        self.onSave = onSave
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
