import CoreGraphics
import Foundation
import PresenterCore
import Testing

@testable import SlideScene

private func presentation(width: Int?, height: Int?, slides: [Slide] = []) -> Presentation {
    Presentation(
        id: "p", name: "Deck", presentationKind: .deck, themeId: "",
        slides: slides, canvasWidth: width, canvasHeight: height)
}

@Test func canvasResolvesStoredSizeAndFallsBack() {
    #expect(SlideSceneBuilder.canvasSize(for: nil) == CGSize(width: 1920, height: 1080))
    #expect(
        SlideSceneBuilder.canvasSize(for: presentation(width: nil, height: nil))
            == CGSize(width: 1920, height: 1080))
    #expect(
        SlideSceneBuilder.canvasSize(for: presentation(width: 1080, height: 1920))
            == CGSize(width: 1080, height: 1920))

    #expect(
        SlideSceneBuilder.canvasSize(for: presentation(width: 0, height: 1920))
            == CGSize(width: 1920, height: 1080))
}

@Test func defaultCanvasStoresAbsent() {
    #expect(SlideSceneBuilder.storedCanvas(width: 1920, height: 1080) == (nil, nil))
    #expect(SlideSceneBuilder.storedCanvas(width: 1024, height: 768) == (1024, 768))

    #expect(SlideSceneBuilder.canvasPresets.allSatisfy { $0.width > 0 && $0.height > 0 })
    #expect(SlideSceneBuilder.canvasPresets.contains { $0.width == 1920 && $0.height == 1080 })
}

@Test func sceneAdoptsThePresentationCanvas() {
    let slide = Slide(id: "s", name: "", objects: [
        SlideObject(id: "m", objectKind: .media, name: "Full", text: "", mediaId: "clip")
    ])
    let vertical = presentation(width: 1080, height: 1920, slides: [slide])
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil, presentation: vertical)
    #expect(scene.canvasSize == CGSize(width: 1080, height: 1920))

    let item = scene.layers.first { $0.kind == .slide }!.items[0]
    #expect(item.frame == CGRect(x: 0, y: 0, width: 1080, height: 1920))

    let pinned = SlideSceneBuilder.scene(
        for: slide, theme: nil, presentation: vertical,
        canvasSize: CGSize(width: 640, height: 360))
    #expect(pinned.canvasSize == CGSize(width: 640, height: 360))
}

@Test func liveSceneFollowsTheFiredPresentation() {
    let slide = Slide(id: "s", name: "", objects: [])
    let vertical = presentation(width: 1080, height: 1920, slides: [slide])
    var state = ShowState()
    state.fire(slide: slide, presentation: vertical)
    #expect(state.scene().canvasSize == CGSize(width: 1080, height: 1920))
    state.clear(function: .slides)
    #expect(state.scene().canvasSize == CGSize(width: 1920, height: 1080))
}
