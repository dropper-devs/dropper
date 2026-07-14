import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ShareListView: View {
    @ObservedObject var store: ShareStore
    @ObservedObject var state: UIState
    let actions: PopoverActions
    @State private var selection = Set<String>()    // selected child KEYS
    @State private var selectionAnchor: String?      // row id of the last click
    @State private var expanded = Set<String>()     // expanded share ids
    @State private var confirming: String?          // confirm id (row id or bulk)
    @State private var revertTask: DispatchWorkItem?
    @State private var insertion: Insertion?        // reorder drop indicator
    @State private var newFolderName: String?       // non-nil: naming a folder
    @State private var fileDropTargetID: String?    // transient external-file hover

    private struct Insertion: Equatable {
        let key: String
        let after: Bool
    }

    /// The toolbar's delete-selected confirm shares the row confirms' state
    /// machine, so opening any confirm closes the others. No collision is
    /// possible: share ids end in a random suffix, child keys contain "/",
    /// and folder confirm ids are prefixed "folder:".
    private static let bulkConfirmID = "bulk"
    private static let popoverDropToken = "popover-surface"

    private var allLeafKeys: Set<String> {
        Set(store.visibleItems.flatMap { $0.children.map(\.key) })
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            pathBar
            Divider()
            content
            Divider()
            DropStrip(state: state, actions: actions)
            Divider()
            footer
        }
        .onChange(of: store.showingArchive) { _, _ in
            selection.removeAll()
            selectionAnchor = nil
            expanded.removeAll()
            clearHighlight()
        }
        .onChange(of: store.allItems) { _, items in
            let childKeys = items.flatMap { $0.children.map(\.key) }
            selection.formIntersection(childKeys)
            // prune expansion for shares that vanished OR shrank out of
            // being collections
            expanded.formIntersection(items.filter { $0.children.count > 1 }.map(\.id))
            // The highlight may reference a share id or a child key.
            if let highlighted = state.highlightedID,
               !items.contains(where: { $0.id == highlighted }),
               !childKeys.contains(highlighted) {
                clearHighlight()
            }
        }
        .onChange(of: selection) { _, _ in
            syncStripToSelection()
        }
        .onDrop(of: [.fileURL], delegate: PopoverFileDragObserver(
            updateCount: { count in
                state.setDraggedFileCount(count, for: Self.popoverDropToken)
            }))
        .onDisappear {
            state.setDraggedFileCount(0, for: Self.popoverDropToken)
            if let fileDropTargetID {
                state.setDraggedFileCount(0, for: dropToken(fileDropTargetID))
                actions.setDropTargeted(dropToken(fileDropTargetID), false)
            }
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
    private func handleSelectionClick(rowID: String, keys: Set<String>) {
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

    /// Selection drives the strip. Fully selected shares contribute their
    /// plain page link (and a file link when single-file); partially
    /// selected collections contribute one anchored link per chosen file —
    /// so a share picked whole opens/copies its page, while cherry-picked
    /// children open/copy their anchors, even when both happen at once.
    private func syncStripToSelection() {
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
                    pages.append("\(item.pageURL.absoluteString)#\(child.name)")
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

    // MARK: - Toolbar

    private var masterState: (icon: String, allSelected: Bool) {
        if selection.isEmpty { return ("square", false) }
        if selection == allLeafKeys { return ("checkmark.square.fill", true) }
        return ("minus.square.fill", true)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if masterState.allSelected {
                    selection.removeAll()
                } else {
                    selection = allLeafKeys
                }
            } label: {
                Image(systemName: masterState.icon)
            }
            .buttonStyle(.borderless)
            .disabled(store.visibleItems.isEmpty)
            .help("Select all")

            if confirming == Self.bulkConfirmID {
                HStack(spacing: 8) {
                    Button {
                        withAnimation { confirming = nil }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")

                    Button {
                        withAnimation { confirming = nil }
                        deleteSelected()
                    } label: {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete selection")
                }
                .padding(4)
                .contentShape(Rectangle())
                .transition(.scale.combined(with: .opacity))
                .onHover(perform: confirmRevertOnHover(Self.bulkConfirmID))
            } else {
                Button {
                    cancelRevert()
                    withAnimation { confirming = Self.bulkConfirmID }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty)
                .help("Delete selected")
            }

            // Archive (or unarchive) every share with a selected file —
            // non-destructive, so no confirm step.
            Button {
                archiveSelected()
            } label: {
                Image(systemName: store.showingArchive
                      ? "tray.and.arrow.up" : "archivebox")
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help(store.showingArchive ? "Unarchive selected" : "Archive selected")

            if !selection.isEmpty {
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if let progress = store.deleteProgress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(progress.done),
                                 total: Double(max(progress.total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text("Deleting \(progress.done)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.loading {
                ProgressView().controlSize(.small)
            }

            Button {
                store.showingArchive.toggle()
            } label: {
                Image(systemName: store.showingArchive ? "archivebox.fill" : "archivebox")
                    .foregroundStyle(store.showingArchive ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(store.showingArchive ? "Back to the list" : "Show archive")

            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Button {
                actions.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button {
                actions.close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Folder navigation

    private var pathSegments: [(label: String, prefix: String)] {
        var segments: [(String, String)] = []
        var prefix = ""
        for part in store.folder.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : "\(prefix)/\(part)"
            segments.append((String(part), prefix))
        }
        return segments
    }

    private var pathBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    actions.navigate("")
                } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.borderless)
                .help("Bucket root")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(pathSegments, id: \.prefix) { segment in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button(segment.label) {
                                actions.navigate(segment.prefix)
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                }

                Spacer()

                Button {
                    let parent = store.folder.split(separator: "/")
                        .dropLast().joined(separator: "/")
                    actions.navigate(parent)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(store.folder.isEmpty)
                .help("Up one level")

                Button {
                    withAnimation { newFolderName = newFolderName == nil ? "" : nil }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New folder")
            }

            if let name = newFolderName {
                HStack(spacing: 6) {
                    TextField("New folder name", text: Binding(
                        get: { name },
                        set: { newFolderName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitNewFolder() }
                    Button("Create") { submitNewFolder() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func submitNewFolder() {
        guard let name = newFolderName?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return }
        newFolderName = nil
        actions.createFolder(name)
    }

    private func folderRow(_ folderItem: FolderRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderItem.name)
                    .lineLimit(1)
                Text(folderItem.objectCount == 0 ? "Empty"
                     : "\(folderItem.objectCount) object\(folderItem.objectCount == 1 ? "" : "s")  ·  \(ByteCountFormatter.string(fromByteCount: folderItem.size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if folderItem.objectCount == 0 {
                deleteControls(id: "folder:\(folderItem.name)",
                               help: "Delete this empty folder") {
                    store.deleteEmptyFolder(named: folderItem.name)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            let prefix = store.folder.isEmpty
                ? folderItem.name : "\(store.folder)/\(folderItem.name)"
            actions.navigate(prefix)
        }
        .onHover(perform: confirmRevertOnHover("folder:\(folderItem.name)"))
    }

    /// Non-share files show for orientation only — no actions. This surface
    /// picks folders and manages shares; it is not a bucket editor.
    private func looseRow(_ file: LooseFile) -> some View {
        HStack(spacing: 10) {
            thumbnail(url: nil, kind: file.kind, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .opacity(0.75)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let browseRowsEmpty = store.visibleItems.isEmpty
            && (store.showingArchive || (store.folders.isEmpty && store.looseFiles.isEmpty))
        if let error = store.errorMessage {
            placeholder(icon: "exclamationmark.triangle", text: error)
        } else if browseRowsEmpty && !store.loading {
            placeholder(icon: store.showingArchive ? "archivebox" : "tray",
                        text: store.showingArchive
                            ? "Nothing archived."
                            : "Empty folder.\nDrop files below.")
        } else {
            // Plain ScrollView instead of List: deterministic padding, so the
            // row checkboxes line up exactly with the toolbar's (10 + 4 = 14).
            ScrollView {
                LazyVStack(spacing: 2) {
                    if !store.showingArchive {
                        ForEach(store.folders) { folderItem in
                            folderRow(folderItem)
                        }
                    }
                    ForEach(store.visibleItems) { item in
                        parentRow(item)
                        // children.count > 1: a share that shrinks to one item
                        // stops being a collection — no indented child row may
                        // outlive its chevron.
                        if expanded.contains(item.id), item.children.count > 1 {
                            ForEach(store.orderedChildren(item)) { child in
                                childRow(item, child)
                            }
                        }
                    }
                    if !store.showingArchive {
                        ForEach(store.looseFiles) { file in
                            looseRow(file)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .clipped()  // rows must not slide under the toolbar
        }
    }

    // MARK: - Rows

    private func kindIcon(_ kind: MediaKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .markdown, .text: return "doc.text"
        case .file, nil: return "doc"
        }
    }

    /// Preview thumbnail; kind icon when there isn't one.
    private func thumbnail(url: URL?, kind: MediaKind?, side: CGFloat) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: kindIcon(kind))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: kindIcon(kind))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func checkbox(isOn: Bool, mixed: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: mixed ? "minus.square.fill"
                  : isOn ? "checkmark.square.fill" : "square")
        }
        .buttonStyle(.borderless)
    }

    private func deleteControls(id: String, help: String,
                                perform: @escaping () -> Void) -> some View {
        Group {
            if confirming == id {
                HStack(spacing: 6) {
                    Button {
                        withAnimation { confirming = nil }
                        perform()
                    } label: {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")

                    Button {
                        withAnimation { confirming = nil }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                }
                .padding(4)
                .contentShape(Rectangle())
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    cancelRevert()
                    withAnimation { confirming = id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(help)
            }
        }
    }

    /// Confirm buttons revert only after a grace period, so grazing the edge
    /// of the row doesn't dismiss them.
    private func scheduleRevert(_ action: @escaping () -> Void) {
        revertTask?.cancel()
        let work = DispatchWorkItem { withAnimation { action() } }
        revertTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func cancelRevert() {
        revertTask?.cancel()
    }

    /// Hover handler for the view hosting the `id` confirm: entering pauses
    /// the pending revert, leaving arms it.
    private func confirmRevertOnHover(_ id: String) -> (Bool) -> Void {
        { hovering in
            if hovering {
                if confirming == id { cancelRevert() }
            } else if confirming == id {
                scheduleRevert { if confirming == id { confirming = nil } }
            }
        }
    }

    private func parentRow(_ item: ShareItem) -> some View {
        let dropTargeted = fileDropTargetID == item.id
        let childKeys = Set(item.children.map(\.key))
        let selectedCount = childKeys.intersection(selection).count
        let allSelected = !childKeys.isEmpty && selectedCount == childKeys.count
        // selection IS the highlight; highlightedID lingers only as the
        // post-upload flash
        let highlighted = selectedCount > 0
            || state.highlightedID == item.id || dropTargeted

        return HStack(spacing: 8) {
            checkbox(isOn: allSelected,
                     mixed: selectedCount > 0 && !allSelected) {
                if allSelected {
                    selection.subtract(childKeys)
                } else {
                    selection.formUnion(childKeys)
                }
            }

            if item.children.count > 1 {
                Button {
                    withAnimation {
                        if expanded.contains(item.id) {
                            expanded.remove(item.id)
                        } else {
                            expanded.insert(item.id)
                            store.loadOrder(for: item)  // list order = page order
                        }
                    }
                } label: {
                    Image(systemName: expanded.contains(item.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        // Keep the glyph compact, but make all of the space
                        // around it clickable instead of only the thin lines.
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                // The 24px hit box consumes the HStack's existing 8px gaps
                // on each side instead of pushing neighboring content away.
                .padding(.horizontal, -8)
                .help(expanded.contains(item.id)
                      ? "Collapse collection" : "Expand collection")
            }

            thumbnail(url: item.thumbURL, kind: item.kind, side: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.date.formatted(.relative(presentation: .named)))  ·  \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                handleSelectionClick(rowID: item.id, keys: childKeys)
            }

            if !store.showingArchive {
                Button {
                    store.setPinned(item, !item.isPinned)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin" : "Pin to top")
            }

            Button {
                if let highlighted = state.highlightedID,
                   highlighted == item.id || childKeys.contains(highlighted) {
                    clearHighlight()
                }
                selection.subtract(childKeys)
                store.setArchived(item, !store.showingArchive)
            } label: {
                Image(systemName: store.showingArchive
                      ? "tray.and.arrow.up" : "archivebox")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.showingArchive ? "Unarchive" : "Archive")

            deleteControls(id: item.id, help: "Delete this share") {
                if let highlighted = state.highlightedID,
                   highlighted == item.id || childKeys.contains(highlighted) {
                    clearHighlight()
                }
                selection.subtract(childKeys)
                store.applyDeletion(full: [item])
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .rowChrome(highlighted: highlighted, dropTargeted: dropTargeted,
                   deleting: store.deletingIDs.contains(item.id))
        .onDrop(of: [.fileURL], delegate: ShareFileDropDelegate(
            enabled: canAttachFiles && !store.deletingIDs.contains(item.id),
            setTargeted: { targeted in
                setFileDropTarget(item.id, targeted: targeted)
            },
            updateCount: { count in
                state.setDraggedFileCount(count, for: dropToken(item.id))
            },
            perform: { providers in
                performFileDrop(providers, into: item,
                                highlightedID: item.id,
                                name: item.title,
                                pageURL: item.pageURL.absoluteString,
                                fileURL: item.children.count == 1
                                    ? item.fileURL.absoluteString : nil)
            }))
        .onHover(perform: confirmRevertOnHover(item.id))
    }

    private func childRow(_ item: ShareItem, _ child: ShareChild) -> some View {
        let dropTargeted = fileDropTargetID == child.key
        let highlighted = selection.contains(child.key)
            || state.highlightedID == child.key || dropTargeted
        // Page link anchored to this file's <figure id> on the share page.
        let anchoredPageURL = "\(item.pageURL.absoluteString)#\(child.name)"
        return HStack(spacing: 8) {
            // Grip: drag to reorder within the collection. Dragging a checked
            // row moves the whole checked set.
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: UTType.dropperShareRow.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(child.key.utf8), nil)
                        return nil
                    }
                    return provider
                } preview: {
                    let count = selection.contains(child.key)
                        ? max(1, item.children.filter { selection.contains($0.key) }.count)
                        : 1
                    DragGhost(label: count > 1 ? "\(count) items" : child.name,
                              icon: kindIcon(child.kind))
                }
                .help("Drag to reorder")

            checkbox(isOn: selection.contains(child.key)) {
                if selection.contains(child.key) {
                    selection.remove(child.key)
                } else {
                    selection.insert(child.key)
                }
            }

            thumbnail(url: child.thumbURL, kind: child.kind, side: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(child.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: child.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                handleSelectionClick(rowID: child.key, keys: [child.key])
            }

            deleteControls(id: child.key, help: "Delete this file") {
                if state.highlightedID == child.key { clearHighlight() }
                selection.remove(child.key)
                store.applyDeletion(full: [], partial: [(item, [child])])
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 34)
        .padding(.trailing, 4)
        .rowChrome(highlighted: highlighted, dropTargeted: dropTargeted,
                   deleting: store.deletingIDs.contains(child.key))
        // Insertion gap: the target row parts to show where the drop lands.
        .padding(.top, insertion == Insertion(key: child.key, after: false) ? 16 : 0)
        .padding(.bottom, insertion == Insertion(key: child.key, after: true) ? 16 : 0)
        .overlay(alignment: .top) {
            if insertion == Insertion(key: child.key, after: false) { insertionLine }
        }
        .overlay(alignment: .bottom) {
            if insertion == Insertion(key: child.key, after: true) { insertionLine }
        }
        .onDrop(of: [.dropperShareRow], delegate: ReorderDropDelegate(
            setInsertion: { after in
                withAnimation(.easeInOut(duration: 0.15)) {
                    if let after {
                        insertion = Insertion(key: child.key, after: after)
                    } else if insertion?.key == child.key {
                        insertion = nil
                    }
                }
            },
            perform: { draggedKey, after in
                withAnimation(.easeInOut(duration: 0.15)) { insertion = nil }
                guard item.children.contains(where: { $0.key == draggedKey }) else { return }
                let moving = selection.contains(draggedKey)
                    ? store.orderedChildren(item).map(\.key).filter { selection.contains($0) }
                    : [draggedKey]
                store.reorderChildren(of: item, moving: moving,
                                      targetKey: child.key, after: after)
            }))
        .onDrop(of: [.fileURL], delegate: ShareFileDropDelegate(
            enabled: canAttachFiles && !store.deletingIDs.contains(child.key),
            setTargeted: { targeted in
                setFileDropTarget(child.key, targeted: targeted)
            },
            updateCount: { count in
                state.setDraggedFileCount(count, for: dropToken(child.key))
            },
            perform: { providers in
                performFileDrop(providers, into: item,
                                highlightedID: child.key,
                                name: child.name,
                                pageURL: anchoredPageURL,
                                fileURL: child.fileURL.absoluteString)
            }))
        .onHover(perform: confirmRevertOnHover(child.key))
    }

    private var footer: some View {
        Text(store.bucketSummary ?? " ")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }

    // MARK: - External file drops

    private var canAttachFiles: Bool {
        guard !store.showingArchive else { return false }
        if case .uploading = state.strip { return false }
        return true
    }

    private func dropToken(_ id: String) -> String {
        "share-row:\(id)"
    }

    /// Hover is transient and separate from the clicked/link selection. The
    /// conditional clear handles enter-B/exit-A event ordering correctly.
    private func setFileDropTarget(_ id: String, targeted: Bool) {
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

    private func performFileDrop(_ providers: [NSItemProvider], into item: ShareItem,
                                 highlightedID: String, name: String,
                                 pageURL: String, fileURL: String?) -> Bool {
        guard canAttachFiles, !providers.isEmpty else { return false }
        state.highlightedID = highlightedID
        state.strip = .links(name: name, pageURLs: [pageURL],
                             fileURLs: fileURL.map { [$0] } ?? [])
        actions.dropCommitted()
        loadFileURLs(from: providers) { urls in
            actions.droppedInto(urls, item.id)
        }
        return true
    }

    private func clearHighlight() {
        state.highlightedID = nil
        if selection.isEmpty, case .links = state.strip { state.strip = .idle }
    }

    /// Archives/unarchives every share that has a selected file.
    private func archiveSelected() {
        let archived = !store.showingArchive
        for item in store.visibleItems
        where item.children.contains(where: { selection.contains($0.key) }) {
            store.setArchived(item, archived)
        }
        selection.removeAll()
        clearHighlight()
    }

    /// Splits the leaf selection into whole shares and partial file sets.
    private func deleteSelected() {
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

    private var insertionLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 36)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    /// Shared row chrome: the selection/flash highlight fill, the external
    /// file-drop ring, and mid-delete dimming.
    func rowChrome(highlighted: Bool, dropTargeted: Bool,
                   deleting: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(dropTargeted ? 0.28
                                             : highlighted ? 0.16 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(dropTargeted ? 0.9 : 0), lineWidth: 1.5)
        )
        .opacity(deleting ? 0.4 : 1)
        .disabled(deleting)
    }
}
