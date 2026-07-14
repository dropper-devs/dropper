import Foundation

/// The small subset of R2 operations used by manifest publication. Keeping
/// this as a protocol makes publication and validation independently testable.
protocol ShareDataClient: Sendable {
    var config: AppConfigSnapshot { get }
    func list(prefix: String) async throws -> [R2Object]
    func get(key: String) async throws -> Data
    func put(data: Data, key: String, contentType: String,
             cacheControl: String) async throws
    func delete(key: String) async throws
}

extension R2Client: ShareDataClient {}

enum ShareStoreError: LocalizedError {
    case missingManifest(String)
    case unreadableManifest(String, String)

    var errorDescription: String? {
        switch self {
        case let .missingManifest(id):
            return "Share \(id) has no manifest. No changes were made."
        case let .unreadableManifest(id, reason):
            return "Share \(id) has an unreadable manifest: \(reason)"
        }
    }
}

/// Pure share logic: reading and publishing manifests, and turning a bucket
/// listing into rows. No UI state — every function is a plain `static`, so it
/// is independently testable and shared with the CLI. A folder is a Dropper
/// share only when its manifest.json decodes; everything else stays an
/// ordinary navigable folder or loose file.
enum ShareCatalog {

    // MARK: - Manifest publication

    private static func isNotFound(_ error: Error) -> Bool {
        if case let R2Client.R2Error.badStatus(status, _) = error {
            return status == 404
        }
        return false
    }

    /// A drop's files never take these names, so a media object can't collide
    /// with the share's own manifest or page. This guards the WRITE path only;
    /// reading never re-judges a manifest that already decoded.
    static let reservedMediaFileNames: Set<String> = [
        "index.html", "manifest.json",
    ]

