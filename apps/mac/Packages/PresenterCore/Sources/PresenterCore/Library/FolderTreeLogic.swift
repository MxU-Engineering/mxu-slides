import Foundation

public struct FolderNode: Equatable {
    public let name: String
    public let path: String
    public var children: [FolderNode]

    public init(name: String, path: String, children: [FolderNode] = []) {
        self.name = name
        self.path = path
        self.children = children
    }
}

public enum FolderTreeLogic {
    public static func tree(paths: [String]) -> [FolderNode] {
        final class Builder {
            var children: [String: Builder] = [:]
        }
        let root = Builder()
        for path in paths where !path.isEmpty {
            var node = root
            for component in path.split(separator: "/").map(String.init) {
                if let child = node.children[component] {
                    node = child
                } else {
                    let child = Builder()
                    node.children[component] = child
                    node = child
                }
            }
        }
        func emit(_ builder: Builder, prefix: String) -> [FolderNode] {
            builder.children.keys
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { name in
                    let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                    return FolderNode(
                        name: name, path: path,
                        children: emit(builder.children[name]!, prefix: path))
                }
        }
        return emit(root, prefix: "")
    }
}
