import Foundation

struct ShareChild: Identifiable, Equatable {
    var id: String { key }
    let key: String     // full object key
    let name: String    // object filename
    let size: Int64
    let fileURL: URL
    let thumbURL: URL?  // ".thumb.<name>.jpg" preview, when one exists

    var kind: MediaKind { MediaKind.of(URL(fileURLWithPath: name)) }
}

struct ShareItem: Identifiable, Equatable {
    let id: String          // the short share ID
    let title: String
    let date: Date
    let size: Int64         // total media bytes
    let keys: [String]      // every object in the share (incl. page/manifest)
    let pageURL: URL
    let fileURL: URL        // first media file (page URL if none)
    let children: [ShareChild]
    let hasManifest: Bool
    let thumbURL: URL?      // ".thumb.jpg" preview, when one was generated
    var isArchived: Bool    // ".archived" marker object in the share folder
    var isPinned: Bool      // ".pinned" marker object

    /// Kind of the first file, for the icon fallback when there's no thumb.
    var kind: MediaKind? {
        children.first.map { MediaKind.of(URL(fileURLWithPath: $0.name)) }
    }
}

/// A navigable plain subfolder of the current folder (not a share).
struct FolderRow: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let objectCount: Int
    let size: Int64
}

/// A file sitting directly in the current folder — not part of any share.
struct LooseFile: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let size: Int64
    let fileURL: URL

    var kind: MediaKind { MediaKind.of(URL(fileURLWithPath: name)) }
}

@MainActor
final class ShareStore: ObservableObject {
    @Published var allItems: [ShareItem] = []
    @Published var showingArchive = false
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var bucketSummary: String?
    @Published var deleteProgress: (done: Int, total: Int)?
    @Published var deletingIDs = Set<String>()   // share ids + child keys mid-delete
    @Published var childOrder: [String: [String]] = [:]  // share id -> manifest file order
    @Published var folders: [FolderRow] = []
    @Published var looseFiles: [LooseFile] = []

    /// The folder being browsed ("" = bucket root) — also the drop target.
    var folder: String { client.config.prefix }

    private let client: R2Client

    init(client: R2Client) {
        self.client = client
    }

    /// The share a highlight refers to (the share itself, or the parent of a
    /// highlighted file) — the "Add to collection" drop target.
    func shareForHighlight(_ id: String) -> ShareItem? {
        allItems.first { item in
            item.id == id || item.children.contains { $0.key == id }
        }
    }

    // MARK: - Child ordering

