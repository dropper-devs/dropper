import SwiftUI
import AppKit

/// Owns ShareListView's interaction state — selection, expansion, the delete
/// confirm/revert machine, reorder and external-file-drop tracking — and the
/// logic over it. The list view, its toolbar, and the row subviews share one
/// instance, so all of them read and drive the same state.
///
/// `store` and `actions` are rebound when Settings rebuilds the client under
/// the persistent popover view tree; `state` is the app-lifetime singleton.
@MainActor
final class ShareListModel: ObservableObject {
    @Published var selection = Set<String>()      // selected child KEYS
    @Published var selectionAnchor: String?        // row id of the last click
    @Published var expanded = Set<String>()        // expanded share ids
    @Published var confirming: ConfirmTarget?      // armed delete confirmation
    @Published var newFolderName: String?          // non-nil: naming a folder
    @Published var fileDropTargetID: String?       // transient external-file hover

    private var revertTask: DispatchWorkItem?

    private(set) var store: ShareStore
    private(set) var state: UIState
    private(set) var actions: PopoverActions

    init(store: ShareStore, state: UIState, actions: PopoverActions) {
        self.store = store
        self.state = state
        self.actions = actions
    }

    func rebind(store: ShareStore, state: UIState, actions: PopoverActions) {
        self.store = store
        self.state = state
        self.actions = actions
    }

    /// Identifies which delete confirmation is armed. One shared state means
    /// opening any confirm closes the others; the enum replaces the old
    /// stringly-typed id scheme that leaned on shares, children, and folders
    /// never colliding as raw strings.
    enum ConfirmTarget: Hashable {
        case bulk
        case share(String)
        case child(String)
        case folder(String)
    }

    // MARK: - Selection

    var allLeafKeys: Set<String> {
        Set(store.visibleItems.flatMap { $0.children.map(\.key) })
    }

    var masterState: (icon: String, allSelected: Bool) {
        if selection.isEmpty { return ("square", false) }
        if selection == allLeafKeys { return ("checkmark.square.fill", true) }
        return ("minus.square.fill", true)
    }

    func toggleSelectAll() {
        if masterState.allSelected {
            selection.removeAll()
        } else {
            selection = allLeafKeys
        }
    }

    /// Visible rows flattened in display order, each with the leaf keys it
    /// stands for — the coordinate system for shift-click ranges.
    private var rowUnits: [(id: String, keys: Set<String>)] {
        var units: [(String, Set<String>)] = []
        for item in store.visibleItems {
            units.append((item.id, Set(item.children.map(\.key))))
            if expanded.contains(item.id), item.children.count > 1 {
                for child in store.orderedChildren(item) {
                    units.append((child.key, [child.key]))
                }
            }
        }
        return units
    }

    /// Selects everything between the anchor row and the clicked row
    /// (inclusive, additive — like Finder). Falls back to a plain click's
    /// behavior when there is no usable anchor.
    private func selectRange(to clickedID: String, fallback: () -> Void) {
        let units = rowUnits
        guard let anchor = selectionAnchor,
              let a = units.firstIndex(where: { $0.id == anchor }),
              let b = units.firstIndex(where: { $0.id == clickedID }) else {
            fallback()
            return
        }
        for unit in units[min(a, b)...max(a, b)] {
            selection.formUnion(unit.keys)
        }
    }

