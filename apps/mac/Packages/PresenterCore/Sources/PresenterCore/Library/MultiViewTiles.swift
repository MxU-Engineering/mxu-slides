import Foundation

public enum MultiViewTiles {

    public struct Context: Sendable {
        public struct Screen: Equatable, Sendable {
            public var id: String
            public var name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public var screens: [Screen]

        public var aspects: [String: Double]

        public var names: [String: String]

        public init(screens: [Screen] = [], aspects: [String: Double] = [:], names: [String: String] = [:]) {
            self.screens = screens
            self.aspects = aspects
            self.names = names
        }
    }

    public static func resolvedScreen(_ node: MultiViewNode, in context: Context) -> Context.Screen? {
        context.screens.first { $0.id == node.screenSourceId }
            ?? context.screens.first { $0.name == node.screenSourceName }
    }

    public static func sourceToken(_ node: MultiViewNode, in context: Context) -> String? {
        switch node.sourceKind ?? .empty {
        case .screen: resolvedScreen(node, in: context).map { "screen::" + $0.id }
        case .liveInput: node.liveInputId.map { "input::" + $0 }
        case .media: node.mediaId.map { "media::" + $0 }
        case .empty, .clock, .timer, .videoCountdown, .text: nil
        }
    }

    public static func defaultLabel(_ node: MultiViewNode, in context: Context) -> String {
        switch node.sourceKind ?? .empty {
        case .empty: "No Source"
        case .screen: resolvedScreen(node, in: context)?.name ?? node.screenSourceName ?? "Screen"
        case .liveInput: sourceToken(node, in: context).flatMap { context.names[$0] } ?? "Video Input"
        case .media: sourceToken(node, in: context).flatMap { context.names[$0] } ?? "Media"
        case .clock: "Clock"
        case .timer: "Time Remaining"
        case .videoCountdown: "Video Countdown"
        case .text: ""
        }
    }

    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct PlacedTile: Equatable, Sendable {
        public var node: MultiViewNode
        public var rect: Rect
    }

    public struct Divider: Equatable, Sendable {
        public var splitId: String

        public var index: Int
        public var axis: MultiViewSplitAxis

        public var splitRect: Rect

        public var position: Double

        public var shares: [Double]

        public func fraction(atX x: Double, y: Double) -> Double {
            axis == .columns
                ? (x - splitRect.x) / max(splitRect.width, 1)
                : (y - splitRect.y) / max(splitRect.height, 1)
        }

        public func isHit(x: Double, y: Double, tolerance: Double) -> Bool {
            axis == .columns
                ? abs(x - position) <= tolerance && y >= splitRect.y && y <= splitRect.y + splitRect.height
                : abs(y - position) <= tolerance && x >= splitRect.x && x <= splitRect.x + splitRect.width
        }
    }

    static let gap = 6.0
    static let minimumShare = 0.05
    static let border = "#3A3A3AFF"

    static func labelHeight(forTile height: Double) -> Double {
        min(44, max(20, height * 0.2))
    }

    static func shares(
        of split: MultiViewNode, in rect: Rect, tree: MultiViewTree, context: Context
    ) -> [Double] {
        let children = split.children ?? []
        let stored = split.fractions ?? []
        let valid = stored.count == children.count && stored.allSatisfy { $0 > 0 }
        let raw = valid ? stored : Array(repeating: 1, count: children.count)
        let total = raw.reduce(0, +)
        var shares = raw.map { $0 / total }
        let extent = split.axis == .columns ? rect.width : rect.height
        var pinned: [Int: Double] = [:]
        for (index, childId) in children.enumerated() {
            if let child = node(childId, in: tree), child.axis == nil, child.matchSourceShape == true,
               let aspect = sourceToken(child, in: context).flatMap({ context.aspects[$0] }), aspect > 0 {
                let label = (child.label ?? defaultLabel(child, in: context)).isEmpty
                    ? 0 : labelHeight(forTile: split.axis == .columns ? rect.height : rect.height * shares[index])
                let wanted = split.axis == .columns
                    ? (rect.height - gap * 2 - label) * aspect + gap * 2
                    : (rect.width - gap * 2) / aspect + gap * 2 + label
                pinned[index] = wanted / extent
            }
        }

        let freeCount = children.count - pinned.count
        let cap = 1 - Double(freeCount) * minimumShare
        let pinnedTotal = pinned.values.reduce(0, +)
        let pinnedScale = pinnedTotal > cap && pinnedTotal > 0 ? cap / pinnedTotal : 1
        let freeTotal = shares.enumerated().filter { pinned[$0.offset] == nil }.map(\.element).reduce(0, +)
        let remaining = 1 - pinnedTotal * pinnedScale
        if !pinned.isEmpty {
            for index in shares.indices {
                if let share = pinned[index] {
                    shares[index] = max(minimumShare, share * pinnedScale)
                } else {
                    shares[index] = freeTotal > 0 ? shares[index] / freeTotal * remaining : remaining / Double(max(freeCount, 1))
                }
            }
            let sum = shares.reduce(0, +)
            shares = shares.map { $0 / sum }
        }
        return shares
    }

