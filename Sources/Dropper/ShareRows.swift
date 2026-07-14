import Foundation

/// One child media object of a share, as shown in the list.
struct ShareChild: Identifiable, Equatable {
    var id: String { key }
    let key: String          // full object key
    let fileName: String     // sanitized object filename / page anchor
    let name: String         // original display name from the manifest
    let kind: MediaKind
    let size: Int64
    let fileURL: URL
    let thumbURL: URL?
}

/// A published Dropper share — a folder whose manifest.json decoded.
struct ShareItem: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let size: Int64
    let keys: [String]
    let pageURL: URL
    let fileURL: URL
    let children: [ShareChild]
    let thumbURL: URL?
    var isArchived: Bool
    var isPinned: Bool

    var kind: MediaKind? { children.first?.kind }
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
