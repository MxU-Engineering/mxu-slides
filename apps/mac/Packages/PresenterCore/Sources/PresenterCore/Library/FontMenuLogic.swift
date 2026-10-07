import Foundation

public enum FontMenuLogic {
    public static let recentLimit = 5

    public static func recents(adding family: String, to recents: [String]) -> [String] {
        var next = recents.filter { $0 != family }
        next.insert(family, at: 0)
        return Array(next.prefix(recentLimit))
    }

    public static func installedRecents(_ recents: [String], installed: [String]) -> [String] {
        let set = Set(installed)
        return recents.filter { set.contains($0) }
    }

    public static func filter(_ families: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return families }
        var prefix: [String] = []
        var contains: [String] = []
        for family in families {
            let lower = family.lowercased()
            if lower.hasPrefix(needle) {
                prefix.append(family)
            } else if lower.contains(needle) {
                contains.append(family)
            }
        }
        return prefix + contains
    }
}
