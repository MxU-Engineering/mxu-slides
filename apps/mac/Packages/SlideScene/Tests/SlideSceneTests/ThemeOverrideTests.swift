import CoreGraphics
import Foundation
import PresenterCore
import Testing

@testable import SlideScene

private let originalTheme = Theme(
    id: "orig", name: "Original", fontFamily: "Helvetica", fontSize: 60,
    textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF"
)

private func overrideTheme(keep: KeepFromSlideOptions? = nil) -> Theme {
    var placeholder = SlideObject(id: "ph", objectKind: .text, name: "Lyrics", text: "Sample")
    placeholder.x = 0
    placeholder.y = 800
    placeholder.width = 1920
    placeholder.height = 280
    var style = TextStyle()
    style.fontSize = 42
    placeholder.textStyle = style
    placeholder.keepFromSlide = keep
    return Theme(
        id: "ov", name: "Stream Lower Third", fontFamily: "Arial", fontSize: 40,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#00000000",
        slides: [Slide(id: "ov-lyrics", name: "Lyrics", objects: [placeholder])]
    )
}

private func lyricsObject(
    runs: [TextStyleRun]? = nil, style: TextStyle? = nil
) -> SlideObject {
    var object = SlideObject(
        id: "lyrics", objectKind: .text, name: "Lyrics",
        text: "Amazing grace how sweet the sound"
    )
    object.x = 100
    object.y = 100
    object.width = 800
    object.height = 400
    object.textStyle = style
    object.styleRuns = runs
    return object
}

private func transformed(
    _ object: SlideObject, keep: KeepFromSlideOptions? = nil
) -> SlideObject {
    let slide = Slide(id: "s", name: "Verse 1", objects: [object])
    return ThemeOverride.overrideObjects(
        for: slide, objects: slide.objects,
        originalTheme: originalTheme, overrideTheme: overrideTheme(keep: keep)
    )[0]
}

@Test func overrideStripsGeometryAndBaseStyle() {
    var style = TextStyle()
    style.fontSize = 80
    style.colorHex = "#FF0000FF"
    let result = transformed(lyricsObject(style: style))

    #expect(result.x == nil && result.y == nil)
    #expect(result.width == nil && result.height == nil)
    #expect(result.textStyle == nil)
    #expect(result.styleRuns == nil)
}

@Test func nonTextObjectsPassThroughUntouched() {
    var shape = SlideObject(id: "pic", objectKind: .shape, name: "Photo", text: "")
    shape.x = 10
    shape.y = 20
    let slide = Slide(id: "s", name: "", objects: [shape])
    let result = ThemeOverride.overrideObjects(
        for: slide, objects: slide.objects,
        originalTheme: originalTheme, overrideTheme: overrideTheme()
    )
    #expect(result[0] == shape)
}

@Test func boldWordCarriesAsTheThemeFontsBoldFace() {
    let run = TextStyleRun(line: 0, column: 0, length: 7, fontName: "Helvetica-Bold")
    let result = transformed(lyricsObject(runs: [run]))
    let carried = try! #require(result.styleRuns?.first)
    let name = try! #require(carried.fontName)

    #expect(ThemeOverride.traits(ofFontNamed: name).bold)
    #expect(!name.lowercased().contains("helvetica"))

    #expect(carried.line == 0 && carried.column == 0 && carried.length == 7)
    #expect(carried.fontSize == nil && carried.colorHex == nil)
}

@Test func allBoldBaseCarriesNothing() {

    var base = TextStyle()
    base.fontName = "Helvetica-Bold"
    let run = TextStyleRun(line: 0, column: 0, length: 7, fontName: "Helvetica-Bold")
    let result = transformed(lyricsObject(runs: [run], style: base))
    #expect(result.styleRuns == nil)
}

@Test func boldToggleOffDropsTheDelta() {
    let run = TextStyleRun(line: 0, column: 0, length: 7, fontName: "Helvetica-Bold")
    let result = transformed(
        lyricsObject(runs: [run]), keep: KeepFromSlideOptions(bold: false)
    )
    #expect(result.styleRuns == nil)
}

@Test func sizeEmphasisCarriesAsARatio() {

    let run = TextStyleRun(line: 0, column: 0, length: 7, fontSize: 80)
    let carried = try! #require(transformed(lyricsObject(runs: [run])).styleRuns?.first)
    let size = try! #require(carried.fontSize)
    #expect(abs(size - 56) < 0.01)
}

