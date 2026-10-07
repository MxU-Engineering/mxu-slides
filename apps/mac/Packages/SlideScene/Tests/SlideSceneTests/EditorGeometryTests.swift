import CoreGraphics
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func object(
    _ id: String,
    x: Double, y: Double, w: Double, h: Double,
    rotation: Double? = nil,
    group: String? = nil
) -> SlideObject {
    var o = SlideObject(id: id, objectKind: .shape, name: id, text: "")
    o.x = x; o.y = y; o.width = w; o.height = h
    o.rotationDegrees = rotation
    o.groupId = group
    return o
}

@Test func hitTestPicksTopmost() {
    let objects = [
        object("under", x: 0, y: 0, w: 400, h: 400),
        object("over", x: 100, y: 100, w: 400, h: 400),
    ]
    #expect(EditorGeometry.hitObject(at: CGPoint(x: 200, y: 200), in: objects)?.id == "over")
    #expect(EditorGeometry.hitObject(at: CGPoint(x: 50, y: 50), in: objects)?.id == "under")
    #expect(EditorGeometry.hitObject(at: CGPoint(x: 900, y: 900), in: objects) == nil)
}

@Test func pressTargetKeepsASelectedObjectUnderAnother() {

    let objects = [
        object("text", x: 100, y: 100, w: 200, h: 100),
        object("outline", x: 0, y: 0, w: 400, h: 400),
    ]
    let overlap = CGPoint(x: 150, y: 150)
    #expect(EditorGeometry.pressTarget(at: overlap, in: objects, selected: ["text"])?.id == "text")

    #expect(EditorGeometry.pressTarget(at: overlap, in: objects, selected: [])?.id == "outline")
    #expect(EditorGeometry.pressTarget(at: CGPoint(x: 350, y: 350), in: objects, selected: ["text"])?.id == "outline")
    #expect(EditorGeometry.pressTarget(at: CGPoint(x: 900, y: 900), in: objects, selected: ["text"]) == nil)
}

@Test func letterboxCentersTheCanvasInABiggerView() {

    let canvas = CGSize(width: 1920, height: 1080)
    let view = CGSize(width: 1000, height: 1000)
    let (scale, origin) = EditorGeometry.letterbox(canvas: canvas, in: view)
    #expect(abs(scale - 1000.0 / 1920.0) < 0.0001)
    #expect(abs(origin.x) < 0.0001)
    #expect(abs(origin.y - (1000 - 1080 * scale) / 2) < 0.0001)
    let center = EditorGeometry.scenePoint(fromView: CGPoint(x: 500, y: 500), viewSize: view, canvas: canvas)
    #expect(abs(center.x - 960) < 0.01 && abs(center.y - 540) < 0.01)
    let above = EditorGeometry.scenePoint(fromView: CGPoint(x: 500, y: 10), viewSize: view, canvas: canvas)
    #expect(above.y < 0)

    let inset = EditorGeometry.letterbox(canvas: canvas, in: view, inset: 40)
    #expect(abs(inset.scale - 920.0 / 1920.0) < 0.0001)
    #expect(abs(inset.origin.x - 40) < 0.0001)
    let left = EditorGeometry.scenePoint(fromView: CGPoint(x: 20, y: 500), viewSize: view, canvas: canvas, inset: 40)
    #expect(left.x < 0, "the band left of the slide is off-canvas scene space")
}

@Test func hitTestHonorsRotation() {

    let bar = object("bar", x: 460, y: 490, w: 1000, h: 20, rotation: 90)
    let center = CGPoint(x: 960, y: 500)
    #expect(EditorGeometry.hitObject(at: center, in: [bar])?.id == "bar")

    #expect(EditorGeometry.hitObject(at: CGPoint(x: 500, y: 500), in: [bar]) == nil)

    #expect(EditorGeometry.hitObject(at: CGPoint(x: 960, y: 200), in: [bar])?.id == "bar")
}

@Test func selectionExpandsToWholeGroup() {
    let objects = [
        object("a", x: 0, y: 0, w: 10, h: 10, group: "g1"),
        object("b", x: 0, y: 0, w: 10, h: 10, group: "g1"),
        object("c", x: 0, y: 0, w: 10, h: 10, group: ""),
        object("d", x: 0, y: 0, w: 10, h: 10),
    ]
    #expect(EditorGeometry.expandSelectionToGroups(["a"], in: objects) == ["a", "b"])
    #expect(EditorGeometry.expandSelectionToGroups(["c"], in: objects) == ["c"])
    #expect(EditorGeometry.expandSelectionToGroups(["d"], in: objects) == ["d"])
}