    private static func walk(
        _ nodeId: String, in rect: Rect, tree: MultiViewTree, context: Context,
        tiles: inout [PlacedTile], dividers: inout [Divider]
    ) {
        if let node = node(nodeId, in: tree) {
            if let axis = node.axis, let children = node.children, !children.isEmpty {
                let shares = shares(of: node, in: rect, tree: tree, context: context)
                var offset = 0.0
                for (index, childId) in children.enumerated() {
                    let share = shares[index]
                    let childRect = axis == .columns
                        ? Rect(x: rect.x + offset * rect.width, y: rect.y, width: share * rect.width, height: rect.height)
                        : Rect(x: rect.x, y: rect.y + offset * rect.height, width: rect.width, height: share * rect.height)
                    walk(childId, in: childRect, tree: tree, context: context, tiles: &tiles, dividers: &dividers)
                    offset += share
                    if index < children.count - 1 {
                        dividers.append(Divider(
                            splitId: node.id, index: index, axis: axis, splitRect: rect,
                            position: axis == .columns ? rect.x + offset * rect.width : rect.y + offset * rect.height,
                            shares: shares
                        ))
                    }
                }
            } else {
                tiles.append(PlacedTile(node: node, rect: rect))
            }
        }
    }

    public static func layout(
        _ tree: MultiViewTree, canvasWidth: Int, canvasHeight: Int, context: Context = Context()
    ) -> (tiles: [PlacedTile], dividers: [Divider]) {
        var tiles: [PlacedTile] = []
        var dividers: [Divider] = []
        walk(
            tree.rootId, in: Rect(x: 0, y: 0, width: Double(canvasWidth), height: Double(canvasHeight)),
            tree: tree, context: context, tiles: &tiles, dividers: &dividers
        )
        return (tiles, dividers)
    }

    public static func faceId(_ nodeId: String) -> String { nodeId + "#face" }
    public static func contentId(_ nodeId: String) -> String { nodeId + "#text" }
    public static func labelId(_ nodeId: String) -> String { nodeId + "#label" }

    public static func nodeId(forObject objectId: String) -> String? {
        objectId.firstIndex(of: "#").map { String(objectId[..<$0]) }
    }

    public static func objects(
        for tree: MultiViewTree, canvasWidth: Int, canvasHeight: Int, context: Context = Context()
    ) -> [SlideObject] {
        layout(tree, canvasWidth: canvasWidth, canvasHeight: canvasHeight, context: context).tiles.flatMap {
            objects(for: $0.node, in: $0.rect, context: context)
        }
    }

