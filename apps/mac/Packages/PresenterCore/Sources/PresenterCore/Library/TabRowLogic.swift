import Foundation

public enum TabRowLogic {

    public static func mergedOrder(stored: [String], all: [String]) -> [String] {
        var order = stored.filter { all.contains($0) }
        for id in all where !order.contains(id) {
            order.append(id)
        }
        return order
    }

    public static func enabled(order: [String], hidden: Set<String>) -> [String] {
        let visible = order.filter { !hidden.contains($0) }
        return visible.isEmpty ? order : visible
    }

    public static func visibleCount(
        widths: [Double],
        spacing: Double,
        containerWidth: Double,
        chevronWidth: Double
    ) -> Int {
        guard !widths.isEmpty else { return 0 }
        func rowWidth(_ count: Int) -> Double {
            widths.prefix(count).reduce(0, +) + spacing * Double(max(0, count - 1))
        }
        if rowWidth(widths.count) <= containerWidth { return widths.count }
        let available = containerWidth - chevronWidth - spacing
        var count = 0
        while count < widths.count, rowWidth(count + 1) <= available {
            count += 1
        }
        return count
    }

    public static func distributedSpacing(
        widths: [Double],
        chevronWidth: Double?,
        containerWidth: Double,
        minimumSpacing: Double
    ) -> Double {
        let itemCount = widths.count + (chevronWidth == nil ? 0 : 1)
        guard itemCount > 1 else { return minimumSpacing }
        let leftover = containerWidth - widths.reduce(0, +) - (chevronWidth ?? 0)
        return max(minimumSpacing, leftover / Double(itemCount - 1))
    }
}

public enum ControlRackLogic {
    public static func groupedByFolder<T>(
        _ items: [T], path: (T) -> String
    ) -> [(folder: String, items: [T])] {
        var groups: [String: [T]] = [:]
        for item in items {
            groups[path(item), default: []].append(item)
        }
        var result: [(folder: String, items: [T])] = []
        if let root = groups[""] {
            result.append((folder: "", items: root))
        }
        for folder in groups.keys.filter({ !$0.isEmpty }).sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            result.append((folder: folder, items: groups[folder]!))
        }
        return result
    }
}