@Test func resizeFromCornerMovesOriginAndSize() {
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let resized = EditorGeometry.resize(frame, dragging: .topLeft, by: CGSize(width: 20, height: 10))
    #expect(resized == CGRect(x: 120, y: 110, width: 180, height: 90))

    let grown = EditorGeometry.resize(frame, dragging: .bottomRight, by: CGSize(width: 50, height: 30))
    #expect(grown == CGRect(x: 100, y: 100, width: 250, height: 130))
}

@Test func resizeEnforcesMinimumSize() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let squeezed = EditorGeometry.resize(frame, dragging: .right, by: CGSize(width: -500, height: 0))
    #expect(squeezed.width == 16)
    let squeezedLeft = EditorGeometry.resize(frame, dragging: .left, by: CGSize(width: 500, height: 0))
    #expect(squeezedLeft.width == 16)
    #expect(squeezedLeft.maxX == 100, "anchored edge must not move")
}

@Test func edgeHandlesResizeOneAxis() {
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let taller = EditorGeometry.resize(frame, dragging: .bottom, by: CGSize(width: 999, height: 40))
    #expect(taller == CGRect(x: 100, y: 100, width: 200, height: 140), "x axis untouched")
}

@Test func moveSnapsToCanvasCenterWithGuides() {

    let frame = CGRect(x: 911, y: 300, width: 100, height: 100)
    let result = EditorGeometry.snapMove(frame, others: [])
    #expect(result.frame.midX == 960)
    #expect(result.guides.contains(.vertical(960)))
}

@Test func moveSnapsToNeighborEdges() {
    let neighbor = CGRect(x: 500, y: 200, width: 300, height: 200)

    let frame = CGRect(x: 805, y: 600, width: 100, height: 100)
    let result = EditorGeometry.snapMove(frame, others: [neighbor])
    #expect(result.frame.minX == 800)
    #expect(result.guides.contains(.vertical(800)))
}

@Test func moveBeyondThresholdDoesNotSnap() {
    let frame = CGRect(x: 300, y: 391, width: 100, height: 100)

    let result = EditorGeometry.snapMove(frame, others: [], threshold: 8)

    #expect(result.frame == frame)
    #expect(result.guides.isEmpty)
}

@Test func resizeSnapsOnlyTheDraggedEdge() {
    let neighbor = CGRect(x: 0, y: 0, width: 600, height: 400)

    let frame = CGRect(x: 300, y: 500, width: 296, height: 100)
    let result = EditorGeometry.snapResize(frame, handle: .right, others: [neighbor])
    #expect(result.frame.maxX == 600)
    #expect(result.frame.minX == 300, "anchor side untouched")
    #expect(result.guides == [.vertical(600)])
}

@Test func snapPrefersTheNearestTarget() {

    let frame = CGRect(x: 6, y: 300, width: 1912, height: 100) 
    let result = EditorGeometry.snapMove(frame, others: [])
    #expect(result.frame.midX == 960)
}

@Test func rotatedBoundsSwapAxesAtNinetyDegrees() {

    let frame = CGRect(x: 420, y: -419.9, width: 1080, height: 1919.879)
    let bounds = EditorGeometry.rotatedBounds(frame, degrees: 90)
    #expect(abs(bounds.width - 1919.879) < 0.001)
    #expect(abs(bounds.height - 1080) < 0.001)
    #expect(abs(bounds.midX - frame.midX) < 0.001)
    #expect(abs(bounds.midY - frame.midY) < 0.001)
    #expect(EditorGeometry.rotatedBounds(frame, degrees: 0) == frame)
}

@Test func moveSnapsRotatedVisualBoundsToCanvasEdge() {

    let frame = CGRect(x: 420, y: -419.9, width: 1080, height: 1919.879)
    let visual = EditorGeometry.rotatedBounds(frame, degrees: 90).offsetBy(dx: 3, dy: 0)
    let result = EditorGeometry.snapMove(visual, others: [])
    #expect(abs(result.frame.maxX - 1920) < 0.001)
    #expect(result.guides.contains(.vertical(1920)))
}

