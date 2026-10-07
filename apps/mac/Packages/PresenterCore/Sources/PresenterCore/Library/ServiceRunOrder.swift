import Foundation

public enum ServiceRunOrder {

    public static func nextFireable(in show: [ServiceItem], after itemID: String) -> ServiceItem? {
        guard let index = show.firstIndex(where: { $0.id == itemID }) else { return nil }
        return show[(index + 1)...].first { $0.itemKind == .presentation || $0.itemKind == .media }
    }

    public static func ordered(_ items: [ServiceItem], by order: [String]?) -> [ServiceItem] {
        guard let order, !order.isEmpty else { return items }
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var leading: [ServiceItem] = []
        var buckets: [Int: [ServiceItem]] = [:]
        var current: Int?
        for item in items {
            if let hexId = item.mxuItemHexId, let slot = position[hexId] {
                current = slot
                buckets[slot, default: []].insert(item, at: 0)
            } else if let slot = current {
                buckets[slot, default: []].append(item)
            } else {
                leading.append(item)
            }
        }
        return leading + buckets.keys.sorted().flatMap { buckets[$0] ?? [] }
    }

    public static func visible(
        _ items: [ServiceItem], timeHexId: String? = nil, order: [String]? = nil
    ) -> [ServiceItem] {
        ordered(items.filter { $0.isInRunOfShow(timeHexId: timeHexId) }, by: order)
    }

    public static func hidden(_ items: [ServiceItem]) -> [ServiceItem] {
        items.filter(\.isHidden)
    }

    public static func divergentTimes(
        _ items: [ServiceItem], times: [MxUPlanTime], orders: [MxUPlanTimeOrder]?,
        selectedTimeHexId: String?
    ) -> [MxUPlanTime] {
        guard times.count > 1 else { return [] }
        let referenceHexId = selectedTimeHexId ?? times[0].hexId
        guard times.contains(where: { $0.hexId == referenceHexId }) else { return [] }
        func run(_ hexId: String) -> [String] {
            visible(items, timeHexId: hexId, order: orders?.first { $0.timeHexId == hexId }?.itemHexIds)
                .map(\.id)
        }
        let reference = run(referenceHexId)
        return times.filter { $0.hexId != referenceHexId && run($0.hexId) != reference }
    }

    public static func fireable(
        _ items: [ServiceItem], timeHexId: String? = nil, order: [String]? = nil
    ) -> [ServiceItem] {
        visible(items, timeHexId: timeHexId, order: order)
            .filter { $0.itemKind == .presentation || $0.itemKind == .media }
    }

    public static func sidebarRows(
        _ items: [ServiceItem], collapsedHeaders: Set<String>,
        timeHexId: String? = nil, order: [String]? = nil
    ) -> [ServiceItem] {
        var result: [ServiceItem] = []
        var inCollapsedGroup = false
        for item in ordered(items, by: order) {
            let shown = item.isInRunOfShow(timeHexId: timeHexId)
            if item.itemKind == .header {
                inCollapsedGroup = shown && collapsedHeaders.contains(item.id)
                if shown { result.append(item) }
            } else if shown, !inCollapsedGroup {
                result.append(item)
            }
        }
        return result
    }
}

public extension ServiceItem {

    var isHidden: Bool { hiddenInPresenter == true }

    func applies(toTime timeHexId: String?) -> Bool {
        guard let timeHexId else { return true }
        return !(excludedTimeHexIds ?? []).contains(timeHexId)
    }

    func isInRunOfShow(timeHexId: String?) -> Bool {
        !isHidden && applies(toTime: timeHexId)
    }
}
