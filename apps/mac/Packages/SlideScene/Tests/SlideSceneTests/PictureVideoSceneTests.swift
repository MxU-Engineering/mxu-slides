import CoreGraphics
import Foundation
import PresenterCore
@testable import RenderEngine
import Testing
@testable import SlideScene

@Test func aCuesScaleAndEndFadeReachTheScene() throws {
    var cue = CueMedia(mediaId: "m", layer: .videos, classification: .foreground, scaleMode: .scaleAndBlur)
    cue.endFade = .black
    let slide = Slide(id: "s", name: "", objects: [], background: cue)
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil)
    let item = try #require(scene.layers.first { $0.kind == .videos }?.items.first)
    #expect(item.content == .media(id: "m", scaleMode: .scaleAndBlur))
    #expect(item.endFade == .black)
    #expect(SlideSceneBuilder.cueItem(CueMedia(mediaId: "m"), id: "x", canvasSize: .zero).endFade == nil)
    #expect(SlideSceneBuilder.scaleMode(nil) == .fill)
}
