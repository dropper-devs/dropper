import SwiftUI
import AppKit

struct ShareListView: View {
    @StateObject private var model: ShareListModel
    @ObservedObject var store: ShareStore
    @ObservedObject var state: UIState
    @ObservedObject private var viewCounts: ShareViewCountState
    let actions: PopoverActions

    init(store: ShareStore, state: UIState, actions: PopoverActions) {
        self.store = store
        self.state = state
        _viewCounts = ObservedObject(wrappedValue: store.viewCounts)
        self.actions = actions
        _model = StateObject(
            wrappedValue: ShareListModel(store: store, state: state, actions: actions))
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
        // Settings can rebuild the client, swapping a new store/actions into
        // this persistent view tree; keep the model pointed at the live one.
        .onChange(of: ObjectIdentifier(store)) { _, _ in
            model.rebind(store: store, state: state, actions: actions)
        }
        .onChange(of: store.showingArchive) { _, _ in
            model.resetForArchiveToggle()
        }
        .onChange(of: store.allItems) { _, items in
            model.reconcile(to: items)
        }
        .onChange(of: model.selection) { _, _ in
            model.syncStripToSelection()
        }
        .onDisappear { model.onListDisappear() }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleSelectAll()
            } label: {
                Image(systemName: model.masterState.icon)
            }
            .buttonStyle(.borderless)
            .disabled(store.visibleItems.isEmpty)
            .help("Select all")

            // Archive (or unarchive) every share with a selected file —
            // non-destructive, so no confirm step.
            Button {
                model.archiveSelected()
            } label: {
                Image(systemName: store.showingArchive
                      ? "tray.and.arrow.up" : "archivebox")
            }
            .buttonStyle(.borderless)
            .disabled(model.selection.isEmpty)
            .help(store.showingArchive ? "Unarchive selected" : "Archive selected")

            if model.confirming == .bulk {
                HStack(spacing: 8) {
                    Button {
                        withAnimation { model.confirming = nil }
                    } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")

                    Button {
                        withAnimation { model.confirming = nil }
                        model.deleteSelected()
                    } label: {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Delete selection")
                }
                .padding(4)
                .contentShape(Rectangle())
                .transition(.scale.combined(with: .opacity))
                .onHover(perform: model.confirmRevertOnHover(.bulk))
            } else {
                Button {
                    model.cancelRevert()
                    withAnimation { model.confirming = .bulk }
                } label: {
                    Image(systemName: "trash")
                        .offset(y: -1)
                }
                .buttonStyle(.borderless)
                .disabled(model.selection.isEmpty)
                .help("Delete selected")
            }

            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
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
                    model.toggleNewFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New folder")
            }

            if let name = model.newFolderName {
                HStack(spacing: 6) {
                    TextField("New folder name", text: Binding(
                        get: { name },
                        set: { model.newFolderName = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.submitNewFolder() }
                    Button("Create") { model.submitNewFolder() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func folderRow(_ folderItem: FolderRow) -> some View {
        HStack(spacing: 10) {
            Button {
                let prefix = store.folder.isEmpty
                    ? folderItem.name : "\(store.folder)/\(folderItem.name)"
                actions.navigate(prefix)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderItem.name)
                            .lineLimit(1)
                        Text(folderItem.objectCount == 0 ? "Empty"
                             : "\(rowPluralCount(folderItem.objectCount, "object"))  ·  \(rowFileSize(folderItem.size))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens this folder")
            if folderItem.objectCount == 0 {
                DeleteConfirmButton(model: model, target: .folder(folderItem.name),
                                    help: "Delete this empty folder") {
                    model.deleteEmptyFolder(named: folderItem.name)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .onHover(perform: model.confirmRevertOnHover(.folder(folderItem.name)))
    }

    /// Non-share files show for orientation only — no actions. This surface
    /// picks folders and manages shares; it is not a bucket editor.
    private func looseRow(_ file: LooseFile) -> some View {
        HStack(spacing: 10) {
            rowThumbnail(url: nil, kind: file.kind, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowFileSize(file.size))
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
            && (store.showingArchive
                || (store.folders.isEmpty && store.looseFiles.isEmpty))
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
                        ParentRow(item: item, model: model, store: store,
                                  state: state, viewCounts: viewCounts)
                        // children.count > 1: a share that shrinks to one item
                        // stops being a collection — no indented child row may
                        // outlive its chevron.
                        if model.expanded.contains(item.id), item.children.count > 1 {
                            CollectionChildrenView(item: item, model: model,
                                                   store: store, state: state)
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

    private var footer: some View {
        Text(store.bucketSummary ?? " ")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