@Test func decorationsCarryAndColorsDontByDefault() {
    let run = TextStyleRun(
        line: 0, column: 8, length: 5,
        underline: true, colorHex: "#FF0000FF", highlightColorHex: "#FFFF00FF"
    )
    let carried = try! #require(transformed(lyricsObject(runs: [run])).styleRuns?.first)
    #expect(carried.underline == true)

    #expect(carried.colorHex == nil)
    #expect(carried.highlightColorHex == nil)

    let kept = try! #require(
        transformed(
            lyricsObject(runs: [run]),
            keep: KeepFromSlideOptions(highlight: true, textColor: true)
        ).styleRuns?.first
    )
    #expect(kept.colorHex == "#FF0000FF")
    #expect(kept.highlightColorHex == "#FFFF00FF")
}

@Test func wordTrackingCarriesScaledToTheThemeSize() {

    let run = TextStyleRun(line: 0, column: 0, length: 7, tracking: 10)
    let carried = try! #require(transformed(lyricsObject(runs: [run])).styleRuns?.first)
    let tracking = try! #require(carried.tracking)
    #expect(abs(tracking - 7) < 0.01)
}

@Test func lineStylesCarryLikeRunsExceptIndentsAndTracking() {
    var style = TextStyle()
    style.lineStyles = [LineStyleOverride(
        lineIndex: 1, fontName: "Helvetica-Bold", fontSize: 90,
        colorHex: "#FF0000FF", tracking: 5, firstLineIndent: 100, leftIndent: 50
    )]
    let result = transformed(lyricsObject(style: style))
    let carried = try! #require(result.textStyle?.lineStyles?.first)
    #expect(carried.lineIndex == 1)

    #expect(ThemeOverride.traits(ofFontNamed: carried.fontName ?? "").bold)
    let size = try! #require(carried.fontSize)
    #expect(abs(size - 63) < 0.01) 

    #expect(carried.colorHex == nil)
    #expect(carried.tracking == nil)
    #expect(carried.firstLineIndent == nil && carried.leftIndent == nil)

    #expect(result.textStyle?.fontName == nil && result.textStyle?.fontSize == nil)
}

@Test func variantSceneReThemesWithStableItemIDs() {
    let object = lyricsObject(
        runs: [TextStyleRun(line: 0, column: 0, length: 7, fontName: "Helvetica-Bold")]
    )
    let slide = Slide(id: "s", name: "Verse 1", objects: [object])
    let presentation = Presentation(
        id: "p", name: "Song", presentationKind: .song, themeId: "orig", slides: [slide]
    )
    var state = ShowState()
    state.fire(slide: slide, presentation: presentation, theme: originalTheme)

    let base = state.scene()
    let variant = state.scene(slideThemeOverride: overrideTheme())

    let baseIDs = base.layers.first { $0.kind == .slide }!.items.map(\.id)
    let variantIDs = variant.layers.first { $0.kind == .slide }!.items.map(\.id)
    #expect(baseIDs == variantIDs)

    let variantItem = variant.layers.first { $0.kind == .slide }!
        .items.first { $0.id == "lyrics" }!
    #expect(variantItem.frame == CGRect(x: 0, y: 800, width: 1920, height: 280))
    guard case .text(let styled) = variantItem.content else {
        Issue.record("expected text content")
        return
    }
    #expect(styled.fontName == "Arial")
    #expect(styled.fontSize == 42)

    #expect(styled.styleRuns.count == 1)

    let baseItem = base.layers.first { $0.kind == .slide }!
        .items.first { $0.id == "lyrics" }!
    #expect(baseItem.frame == CGRect(x: 100, y: 100, width: 800, height: 400))
}

@Test func overrideThemeDecorMediaStaysWanted() {

    var decor = SlideObject(id: "strip", objectKind: .shape, name: "Strip", text: "")
    decor.fill = ObjectFill(fillKind: .media, mediaId: "motion-strip")
    var theme = overrideTheme()
    theme.slides?[0].objects.insert(decor, at: 0)

    let slide = Slide(id: "s", name: "Verse 1", objects: [lyricsObject()])
    var state = ShowState()
    state.fire(slide: slide, theme: originalTheme)
    #expect(state.wantedMedia()["motion-strip"] == nil)
    #expect(state.wantedMedia(slideThemeOverrides: [theme]).keys.contains("motion-strip"))
}