    /// The manifest's fresh copy (adds/reorders), or one reconstructed from
    /// the listed files for legacy shares.
    nonisolated static func currentManifest(
        client: R2Client, config: AppConfigSnapshot, item: ShareItem
    ) async -> Manifest {
        if item.hasManifest,
           let data = try? await client.get(key: ShareKeys(id: item.id, config: config).manifest),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            return manifest
        }
        return Manifest(items: item.children.map {
            ManifestItem(file: $0.name, name: $0.name,
                         kind: MediaKind.of(URL(fileURLWithPath: $0.name)),
                         size: $0.size, peaks: nil, width: nil, height: nil)
        }, thumb: nil)
    }

    /// Writes the manifest and regenerated page together — the pair that
    /// keeps a share's link truthful. Every manifest mutation funnels here.
    nonisolated static func publish(_ manifest: Manifest, keys: ShareKeys,
                                    client: R2Client) async throws {
        try await client.put(
            data: JSONEncoder().encode(manifest), key: keys.manifest,
            contentType: "application/json", cacheControl: "no-cache")
        let html = renderShareHTML(title: manifest.title, items: manifest.items)
        // no-cache, not max-age: the page is the one MUTABLE object in a
        // share (collections change it), and an hour-stale page shows edits
        // to nobody. Browsers/edge revalidate the ~15 KB of HTML per view;
        // the heavy media stays immutable-cached.
        try await client.put(
            data: Data(html.utf8), key: keys.page,
            contentType: "text/html; charset=utf-8",
            cacheControl: "no-cache")
    }

    private func keys(for id: String) -> ShareKeys {
        ShareKeys(id: id, config: client.config)
    }

    /// Fetches the share's display order (one small GET) the first time its
    /// row expands, so the list matches the page.
    func loadOrder(for item: ShareItem) {
        guard childOrder[item.id] == nil, item.hasManifest else { return }
        Task {
            let manifest = await Self.currentManifest(client: client,
                                                      config: client.config, item: item)
            self.childOrder[item.id] = manifest.items.map(\.file)
        }
    }

    /// Children in manifest order when known; alphabetical otherwise (files
    /// missing from the manifest sort to the end by name).
    func orderedChildren(_ item: ShareItem) -> [ShareChild] {
        guard let order = childOrder[item.id] else { return item.children }
        let index = Dictionary(uniqueKeysWithValues:
            order.enumerated().map { ($1, $0) })
        return item.children.sorted {
            (index[$0.name] ?? .max, $0.name) < (index[$1.name] ?? .max, $1.name)
        }
    }

    /// Moves `movingKeys` before/after `targetKey`, rewrites the manifest and
    /// regenerates the page — the share link keeps working, in the new order.
    func reorderChildren(of item: ShareItem, moving movingKeys: [String],
                         targetKey: String, after: Bool) {
        let fileName = { (key: String) in String(key.split(separator: "/").last ?? "") }
        let movingNames = Set(movingKeys.map(fileName))
        let targetName = fileName(targetKey)
        guard !movingNames.contains(targetName), !movingNames.isEmpty else { return }

        Task {
            var manifest = await Self.currentManifest(client: client,
                                                      config: client.config, item: item)
            var order = manifest.items.map(\.file)
            let movingOrdered = order.filter { movingNames.contains($0) }
            guard !movingOrdered.isEmpty else { return }
            order.removeAll { movingNames.contains($0) }
            guard var insertAt = order.firstIndex(of: targetName) else { return }
            if after { insertAt += 1 }
            order.insert(contentsOf: movingOrdered, at: insertAt)

            let index = Dictionary(uniqueKeysWithValues:
                order.enumerated().map { ($1, $0) })
            manifest.items.sort { (index[$0.file] ?? .max) < (index[$1.file] ?? .max) }
            self.childOrder[item.id] = order  // optimistic: reorder the UI now

            do {
                try await Self.publish(manifest, keys: keys(for: item.id), client: client)
            } catch {
                self.errorMessage = error.localizedDescription
                self.refresh()
            }
        }
    }

    /// What the list shows: the archive, or all active shares with pinned
    /// ones first. No row cap — archiving is how the list stays short.
    var visibleItems: [ShareItem] {
        let filtered = allItems.filter { $0.isArchived == showingArchive }
        if showingArchive { return filtered }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.date > b.date
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        let config = client.config
        Task {
            do {
                // One prefix listing feeds the share list, the markers, and
                // the folder totals — no per-share requests.
                let objects = try await client.list(prefix: config.listPrefix)
                let grouped = Self.group(objects, config: config)
                self.allItems = grouped.items
                self.folders = grouped.folders
                self.looseFiles = grouped.loose
                let archived = grouped.items.filter(\.isArchived).count
                let active = grouped.items.count - archived
                let total = objects.reduce(Int64(0)) { $0 + $1.size }
                var summary = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    + " · \(active) item\(active == 1 ? "" : "s")"
                if archived > 0 { summary += " · \(archived) archived" }
                self.bucketSummary = summary
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.loading = false
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
        // Optimistic; the trailing refresh reconciles the keys list.
        updateLocal(item.id) {
            $0.isArchived = archived
            if archived { $0.isPinned = false }
        }
        Task {
            do {
                if archived {
                    try await client.put(data: Data(), key: keys(for: item.id).archivedMarker,
                                         contentType: "application/octet-stream",
                                         cacheControl: "no-store")
                    if item.isPinned {
                        try? await client.delete(key: keys(for: item.id).pinnedMarker)
                    }
                } else {
                    try await client.delete(key: keys(for: item.id).archivedMarker)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.refresh()
        }
    }

    func setPinned(_ item: ShareItem, _ pinned: Bool) {
        updateLocal(item.id) { $0.isPinned = pinned }
        Task {
            do {
                if pinned {
                    try await client.put(data: Data(), key: keys(for: item.id).pinnedMarker,
                                         contentType: "application/octet-stream",
                                         cacheControl: "no-store")
                } else {
                    try await client.delete(key: keys(for: item.id).pinnedMarker)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.refresh()
        }
    }

    // MARK: - Deletion

    /// Deletes whole shares and/or individual files. Partial deletes rewrite
    /// the share's manifest and page so its link keeps working. Progress is
    /// per item/file (`deleteProgress`), affected rows dim (`deletingIDs`).
    func applyDeletion(full: [ShareItem], partial: [(ShareItem, [ShareChild])] = []) {
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

    /// Deletes an empty folder — just its zero-byte marker object. Folders
    /// with any content are never deletable from Dropper.
    func deleteEmptyFolder(named name: String) {
        Task {
            do {
                try await client.delete(key: client.config.key("\(name)/"))
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.refresh()
        }
    }

    /// Ownership-scoped delete: removes only what Dropper created — the files
    /// in the manifest (fetched fresh, never from a stale snapshot) plus the
    /// fixed artifact set. Files that ended up in the folder by other means
    /// are never touched; they surface as leftovers in the refreshed list.
    /// Deleting already-missing keys is a no-op (S3 returns success), which
    /// is what keeps this tolerant of external deletions.
    private func deleteOwned(of item: ShareItem) async throws {
        let shareKeys = keys(for: item.id)
        let manifest: Manifest? = item.hasManifest
            ? (try? await client.get(key: shareKeys.manifest))
                .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
            : nil
        let hasPage = item.keys.contains(shareKeys.page)
        for key in Self.ownedKeys(keys: shareKeys, manifest: manifest, hasPage: hasPage,
                                  listedChildKeys: item.children.map(\.key)) {
            try await client.delete(key: key)
        }
    }

    /// The keys Dropper owns in a share folder. Legacy shares (pre-manifest,
    /// but carrying Dropper's index.html signature) were created entirely by
    /// Dropper, so their listed files count as owned. A folder with neither
    /// manifest nor page was never Dropper's — only the artifact names are
    /// attempted (harmless no-ops when absent), its files are left alone.
    nonisolated static func ownedKeys(keys: ShareKeys, manifest: Manifest?,
                                      hasPage: Bool,
                                      listedChildKeys: [String]) -> [String] {
        var owned = Set([keys.page, keys.manifest, keys.legacyThumb,
                         keys.archivedMarker, keys.pinnedMarker])
        if let manifest {
            for entry in manifest.items {
                owned.insert(keys.media(entry.file))
                owned.insert(keys.thumb(entry.file))
                if entry.poster != nil {
                    owned.insert(keys.poster(entry.file))
                }
            }
        } else if hasPage {
            owned.formUnion(listedChildKeys)
            for key in listedChildKeys {
                if let name = key.split(separator: "/").last {
                    owned.insert(keys.thumb(String(name)))
                    owned.insert(keys.poster(String(name)))
                }
            }
        }
        return owned.sorted()
    }

    private func removeChildren(from item: ShareItem, children: [ShareChild]) async throws {
        let shareKeys = keys(for: item.id)
        let removedKeys = Set(children.map(\.key))
        for child in children {
            try await client.delete(key: child.key)
        }

        if item.hasManifest,
           let data = try? await client.get(key: shareKeys.manifest),
           var manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
            let removedItems = manifest.items.filter {
                removedKeys.contains(shareKeys.media($0.file))
            }
            let before = manifest.items.count
            manifest.items.removeAll { removedKeys.contains(shareKeys.media($0.file)) }
            if before == manifest.items.count {
                // Only foreign files were deleted; the share is untouched.
                return
            }
            // Removed files take their thumbnails and posters with them.
            for removed in removedItems {
                try? await client.delete(key: shareKeys.thumb(removed.file))
                if removed.poster != nil {
                    try? await client.delete(key: shareKeys.poster(removed.file))
                }
            }
            if manifest.items.isEmpty {
                // Last owned file gone: Dropper's artifacts go with it.
                try await deleteOwned(of: item)
            } else {
                // The legacy share-level thumbnail depicts a specific file;
                // drop it if that file was just removed.
                if let thumbFile = manifest.thumb,
                   removedKeys.contains(shareKeys.media(thumbFile)) {
                    try? await client.delete(key: shareKeys.legacyThumb)
                    manifest.thumb = nil
                }
                try await Self.publish(manifest, keys: shareKeys, client: client)
            }
        } else {
            // Legacy share (no manifest): if no media remains, remove
            // Dropper's artifacts too.
            let remaining = item.children.filter { !removedKeys.contains($0.key) }
            if remaining.isEmpty {
                try await deleteOwned(of: item)
            }
        }
    }

    // MARK: - Grouping

    /// Group flat keys (<prefix>/<id>/<file>) into shares, newest first.
    nonisolated static func group(_ objects: [R2Object],
                                  config: AppConfigSnapshot)
        -> (folders: [FolderRow], items: [ShareItem], loose: [LooseFile]) {
        var byFolder: [String: [R2Object]] = [:]
        var looseObjects: [R2Object] = []
        var folderMarkers = Set<String>()
        for object in objects {
            guard object.key.hasPrefix(config.listPrefix) else { continue }
            let relative = object.key.dropFirst(config.listPrefix.count)
            let parts = relative.split(separator: "/")
            if parts.count == 1 {
                if relative.hasSuffix("/") {
                    // Zero-byte folder marker ("name/") from Create Folder.
                    folderMarkers.insert(String(parts[0]))
                } else {
                    looseObjects.append(object)
                }
            } else if parts.count >= 2 {
                byFolder[String(parts[0]), default: []].append(object)
            }
        }

        // A subfolder is a share iff Dropper's signature sits DIRECTLY in it;
        // nested shares deeper down don't make the outer folder a share.
        let hasSignature = { (members: [R2Object]) -> Bool in
            members.contains { object in
                let parts = object.key.dropFirst(config.listPrefix.count)
                    .split(separator: "/")
                return parts.count == 2
                    && (parts[1] == "manifest.json" || parts[1] == "index.html")
            }
        }

        var folderRows: [FolderRow] = []
        var shareGroups: [String: [R2Object]] = [:]
        for (name, members) in byFolder {
            if hasSignature(members) {
                shareGroups[name] = members
            } else if !name.hasPrefix(".") {
                folderRows.append(FolderRow(
                    name: name, objectCount: members.count,
                    size: members.reduce(0) { $0 + $1.size }))
            }
        }
        for name in folderMarkers
        where byFolder[name] == nil && !name.hasPrefix(".") {
            folderRows.append(FolderRow(name: name, objectCount: 0, size: 0))
        }
        folderRows.sort { $0.name < $1.name }

        let loose = looseObjects.compactMap { object -> LooseFile? in
            let name = String(object.key.split(separator: "/").last ?? "")
            guard !name.hasPrefix(".") else { return nil }
            let fileURL = object.key
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                .flatMap { URL(string: "\(config.publicBase)/\($0)") }
            guard let fileURL else { return nil }
            return LooseFile(key: object.key, name: name,
                             size: object.size, fileURL: fileURL)
        }.sorted { $0.name < $1.name }

        let items = shareGroups.map { id, members -> ShareItem in
            let shareKeys = ShareKeys(id: id, config: config)
            // Meta: the page, the manifest, and dot-markers (.archived etc.)
            let isMeta = { (key: String) in
                let name = key.split(separator: "/").last.map(String.init) ?? ""
                return name == "index.html" || name == "manifest.json"
                    || name.hasPrefix(".")
            }
            let media = members.filter { !isMeta($0.key) }
            let pageURL = URL(string: shareKeys.pageURL)!
            let memberKeys = Set(members.map(\.key))
            let children = media.map { object -> ShareChild in
                let name = String(object.key.split(separator: "/").last ?? "file")
                let fileURL = object.key
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    .flatMap { URL(string: "\(config.publicBase)/\($0)") } ?? pageURL
                let thumbKey = shareKeys.thumb(name)
                return ShareChild(
                    key: object.key, name: name,
                    size: object.size, fileURL: fileURL,
                    thumbURL: memberKeys.contains(thumbKey)
                        ? URL(string: "\(config.publicBase)/\(thumbKey)") : nil)
            }.sorted { $0.name < $1.name }
            let title: String
            switch children.count {
            case 0: title = id
            case 1: title = children[0].name
            default: title = "\(children[0].name) +\(children.count - 1)"
            }
            return ShareItem(
                id: id,
                title: title,
                date: media.map(\.lastModified).max()
                    ?? members.map(\.lastModified).max() ?? .distantPast,
                size: children.reduce(0) { $0 + $1.size },
                keys: members.map(\.key),
                pageURL: pageURL,
                fileURL: children.first?.fileURL ?? pageURL,
                children: children,
                hasManifest: members.contains { $0.key.hasSuffix("/manifest.json") },
                // First child's own thumb; legacy shares fall back to the old
                // share-level .thumb.jpg.
                thumbURL: children.first(where: { $0.thumbURL != nil })?.thumbURL
                    ?? (members.contains { $0.key.hasSuffix("/.thumb.jpg") }
                        ? URL(string: "\(config.publicBase)/\(shareKeys.legacyThumb)")
                        : nil),
                isArchived: members.contains { $0.key.hasSuffix("/.archived") },
                isPinned: members.contains { $0.key.hasSuffix("/.pinned") }
            )
        }
        .sorted { $0.date > $1.date }
        return (folderRows, items, loose)
    }
}
