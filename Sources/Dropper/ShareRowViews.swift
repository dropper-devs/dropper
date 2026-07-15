import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared row UI

func rowKindIcon(_ kind: MediaKind?) -> String {
    switch kind {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    case .markdown, .text: return "doc.text"
    case .file, nil: return "doc"
    }
}

/// The app's one byte formatter for row/footer sizes.
func rowFileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// "1 object" / "3 objects".
func rowPluralCount(_ count: Int, _ singular: String) -> String {
    "\(count) \(singular)\(count == 1 ? "" : "s")"
}

/// Preview thumbnail; kind icon when there isn't one.
@ViewBuilder
func rowThumbnail(url: URL?, kind: MediaKind?, side: CGFloat) -> some View {
    Group {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: rowKindIcon(kind)).foregroundStyle(.secondary)
            }
        } else {
            Image(systemName: rowKindIcon(kind)).foregroundStyle(.secondary)
        }
    }
    .frame(width: side, height: side)
    .background(Color.secondary.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    // A `.fill` landscape cover overflows the frame and clipShape masks only the
    // pixels, not the hit region. Pin the hit shape to the frame: that stops the
    // overflow swallowing the adjacent chevron/grip AND keeps the thumbnail
    // clickable, so callers can make it part of the row's select area.
    .contentShape(Rectangle())
}

func rowCheckbox(isOn: Bool, mixed: Bool = false,
                 action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: mixed ? "minus.square.fill"
              : isOn ? "checkmark.square.fill" : "square")
    }
    .buttonStyle(.borderless)
}

/// The reorder drop indicator drawn above/below a child row.
func rowInsertionLine() -> some View {
    Capsule()
        .fill(Color.accentColor)
        .frame(height: 2)
        .padding(.horizontal, 36)
}

extension View {
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

/// Trash → (confirm / cancel) control shared by every per-row delete. The
/// grace-period revert is driven by the row's own `.onHover` through the
/// model; this view only arms and fires.
struct DeleteConfirmButton: View {
    @ObservedObject var model: ShareListModel
    let target: ShareListModel.ConfirmTarget
    let help: String
    let perform: () -> Void

