import Foundation

/// A file or folder in the on-device workspace, addressed by its path relative to the workspace root.
public struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    public var path: String
    public var isDirectory: Bool
    public var size: Int

    public init(path: String, isDirectory: Bool, size: Int = 0) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }

    public var id: String { path }
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// Nesting level below the workspace root.
    public var depth: Int { max(path.split(separator: "/").count - 1, 0) }
}

/// Read-only views of the workspace for the file browser. Paths are confined to the workspace like the agent's file tools.
public enum WorkspaceFiles {
    /// Entries directly inside `directory` ("" is the root): folders first, then files, each by name.
    public static func list(root: URL, directory: String = "") -> [WorkspaceEntry] {
        guard let url = try? ToolBox(workspace: root, shell: nil).resolve(directory),
              let children = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        let prefix = directory.isEmpty ? "" : directory + "/"
        return children.map { child -> WorkspaceEntry in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return WorkspaceEntry(path: prefix + child.lastPathComponent, isDirectory: values?.isDirectory == true,
                                  size: values?.fileSize ?? 0)
        }
        .sorted { first, second in
            first.isDirectory != second.isDirectory ? first.isDirectory : first.name.lowercased() < second.name.lowercased()
        }
    }

    /// The tree flattened in display order, descending only into `expanded` folders.
    public static func tree(root: URL, expanded: Set<String>) -> [WorkspaceEntry] {
        func walk(_ directory: String) -> [WorkspaceEntry] {
            list(root: root, directory: directory).flatMap { entry -> [WorkspaceEntry] in
                entry.isDirectory && expanded.contains(entry.path) ? [entry] + walk(entry.path) : [entry]
            }
        }
        return walk("")
    }

    /// Files anywhere in the workspace whose path contains `query`, ignoring case.
    public static func search(root: URL, query: String, limit: Int = 200) -> [WorkspaceEntry] {
        let needle = query.lowercased()
        var matches: [WorkspaceEntry] = []
        var pending = [""]
        // Bounded so a huge or cyclic tree cannot stall the UI.
        var visited = 0
        while let directory = pending.popLast(), visited < 2_000 {
            visited += 1
            for entry in list(root: root, directory: directory) {
                if entry.isDirectory {
                    pending.append(entry.path)
                } else if entry.path.lowercased().contains(needle) {
                    matches.append(entry)
                }
            }
        }
        return Array(matches.sorted { $0.path.lowercased() < $1.path.lowercased() }.prefix(limit))
    }

    /// Text of a workspace file for previewing; nil when it is missing, outside the workspace or not UTF-8.
    public static func text(root: URL, path: String, limit: Int = 200_000) -> String? {
        guard let url = try? ToolBox(workspace: root, shell: nil).resolve(path),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "\n… [truncated]" : text
    }
}
