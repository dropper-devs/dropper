import Foundation
import XCTest
@testable import Dropper

private enum FakeShareClientError: LocalizedError, Sendable {
    case injected(String)

    var errorDescription: String? {
        switch self {
        case let .injected(operation):
            return "Injected \(operation) failure"
        }
    }
}

private actor FakeShareDataClient: ShareDataClient {
    nonisolated let config: AppConfigSnapshot

    private var storage: [String: Data] = [:]
    private var modified: [String: Date] = [:]
    private var putFailures: [String: Int] = [:]
    private var deleteFailures: [String: Int] = [:]

    init(config: AppConfigSnapshot) {
        self.config = config
    }

    func seed(_ data: Data, key: String,
              date: Date = Date(timeIntervalSince1970: 1)) {
        storage[key] = data
        modified[key] = date
    }

    func failNextPut(key: String) {
        putFailures[key, default: 0] += 1
    }

    func failNextDelete(key: String) {
        deleteFailures[key, default: 0] += 1
    }

    func data(for key: String) -> Data? { storage[key] }

    func list(prefix: String) async throws -> [R2Object] {
        storage.compactMap { key, data in
            guard key.hasPrefix(prefix) else { return nil }
            return R2Object(
                key: key,
                lastModified: modified[key] ?? Date(timeIntervalSince1970: 1),
                size: Int64(data.count))
        }
    }

    func get(key: String) async throws -> Data {
        guard let data = storage[key] else {
            throw R2Client.R2Error.badStatus(404, "not found")
        }
        return data
    }

    func put(data: Data, key: String, contentType: String,
             cacheControl: String) async throws {
        if let count = putFailures[key], count > 0 {
            putFailures[key] = count - 1
            throw FakeShareClientError.injected("PUT \(key)")
        }
        storage[key] = data
        modified[key] = Date(timeIntervalSince1970: 2)
    }

    func delete(key: String) async throws {
        if let count = deleteFailures[key], count > 0 {
            deleteFailures[key] = count - 1
            throw FakeShareClientError.injected("DELETE \(key)")
        }
        storage[key] = nil
        modified[key] = nil
    }
}

private actor TestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

final class ShareStoreReliabilityTests: XCTestCase {
    private let config = AppConfigSnapshot(
        accountID: String(repeating: "a", count: 32),
        bucket: "bucket", prefix: "shares",
        publicBase: "https://public.example")

    private func item(_ file: String, name: String? = nil,
                      kind: MediaKind = .file, size: Int64 = 10,
                      poster: String? = nil) -> ManifestItem {
        ManifestItem(
            file: file, name: name ?? file, kind: kind, size: size,
            peaks: nil, width: nil, height: nil, poster: poster)
    }

    func testCurrentManifestReadsWhateverDecodes() async throws {
        // If the bytes decode, that IS the manifest — no version gate, no
        // semantic rejection. Reading never fails a manifest that parsed.
        let keys = ShareKeys(id: "any", config: config)
        let client = FakeShareDataClient(config: config)
        let json = #"{"version":1,"items":[{"file":"a.txt","name":"A","kind":"file","size":10}],"thumb":"a.txt"}"#
        await client.seed(Data(json.utf8), key: keys.manifest)

        let manifest = try await ShareCatalog.currentManifest(client: client, keys: keys)
        XCTAssertEqual(manifest.items.map(\.file), ["a.txt"])
    }

