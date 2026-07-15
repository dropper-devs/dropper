import SwiftUI
import UniformTypeIdentifiers

/// External files (from Finder) attach to the parent share the row represents.
/// Child reordering within a collection is a DragGesture (see ShareRowViews),
/// not a drop target, so it never conflicts with this.
struct ShareFileDropDelegate: DropDelegate {
    let enabled: Bool
    let setTargeted: (Bool) -> Void
    let updateCount: (Int) -> Void
    let perform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        updateCount(info.itemProviders(for: [.fileURL]).count)
        setTargeted(true)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .cancel) }
        updateCount(info.itemProviders(for: [.fileURL]).count)
        setTargeted(true)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        updateCount(0)
        setTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            updateCount(0)
            setTargeted(false)
            return false
        }
        let providers = info.itemProviders(for: [.fileURL])
        updateCount(0)
        setTargeted(false)
        return perform(providers)
    }
}
