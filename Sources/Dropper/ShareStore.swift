import Foundation

/// A single share's manifest-fetch outcome, carried out of a concurrent task
/// group. Every case holds only Sendable values so nothing unsafe crosses the
/// group boundary.
private enum ManifestFetch: Sendable {
    case loaded(String, Manifest)
    case unavailable(String)
}

@MainActor
final class ShareStore: ObservableObject {
    @Published var allItems: [ShareItem] = []
    @Published var showingArchive = false
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var bucketSummary: String?
    @Published var deleteProgress: (done: Int, total: Int)?
    @Published var deletingIDs = Set<String>()
    @Published var childOrder: [String: [String]] = [:]
    @Published var folders: [FolderRow] = []
    @Published var looseFiles: [LooseFile] = []

    let viewCounts: ShareViewCountState
    var folder: String { client.config.prefix }

    private let client: R2Client
    private let mutations: ShareMutationCoordinator
    private var refreshRequested = false
    private var refreshTask: Task<Void, Never>?
    /// Decoded manifests keyed by share ID, tagged with the manifest object's
    /// lastModified from the listing — an unchanged share costs no extra GET.
    private var manifestCache: [String: (modified: Date, manifest: Manifest)] = [:]

    convenience init(client: R2Client, viewCounts: ShareViewCountState) {
        self.init(client: client, viewCounts: viewCounts, mutations: .shared)
    }

    init(client: R2Client, viewCounts: ShareViewCountState,
         mutations: ShareMutationCoordinator) {
        self.client = client
        self.viewCounts = viewCounts
        self.mutations = mutations
    }

    func shareForHighlight(_ id: String) -> ShareItem? {
        allItems.first { item in
            item.id == id || item.children.contains { $0.key == id }
        }
    }

    private func keys(for id: String) -> ShareKeys {
        ShareKeys(id: id, config: client.config)
    }

    private func mutationScope(for id: String) -> String {
        let config = client.config
        return [config.accountID, config.bucket, config.prefix, id]
            .joined(separator: "\u{0}")
    }

    /// UploadCoordinator uses this same gate as list mutations, preventing an
    /// add, reorder, and delete from reading the same stale manifest.
    func withShareMutation<T>(
        id: String,
        operation: (R2Client, ShareKeys) async throws -> T
    ) async throws -> T {
        let client = client
        let shareKeys = keys(for: id)
        return try await mutations.perform(scope: mutationScope(for: id)) {
            try await operation(client, shareKeys)
        }
    }

