import Foundation

/// Headless debug interface exercising the same client code as the UI:
///   Dropper --list                  print the shares the window would show
///   Dropper --delete <id>           delete every object of one share
///   Dropper --verify-token <token>  test the token -> credentials derivation
///   Dropper --convert-video <path>  test the web-safe MP4 conversion
enum CLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--list") || args.contains("--delete")
                || args.contains("--verify-token")
                || args.contains("--convert-video") else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var status: Int32 = 0

        Task {
            do {
                if let flag = args.firstIndex(of: "--verify-token"), flag + 1 < args.count {
                    try await verifyToken(args[flag + 1])
                } else if let flag = args.firstIndex(of: "--convert-video"), flag + 1 < args.count {
                    try await convertVideo(args[flag + 1])
                } else {
                    try await shareCommands(args)
                }
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                status = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(status)
    }

    /// Proves the single-token onboarding chain end to end:
    /// verify -> token ID (access key), SHA-256 (secret), accounts, S3 access.
    private static func verifyToken(_ token: String) async throws {
        let tokenID = try await CloudflareAPI.verifyToken(token)
        print("token ID (S3 access key): \(tokenID)")
        let secret = ConfigStore.sha256Hex(token)
        print("derived S3 secret:        \(secret.prefix(8))… (sha256 of token)")

        do {
            let accounts = try await CloudflareAPI.accounts(token)
            for account in accounts {
                print("account:                  \(account.id)  \(account.name)")
            }
            if accounts.isEmpty { print("account:                  (none visible to this token)") }
        } catch {
            print("account discovery FAILED: \(error.localizedDescription)")
        }

        let snapshot = ConfigStore.snapshot()
        do {
            let managed = try await CloudflareAPI.managedDomain(
                token: token, accountID: snapshot.accountID, bucket: snapshot.bucket)
            print("bucket public domain:     https://\(managed.domain) (enabled: \(managed.enabled))")
        } catch {
            print("managed-domain lookup FAILED: \(error.localizedDescription)")
        }

        // The real test: derived credentials against the S3 API.
        let credentials = AWSCredentials(accessKeyId: tokenID,
                                         secretAccessKey: ConfigStore.sha256Hex(token))
        let client = R2Client(credentials: credentials, config: snapshot)
        let folders = try await client.listFolders(prefix: "")
        print("S3 listing with derived credentials OK — top-level folders: \(folders.joined(separator: ", "))")
    }

    /// Exercises VideoConverter on one file: prints the plan, converts, and
    /// reports the output codec so remux vs re-encode can be verified.
    private static func convertVideo(_ path: String) async throws {
        let url = URL(fileURLWithPath: path)
        print("input:  \(path)")
        print("codec:  \(await VideoConverter.codecName(of: url) ?? "(no video track)")")
        guard let plan = await VideoConverter.conversionPlan(for: url) else {
            print("plan:   none — upload as-is")
            return
        }
        print("plan:   \(plan)")
        let start = Date()
        guard let output = try await VideoConverter.mp4Copy(of: url, plan: plan,
                                                            progress: { _ in }) else {
            print("conversion FAILED")
            exit(1)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        print("output: \(output.path)")
        print("        \(size) bytes in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        print("codec:  \(await VideoConverter.codecName(of: output) ?? "(no video track)")")
    }

    private static func shareCommands(_ args: [String]) async throws {
        guard let credentials = ConfigStore.resolveCredentials() else {
            FileHandle.standardError.write(Data("no credentials\n".utf8))
            exit(2)
        }
        let config = ConfigStore.snapshot()
        let client = R2Client(credentials: credentials, config: config)

        if args.contains("--list") {
            let objects = try await client.list(prefix: config.listPrefix)
            let grouped = ShareStore.group(objects, config: config)
            for item in grouped.items {
                var flags = ""
                if item.isPinned { flags += "P" }
                if item.isArchived { flags += "A" }
                if flags.isEmpty { flags = "-" }
                print("\(item.id)\t\(flags)\t\(item.title)\t\(item.size)\t\(item.date)\t\(item.pageURL)")
            }
            let total = objects.reduce(Int64(0)) { $0 + $1.size }
            print("folder-total\t\(total) bytes\t\(grouped.totalShares) items")
        } else if let flag = args.firstIndex(of: "--delete"), flag + 1 < args.count {
            // Same ownership semantics as the UI: only Dropper's files go;
            // anything foreign in the folder is reported, not deleted.
            let id = args[flag + 1]
            let keys = ShareKeys(id: id, config: config)
            let objects = try await client.list(prefix: keys.folderPrefix)
            if objects.isEmpty {
                FileHandle.standardError.write(Data("no such share: \(id)\n".utf8))
                exit(1)
            }
            let manifest = (try? await client.get(key: keys.manifest))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            let hasPage = objects.contains { $0.key == keys.page }
            let owned = Set(ShareStore.ownedKeys(
                keys: keys, manifest: manifest, hasPage: hasPage,
                listedChildKeys: manifest == nil ? objects.map(\.key) : []))
            for object in objects where owned.contains(object.key) {
                try await client.delete(key: object.key)
                print("deleted \(object.key)")
            }
            for object in objects where !owned.contains(object.key) {
                print("kept (not Dropper's): \(object.key)")
            }
        }
    }
}
