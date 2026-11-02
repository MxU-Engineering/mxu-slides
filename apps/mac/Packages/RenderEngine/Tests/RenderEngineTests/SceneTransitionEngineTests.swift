import CoreGraphics
import Metal
import XCTest
@testable import RenderEngine

final class SceneTransitionEngineTests: XCTestCase {
    private func scene(_ ids: [String], layer: LayerKind = .slide) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        for id in ids {
            scene.addItem(
                RenderItem(
                    id: id, frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                    content: .media(id: "media-\(id)")
                ),
                to: layer
            )
        }
        return scene
    }

    func testDurationsReachThirtySeconds() {
        XCTAssertEqual(SceneTransition(kind: .dissolve, duration: 12).duration, 12, "a typed length past the slider plays")
        XCTAssertEqual(SceneTransition(kind: .dissolve, duration: 45).duration, 30)
    }

    func testContentEditsDoNotAnimateMembershipDoes() {
        XCTAssertTrue(SceneTransitionEngine.changedLayers(
            from: scene(["a"]), to: scene(["a"])
        ).isEmpty, "same ids = a content edit, never a fade")
        XCTAssertEqual(
            SceneTransitionEngine.changedLayers(from: scene(["a"]), to: scene(["b"])),
            ["slide"]
        )
    }

    func testAlphaLayerDissolveFadesWholeStacks() {
        let composite = SceneTransitionEngine.composite(
            previous: scene(["stay", "leave"]), target: scene(["stay", "arrive"]),
            transition: SceneTransition(kind: .dissolve, duration: 1),
            progress: 0.25, layers: [.slide]
        )
        let layer = composite.layers.first { $0.kind == .slide }!

        XCTAssertEqual(layer.crossfadeProgress ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(layer.items.filter(\.crossfadeLeaving).map(\.id), ["stay::leaving", "leave::leaving"])
        XCTAssertEqual(layer.items.filter { !$0.crossfadeLeaving }.map(\.id), ["stay", "arrive"])
        XCTAssertTrue(layer.items.allSatisfy { $0.opacity == 1 }, "the compositor mixes; items stay full")

        let flat = SceneTransitionEngine.flattened(composite).layers.first { $0.kind == .slide }!
        XCTAssertNil(flat.crossfadeProgress)
        XCTAssertEqual(flat.items.first { $0.id == "leave::leaving" }?.opacity ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(flat.items.first { $0.id == "arrive" }?.opacity ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(flat.items.filter { $0.id.hasPrefix("stay") }.map(\.id), ["stay"], "staying once")
        XCTAssertEqual(flat.items.first { $0.id == "stay" }?.opacity ?? -1, 1, accuracy: 0.001)
        XCTAssertFalse(flat.items.contains { $0.crossfadeLeaving })
    }

    func testEachLayerRunsOnItsOwnLength() {
        func both(_ id: String) -> RenderScene {
            var scene = scene([id])
            scene.addItem(
                RenderItem(id: "live-media-loopingVideos", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                           content: .media(id: "bg-\(id)")),
                to: .loopingVideos
            )
            return scene
        }
        let mid = SceneTransitionEngine.composite(
            previous: both("a"), target: both("b"),
            transitions: [
                "slide": SceneTransition(kind: .dissolve, duration: 1),
                "loopingVideos": SceneTransition(kind: .dissolve, duration: 0.25),
            ],
            elapsed: 0.5
        )
        XCTAssertEqual(mid.layers.first { $0.kind == .loopingVideos }?.items.map(\.id), ["live-media-loopingVideos"])
        XCTAssertEqual(mid.layers.first { $0.kind == .slide }?.crossfadeProgress ?? -1, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testDissolvingAwayAnOpaqueStackNeverShowsWhatItCovers() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let compositor = try Compositor()
        let canvas = CGRect(x: 0, y: 0, width: 192, height: 108)
        var old = RenderScene(canvasSize: canvas.size)
        old.background = .black
        old.addItem(RenderItem(id: "backdrop", frame: canvas, content: .solid(.white)), to: .slide)
        old.addItem(RenderItem(id: "picture", frame: canvas, content: .solid(SceneColor(red: 1, green: 0, blue: 0))), to: .slide)
        var empty = RenderScene(canvasSize: canvas.size)
        empty.background = .black
        let mid = SceneTransitionEngine.composite(
            previous: old, target: empty,
            transition: SceneTransition(kind: .dissolve, duration: 1),
            progress: 0.5, layers: [.slide]
        )
        let frame = try compositor.renderFrame(scene: mid, width: 192, height: 108)
        var pixel = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let halves = (raw.baseAddress! + 54 * frame.bytesPerRow + 96 * 8).assumingMemoryBound(to: Float16.self)
            pixel = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        XCTAssertEqual(pixel.x, 0.5, accuracy: 0.02, "half the picture")
        XCTAssertEqual(pixel.y, 0, accuracy: 0.01, "no white backdrop bleeding through")
        XCTAssertEqual(pixel.z, 0, accuracy: 0.01)
    }

    func testFadeShowsOldThenPlateThenNew() {
        let transition = SceneTransition(kind: .fade(.black), duration: 1)
        let early = SceneTransitionEngine.composite(
            previous: scene(["old"]), target: scene(["new"]),
            transition: transition, progress: 0.25, layers: [.slide]
        ).layers.first { $0.kind == .slide }!.items
        XCTAssertNotNil(early.first { $0.id == "old" || $0.id == "old::leaving" })
        XCTAssertNil(early.first { $0.id == "new" }, "first half never leaks the new content")
        XCTAssertNotNil(early.first { $0.id.hasPrefix("transition-plate") })
        let late = SceneTransitionEngine.composite(
            previous: scene(["old"]), target: scene(["new"]),
            transition: transition, progress: 0.75, layers: [.slide]
        ).layers.first { $0.kind == .slide }!.items
        XCTAssertNil(late.first { $0.id.hasPrefix("old") })
        XCTAssertNotNil(late.first { $0.id == "new" })
    }

    func testEngineHoldsOutgoingMediaUntilTheFadeLands() {
        let engine = SceneTransitionEngine(initial: scene(["a"]))
        engine.push(scene(["b"]), transition: SceneTransition(kind: .dissolve, duration: 0.2))
        XCTAssertEqual(engine.heldMediaIDs(), ["media-a"])

        let after = Date(timeIntervalSinceNow: 0.3)
        XCTAssertTrue(engine.heldMediaIDs(at: after).isEmpty)
        let landed = engine.scene(at: after)
        XCTAssertEqual(
            landed.layers.first { $0.kind == .slide }?.items.map(\.id), ["b"]
        )
    }

    func testContentOnlyPushRidesThroughAnActiveFade() {
        let engine = SceneTransitionEngine(initial: scene(["a"]))
        engine.push(scene(["b"]), transition: SceneTransition(kind: .dissolve, duration: 5))
        engine.push(scene(["b"]), transition: SceneTransition(kind: .dissolve, duration: 5))
        XCTAssertEqual(engine.heldMediaIDs(), ["media-a"], "the fade keeps running")
        let mid = engine.scene(at: Date()).layers.first { $0.kind == .slide }!.items
        XCTAssertEqual(Set(mid.map(\.id)), ["a::leaving", "b"], "both sides still render")
    }

    func testCutLandsInstantlyAndCancelsAnyFade() {
        let engine = SceneTransitionEngine(initial: scene(["a"]))
        engine.push(scene(["b"]), transition: SceneTransition(kind: .dissolve, duration: 5))
        engine.push(scene(["c"]), transition: .cut)
        XCTAssertTrue(engine.heldMediaIDs().isEmpty)
        XCTAssertEqual(
            engine.scene(at: Date()).layers.first { $0.kind == .slide }?.items.map(\.id),
            ["c"]
        )
    }
}

extension SceneTransitionEngineTests {

    func testMediaFilledShapesRideTheMediaContracts() {
        func fillScene(_ mediaID: String) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
            scene.addItem(
                RenderItem(
                    id: "s", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    content: .shape(ShapeStyle(
                        kind: .rectangle, fill: .media(id: mediaID, scaleMode: .fill)
                    ))
                ),
                to: .slide
            )
            return scene
        }
        XCTAssertEqual(
            fillScene("clip-a").visibleMediaIDs, ["clip-a"],
            "fill players reach the static-skip media check")
        XCTAssertEqual(
            SceneTransitionEngine.changedLayers(
                from: fillScene("clip-a"), to: fillScene("clip-b")
            ),
            ["slide"], "a fill media swap is a content change"
        )
        let engine = SceneTransitionEngine(initial: fillScene("clip-a"))
        engine.push(fillScene("clip-b"), transition: SceneTransition(kind: .dissolve, duration: 1))
        XCTAssertEqual(engine.heldMediaIDs(), ["clip-a"], "the outgoing fill player holds through the fade")
    }

    func testStableItemIdMediaSwapStillAnimates() {
        func mediaScene(_ mediaID: String) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
            scene.addItem(
                RenderItem(
                    id: "live-media-loopingVideos",
                    frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                    content: .media(id: mediaID)
                ),
                to: .loopingVideos
            )
            return scene
        }
        XCTAssertEqual(
            SceneTransitionEngine.changedLayers(
                from: mediaScene("clip-a"), to: mediaScene("clip-b")
            ),
            ["loopingVideos"]
        )
        let mid = SceneTransitionEngine.composite(
            previous: mediaScene("clip-a"), target: mediaScene("clip-b"),
            transition: SceneTransition(kind: .dissolve, duration: 1),
            progress: 0.5, layers: [.loopingVideos]
        ).layers.first { $0.kind == .loopingVideos }!.items
        XCTAssertEqual(mid.count, 2, "both clips render mid-fade")
        XCTAssertEqual(Set(mid.map(\.id)).count, 2, "no colliding item ids")

        XCTAssertEqual(
            mid.first { $0.id.hasSuffix("::leaving") }?.opacity ?? -1, 1, accuracy: 0.001
        )

        XCTAssertTrue(SceneTransitionEngine.changedLayers(
            from: mediaScene("clip-a"), to: mediaScene("clip-a")
        ).isEmpty)
    }
}


extension SceneTransitionEngineTests {

    func testMediaClearFadesOutInsteadOfHoldAndPop() {
        var old = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        old.addItem(
            RenderItem(
                id: "live-media-videos",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .media(id: "intro")
            ),
            to: .videos
        )
        let empty = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        let mid = SceneTransitionEngine.composite(
            previous: old, target: empty,
            transition: SceneTransition(kind: .dissolve, duration: 1),
            progress: 0.5, layers: [.videos]
        ).layers.first { $0.kind == .videos }!.items
        XCTAssertEqual(mid.count, 1)
        XCTAssertEqual(mid.first?.opacity ?? -1, 0.5, accuracy: 0.001, "the clear FADES")
    }
}
