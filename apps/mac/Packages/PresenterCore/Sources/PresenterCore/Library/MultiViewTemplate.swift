import Foundation

public enum MultiViewTemplate: String, CaseIterable, Sendable {
    case wideGrid
    case wideFeature
    case tallStack

    public struct Source: Equatable, Sendable {
        public var screenId: String
        public var name: String

        public init(screenId: String, name: String) {
            self.screenId = screenId
            self.name = name
        }
    }

    public var title: String {
        switch self {
        case .wideGrid: "MultiView — 2 × 2"
        case .wideFeature: "MultiView — 1 + 3"
        case .tallStack: "MultiView — Tall Stack"
        }
    }

    public var canvasWidth: Int { self == .tallStack ? 1080 : 1920 }
    public var canvasHeight: Int { self == .tallStack ? 1920 : 1080 }

    var tree: MultiViewTree {
        switch self {
        case .wideGrid:
            return MultiViewTiles.grid(columns: 2, rows: 2)
        case .wideFeature:
            let feature = MultiViewTiles.tile()
            let side = (0..<3).map { _ in MultiViewTiles.tile() }
            let reads = Self.reads([.clock, .timer, .videoCountdown])
            let sideColumn = MultiViewNode(id: UUID().uuidString, axis: .rows, children: side.map(\.id))
            let monitors = MultiViewNode(
                id: UUID().uuidString, axis: .columns,
                children: [feature.id, sideColumn.id], fractions: [2.0 / 3, 1.0 / 3])
            let strip = MultiViewNode(id: UUID().uuidString, axis: .columns, children: reads.map(\.id))
            let root = MultiViewNode(
                id: UUID().uuidString, axis: .rows,
                children: [monitors.id, strip.id], fractions: [0.8, 0.2])
            return MultiViewTree(
                rootId: root.id, nodes: [feature] + side + reads + [sideColumn, monitors, strip, root])
        case .tallStack:
            let monitors = (0..<3).map { _ in MultiViewTiles.tile() }
            let reads = Self.reads([.clock, .timer])
            let strip = MultiViewNode(id: UUID().uuidString, axis: .columns, children: reads.map(\.id))
            let root = MultiViewNode(
                id: UUID().uuidString, axis: .rows,
                children: monitors.map(\.id) + [strip.id], fractions: [0.29, 0.29, 0.29, 0.13])
            return MultiViewTree(rootId: root.id, nodes: monitors + reads + [strip, root])
        }
    }

    private static func reads(_ kinds: [MultiViewSourceKind]) -> [MultiViewNode] {
        kinds.map { MultiViewNode(id: UUID().uuidString, sourceKind: $0) }
    }

    public func make(name: String, sources: [Source] = []) -> ConfidenceLayout {
        var tree = tree
        let context = MultiViewTiles.Context(
            screens: sources.map { .init(id: $0.screenId, name: $0.name) })
        let empties = MultiViewTiles.layout(tree, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            .tiles.map(\.node).filter { ($0.sourceKind ?? .empty) == .empty }
        for (tile, source) in zip(empties, sources) {
            tree = MultiViewTiles.update(tree, tile: tile.id) {
                $0.sourceKind = .screen
                $0.screenSourceId = source.screenId
                $0.screenSourceName = source.name
            }
        }
        let isDefaultCanvas = canvasWidth == 1920 && canvasHeight == 1080
        return ConfidenceLayout(
            id: UUID().uuidString, name: name,
            objects: MultiViewTiles.objects(
                for: tree, canvasWidth: canvasWidth, canvasHeight: canvasHeight, context: context),

            canvasWidth: isDefaultCanvas ? nil : canvasWidth,
            canvasHeight: isDefaultCanvas ? nil : canvasHeight,
            multiView: tree
        )
    }
}