    private static func objects(for node: MultiViewNode, in rect: Rect, context: Context) -> [SlideObject] {
        let labelText = node.label ?? defaultLabel(node, in: context)
        let label = labelText.isEmpty ? 0 : labelHeight(forTile: rect.height)
        let x = rect.x + gap
        let y = rect.y + gap
        let width = max(rect.width - gap * 2, 1)
        let faceHeight = max(rect.height - gap * 2 - label, 1)
        let kind = node.sourceKind ?? .empty

        var face = SlideObject(id: faceId(node.id), objectKind: .shape, name: labelText.isEmpty ? "Tile" : labelText, text: "")
        face.shapeKind = .rectangle
        face.x = x
        face.y = y
        face.width = width
        face.height = faceHeight
        face.stroke = ObjectStroke(colorHex: border, width: 2)
        switch kind {
        case .empty, .clock, .timer, .videoCountdown, .text:
            face.fill = ObjectFill(fillKind: .none)
        case .screen:
            face.fill = ObjectFill(
                fillKind: .media, mediaScaleMode: node.scaleMode ?? .fit,
                screenSourceId: resolvedScreen(node, in: context)?.id ?? node.screenSourceId)
        case .liveInput:
            face.fill = ObjectFill(fillKind: .media, mediaScaleMode: node.scaleMode ?? .fit, liveInputId: node.liveInputId)
        case .media:
            face.fill = ObjectFill(fillKind: .media, mediaId: node.mediaId, mediaScaleMode: node.scaleMode ?? .fit, loops: true)
        }
        var objects = [face]

        let linkedSource: TextSourceKind? = switch kind {
        case .clock: .clock
        case .timer: .timer
        case .videoCountdown: .videoCountdown
        case .empty, .screen, .liveInput, .media, .text: nil
        }
        if let linkedSource {
            var content = ConfidenceLayoutTemplate.linked(
                labelText.isEmpty ? "Tile Text" : labelText, linkedSource,
                x: x + 12, y: y + 8, width: max(width - 24, 1), height: max(faceHeight - 16, 1),
                size: max(faceHeight * 0.55, 24),
                color: kind == .clock ? ConfidenceLayoutTemplate.dimmed : ConfidenceLayoutTemplate.green,
                tabular: true, shrink: true,
                clockFormat: kind == .clock ? "h:mm:ss a" : nil
            )
            content.id = contentId(node.id)
            content.textLink?.timerId = kind == .timer ? node.timerId : nil
            objects.append(content)
        } else if kind == .text {
            var content = text(
                node.text ?? "", id: contentId(node.id), name: "Tile Text",
                x: x + 12, y: y + 8, width: max(width - 24, 1), height: max(faceHeight - 16, 1),
                size: max(faceHeight * 0.4, 24), color: "#FFFFFFFF")
            content.textStyle?.minFontSize = 20
            objects.append(content)
        }
        if !labelText.isEmpty {
            objects.append(text(
                labelText, id: labelId(node.id), name: "Label",
                x: x, y: y + faceHeight, width: width, height: label,
                size: label * 0.6, color: ConfidenceLayoutTemplate.dimmed))
        }
        return objects
    }

    private static func text(
        _ string: String, id: String, name: String,
        x: Double, y: Double, width: Double, height: Double, size: Double, color: String
    ) -> SlideObject {
        var object = SlideObject(id: id, objectKind: .text, name: name, text: string)
        object.x = x
        object.y = y
        object.width = width
        object.height = height
        object.textStyle = TextStyle(
            fontSize: size, colorHex: color,
            horizontalAlignment: .center, verticalAlignment: .middle,
            autoShrink: true, minFontSize: 12
        )
        return object
    }

    public static func tile(atX x: Double, y: Double, in tiles: [PlacedTile]) -> PlacedTile? {
        tiles.first {
            x >= $0.rect.x && x < $0.rect.x + $0.rect.width && y >= $0.rect.y && y < $0.rect.y + $0.rect.height
        }
    }

    public static func node(_ id: String, in tree: MultiViewTree) -> MultiViewNode? {
        tree.nodes.first { $0.id == id }
    }

    public static func parent(of id: String, in tree: MultiViewTree) -> MultiViewNode? {
        tree.nodes.first { $0.children?.contains(id) == true }
    }

    static func descendants(of id: String, in tree: MultiViewTree) -> [String] {
        (node(id, in: tree)?.children ?? []).flatMap { [$0] + descendants(of: $0, in: tree) }
    }

    public static func tile(id: String = UUID().uuidString) -> MultiViewNode {
        MultiViewNode(id: id, sourceKind: .empty)
    }

    public static func grid(columns: Int, rows: Int) -> MultiViewTree {
        var nodes: [MultiViewNode] = []
        let rowIds = (0..<max(rows, 1)).map { _ -> String in
            let tiles = (0..<max(columns, 1)).map { _ in tile() }
            nodes += tiles
            if tiles.count == 1 {
                return tiles[0].id
            } else {
                let row = MultiViewNode(id: UUID().uuidString, axis: .columns, children: tiles.map(\.id))
                nodes.append(row)
                return row.id
            }
        }
        if rowIds.count == 1 {
            return MultiViewTree(rootId: rowIds[0], nodes: nodes)
        } else {
            let root = MultiViewNode(id: UUID().uuidString, axis: .rows, children: rowIds)
            return MultiViewTree(rootId: root.id, nodes: nodes + [root])
        }
    }

