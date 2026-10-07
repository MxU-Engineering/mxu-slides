import Foundation
import Testing
@testable import PresenterCore

private typealias Tiles = MultiViewTiles

private func layout(_ tree: MultiViewTree, _ context: Tiles.Context = .init()) -> [Tiles.PlacedTile] {
    Tiles.layout(tree, canvasWidth: 1920, canvasHeight: 1080, context: context).tiles
}

private let context = Tiles.Context(
    screens: [.init(id: "here-1", name: "Projector"), .init(id: "here-2", name: "LED Strip")],
    aspects: ["screen::here-2": 9.0 / 16.0]
)

@Test func aGridTilesTheWholeCanvasInReadingOrder() {
    let tiles = layout(Tiles.grid(columns: 2, rows: 2))
    #expect(tiles.map(\.rect) == [
        .init(x: 0, y: 0, width: 960, height: 540), .init(x: 960, y: 0, width: 960, height: 540),
        .init(x: 0, y: 540, width: 960, height: 540), .init(x: 960, y: 540, width: 960, height: 540),
    ])
}

@Test func badFractionsFallBackToEqualShares() {
    var tree = Tiles.grid(columns: 2, rows: 1)
    let root = tree.nodes.firstIndex { $0.id == tree.rootId }!
    tree.nodes[root].fractions = [0.7]
    #expect(layout(tree).map(\.rect.width) == [960, 960])
    tree.nodes[root].fractions = [3, 1]
    #expect(layout(tree).map(\.rect.width) == [1440, 480])
}

@Test func splittingKeepsTheTileFirstAndSameAxisSplitsStaySiblings() {
    var tree = Tiles.grid(columns: 2, rows: 1)
    let first = layout(tree)[0].node.id
    tree = Tiles.split(tree, tile: first, axis: .columns)

    #expect(Tiles.node(tree.rootId, in: tree)?.children?.count == 3)
    #expect(layout(tree).map(\.rect.width) == [480, 480, 960])
    #expect(layout(tree)[0].node.id == first)

    tree = Tiles.split(tree, tile: first, axis: .rows)
    #expect(layout(tree).prefix(2).map(\.rect) == [
        .init(x: 0, y: 0, width: 480, height: 540), .init(x: 0, y: 540, width: 480, height: 540),
    ])
}

@Test func quadThenMergeReturnsTheOneTileWithItsSource() {
    var tree = Tiles.grid(columns: 1, rows: 1)
    let id = tree.rootId
    tree = Tiles.update(tree, tile: id) { $0.sourceKind = .clock }
    #expect(!Tiles.canMerge(tree, tile: id))

    tree = Tiles.quad(tree, tile: id)
    #expect(layout(tree).count == 4)
    #expect(layout(tree)[0].node.id == id)

    tree = Tiles.split(tree, tile: layout(tree)[3].node.id, axis: .rows)
    tree = Tiles.merge(tree, tile: id)
    tree = Tiles.merge(tree, tile: id)
    #expect(tree.rootId == id)
    #expect(tree.nodes.map(\.id) == [id])
    #expect(tree.nodes[0].sourceKind == .clock)
}

@Test func unknownIdsChangeNothing() {
    let tree = Tiles.grid(columns: 2, rows: 2)
    #expect(Tiles.split(tree, tile: "nope", axis: .rows) == tree)
    #expect(Tiles.quad(tree, tile: tree.rootId) == tree)  
    #expect(Tiles.merge(tree, tile: "nope") == tree)
}

@Test func aDividerDragTradesShareBetweenNeighborsOnlyAndHonorsTheMinimum() {
    var tree = Tiles.grid(columns: 3, rows: 1)
    let third = 1.0 / 3
    tree = Tiles.moveDivider(tree, split: tree.rootId, index: 0, to: 0.5, currentShares: [third, third, third])
    let widths = layout(tree).map(\.rect.width)
    #expect(abs(widths[0] - 960) < 0.001 && abs(widths[1] - 320) < 0.001 && abs(widths[2] - 640) < 0.001)

    tree = Tiles.moveDivider(tree, split: tree.rootId, index: 0, to: 0.99, currentShares: [0.5, 1.0 / 6, third])
    #expect(abs(layout(tree)[1].rect.width - 1920 * Tiles.minimumShare) < 0.001)
}

@Test func theLayoutReportsOneDividerBetweenEachPairOfSiblings() {
    let dividers = Tiles.layout(Tiles.grid(columns: 2, rows: 2), canvasWidth: 1920, canvasHeight: 1080).dividers
    #expect(dividers.map(\.position).sorted() == [540, 960, 960])
    #expect(dividers.filter { $0.axis == .rows }.count == 1)
}

@Test func aTileMatchingAVerticalSourceTakesAVerticalShareAndADragUnpinsIt() {
    var tree = Tiles.grid(columns: 2, rows: 1)
    let strip = layout(tree)[0].node.id
    tree = Tiles.update(tree, tile: strip) {
        $0.sourceKind = .screen
        $0.screenSourceId = "here-2"
        $0.matchSourceShape = true
    }
    let placed = layout(tree, context)
    let face = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080, context: context)
        .first { $0.id == Tiles.faceId(strip) }!
    #expect(placed[0].rect.width < 700)
    #expect(abs((face.width ?? 0) / (face.height ?? 1) - 9.0 / 16.0) < 0.01)
    #expect(abs(placed[0].rect.width + placed[1].rect.width - 1920) < 0.001)

    tree = Tiles.moveDivider(
        tree, split: tree.rootId, index: 0, to: 0.5,
        currentShares: placed.map { $0.rect.width / 1920 })
    #expect(Tiles.node(strip, in: tree)?.matchSourceShape == nil)
    #expect(layout(tree, context)[0].rect.width == 960)
}

