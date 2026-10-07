import CoreGraphics
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

    func testContentEditsDoNotAnimateMembershipDoes() {
        XCTAssertTrue(SceneTransitionEngine.changedLayers(
            from: scene(["a"]), to: scene(["a"])
        ).isEmpty, "same ids = a content edit, never a fade")
        XCTAssertEqual(
            SceneTransitionEngine.changedLayers(from: scene(["a"]), to: scene(["b"])),
            [.slide]
        )
    }

    func testDissolveFadesLeavingAndArrivingButNeverStaying() {
        let composite = SceneTransitionEngine.composite(
            previous: scene(["stay", "leave"]), target: scene(["stay", "arrive"]),
            transition: SceneTransition(kind: .dissolve, duration: 1),
            progress: 0.25, layers: [.slide]
        )
        let items = composite.layers.first { $0.kind == .slide }!.items

        XCTAssertEqual(items.first { $0.id == "leave::leaving" }?.opacity ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(items.first { $0.id == "arrive" }?.opacity ?? -1, 0.25, accuracy: 0.001)
        XCTAssertEqual(items.first { $0.id == "stay" }?.opacity ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(items.filter { $0.id == "stay" }.count, 1, "no colliding twins")
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
        XCTAssertTrue(fillScene("clip-a").isTimeVarying, "fill players re-encode every tick")
        XCTAssertEqual(
            SceneTransitionEngine.changedLayers(
                from: fillScene("clip-a"), to: fillScene("clip-b")
            ),
            [.slide], "a fill media swap is a content change"
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
            [.loopingVideos]
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