    /// The one property reading cares about: does the name stay inside the
    /// share's folder as a single object key? A name that fails this can't be
    /// turned into a media key safely, so that one child is skipped — the
    /// share still renders. It is deliberately NOT a version or format gate.
    static func mediaFileNameIsSafe(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && !name.contains("/")
            && !reservedMediaFileNames.contains(name)
            && !name.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains)
    }

    /// The manifest, decoded — nothing more. If the bytes parse as a manifest,
    /// that IS the manifest, whatever its version; the caller renders it
    /// best-effort. Only a genuinely absent object (404) or bytes that don't
    /// decode are errors. No version gate, no semantic rejection.
    static func currentManifest(
        client: any ShareDataClient, keys: ShareKeys
    ) async throws -> Manifest {
        let data: Data
        do {
            data = try await client.get(key: keys.manifest)
        } catch where isNotFound(error) {
            throw ShareStoreError.missingManifest(keys.id)
        } catch {
            throw ShareStoreError.unreadableManifest(
                keys.id, error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw ShareStoreError.unreadableManifest(
                keys.id, error.localizedDescription)
        }
    }

    /// Writes the manifest and regenerated page together — the pair that
    /// keeps a share's link truthful. Every manifest mutation funnels here.
    /// `cleanupKeys` (a partial delete's removed media) are deleted only
    /// after both PUTs land, so the live page never references a removed
    /// object. Detached so a cancelled caller cannot tear the pair mid-write.
    ///
    /// no-cache, not max-age: the page is the one MUTABLE object in a share
    /// (collections change it), and an hour-stale page shows edits to nobody.
    /// Browsers/edge revalidate the ~15 KB of HTML per view; the heavy media
    /// stays immutable-cached.
    static func publish(
        _ manifest: Manifest, keys: ShareKeys, client: any ShareDataClient,
        cleanupKeys: [String] = []
    ) async throws {
        let manifestData = try JSONEncoder().encode(manifest)
        let html = renderShareHTML(title: manifest.title, items: manifest.items)
        let pageData = Data(html.utf8)
        let transaction = Task.detached {
            try await client.put(
                data: manifestData, key: keys.manifest,
                contentType: "application/json", cacheControl: "no-cache")
            try await client.put(
                data: pageData, key: keys.page,
                contentType: "text/html; charset=utf-8",
                cacheControl: "no-cache")
            for key in cleanupKeys {
                try await client.delete(key: key)
            }
        }
        try await transaction.value
    }

    // MARK: - Grouping

    /// IDs with a direct manifest. An index page by itself is never enough to
    /// classify a folder as a healthy Dropper share.
    static func shareIDs(
        in objects: [R2Object], config: AppConfigSnapshot
    ) -> [String] {
        directIDs(in: objects, named: "manifest.json", config: config)
    }

    private static func directIDs(
        in objects: [R2Object], named target: String,
        config: AppConfigSnapshot
    ) -> [String] {
        Set(objects.compactMap { object -> String? in
            guard object.key.hasPrefix(config.listPrefix) else { return nil }
            let parts = object.key.dropFirst(config.listPrefix.count)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == Substring(target),
                  !parts[0].isEmpty else { return nil }
            return String(parts[0])
        }).sorted()
    }

    /// A folder is a share only when its manifest decoded successfully.
    /// Everything else remains an ordinary navigable folder.
    static func group(
        _ objects: [R2Object], manifests: [String: Manifest],
        config: AppConfigSnapshot
    ) -> (folders: [FolderRow], items: [ShareItem], loose: [LooseFile]) {
        var byFolder: [String: [R2Object]] = [:]
        var looseObjects: [R2Object] = []
        var folderMarkers = Set<String>()
        for object in objects {
            guard object.key.hasPrefix(config.listPrefix) else { continue }
            let relative = object.key.dropFirst(config.listPrefix.count)
            let parts = relative.split(separator: "/")
            if parts.count == 1 {
                if relative.hasSuffix("/") {
                    folderMarkers.insert(String(parts[0]))
                } else {
                    looseObjects.append(object)
                }
            } else if parts.count >= 2 {
                byFolder[String(parts[0]), default: []].append(object)
            }
        }

        var folderRows: [FolderRow] = []
        var items: [ShareItem] = []
        for (name, members) in byFolder {
            if let manifest = manifests[name] {
                items.append(shareItem(
                    id: name, keys: ShareKeys(id: name, config: config),
                    manifest: manifest, members: members, config: config))
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
            guard !name.hasPrefix("."),
                  let fileURL = publicURL(for: object.key, config: config) else {
                return nil
            }
            return LooseFile(key: object.key, name: name,
                             size: object.size, fileURL: fileURL)
        }.sorted { $0.name < $1.name }

        items.sort { $0.date > $1.date }
        return (folderRows, items, loose)
    }

    /// Builds a row from a decoded manifest. Best-effort: a child whose media
    /// object is missing from the listing, or whose name can't form a safe
    /// key, is skipped — the share still renders with the rest. The page URL
    /// is derived from the layout, so a share is shown even if index.html is
    /// momentarily absent (the next publish regenerates it).
    private static func shareItem(
        id: String, keys: ShareKeys, manifest: Manifest,
        members: [R2Object], config: AppConfigSnapshot
    ) -> ShareItem {
        let memberByKey = Dictionary(
            members.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let pageURL = publicURL(for: keys.page, config: config)
            ?? URL(string: config.publicBase)!

        var children: [ShareChild] = []
        for entry in manifest.items {
            guard mediaFileNameIsSafe(entry.file) else {
                NSLog("Dropper: skipping unsafe manifest filename in \(id): \(entry.file)")
                continue
            }
            let mediaKey = keys.media(entry.file)
            guard memberByKey[mediaKey] != nil,
                  let fileURL = publicURL(for: mediaKey, config: config) else {
                continue  // media gone (e.g. deleted in the dashboard) — skip it
            }
            let thumbKey = keys.thumb(entry.file)
            children.append(ShareChild(
                key: mediaKey, fileName: entry.file, name: entry.name,
                kind: entry.kind, size: entry.size, fileURL: fileURL,
                thumbURL: memberByKey[thumbKey] == nil
                    ? nil : publicURL(for: thumbKey, config: config)))
        }

        let mediaDates = children.compactMap { memberByKey[$0.key]?.lastModified }
        return ShareItem(
            id: id,
            title: manifest.title,
            date: mediaDates.max() ?? .distantPast,
            size: children.reduce(Int64(0)) { $0 + $1.size },
            keys: members.map(\.key).sorted(),
            pageURL: pageURL,
            fileURL: children.first?.fileURL ?? pageURL,
            children: children,
            thumbURL: children.first?.thumbURL,
            isArchived: memberByKey[keys.archivedMarker] != nil,
            isPinned: memberByKey[keys.pinnedMarker] != nil)
    }

    /// Only a readable current manifest establishes ownership. The page goes
    /// first so an interrupted delete leaves the share unreachable, and the
    /// manifest goes last.
    static func ownedKeys(keys: ShareKeys, manifest: Manifest) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ key: String) {
            if seen.insert(key).inserted { ordered.append(key) }
        }
        append(keys.page)
        for entry in manifest.items {
            append(keys.media(entry.file))
            append(keys.thumb(entry.file))
            if entry.poster != nil { append(keys.poster(entry.file)) }
        }
        append(keys.archivedMarker)
        append(keys.pinnedMarker)
        append(keys.manifest)
        return ordered
    }

    private static func publicURL(
        for key: String, config: AppConfigSnapshot
    ) -> URL? {
        key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            .flatMap { URL(string: "\(config.publicBase)/\($0)") }
    }
}
