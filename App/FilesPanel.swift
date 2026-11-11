import SwiftUI
import TermCore
import UniformTypeIdentifiers

/// Browser for the on-device workspace: the files the agent reads and writes.
struct FilesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var entries: [WorkspaceEntry] = []
    @State private var importing = false

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let palette = model.palette
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(palette.dim)
                    TextField("", text: $query, prompt: Text("Filter files").foregroundStyle(palette.dim))
                        .foregroundStyle(palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .font(palette.label)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .card(palette, fill: palette.code, radius: 10)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if entries.isEmpty {
                    Text(isSearching ? "No files match." : "No files yet. Files the agent writes appear here, and + imports one from your iPhone.")
                        .font(palette.label)
                        .foregroundStyle(palette.dim)
                        .multilineTextAlignment(.center)
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    List {
                        ForEach(entries) { entry in
                            FileRow(entry: entry, isExpanded: expanded.contains(entry.path), showsPath: isSearching, palette: palette) {
                                toggle(entry)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.deleteFile(entry.path)
                                    reload()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(palette.background.ignoresSafeArea())
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import file")
                }
            }
            .navigationDestination(for: WorkspaceEntry.self) { entry in
                FilePreview(entry: entry, onDelete: reload)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: query) { reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                model.importFiles(urls)
                reload()
            }
        }
    }

    private func toggle(_ entry: WorkspaceEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
        }
        reload()
    }

    private func reload() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        entries = needle.isEmpty
            ? WorkspaceFiles.tree(root: model.workspace, expanded: expanded)
            : WorkspaceFiles.search(root: model.workspace, query: needle)
    }
}

private struct FileRow: View {
    let entry: WorkspaceEntry
    let isExpanded: Bool
    /// Search results come from anywhere in the tree, so they show their full path.
    let showsPath: Bool
    let palette: Palette
    let toggle: () -> Void

    var body: some View {
        if entry.isDirectory {
            Button(action: toggle) {
                label(icon: "chevron.right", rotation: isExpanded ? 90 : 0)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: entry) {
                label(icon: "doc", rotation: 0)
            }
        }
    }

    private func label(icon: String, rotation: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.dim)
                .rotationEffect(.degrees(rotation))
                .frame(width: 18)
            Text(showsPath ? entry.path : entry.name)
                .font(palette.prose)
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, showsPath ? 0 : CGFloat(entry.depth) * 18)
        .frame(height: 40)
        .contentShape(Rectangle())
    }
}

private struct FilePreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: WorkspaceEntry
    let onDelete: () -> Void
    @State private var text: String?
    @State private var loaded = false

    var body: some View {
        let palette = model.palette
        ScrollView {
            content(palette)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(palette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button {
                model.attach(path: entry.path)
            } label: {
                Label("Add to message", systemImage: "paperclip")
                    .font(palette.labelBold)
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(palette.background)
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: model.workspace.appendingPathComponent(entry.path)) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    model.deleteFile(entry.path)
                    onDelete()
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete file")
            }
        }
        .onAppear {
            text = WorkspaceFiles.text(root: model.workspace, path: entry.path)
            loaded = true
        }
    }

    @ViewBuilder
    private func content(_ palette: Palette) -> some View {
        if let text {
            Text(text.isEmpty ? "(empty file)" : text)
                .font(palette.mono)
                .foregroundStyle(text.isEmpty ? palette.dim : palette.text)
                .textSelection(.enabled)
        } else if loaded {
            Text("This file is not UTF-8 text, so there is no preview.")
                .font(palette.label)
                .foregroundStyle(palette.dim)
        }
    }
}