    var body: some View {
        Group {
            if model.confirming == target {
                HStack(spacing: 6) {
                    Button {
                        withAnimation { model.confirming = nil }
                        perform()
                    } label: {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")

                    Button {
                        withAnimation { model.confirming = nil }
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
                    model.cancelRevert()
                    withAnimation { model.confirming = target }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .offset(y: -2)
                }
                .buttonStyle(.borderless)
                .help(help)
            }
        }
    }
}

// MARK: - Parent (share) row

struct ParentRow: View {
    let item: ShareItem
    @ObservedObject var model: ShareListModel
    @ObservedObject var store: ShareStore
    @ObservedObject var state: UIState
    @ObservedObject var viewCounts: ShareViewCountState

    var body: some View {
        let dropTargeted = model.fileDropTargetID == item.id
        let childKeys = Set(item.children.map(\.key))
        let selectedCount = childKeys.intersection(model.selection).count
        let allSelected = !childKeys.isEmpty && selectedCount == childKeys.count
        // selection IS the highlight; highlightedID lingers only as the
        // post-upload flash
        let highlighted = selectedCount > 0
            || state.highlightedID == item.id || dropTargeted

        return HStack(spacing: 8) {
            // For collections, the expansion button is the entire existing
            // 24-point gap between the checkbox and thumbnail. Keeping these
            // three controls in a zero-spacing group makes that a real hit
            // target instead of relying on negatively padded overflow.
            HStack(spacing: item.children.count > 1 ? 0 : 8) {
                rowCheckbox(isOn: allSelected,
                            mixed: selectedCount > 0 && !allSelected) {
                    model.toggleShareSelection(childKeys: childKeys, allSelected: allSelected)
                }

                if item.children.count > 1 {
                    Button {
                        withAnimation { model.toggleExpanded(item) }
                    } label: {
                        Image(systemName: model.expanded.contains(item.id)
                              ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
                    .help(model.expanded.contains(item.id)
                          ? "Collapse collection" : "Expand collection")
                }

                rowThumbnail(url: item.thumbURL, kind: item.kind, side: 30)
                    .onTapGesture {
                        model.handleSelectionClick(rowID: item.id, keys: childKeys)
                    }
            }

            Button {
                model.handleSelectionClick(rowID: item.id, keys: childKeys)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let count = viewCount(for: item) {
                        Text(metadata(for: item, viewCount: count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Page views in the last 31 days")
                            .accessibilityLabel(metadataAccessibilityLabel(
                                for: item, viewCount: count))
                    } else {
                        Text(metadata(for: item, viewCount: nil))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityValue(allSelected ? "Selected"
                : selectedCount > 0 ? "Partially selected" : "Not selected")
            .accessibilityHint("Selects or deselects this share")

            if !store.showingArchive {
                Button {
                    model.pinToggle(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(item.isPinned ? "Unpin" : "Pin to top")
            }

            Button {
                model.archiveRow(item, childKeys: childKeys)
            } label: {
                Image(systemName: store.showingArchive
                      ? "tray.and.arrow.up" : "archivebox")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(store.showingArchive ? "Unarchive" : "Archive")

            DeleteConfirmButton(model: model, target: .share(item.id),
                                help: "Delete this share") {
                model.deleteShare(item, childKeys: childKeys)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .rowChrome(highlighted: highlighted, dropTargeted: dropTargeted,
                   deleting: store.deletingIDs.contains(item.id))
        .onDrop(of: [.fileURL], delegate: ShareFileDropDelegate(
            enabled: model.fileDropEnabled(id: item.id),
            setTargeted: { targeted in
                model.setFileDropTarget(item.id, targeted: targeted)
            },
            updateCount: { count in
                model.reportExternalDragCount(count, for: item.id)
            },
            perform: { providers in
                model.performFileDrop(providers, into: item,
                                      highlightedID: item.id,
                                      name: item.title,
                                      pageURL: item.pageURL.absoluteString,
                                      fileURL: item.children.count == 1
                                          ? item.fileURL.absoluteString : nil)
            }))
        .onHover(perform: model.confirmRevertOnHover(.share(item.id)))
    }

    private func viewCount(for item: ShareItem) -> Int64? {
        guard let pageKey = item.keys.first(where: {
            $0 == "index.html" || $0.hasSuffix("/index.html")
        }) else { return nil }
        return viewCounts.count(forPageKey: pageKey)
    }

    private func metadata(for item: ShareItem, viewCount: Int64?) -> String {
        var parts = [item.date.formatted(.relative(presentation: .named))]
        if let viewCount {
            let number = viewCount.formatted(.number.grouping(.automatic))
            parts.append("\(number) \(viewCount == 1 ? "view" : "views")")
        }
        parts.append(rowFileSize(item.size))
        return parts.joined(separator: "  ·  ")
    }

    private func metadataAccessibilityLabel(
        for item: ShareItem, viewCount: Int64
    ) -> String {
        let number = viewCount.formatted(.number.grouping(.automatic))
        let views = "\(number) page \(viewCount == 1 ? "view" : "views") in the last 31 days"
        let size = rowFileSize(item.size)
        return "\(item.date.formatted(.relative(presentation: .named))), \(views), \(size)"
    }
}

// MARK: - Child (file) row

struct ChildRow: View {
    let item: ShareItem
    let child: ShareChild
    @ObservedObject var model: ShareListModel
    @ObservedObject var store: ShareStore
    @ObservedObject var state: UIState
    /// Live reorder drag from the grip. `CollectionChildrenView` owns the
    /// reorder state and applies the row offsets; `dy` is vertical translation.
    let onReorderChanged: (CGFloat) -> Void
    let onReorderEnded: (CGFloat) -> Void

    var body: some View {
        let dropTargeted = model.fileDropTargetID == child.key
        let highlighted = model.selection.contains(child.key)
            || state.highlightedID == child.key || dropTargeted
        // Page link anchored to this file's <figure id> on the share page.
        let anchoredPageURL = "\(item.pageURL.absoluteString)#\(child.fileName)"
        return HStack(spacing: 8) {
            // Leading indent is an INVISIBLE checkbox (same width as the
            // parent's) so the grip lands directly under the collection's
            // chevron — the grip sits exactly where the chevron is, no magic
            // numbers.
            HStack(spacing: 0) {
                rowCheckbox(isOn: false, action: {})
                    .hidden()
                    .accessibilityHidden(true)
                // Grip: drag to reorder within THIS collection. A DragGesture
                // drives it (not an AppKit drag session), so it's reliable and
                // can only move files inside their own collection. A checked row
                // moves the whole checked set on commit.
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 30)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 5, coordinateSpace: .local)
                            .onChanged { onReorderChanged($0.translation.height) }
                            .onEnded { onReorderEnded($0.translation.height) }
                    )
                    .help("Drag to reorder")
            }

            rowCheckbox(isOn: model.selection.contains(child.key)) {
                model.toggleChildSelection(child.key)
            }

            rowThumbnail(url: child.thumbURL, kind: child.kind, side: 24)
                .onTapGesture {
                    model.handleSelectionClick(rowID: child.key, keys: [child.key])
                }

            Button {
                model.handleSelectionClick(rowID: child.key, keys: [child.key])
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(child.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(rowFileSize(child.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityValue(model.selection.contains(child.key)
                ? "Selected" : "Not selected")
            .accessibilityHint("Selects or deselects this file")

            DeleteConfirmButton(model: model, target: .child(child.key),
                                help: "Delete this file") {
                model.deleteChild(item, child)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .rowChrome(highlighted: highlighted, dropTargeted: dropTargeted,
                   deleting: store.deletingIDs.contains(child.key))
        .onDrop(of: [.fileURL], delegate: ShareFileDropDelegate(
            enabled: model.fileDropEnabled(id: child.key),
            setTargeted: { targeted in
                model.setFileDropTarget(child.key, targeted: targeted)
            },
            updateCount: { count in
                model.reportExternalDragCount(count, for: child.key)
            },
            perform: { providers in
                model.performFileDrop(providers, into: item,
                                      highlightedID: child.key,
                                      name: child.name,
                                      pageURL: anchoredPageURL,
                                      fileURL: child.fileURL.absoluteString)
            }))
        .onHover(perform: model.confirmRevertOnHover(.child(child.key)))
    }
}

private struct ChildRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 34
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Drag-to-reorder for one expanded collection's children.
///
/// The grip drives a `DragGesture` (NOT an AppKit `.onDrag`/`.onDrop` session —
/// that model was flaky and let files cross between collections). The picked row
/// follows the pointer and the others slide to open a slot; on release the move
/// is committed and persisted. Reordering is strictly scoped to THIS collection:
/// there is no cross-collection drop target, so a file can never land elsewhere.
struct CollectionChildrenView: View {
    let item: ShareItem
    @ObservedObject var model: ShareListModel
    @ObservedObject var store: ShareStore
    @ObservedObject var state: UIState

    @State private var draggingKey: String?
    @State private var slotGap: Int?          // gap the blue bar snaps to (0...count)
    @State private var rowUnit: CGFloat = 34  // measured row height + spacing

    var body: some View {
        let children = store.orderedChildren(item)
        VStack(spacing: 2) {
            ForEach(Array(children.enumerated()), id: \.element.key) { _, child in
                ChildRow(
                    item: item, child: child, model: model, store: store, state: state,
                    onReorderChanged: { dy in dragChanged(key: child.key, dy: dy, children: children) },
                    onReorderEnded: { dy in commit(key: child.key, dy: dy) })
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: ChildRowHeightKey.self, value: proxy.size.height)
                    })
                    // The picked row stays put and just dims; NOTHING follows the
                    // pointer (that ghost is what vibrated). The blue bar shows
                    // where it will land.
                    .opacity(child.key == draggingKey ? 0.4 : 1)
            }
        }
        .overlay(alignment: .top) {
            if let y = insertionY() {
                insertionBar.offset(y: y)
            }
        }
        .onPreferenceChange(ChildRowHeightKey.self) { height in
            if height > 1 { rowUnit = height + 2 }   // + the VStack spacing
        }
        .animation(.easeInOut(duration: 0.15), value: slotGap)
        .animation(.easeInOut(duration: 0.15), value: draggingKey)
    }

    /// The classic drop indicator: an accent dot with a trailing bar.
    private var insertionBar: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func insertionY() -> CGFloat? {
        guard let slotGap, draggingKey != nil else { return nil }
        return CGFloat(slotGap) * rowUnit - 5   // center the ~9pt indicator on the gap
    }

    /// The gap (0...count) the pointer is nearest. EVERY gap is reachable,
    /// including the two around the file's own slot, so you can drop it back.
    private func gap(from: Int, count: Int, translation: CGFloat) -> Int {
        let pointer = Double(from) + 0.5 + Double(translation) / Double(rowUnit)
        return min(max(Int(pointer.rounded()), 0), count)
    }

    private func dragChanged(key: String, dy: CGFloat, children: [ShareChild]) {
        if draggingKey != key { draggingKey = key }
        guard let from = children.firstIndex(where: { $0.key == key }) else { return }
        let g = gap(from: from, count: children.count, translation: dy)
        if g != slotGap {
            withAnimation(.easeInOut(duration: 0.15)) { slotGap = g }
        }
    }

    private func commit(key: String, dy: CGFloat) {
        let children = store.orderedChildren(item)
        guard let from = children.firstIndex(where: { $0.key == key }) else {
            draggingKey = nil
            slotGap = nil
            return
        }
        let g = gap(from: from, count: children.count, translation: dy)
        // Commit + clear the indicator in one animated transaction. Dropping in
        // the file's own gap is a no-op (reorderChildren guards it), so it just
        // settles back into place.
        withAnimation(.easeInOut(duration: 0.2)) {
            if g == 0 {
                model.reorder(in: item, draggedKey: key,
                              targetKey: children[0].key, after: false)
            } else {
                model.reorder(in: item, draggedKey: key,
                              targetKey: children[g - 1].key, after: true)
            }
            draggingKey = nil
            slotGap = nil
        }
    }
}
