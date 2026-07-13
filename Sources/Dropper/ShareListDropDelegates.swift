import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// Internal-only payload for moving files within an existing collection.
    /// Finder file drags also advertise plain text, so plainText cannot safely
    /// distinguish reordering from the external file-attachment destination.
    static let dropperShareRow = UTType(exportedAs: "page.dropper.share-row")
}

/// What the dragged rows look like while in flight.
struct DragGhost: View {
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.6))
        )
    }
}

/// Accepts a Dropper-only row key; drops on the lower half of a row land
/// after it, upper half before it. Hover position drives the insertion gap.
struct ReorderDropDelegate: DropDelegate {
    let setInsertion: (Bool?) -> Void   // true/false = after/before; nil = exited
    let perform: (String, Bool) -> Void

    private func after(_ info: DropInfo) -> Bool {
        info.location.y > 18  // ~half the row height
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.dropperShareRow])
    }

    func dropEntered(info: DropInfo) {
        setInsertion(after(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setInsertion(after(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setInsertion(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let landAfter = after(info)
        setInsertion(nil)
        guard let provider = info.itemProviders(for: [.dropperShareRow]).first
        else { return false }
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.dropperShareRow.identifier
        ) { data, _ in
            guard let data, let key = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { perform(key, landAfter) }
        }
        return true
    }
}

/// External files attach to the explicit parent share represented by the
/// row. Internal child reordering continues through its plain-text target.
struct ShareFileDropDelegate: DropDelegate {
    let enabled: Bool
    let setTargeted: (Bool) -> Void
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        setTargeted(true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .cancel) }
        setTargeted(true)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            setTargeted(false)
            return false
        }
        let providers = info.itemProviders(for: [.fileURL])
        setTargeted(false)
        return perform(providers)
    }
}