@Test func aSyncedScreenTileBindsByNameWhereItsIdIsUnknown() {
    var tree = Tiles.grid(columns: 1, rows: 1)
    tree = Tiles.update(tree, tile: tree.rootId) {
        $0.sourceKind = .screen
        $0.screenSourceId = "other-machine-7"
        $0.screenSourceName = "Projector"
    }
    let objects = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080, context: context)
    #expect(objects.first?.fill?.screenSourceId == "here-1")
    #expect(objects.last?.text == "Projector")

    let nowhere = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080)
    #expect(nowhere.first?.fill?.screenSourceId == "other-machine-7")
    #expect(nowhere.last?.text == "Projector")
}

@Test func objectIdsDeriveFromTheTileSoRegenerationIsStable() {
    var tree = Tiles.grid(columns: 2, rows: 1)
    let id = layout(tree)[0].node.id
    tree = Tiles.update(tree, tile: id) {
        $0.sourceKind = .timer
        $0.timerId = "t1"
        $0.label = "Sermon"
    }
    let first = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080)
    let again = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080)
    #expect(first == again)
    #expect(first.prefix(3).map(\.id) == [Tiles.faceId(id), Tiles.contentId(id), Tiles.labelId(id)])
    #expect(first[1].textLink?.source == .timer && first[1].textLink?.timerId == "t1")
    #expect(first[2].text == "Sermon")
    #expect(Tiles.nodeId(forObject: first[1].id) == id)
    #expect(Tiles.nodeId(forObject: "free-object") == nil)
}

@Test func anEmptyLabelGivesTheFaceTheWholeTile() {
    var tree = Tiles.grid(columns: 1, rows: 1)
    tree = Tiles.update(tree, tile: tree.rootId) {
        $0.sourceKind = .text
        $0.text = "Welcome"
    }
    let objects = Tiles.objects(for: tree, canvasWidth: 1920, canvasHeight: 1080)
    #expect(objects.map(\.id) == [Tiles.faceId(tree.rootId), Tiles.contentId(tree.rootId)])
    #expect(objects[0].height == 1080 - Tiles.gap * 2)
    #expect(objects[1].text == "Welcome")
}

@Test func hitTestingFindsDividersBeforeTilesAndMapsTheDragToAFraction() throws {
    let placed = Tiles.layout(Tiles.grid(columns: 2, rows: 2), canvasWidth: 1920, canvasHeight: 1080)
    let column = try #require(placed.dividers.first { $0.axis == .columns && $0.splitRect.y == 0 })
    #expect(column.isHit(x: 964, y: 200, tolerance: 8))
    #expect(!column.isHit(x: 964, y: 800, tolerance: 8))  
    #expect(!column.isHit(x: 1000, y: 200, tolerance: 8))
    #expect(column.fraction(atX: 1440, y: 0) == 0.75)
    #expect(column.shares == [0.5, 0.5])
    #expect(Tiles.tile(atX: 1000, y: 800, in: placed.tiles)?.node.id == placed.tiles[3].node.id)
    #expect(Tiles.tile(atX: -5, y: 0, in: placed.tiles) == nil)
}

@Test func aCanvasChangeRemeasuresAMultiViewAndUnlockKeepsTheObjects() {
    var layout = MultiViewTemplate.wideGrid.make(name: "Booth")
    layout.canvasWidth = 1080
    layout.canvasHeight = 1920
    layout.regenerateMultiViewObjects(context: .init())
    #expect(layout.objects.allSatisfy { ($0.x ?? 0) + ($0.width ?? 0) <= 1080 })

    let objects = layout.objects
    layout.unlockTiles()
    #expect(layout.multiView == nil)
    #expect(layout.objects == objects)

    layout.objects = []
    layout.regenerateMultiViewObjects(context: .init())
    #expect(layout.objects.isEmpty)
}

@Test func duplicateAsTallTurnsTheWallAndKeepsEverySource() throws {
    var wide = MultiViewTemplate.wideFeature.make(
        name: "Booth", sources: [.init(screenId: "s1", name: "Projector")])
    wide.folder = "Walls"
    let tall = try #require(wide.multiViewTurnedCopy(context: .init(screens: [.init(id: "s1", name: "Projector")])))

    #expect(tall.id != wide.id && tall.name == "Booth (Tall)" && tall.folder == "Walls")
    #expect(tall.canvasWidth == 1080 && tall.canvasHeight == 1920 && tall.isTallCanvas)
    #expect(tall.multiView?.nodes.map(\.sourceKind) == wide.multiView?.nodes.map(\.sourceKind))
    #expect(tall.objects.first { $0.fill?.screenSourceId == "s1" } != nil)
    #expect(tall.objects.allSatisfy { ($0.x ?? 0) + ($0.width ?? 0) <= 1080.001 })

    let tiles = MultiViewTiles.layout(try #require(tall.multiView), canvasWidth: 1080, canvasHeight: 1920).tiles
    #expect(tiles[0].rect.y == 0 && tiles[1].rect.y > tiles[0].rect.y)

    let back = try #require(tall.multiViewTurnedCopy(context: .init()))
    #expect(back.canvasWidth == nil && back.name == "Booth (Tall) (Wide)")
    #expect(ConfidenceLayout(id: "x", name: "Plain", objects: []).multiViewTurnedCopy(context: .init()) == nil)
}