    /// The list-mutation envelope shared by reorder/archive/pin/folder-delete:
    /// run `operation`, surface any failure to `errorMessage`, then always
    /// refresh so the list reflects the bucket's true state.
    private func runMutation(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { self.errorMessage = error.localizedDescription }
            self.refresh()
        }
    }

    // MARK: - Child ordering

    func orderedChildren(_ item: ShareItem) -> [ShareChild] {
        guard let order = childOrder[item.id] else { return item.children }
        let index = Dictionary(uniqueKeysWithValues:
            order.enumerated().map { ($1, $0) })
        return item.children.sorted {
            (index[$0.fileName] ?? .max, $0.fileName)
                < (index[$1.fileName] ?? .max, $1.fileName)
        }
    }

    func reorderChildren(of item: ShareItem, moving movingKeys: [String],
                         targetKey: String, after: Bool) {
        let fileName = { (key: String) in
            String(key.split(separator: "/").last ?? "")
        }
        let movingNames = Set(movingKeys.map(fileName))
        let targetName = fileName(targetKey)
        guard !movingNames.contains(targetName), !movingNames.isEmpty else { return }

        // Optimistic: reorder the visible children immediately so the drop
        // lands with no lag; the publish below re-asserts authoritatively.
        var optimistic = orderedChildren(item).map(\.fileName)
        let optimisticMoving = optimistic.filter { movingNames.contains($0) }
        if !optimisticMoving.isEmpty,
           var insertAt = optimistic.filter({ !movingNames.contains($0) })
            .firstIndex(of: targetName) {
            optimistic.removeAll { movingNames.contains($0) }
            if after { insertAt += 1 }
            optimistic.insert(contentsOf: optimisticMoving, at: insertAt)
            childOrder[item.id] = optimistic
        }

        runMutation {
            let order = try await self.withShareMutation(id: item.id) { client, keys in
                var manifest = try await ShareCatalog.currentManifest(
                    client: client, keys: keys)
                var order = manifest.items.map(\.file)
                let movingOrdered = order.filter { movingNames.contains($0) }
                guard !movingOrdered.isEmpty,
                      var insertAt = order.filter({ !movingNames.contains($0) })
                        .firstIndex(of: targetName) else {
                    return order
                }
                order.removeAll { movingNames.contains($0) }
                if after { insertAt += 1 }
                order.insert(contentsOf: movingOrdered, at: insertAt)
                let index = Dictionary(uniqueKeysWithValues:
                    order.enumerated().map { ($1, $0) })
                manifest.items.sort {
                    (index[$0.file] ?? .max) < (index[$1.file] ?? .max)
                }
                try await ShareCatalog.publish(manifest, keys: keys, client: client)
                return order
            }
            self.childOrder[item.id] = order
        }
    }

    var visibleItems: [ShareItem] {
        let filtered = allItems.filter { $0.isArchived == showingArchive }
        if showingArchive { return filtered }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.date > b.date
        }
    }

    // MARK: - Refresh

    /// Coalesces refreshes instead of discarding one that arrives while a
    /// listing is in flight. This matters when an upload completes mid-list.
    func refresh() {
        refreshRequested = true
        guard refreshTask == nil else { return }
        loading = true
        errorMessage = nil
        refreshTask = Task {
            while self.refreshRequested {
                self.refreshRequested = false
                do {
                    try await self.performRefresh()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.loading = false
            self.refreshTask = nil
        }
    }

    private func performRefresh() async throws {
        let config = client.config
        let objects = try await client.list(prefix: config.listPrefix)

        // Manifests drive the rows. The listing's lastModified doubles as the
        // cache key, so unchanged shares cost no extra request; the fetches
        // for new or changed shares run concurrently. Deliberately no
        // per-share mutation gate here: a refresh must never queue behind a
        // long upload, and a mid-publish read at worst shows one stale or
        // degraded row that the upload's own trailing refresh corrects.
        var manifestDates: [String: Date] = [:]
        let objectsByKey = Dictionary(
            objects.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for id in ShareCatalog.shareIDs(in: objects, config: config) {
            manifestDates[id] =
                objectsByKey[ShareKeys(id: id, config: config).manifest]?.lastModified
        }

        var manifests: [String: Manifest] = [:]
        var idsToFetch: [String] = []
        for (id, modified) in manifestDates {
            if let cached = manifestCache[id], cached.modified == modified {
                manifests[id] = cached.manifest
            } else {
                idsToFetch.append(id)
            }
        }
        // Only Sendable values may cross the task-group boundary — never an
        // `any Error` existential, which corrupts the group at runtime.
        let client = client
        let fetched = await withTaskGroup(of: ManifestFetch.self) { group in
            for id in idsToFetch {
                let keys = ShareKeys(id: id, config: config)
                group.addTask {
                    do {
                        return .loaded(id, try await ShareCatalog.currentManifest(
                            client: client, keys: keys))
                    } catch {
                        return .unavailable(id)
                    }
                }
            }
            var results: [ManifestFetch] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        for outcome in fetched {
            switch outcome {
            case let .loaded(id, manifest):
                manifests[id] = manifest
                if let modified = manifestDates[id] {
                    manifestCache[id] = (modified, manifest)
                }
            case let .unavailable(id):
                manifestCache.removeValue(forKey: id)
            }
        }
        manifestCache = manifestCache.filter { manifestDates[$0.key] != nil }

        let grouped = ShareCatalog.group(objects, manifests: manifests, config: config)
        allItems = grouped.items
        folders = grouped.folders
        looseFiles = grouped.loose
        childOrder = Dictionary(uniqueKeysWithValues: grouped.items.map {
            ($0.id, $0.children.map(\.fileName))
        })
        refreshViewCounts(pageKeys: grouped.items.map {
            ShareKeys(id: $0.id, config: config).page
        })

        let archived = grouped.items.filter(\.isArchived).count
        let active = grouped.items.count - archived
        let total = objects.reduce(Int64(0)) { $0 + $1.size }
        var summary = ByteCountFormatter.string(
            fromByteCount: total, countStyle: .file)
            + " · \(active) item\(active == 1 ? "" : "s")"
        if archived > 0 { summary += " · \(archived) archived" }
        bucketSummary = summary
    }

    func refreshViewCounts(pageKeys: [String]? = nil, force: Bool = false) {
        guard !viewCounts.isLoading else { return }
        if !force,
           viewCounts.accessState == .permissionRequired
            || viewCounts.accessState == .authenticationFailed {
            return
        }
        guard let token = Keychain.loadAnalyticsToken() ?? Keychain.loadToken() else {
            return
        }

        let config = client.config
        let keys = pageKeys ?? allItems.map {
            ShareKeys(id: $0.id, config: config).page
        }
        Task {
            if keys.isEmpty {
                await viewCounts.checkAccess(
                    accountID: config.accountID,
                    bucketName: config.bucket,
                    token: token)
            } else {
                await viewCounts.load(
                    accountID: config.accountID,
                    bucketName: config.bucket,
                    pageKeys: keys,
                    token: token,
                    force: force)
            }
        }
    }

    // MARK: - Archive / pin markers

    private func updateLocal(_ id: String, _ transform: (inout ShareItem) -> Void) {
        allItems = allItems.map { item in
            guard item.id == id else { return item }
            var copy = item
            transform(&copy)
            return copy
        }
    }

    func setArchived(_ item: ShareItem, _ archived: Bool) {
        updateLocal(item.id) {
            $0.isArchived = archived
            if archived { $0.isPinned = false }
        }
        runMutation {
            try await self.withShareMutation(id: item.id) { client, keys in
                try await client.setMarker(keys.archivedMarker, present: archived)
                if archived {
                    try await client.setMarker(keys.pinnedMarker, present: false)
                }
            }
        }
    }

    func setPinned(_ item: ShareItem, _ pinned: Bool) {
        updateLocal(item.id) { $0.isPinned = pinned }
        runMutation {
            try await self.withShareMutation(id: item.id) { client, keys in
                try await client.setMarker(keys.pinnedMarker, present: pinned)
            }
        }
    }

    // MARK: - Deletion

    func applyDeletion(full: [ShareItem],
                       partial: [(ShareItem, [ShareChild])] = []) {
        let total = full.count + partial.reduce(0) { $0 + $1.1.count }
        guard total > 0 else { return }
        deleteProgress = (0, total)
        deletingIDs = Set(full.map(\.id))
            .union(partial.flatMap { $0.1.map(\.key) })
        var done = 0
        Task {
            do {
                for item in full {
                    try await deleteOwned(of: item)
                    self.allItems.removeAll { $0.id == item.id }
                    done += 1
                    self.deleteProgress = (done, total)
                }
                for (item, children) in partial {
                    try await removeChildren(from: item, children: children)
                    done += children.count
                    self.deleteProgress = (done, total)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.deleteProgress = nil
            self.deletingIDs = []
            self.refresh()
        }
    }

    func deleteEmptyFolder(named name: String) {
        runMutation {
            try await self.client.delete(key: self.client.config.key("\(name)/"))
        }
    }

    private func deleteOwned(of item: ShareItem) async throws {
        try await withShareMutation(id: item.id) { client, keys in
            let manifest = try await ShareCatalog.currentManifest(client: client, keys: keys)
            for key in ShareCatalog.ownedKeys(keys: keys, manifest: manifest) {
                try await client.delete(key: key)
            }
        }
    }

    private func removeChildren(from item: ShareItem,
                                children: [ShareChild]) async throws {
        let removedNames = Set(children.map(\.fileName))
        guard !removedNames.isEmpty else { return }
        try await withShareMutation(id: item.id) { client, keys in
            var manifest = try await ShareCatalog.currentManifest(client: client, keys: keys)
            let removed = manifest.items.filter { removedNames.contains($0.file) }
            // A selection made from a stale list may reference files already
            // gone from the manifest; remove what's still there.
            guard !removed.isEmpty else { return }
            manifest.items.removeAll { removedNames.contains($0.file) }
            if manifest.items.isEmpty {
                for key in ShareCatalog.ownedKeys(
                    keys: keys,
                    manifest: Manifest(items: removed)) {
                    try await client.delete(key: key)
                }
                return
            }

            var cleanup: [String] = []
            for entry in removed {
                cleanup.append(keys.media(entry.file))
                cleanup.append(keys.thumb(entry.file))
                if entry.poster != nil { cleanup.append(keys.poster(entry.file)) }
            }
            try await ShareCatalog.publish(
                manifest, keys: keys, client: client,
                cleanupKeys: cleanup)
        }
    }
}

/// Zero-byte marker objects (a share's `.archived` / `.pinned` flags), written
/// or cleared through the share mutation gate.
extension R2Client {
    func setMarker(_ key: String, present: Bool) async throws {
        if present {
            try await put(data: Data(), key: key,
                          contentType: "application/octet-stream",
                          cacheControl: "no-store")
        } else {
            try await delete(key: key)
        }
    }
}