    func testMissingManifestObjectReportsMissingNotUnreadable() async {
        let keys = ShareKeys(id: "absent", config: config)
        let client = FakeShareDataClient(config: config)  // nothing seeded

        do {
            _ = try await ShareCatalog.currentManifest(client: client, keys: keys)
            XCTFail("A 404 must surface as missingManifest")
        } catch let error as ShareStoreError {
            guard case .missingManifest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUploadsNeverTakeReservedArtifactNames() {
        // The write path still protects the share's own manifest/page keys.
        XCTAssertEqual(
            ShareNaming.sanitizeAll(
                ["manifest.json", "index.html"],
                existing: ShareCatalog.reservedMediaFileNames),
            ["manifest-2.json", "index-2.html"])
    }

    func testGroupingUsesManifestOrderAndMetadataAndIgnoresForeignFiles() throws {
        let keys = ShareKeys(id: "collection", config: config)
        let manifest = Manifest(items: [
            item("second.png", name: "Second Original.PNG", kind: .image, size: 20),
            item("first.md", name: "First Notes.md", kind: .markdown, size: 10),
        ])
        let date = Date(timeIntervalSince1970: 10)
        let objects = [
            R2Object(key: keys.manifest, lastModified: date, size: 1),
            R2Object(key: keys.page, lastModified: date, size: 2),
            R2Object(key: keys.media("first.md"), lastModified: date, size: 999),
            R2Object(key: keys.media("second.png"), lastModified: date, size: 999),
            R2Object(key: keys.thumb("second.png"), lastModified: date, size: 3),
            R2Object(key: keys.folderPrefix + "foreign.bin", lastModified: date, size: 9_999),
            R2Object(
                key: config.key("page-only/index.html"),
                lastModified: date, size: 4),
        ]

        let grouped = ShareCatalog.group(
            objects, manifests: [keys.id: manifest], config: config)
        let share = try XCTUnwrap(grouped.items.first)

        XCTAssertEqual(grouped.items.count, 1)
        XCTAssertEqual(grouped.folders.map(\.name), ["page-only"])
        XCTAssertEqual(share.children.map(\.fileName), ["second.png", "first.md"])
        XCTAssertEqual(share.children.map(\.name),
                       ["Second Original.PNG", "First Notes.md"])
        XCTAssertEqual(share.children.map(\.kind), [.image, .markdown])
        XCTAssertEqual(share.children.map(\.size), [20, 10])
        XCTAssertEqual(share.title, "Second Original.PNG +1")
        XCTAssertEqual(share.size, 30)
        XCTAssertNotNil(share.thumbURL)
        XCTAssertFalse(share.children.contains { $0.key.hasSuffix("foreign.bin") })
    }

    func testOwnedDeletionIsPageFirstManifestLastAndManifestScoped() {
        let keys = ShareKeys(id: "owned", config: config)
        let manifest = Manifest(items: [
            item("clip.mp4", kind: .video,
                 poster: keys.posterName("clip.mp4")),
        ])

        let owned = ShareCatalog.ownedKeys(keys: keys, manifest: manifest)

        XCTAssertEqual(owned.first, keys.page)
        XCTAssertEqual(owned.last, keys.manifest)
        XCTAssertTrue(owned.contains(keys.media("clip.mp4")))
        XCTAssertTrue(owned.contains(keys.thumb("clip.mp4")))
        XCTAssertTrue(owned.contains(keys.poster("clip.mp4")))
        XCTAssertFalse(owned.contains(keys.folderPrefix + "foreign.bin"))
    }

    func testFailedManifestPutLeavesOldShareIntactAndMediaUntouched() async throws {
        let keys = ShareKeys(id: "torn", config: config)
        let client = FakeShareDataClient(config: config)
        let oldManifest = Manifest(items: [item("old.txt")])
        let newManifest = Manifest(items: [item("new.txt")])
        let oldManifestData = try JSONEncoder().encode(oldManifest)
        let oldPage = Data("old page".utf8)
        let newMedia = keys.media("new.txt")
        await client.seed(oldManifestData, key: keys.manifest)
        await client.seed(oldPage, key: keys.page)
        await client.seed(Data("new media".utf8), key: newMedia)
        await client.failNextPut(key: keys.manifest)

        do {
            try await ShareCatalog.publish(newManifest, keys: keys, client: client)
            XCTFail("The injected manifest failure should escape")
        } catch {
            // Expected. The manifest goes first, so the earliest failure
            // changes nothing at all.
        }

        let storedManifest = await client.data(for: keys.manifest)
        let storedPage = await client.data(for: keys.page)
        let storedMedia = await client.data(for: newMedia)
        XCTAssertEqual(storedManifest, oldManifestData)
        XCTAssertEqual(storedPage, oldPage)
        XCTAssertNotNil(storedMedia)
    }

    func testCleanupKeysAreDeletedOnlyAfterBothObjectsPublish() async throws {
        let keys = ShareKeys(id: "cleanup", config: config)
        let client = FakeShareDataClient(config: config)
        let oldManifest = Manifest(items: [item("keep.txt"), item("gone.txt")])
        let newManifest = Manifest(items: [item("keep.txt")])
        let removed = keys.media("gone.txt")
        await client.seed(try JSONEncoder().encode(oldManifest), key: keys.manifest)
        await client.seed(Data("old page".utf8), key: keys.page)
        await client.seed(Data("keep".utf8), key: keys.media("keep.txt"))
        await client.seed(Data("gone".utf8), key: removed)

        try await ShareCatalog.publish(
            newManifest, keys: keys, client: client, cleanupKeys: [removed])

        let storedManifest = await client.data(for: keys.manifest)
        let removedAfter = await client.data(for: removed)
        XCTAssertEqual(
            try JSONDecoder().decode(Manifest.self, from: XCTUnwrap(storedManifest)),
            newManifest)
        XCTAssertNil(removedAfter)
    }

    func testFailedPagePutKeepsCleanupMediaSoTheLivePageStaysWhole() async throws {
        let keys = ShareKeys(id: "deferred", config: config)
        let client = FakeShareDataClient(config: config)
        let oldManifest = Manifest(items: [item("keep.txt"), item("gone.txt")])
        let newManifest = Manifest(items: [item("keep.txt")])
        let removed = keys.media("gone.txt")
        await client.seed(try JSONEncoder().encode(oldManifest), key: keys.manifest)
        await client.seed(Data("old page".utf8), key: keys.page)
        await client.seed(Data("gone".utf8), key: removed)
        await client.failNextPut(key: keys.page)

        do {
            try await ShareCatalog.publish(
                newManifest, keys: keys, client: client, cleanupKeys: [removed])
            XCTFail("The injected page failure should escape")
        } catch {
            // Expected: the old page is still live, so the media it
            // references must not have been deleted.
        }

        let removedAfter = await client.data(for: removed)
        XCTAssertNotNil(removedAfter)
    }

    func testUnreadableManifestLeavesAnOrdinaryFolder() throws {
        let healthy = ShareKeys(id: "healthy", config: config)
        let damaged = ShareKeys(id: "damaged", config: config)
        let date = Date(timeIntervalSince1970: 10)
        let manifest = Manifest(items: [item("a.txt")])
        let objects = [
            R2Object(key: healthy.manifest, lastModified: date, size: 1),
            R2Object(key: healthy.page, lastModified: date, size: 2),
            R2Object(key: healthy.media("a.txt"), lastModified: date, size: 10),
            R2Object(key: damaged.manifest, lastModified: date, size: 1),
            R2Object(key: damaged.page, lastModified: date, size: 2),
        ]

        let grouped = ShareCatalog.group(
            objects, manifests: ["healthy": manifest], config: config)

        XCTAssertEqual(grouped.items.map(\.id), ["healthy"])
        XCTAssertEqual(grouped.folders.map(\.name), ["damaged"])
    }

    func testShareStillRendersWhenOneMediaObjectIsMissing() {
        let share = ShareKeys(id: "partial", config: config)
        let date = Date(timeIntervalSince1970: 10)
        let manifest = Manifest(items: [
            item("here.png", kind: .image, size: 5),
            item("vanished.png", kind: .image, size: 7),  // deleted externally
        ])
        let objects = [
            R2Object(key: share.manifest, lastModified: date, size: 1),
            R2Object(key: share.page, lastModified: date, size: 2),
            R2Object(key: share.media("here.png"), lastModified: date, size: 5),
        ]

        let grouped = ShareCatalog.group(
            objects, manifests: ["partial": manifest], config: config)

        // Decoded manifest ⇒ the share renders; only the missing child drops.
        XCTAssertEqual(grouped.items.map(\.id), ["partial"])
        XCTAssertEqual(
            grouped.items.first?.children.map(\.fileName), ["here.png"])
    }

    func testMediaFileNameSafetyStaysStructural() {
        XCTAssertTrue(ShareCatalog.mediaFileNameIsSafe("photo.jpg_large"))
        XCTAssertTrue(ShareCatalog.mediaFileNameIsSafe("track３.mp3"))
        XCTAssertTrue(ShareCatalog.mediaFileNameIsSafe("kick-2.wav"))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe(""))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe(".hidden"))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe(".."))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe("a/b"))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe("bad\nname"))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe("manifest.json"))
        XCTAssertFalse(ShareCatalog.mediaFileNameIsSafe("index.html"))
    }

    @MainActor
    func testMutationCoordinatorSerializesTheSameShare() async throws {
        let coordinator = ShareMutationCoordinator()
        let gate = TestGate()
        var events: [String] = []

        let first = Task { @MainActor in
            try await coordinator.perform(scope: "same") {
                events.append("first-start")
                await gate.wait()
                events.append("first-end")
            }
        }
        while events.isEmpty { await Task.yield() }
        let second = Task { @MainActor in
            try await coordinator.perform(scope: "same") {
                events.append("second")
            }
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(events, ["first-start"])
        await gate.open()
        try await first.value
        try await second.value
        XCTAssertEqual(events, ["first-start", "first-end", "second"])
    }
}