@Test func resizeDoesNotSnapRotatedObjects() {

    let frame = CGRect(x: 300, y: 500, width: 296, height: 100)
    let result = EditorGeometry.snapResize(frame, handle: .right, rotationDegrees: 90, others: [])
    #expect(result.frame == frame)
    #expect(result.guides.isEmpty)
}

private func unit(_ id: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> EditorGeometry.AlignUnit {
    EditorGeometry.AlignUnit(ids: [id], frame: CGRect(x: x, y: y, width: w, height: h))
}

@Test func alignLeftSnapsUnitsToReferenceEdge() {
    let units = [unit("a", x: 100, y: 0, w: 50, h: 50), unit("b", x: 300, y: 100, w: 80, h: 50)]
    let reference = units[0].frame.union(units[1].frame) 
    let deltas = EditorGeometry.alignDeltas(units: units, edge: .left, reference: reference)
    #expect(deltas["a"] == nil, "already on the edge — no write, no churn")
    #expect(deltas["b"] == CGVector(dx: -200, dy: 0))
}

@Test func alignCenterYCentersEveryUnit() {
    let units = [unit("a", x: 0, y: 0, w: 50, h: 100), unit("b", x: 100, y: 300, w: 50, h: 40)]
    let reference = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let deltas = EditorGeometry.alignDeltas(units: units, edge: .centerY, reference: reference)
    #expect(deltas["a"] == CGVector(dx: 0, dy: 490), "midY 50 → 540")
    #expect(deltas["b"] == CGVector(dx: 0, dy: 220), "midY 320 → 540")
}

@Test func alignMovesGroupMembersByOneDelta() {

    let group = EditorGeometry.AlignUnit(
        ids: ["g1", "g2"], frame: CGRect(x: 200, y: 0, width: 100, height: 50)
    )
    let deltas = EditorGeometry.alignDeltas(
        units: [group], edge: .right,
        reference: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    #expect(deltas["g1"] == CGVector(dx: 1620, dy: 0))
    #expect(deltas["g2"] == CGVector(dx: 1620, dy: 0))
}

@Test func distributeEqualizesGapsAndPinsEnds() {

    let units = [
        unit("a", x: 0, y: 0, w: 100, h: 50),
        unit("b", x: 120, y: 0, w: 50, h: 50),
        unit("c", x: 500, y: 0, w: 100, h: 50),
    ]
    let deltas = EditorGeometry.distributeDeltas(units: units, horizontally: true)
    #expect(deltas["a"] == nil, "first pinned")
    #expect(deltas["c"] == nil, "last pinned")
    #expect(deltas["b"] == CGVector(dx: 155, dy: 0), "minX 120 → 100+175 = 275")
}

@Test func distributeSortsByPositionNotSelectionOrder() {
    let units = [
        unit("right", x: 800, y: 0, w: 100, h: 50),
        unit("left", x: 0, y: 0, w: 100, h: 50),
        unit("mid", x: 150, y: 0, w: 100, h: 50),
    ]
    let deltas = EditorGeometry.distributeDeltas(units: units, horizontally: true)

    #expect(deltas["mid"] == CGVector(dx: 250, dy: 0))
    #expect(deltas["left"] == nil)
    #expect(deltas["right"] == nil)
}

@Test func distributeNeedsThreeUnits() {
    let units = [unit("a", x: 0, y: 0, w: 100, h: 50), unit("b", x: 500, y: 0, w: 100, h: 50)]
    #expect(EditorGeometry.distributeDeltas(units: units, horizontally: true).isEmpty)
}

@Test func perspectiveCornersAreNilForFlatUnrotatedObjects() {
    let flat = object("a", x: 10, y: 10, w: 100, h: 50)
    #expect(EditorGeometry.perspectiveCorners(
        frame: CGRect(x: 10, y: 10, width: 100, height: 50), object: flat, canvasSize: CGSize(width: 1920, height: 1080)) == nil)
}

