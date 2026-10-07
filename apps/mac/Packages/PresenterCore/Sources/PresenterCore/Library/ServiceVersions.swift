import Foundation

public enum ServiceVersions {

    public static func running(_ service: Service, machineID: String, rememberedName: String?) -> ServiceVersion? {
        guard let versions = service.versions, !versions.isEmpty else { return nil }
        if let mine = versions.first(where: { $0.stations?.contains { $0.id == machineID } == true }) { return mine }
        guard let name = rememberedName else { return nil }
        return versions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static func apply(_ version: ServiceVersion, to main: Service) -> Service {
        var service = main
        service.versions = nil
        let changes = version.changes ?? []
        let changeByID = Dictionary(changes.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
        let added = Dictionary((version.added ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items = main.items.map { item in changeByID[item.id].map { changed(item, by: $0) } ?? item }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let movers = changes.filter { $0.after != nil && (byID[$0.itemId] != nil || added[$0.itemId] != nil) }
        let moving = Set(movers.map(\.itemId))
        items.removeAll { moving.contains($0.id) }
        for change in movers {
            guard let item = byID[change.itemId] ?? added[change.itemId] else { continue }
            if change.after == "" {
                items.insert(item, at: 0)
            } else if let anchor = items.firstIndex(where: { $0.id == change.after }) {
                items.insert(item, at: anchor + 1)
            } else {

                items.append(item)
            }
        }
        items += (version.added ?? []).filter { !moving.contains($0.id) }
        service.items = items
        return service
    }

    public static func edit(_ main: inout Service, versionID: String, _ mutate: (inout Service) -> Void) {
        guard var versions = main.versions, let index = versions.firstIndex(where: { $0.id == versionID }) else { return }
        var edited = apply(versions[index], to: main)
        mutate(&edited)
        let recorded = record(edited.items, main: main.items)
        versions[index].added = recorded.added.isEmpty ? nil : recorded.added
        versions[index].changes = recorded.changes.isEmpty ? nil : recorded.changes
        edited.items = recorded.main
        edited.versions = versions
        main = edited
    }

    public static func allItems(_ service: Service) -> [ServiceItem] {
        service.items + (service.versions ?? []).flatMap { apply($0, to: service).items }
    }

    @discardableResult
    public static func create(name: String, in service: inout Service, id: String = UUID().uuidString) -> String {
        service.versions = (service.versions ?? []) + [ServiceVersion(id: id, name: name)]
        return id
    }

    public static func choose(_ versionID: String?, in service: inout Service, computer: ServiceVersionStation) {
        guard var versions = service.versions else { return }
        for index in versions.indices {
            var stations = (versions[index].stations ?? []).filter { $0.id != computer.id }
            if versions[index].id == versionID { stations.append(computer) }
            if stations != (versions[index].stations ?? []) { versions[index].stations = stations.isEmpty ? nil : stations }
        }
        service.versions = versions
    }

    public static func useMain(itemID: String, versionID: String, in service: inout Service) {
        guard let index = service.versions?.firstIndex(where: { $0.id == versionID }) else { return }
        let changes = service.versions?[index].changes?.filter { $0.itemId != itemID }
        service.versions?[index].changes = changes?.isEmpty == true ? nil : changes
    }

    public static func changedItemIDs(_ version: ServiceVersion) -> Set<String> {
        let added = Set((version.added ?? []).map(\.id))
        return Set((version.changes ?? []).map(\.itemId)).subtracting(added)
    }

    private static func changed(_ item: ServiceItem, by change: ServiceItemChange) -> ServiceItem {
        var item = item
        if let hidden = change.hidden { item.hiddenInPresenter = hidden ? true : nil }
        if let kind = change.itemKind { item.itemKind = kind }
        if let refId = change.refId { item.refId = refId }
        if let name = change.name { item.name = name }
        if let arrangement = change.arrangementId { item.arrangementId = arrangement.isEmpty ? nil : arrangement }
        if let look = change.outputPresetId { item.outputPresetId = look.isEmpty ? nil : look }
        return item
    }

    static func record(_ edited: [ServiceItem], main: [ServiceItem]) -> (added: [ServiceItem], changes: [ServiceItemChange], main: [ServiceItem]) {
        let mainIndex = Dictionary(main.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let inPlace = longestInOrder(edited.compactMap { mainIndex[$0.id] })
        var mainItems = main
        var added: [ServiceItem] = []
        var changes: [ServiceItemChange] = []
        var previous = ""
        for item in edited {
            defer { previous = item.id }
            guard let index = mainIndex[item.id] else {
                added.append(item)
                changes.append(ServiceItemChange(itemId: item.id, after: previous))
                continue
            }
            let base = main[index]
            var change = ServiceItemChange(itemId: item.id)
            if !inPlace.contains(index) { change.after = previous }
            if (item.hiddenInPresenter ?? false) != (base.hiddenInPresenter ?? false) { change.hidden = item.hiddenInPresenter ?? false }
            if item.itemKind != base.itemKind { change.itemKind = item.itemKind }
            if item.refId != base.refId { change.refId = item.refId }
            if item.name != base.name { change.name = item.name }
            if item.arrangementId != base.arrangementId { change.arrangementId = item.arrangementId ?? "" }
            if item.outputPresetId != base.outputPresetId { change.outputPresetId = item.outputPresetId ?? "" }
            if change != ServiceItemChange(itemId: item.id) { changes.append(change) }
            var shared = item
            shared.hiddenInPresenter = base.hiddenInPresenter
            shared.itemKind = base.itemKind
            shared.refId = base.refId
            shared.name = base.name
            shared.arrangementId = base.arrangementId
            shared.outputPresetId = base.outputPresetId
            mainItems[index] = shared
        }
        let kept = Set(edited.map(\.id))
        changes += main.filter { !kept.contains($0.id) }.map { ServiceItemChange(itemId: $0.id, hidden: true) }
        return (added, changes, mainItems)
    }

    private static func longestInOrder(_ indexes: [Int]) -> Set<Int> {
        guard !indexes.isEmpty else { return [] }
        var length = Array(repeating: 1, count: indexes.count)
        var parent = Array(repeating: -1, count: indexes.count)
        for i in indexes.indices {
            for j in 0..<i where indexes[j] < indexes[i] && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                parent[i] = j
            }
        }
        var at = length.indices.max { length[$0] < length[$1] } ?? 0
        var out: Set<Int> = []
        while at >= 0 {
            out.insert(indexes[at])
            at = parent[at]
        }
        return out
    }
}