    /// One click model for parent and child rows, over the leaf keys the row
    /// stands for.
    func handleSelectionClick(rowID: String, keys: Set<String>) {
        state.highlightedID = nil
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            // shift-click: extend from the anchor over every row between
            // (anchor keeps its place for the next range)
            selectRange(to: rowID) { selection = keys }
        } else if flags.contains(.command) {
            // ⌘-click: toggle this row in/out of the selection
            if selection.isSuperset(of: keys) {
                selection.subtract(keys)
            } else {
                selection.formUnion(keys)
            }
            selectionAnchor = rowID
        } else if selection == keys {
            selection.removeAll() // sole selection: click deselects
            selectionAnchor = nil
        } else {
            selection = keys
            selectionAnchor = rowID
        }
    }

    func toggleShareSelection(childKeys: Set<String>, allSelected: Bool) {
        if allSelected {
            selection.subtract(childKeys)
        } else {
            selection.formUnion(childKeys)
        }
    }

    func toggleChildSelection(_ key: String) {
        if selection.contains(key) {
            selection.remove(key)
        } else {
            selection.insert(key)
        }
    }

    func toggleExpanded(_ item: ShareItem) {
        if expanded.contains(item.id) {
            expanded.remove(item.id)
        } else {
            expanded.insert(item.id)
        }
    }

    /// Prunes selection/expansion/highlight to a freshly loaded item set:
    /// drop selected keys and expanded ids that vanished or shrank out of
    /// being collections, and clear a highlight that no longer resolves.
    func reconcile(to items: [ShareItem]) {
        let childKeys = items.flatMap { $0.children.map(\.key) }
        selection.formIntersection(childKeys)
        expanded.formIntersection(items.filter { $0.children.count > 1 }.map(\.id))
        if let highlighted = state.highlightedID,
           !items.contains(where: { $0.id == highlighted }),
           !childKeys.contains(highlighted) {
            clearHighlight()
        }
    }

    func resetForArchiveToggle() {
        selection.removeAll()
        selectionAnchor = nil
        expanded.removeAll()
        clearHighlight()
    }

    /// Selection drives the strip. Fully selected shares contribute their
    /// plain page link (and a file link when single-file); partially
    /// selected collections contribute one anchored link per chosen file —
    /// so a share picked whole opens/copies its page, while cherry-picked
    /// children open/copy their anchors, even when both happen at once.
    func syncStripToSelection() {
        if case .uploading = state.strip { return }
        var names: [String] = []
        var pages: [String] = []
        var files: [String] = []
        for item in store.visibleItems {
            let keys = item.children.map(\.key)
            let picked = keys.filter(selection.contains)
            guard !picked.isEmpty else { continue }
            if picked.count == keys.count {
                names.append(item.title)
                pages.append(item.pageURL.absoluteString)
                if item.children.count == 1 {
                    files.append(item.fileURL.absoluteString)
                }
            } else {
                for child in store.orderedChildren(item)
                where selection.contains(child.key) {
                    names.append(child.name)
                    pages.append("\(item.pageURL.absoluteString)#\(child.fileName)")
                    files.append(child.fileURL.absoluteString)
                }
            }
        }
        guard !pages.isEmpty else {
            if case .links = state.strip { state.strip = .idle }
            return
        }
        let title = names.count == 1 ? names[0] : "\(names.count) selected"
        state.strip = .links(name: title, pageURLs: pages, fileURLs: files)
    }

    // MARK: - Confirm / revert

    /// Confirm buttons revert only after a grace period, so grazing the edge
    /// of the row doesn't dismiss them.
    private func scheduleRevert(_ action: @escaping () -> Void) {
        revertTask?.cancel()
        let work = DispatchWorkItem { withAnimation { action() } }
        revertTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func cancelRevert() {
        revertTask?.cancel()
    }

    /// Hover handler for the view hosting the `target` confirm: entering pauses
    /// the pending revert, leaving arms it.
    func confirmRevertOnHover(_ target: ConfirmTarget) -> (Bool) -> Void {
        { [self] hovering in
            if hovering {
                if confirming == target { cancelRevert() }
            } else if confirming == target {
                scheduleRevert { if self.confirming == target { self.confirming = nil } }
            }
        }
    }

    // MARK: - Mutations

    func pinToggle(_ item: ShareItem) {
        store.setPinned(item, !item.isPinned)
    }

    func archiveRow(_ item: ShareItem, childKeys: Set<String>) {
        clearHighlightIfMatches(id: item.id, childKeys: childKeys)
        selection.subtract(childKeys)
        store.setArchived(item, !store.showingArchive)
    }

    func deleteShare(_ item: ShareItem, childKeys: Set<String>) {
        clearHighlightIfMatches(id: item.id, childKeys: childKeys)
        selection.subtract(childKeys)
        store.applyDeletion(full: [item])
    }

    func deleteChild(_ item: ShareItem, _ child: ShareChild) {
        if state.highlightedID == child.key { clearHighlight() }
        selection.remove(child.key)
        store.applyDeletion(full: [], partial: [(item, [child])])
    }

    func deleteEmptyFolder(named name: String) {
        store.deleteEmptyFolder(named: name)
    }

    private func clearHighlightIfMatches(id: String, childKeys: Set<String>) {
        if let highlighted = state.highlightedID,
           highlighted == id || childKeys.contains(highlighted) {
            clearHighlight()
        }
    }

    /// Archives/unarchives every share that has a selected file.
    func archiveSelected() {
        let archived = !store.showingArchive
        for item in store.visibleItems
        where item.children.contains(where: { selection.contains($0.key) }) {
            store.setArchived(item, archived)
        }
        selection.removeAll()
        clearHighlight()
    }

    /// Splits the leaf selection into whole shares and partial file sets.
    func deleteSelected() {
        var full: [ShareItem] = []
        var partial: [(ShareItem, [ShareChild])] = []
        for item in store.visibleItems {
            let picked = item.children.filter { selection.contains($0.key) }
            guard !picked.isEmpty else { continue }
            if picked.count == item.children.count {
                full.append(item)
            } else {
                partial.append((item, picked))
            }
            if state.highlightedID == item.id { clearHighlight() }
        }
        guard !full.isEmpty || !partial.isEmpty else { return }
        store.applyDeletion(full: full, partial: partial)
        selection.removeAll()
    }

    // MARK: - Reorder

    /// Commits a reorder. The transient hover indicator is row-local `@State`
    /// (see ChildRow) — deliberately NOT on this shared model, so a drag hover
    /// never re-renders the row being dragged.
    func reorder(in item: ShareItem, draggedKey: String, targetKey: String, after: Bool) {
        guard item.children.contains(where: { $0.key == draggedKey }) else { return }
        let moving = selection.contains(draggedKey)
            ? store.orderedChildren(item).map(\.key).filter { selection.contains($0) }
            : [draggedKey]
        store.reorderChildren(of: item, moving: moving, targetKey: targetKey, after: after)
    }

    // MARK: - New folder

    func toggleNewFolder() {
        withAnimation { newFolderName = newFolderName == nil ? "" : nil }
    }

    func submitNewFolder() {
        guard let name = newFolderName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return }
        newFolderName = nil
        actions.createFolder(name)
    }

    // MARK: - External file drops

    var canAttachFiles: Bool {
        guard !store.showingArchive else { return false }
        if case .uploading = state.strip { return false }
        return true
    }

    func fileDropEnabled(id: String) -> Bool {
        canAttachFiles && !store.deletingIDs.contains(id)
    }

    private func dropToken(_ id: String) -> String {
        "share-row:\(id)"
    }

    func reportExternalDragCount(_ count: Int, for id: String) {
        state.setDraggedFileCount(count, for: dropToken(id))
    }

    /// Hover is transient and separate from the clicked/link selection. The
    /// conditional clear handles enter-B/exit-A event ordering correctly.
    func setFileDropTarget(_ id: String, targeted: Bool) {
        if targeted {
            if let previous = fileDropTargetID, previous != id {
                actions.setDropTargeted(dropToken(previous), false)
            }
            withAnimation(.easeInOut(duration: 0.1)) { fileDropTargetID = id }
        } else if fileDropTargetID == id {
            withAnimation(.easeInOut(duration: 0.1)) { fileDropTargetID = nil }
        }
        actions.setDropTargeted(dropToken(id), targeted)
    }

    func performFileDrop(_ providers: [NSItemProvider], into item: ShareItem,
                         highlightedID: String, name: String,
                         pageURL: String, fileURL: String?) -> Bool {
        guard canAttachFiles, !providers.isEmpty else { return false }
        state.highlightedID = highlightedID
        state.strip = .links(name: name, pageURLs: [pageURL],
                             fileURLs: fileURL.map { [$0] } ?? [])
        actions.dropCommitted()
        loadFileURLs(from: providers) { [actions] urls in
            actions.droppedInto(urls, item.id)
        }
        return true
    }

    func clearHighlight() {
        state.highlightedID = nil
        if selection.isEmpty, case .links = state.strip { state.strip = .idle }
    }

    /// Clean up transient drop-target advertisement when the list goes away.
    func onListDisappear() {
        if let fileDropTargetID {
            state.setDraggedFileCount(0, for: dropToken(fileDropTargetID))
            actions.setDropTargeted(dropToken(fileDropTargetID), false)
        }
    }
}