    public static func update(
        _ tree: MultiViewTree, tile id: String, _ mutate: (inout MultiViewNode) -> Void
    ) -> MultiViewTree {
        var tree = tree
        if let index = tree.nodes.firstIndex(where: { $0.id == id && $0.axis == nil }) {
            mutate(&tree.nodes[index])
        }
        return tree
    }

    public static func split(
        _ tree: MultiViewTree, tile id: String, axis: MultiViewSplitAxis, into count: Int = 2
    ) -> MultiViewTree {
        var tree = tree
        if count > 1, let target = node(id, in: tree), target.axis == nil {
            let added = (1..<count).map { _ in tile() }
            if let parent = parent(of: id, in: tree), parent.axis == axis,
               let parentIndex = tree.nodes.firstIndex(where: { $0.id == parent.id }),
               let position = parent.children?.firstIndex(of: id) {
                let children = parent.children ?? []
                let stored = parent.fractions ?? []
                var fractions = stored.count == children.count
                    ? stored : Array(repeating: 1 / Double(children.count), count: children.count)
                let share = fractions[position] / Double(count)
                fractions[position] = share
                fractions.insert(contentsOf: Array(repeating: share, count: count - 1), at: position + 1)
                tree.nodes[parentIndex].children?.insert(contentsOf: added.map(\.id), at: position + 1)
                tree.nodes[parentIndex].fractions = fractions
            } else {
                let splitNode = MultiViewNode(
                    id: UUID().uuidString, axis: axis, children: [id] + added.map(\.id))
                tree = replacing(id, with: splitNode.id, in: tree)
                tree.nodes.append(splitNode)
            }
            tree.nodes += added
        }
        return tree
    }

    public static func quad(_ tree: MultiViewTree, tile id: String) -> MultiViewTree {
        var tree = tree
        if let target = node(id, in: tree), target.axis == nil {
            let others = (0..<3).map { _ in tile() }
            let top = MultiViewNode(id: UUID().uuidString, axis: .columns, children: [id, others[0].id])
            let bottom = MultiViewNode(id: UUID().uuidString, axis: .columns, children: [others[1].id, others[2].id])
            let rows = MultiViewNode(id: UUID().uuidString, axis: .rows, children: [top.id, bottom.id])
            tree = replacing(id, with: rows.id, in: tree)
            tree.nodes += others + [top, bottom, rows]
        }
        return tree
    }

    public static func merge(_ tree: MultiViewTree, tile id: String) -> MultiViewTree {
        var tree = tree
        if let target = node(id, in: tree), target.axis == nil, let parent = parent(of: id, in: tree) {
            let removed = Set(descendants(of: parent.id, in: tree)).subtracting([id]).union([parent.id])
            tree = replacing(parent.id, with: id, in: tree)
            tree.nodes.removeAll { removed.contains($0.id) }
        }
        return tree
    }

    public static func canMerge(_ tree: MultiViewTree, tile id: String) -> Bool {
        node(id, in: tree)?.axis == nil && parent(of: id, in: tree) != nil
    }

    public static func moveDivider(_ tree: MultiViewTree, _ divider: Divider, to position: Double) -> MultiViewTree {
        moveDivider(tree, split: divider.splitId, index: divider.index, to: position, currentShares: divider.shares)
    }

    public static func moveDivider(
        _ tree: MultiViewTree, split id: String, index: Int, to position: Double,
        currentShares: [Double]
    ) -> MultiViewTree {
        var tree = tree
        if let splitIndex = tree.nodes.firstIndex(where: { $0.id == id }),
           let children = tree.nodes[splitIndex].children,
           index >= 0, index < children.count - 1, currentShares.count == children.count {
            var shares = currentShares
            let before = shares[..<index].reduce(0, +)
            let pair = shares[index] + shares[index + 1]
            let first = min(max(position - before, minimumShare), pair - minimumShare)
            shares[index] = first
            shares[index + 1] = pair - first
            tree.nodes[splitIndex].fractions = shares
            for childId in [children[index], children[index + 1]] {
                tree = update(tree, tile: childId) { $0.matchSourceShape = nil }
            }
        }
        return tree
    }

    private static func replacing(_ old: String, with new: String, in tree: MultiViewTree) -> MultiViewTree {
        var tree = tree
        if tree.rootId == old {
            tree.rootId = new
        }
        for index in tree.nodes.indices {
            if let position = tree.nodes[index].children?.firstIndex(of: old) {
                tree.nodes[index].children?[position] = new
            }
        }
        return tree
    }
}
