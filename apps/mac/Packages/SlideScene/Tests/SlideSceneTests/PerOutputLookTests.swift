import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private func streamTheme() -> Theme {
    func design(_ id: String, _ name: String, x: Double, width: Double) -> Slide {
        var placeholder = SlideObject(id: "\(id)-ph", objectKind: .text, name: "Lyrics", text: "Sample")
        placeholder.x = x; placeholder.y = 200; placeholder.width = width; placeholder.height = 400
        return Slide(id: id, name: name, objects: [placeholder])
    }
    return Theme(
        id: "stream", name: "Stream", fontFamily: "Arial", fontSize: 40,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
        slides: [design("narrow", "Lyrics", x: 20, width: 500), design("wide", "Lyrics Wide", x: 100, width: 1700)])
}

@Test func anOverrideOutputRendersTheSlideThroughItsChosenLook() {
    var slide = Slide(id: "s1", name: "", objects: [SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "Amazing grace")])
    slide.themeSlideName = "Lyrics"
    let theme = streamTheme()
    func lyricsFrame(_ scene: RenderScene) -> CGRect? {
        scene.layers.first { $0.kind == .slide }?.items.first { $0.id.hasPrefix("lyrics") }?.frame
    }

    var show = ShowState()
    show.slideThemeOverrides = [theme]
    show.fire(slide: slide, atHostTime: 1)
    #expect(lyricsFrame(show.scene(slideThemeOverride: theme))?.minX == 20, "no choice: the same-named design")

    slide.setOverrideDesign("Lyrics Wide", forTheme: "stream")
    show.fire(slide: slide, atHostTime: 2)
    #expect(lyricsFrame(show.scene(slideThemeOverride: theme))?.minX == 100, "the chosen look on the override output")
    #expect(show.scene().layers.first { $0.kind == .slide }?.items.contains { $0.id.hasPrefix("lyrics") } == true,
            "the projector still renders the slide as its own")
}