@Test func perspectiveCornersFollowKeystoneAndRotation() {
    var keyed = object("k", x: 100, y: 100, w: 200, h: 100)
    keyed.keystoneTop = 50
    let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
    let corners = EditorGeometry.perspectiveCorners(frame: frame, object: keyed, canvasSize: CGSize(width: 1920, height: 1080))!
    #expect(corners[0] == CGPoint(x: 150, y: 100))
    #expect(corners[1] == CGPoint(x: 250, y: 100))
    #expect(corners[2] == CGPoint(x: 100, y: 200))

    keyed.rotationDegrees = 90
    let turned = EditorGeometry.perspectiveCorners(frame: frame, object: keyed, canvasSize: CGSize(width: 1920, height: 1080))!
    #expect(abs(turned[0].x - 250) < 0.001 && abs(turned[0].y - 100) < 0.001)
    #expect(abs(turned[1].x - 250) < 0.001 && abs(turned[1].y - 200) < 0.001)
}

@Test func homographyMapsRectCornersAndInverts() {
    let rect = CGRect(x: 20, y: 30, width: 200, height: 100)
    let quad = [CGPoint(x: 60, y: 30), CGPoint(x: 200, y: 40), CGPoint(x: 10, y: 150), CGPoint(x: 260, y: 140)]
    let h = EditorGeometry.Homography(from: rect, to: quad)!
    let sources = [
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
    ]
    for (source, target) in zip(sources, quad) {
        let mapped = h.apply(source)
        #expect(abs(mapped.x - target.x) < 0.001 && abs(mapped.y - target.y) < 0.001)
        let back = h.inverseApply(target)
        #expect(abs(back.x - source.x) < 0.001 && abs(back.y - source.y) < 0.001)
    }

    let mid = CGPoint(x: 120, y: 80)
    let round = h.inverseApply(h.apply(mid))
    #expect(abs(round.x - mid.x) < 0.001 && abs(round.y - mid.y) < 0.001)

    let same = EditorGeometry.Homography(from: rect, to: sources)!
    #expect(abs(same.apply(mid).x - mid.x) < 0.001 && abs(same.apply(mid).y - mid.y) < 0.001)
}

private func frames(_ object: SlideObject) -> CGRect {
    CGRect(x: object.x ?? 0, y: object.y ?? 0, width: object.width ?? 0, height: object.height ?? 0)
}

@Test func rubberBandSweepsWhatItTouches() {
    let objects = [
        object("inside", x: 100, y: 100, w: 50, h: 50),
        object("edge", x: 190, y: 190, w: 100, h: 100),
        object("outside", x: 500, y: 500, w: 50, h: 50),
    ]
    let band = CGRect(x: 0, y: 0, width: 200, height: 200)
    #expect(EditorGeometry.sweptObjectIDs(band: band, in: objects, frame: frames) == ["inside", "edge"])
    #expect(EditorGeometry.sweptObjectIDs(band: CGRect(x: 0, y: 0, width: 10, height: 10), in: objects, frame: frames).isEmpty)
}

@Test func rubberBandHonorsRotationAndSkipsHidden() {

    let bar = object("bar", x: 460, y: 490, w: 1000, h: 20, rotation: 90)
    var hidden = object("hidden", x: 0, y: 0, w: 100, h: 100)
    hidden.hidden = true
    let band = CGRect(x: 900, y: 0, width: 120, height: 150)
    #expect(EditorGeometry.sweptObjectIDs(band: band, in: [bar, hidden], frame: frames) == ["bar"])
    #expect(EditorGeometry.sweptObjectIDs(band: CGRect(x: 0, y: 0, width: 50, height: 50), in: [hidden], frame: frames).isEmpty)
}

@Test func selectAllTakesEveryObjectOrWhatTheCanvasDraws() {
    var hidden = object("hidden", x: 0, y: 0, w: 100, h: 100)
    hidden.hidden = true
    let objects = [object("title", x: 0, y: 0, w: 10, h: 10), hidden]
    #expect(EditorGeometry.allObjectIDs(in: objects, includingHidden: true) == ["title", "hidden"], "the Objects panel lists hidden rows")
    #expect(EditorGeometry.allObjectIDs(in: objects, includingHidden: false) == ["title"], "the canvas never picks what it doesn't draw")
}

@Test func rubberBandResolvesFramesThroughTheCanvas() {

    let object = object("placed", x: 0, y: 0, w: 10, h: 10)
    let band = CGRect(x: 800, y: 800, width: 100, height: 100)
    let shown = EditorGeometry.sweptObjectIDs(band: band, in: [object]) { _ in
        CGRect(x: 850, y: 850, width: 20, height: 20)
    }
    #expect(shown == ["placed"])
}
