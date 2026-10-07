import Foundation
import PresenterCore
import RenderEngine
import Testing

@testable import SlideScene

private let fixedDate = Date(timeIntervalSince1970: 1_784_800_000)

private func chordedSlide() -> Slide {
    var lyrics = SlideObject(
        id: "lyrics", objectKind: .text, name: "Lyrics",
        text: "Amazing grace how sweet the sound\nThat saved a wretch like me"
    )
    lyrics.chords = [
        ChordPlacement(line: 0, column: 0, symbol: "G"),
        ChordPlacement(line: 1, column: 5, symbol: "C"),
    ]
    return Slide(id: "s1", name: "", objects: [lyrics])
}

private func chordedInfo(maxKeyed: Bool = true) -> ConfidenceInfo {
    ConfidenceInfo(
        current: ConfidenceSceneBuilder.slideText(
            for: chordedSlide(),
            in: Presentation(
                id: "p", name: "Song", presentationKind: .deck, themeId: "", slides: [],
                musicKey: maxKeyed ? "G" : nil, displayKey: maxKeyed ? "A" : nil
            )
        ),
        next: .init(body: "next one\nnext two\nnext three", chords: [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 2, column: 0, symbol: "D"),
        ])
    )
}

@Test func lyricChordsShiftLinesAcrossObjects() {
    var first = SlideObject(id: "a", objectKind: .text, name: "A", text: "one\ntwo")
    first.chords = [ChordPlacement(line: 1, column: 0, symbol: "G")]
    var second = SlideObject(id: "b", objectKind: .text, name: "B", text: "three")
    second.chords = [ChordPlacement(line: 0, column: 2, symbol: "C")]

    let media = SlideObject(id: "m", objectKind: .media, name: "M", text: "")
    let blank = SlideObject(id: "e", objectKind: .text, name: "E", text: "")
    let slide = Slide(id: "s", name: "", objects: [first, media, blank, second])

    let chords = ConfidenceSceneBuilder.lyricChords(for: slide)
    #expect(ConfidenceSceneBuilder.lyricText(for: slide) == "one\ntwo\nthree")
    #expect(chords.map(\.line) == [1, 2])
    #expect(chords.map(\.symbol) == ["G", "C"])
}

@Test func chordsOnlyBlankSlideReachesTheConfidenceBody() {

    var blank = SlideObject(id: "e", objectKind: .text, name: "E", text: "")
    blank.chords = [ChordPlacement(line: 0, column: 0, symbol: "G"), ChordPlacement(line: 0, column: 0, symbol: "D")]
    let verse = SlideObject(id: "v", objectKind: .text, name: "V", text: "words")
    let slide = Slide(id: "s", name: "", objects: [blank, verse])
    #expect(ConfidenceSceneBuilder.lyricText(for: slide) == "\nwords")
    #expect(ConfidenceSceneBuilder.lyricChords(for: slide).map(\.line) == [0, 0])

    let chordsOnly = Slide(id: "c", name: "", objects: [blank])
    var box = SlideObject(id: "box", objectKind: .text, name: "Current", text: "")
    box.textLink = TextLink(source: .currentSlide)
    var style = TextStyle()
    style.showChords = true
    box.textStyle = style
    let info = ConfidenceInfo(current: ConfidenceSceneBuilder.slideText(for: chordsOnly, in: nil))
    let resolved = LinkedText.resolvedObjects([box], info: info, at: fixedDate)[0]
    #expect(resolved.text == "")
    let items = SlideSceneBuilder.renderItems(
        for: resolved, theme: nil, in: SlideSceneBuilder.canvasSize, baseID: "box"
    )
    let chords = items.compactMap { item -> [ChordRun]? in
        guard case .text(let styled) = item.content else { return nil }
        return styled.chords
    }.flatMap(\.self)
    #expect(chords.map(\.symbol) == ["G", "D"])

    let empty = Slide(id: "blank", name: "", objects: [])
    #expect(ConfidenceSceneBuilder.nextSlide(in: [empty, chordsOnly], skippingBlanks: true)?.id == "c")
}

@Test func linkedSlideTextCarriesDisplayReadyChords() {
    var box = SlideObject(id: "box", objectKind: .text, name: "Current", text: "")
    box.textLink = TextLink(source: .currentSlide)
    let resolved = LinkedText.resolvedObjects([box], info: chordedInfo(), at: fixedDate)[0]
    #expect(resolved.text == "Amazing grace how sweet the sound\nThat saved a wretch like me")

    #expect(resolved.chords?.map(\.symbol) == ["A", "D"])
}

@Test func linkedObjectNotationConvertsAtResolution() {

    var box = SlideObject(id: "box", objectKind: .text, name: "Current", text: "")
    box.textLink = TextLink(source: .currentSlide)
    var style = TextStyle()
    style.chordNotation = .numbers
    box.textStyle = style
    let resolved = LinkedText.resolvedObjects([box], info: chordedInfo(), at: fixedDate)[0]
    #expect(resolved.chords?.map(\.symbol) == ["1", "4"])
}

@Test func maxLinesTruncatesBodyAndChords() {
    var box = SlideObject(id: "box", objectKind: .text, name: "Next", text: "")
    var link = TextLink(source: .nextSlide)
    link.maxLines = 1
    box.textLink = link
    let resolved = LinkedText.resolvedObjects([box], info: chordedInfo(), at: fixedDate)[0]
    #expect(resolved.text == "next one")

    #expect(resolved.chords?.map(\.symbol) == ["G"])
}

@Test func maxLinesLeavesShortSlidesAlone() {
    var box = SlideObject(id: "box", objectKind: .text, name: "Next", text: "")
    var link = TextLink(source: .nextSlide)
    link.maxLines = 5
    box.textLink = link
    let resolved = LinkedText.resolvedObjects([box], info: chordedInfo(), at: fixedDate)[0]
    #expect(resolved.text == "next one\nnext two\nnext three")
}

@Test func nonSlideSourcesNeverCarryChords() {
    var box = SlideObject(id: "box", objectKind: .text, name: "Clock", text: "")
    box.textLink = TextLink(source: .clock)
    let resolved = LinkedText.resolvedObjects([box], info: chordedInfo(), at: fixedDate)[0]
    #expect(resolved.chords == nil)
}

@Test func styledTextTransposesAndGatesOnShowChords() {
    var object = chordedSlide().objects[0]

    let dark = SlideSceneBuilder.styledText(
        for: object, theme: nil,
        music: SlideSceneBuilder.MusicContext(musicKey: "G", displayKey: "A")
    )
    #expect(dark.chords.isEmpty)

    var style = TextStyle()
    style.showChords = true
    style.chordColorHex = "#FF0000FF"
    object.textStyle = style
    let shown = SlideSceneBuilder.styledText(
        for: object, theme: nil,
        music: SlideSceneBuilder.MusicContext(musicKey: "G", displayKey: "A")
    )

    #expect(shown.chords.map(\.symbol) == ["A", "D"])
    #expect(shown.chords.map(\.line) == [0, 1])
    #expect(shown.chordColor != nil)
}

@Test func styledTextNotatesNashville() {
    var object = chordedSlide().objects[0]
    var style = TextStyle()
    style.showChords = true
    style.chordNotation = .numbers
    object.textStyle = style
    let text = SlideSceneBuilder.styledText(
        for: object, theme: nil,
        music: SlideSceneBuilder.MusicContext(musicKey: "G", displayKey: nil)
    )
    #expect(text.chords.map(\.symbol) == ["1", "4"])
}

@Test func programSceneCarriesChordsThroughThePresentation() {
    var slide = chordedSlide()
    var style = TextStyle()
    style.showChords = true
    slide.objects[0].textStyle = style
    let presentation = Presentation(
        id: "p", name: "Song", presentationKind: .deck, themeId: "",
        slides: [slide], musicKey: "G", displayKey: "Bb"
    )
    let scene = SlideSceneBuilder.scene(for: slide, theme: nil, presentation: presentation)
    let texts: [StyledText] = (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled }
        return nil
    }
    let chorded = texts.first { !$0.chords.isEmpty }
    #expect(chorded?.chords.map(\.symbol) == ["Bb", "Eb"])
}

@Test func chordsTemplateShowsCurrentWithChordsAndNextFirstLineOnly() {
    let layout = ConfidenceLayoutTemplate.currentOverNextChords.make(name: "Chords")
    #expect(ConfidenceLayoutTemplate.workspaceStarters.contains(.currentOverNextChords))

    let scene = ConfidenceSceneBuilder.scene(layout: layout, info: chordedInfo(), at: fixedDate)
    let texts: [StyledText] = (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled }
        return nil
    }

    let current = texts.first { $0.string.hasPrefix("Amazing grace") }
    #expect(current?.chords.map(\.symbol) == ["A", "D"])
    #expect(current?.autoShrink == true)

    let next = texts.first { $0.string.hasPrefix("next") }
    #expect(next?.string == "next one")
    #expect(next?.chords.map(\.symbol) == ["G"])
    #expect(next?.autoShrink == false)
}

@Test func confidenceLayoutRendersChordsInTheSlideKey() {
    var box = SlideObject(
        id: "box", objectKind: .text, name: "Current", text: "",
        x: 0, y: 0, width: 1920, height: 540
    )
    box.textLink = TextLink(source: .currentSlide)
    var style = TextStyle()
    style.showChords = true
    box.textStyle = style
    let layout = ConfidenceLayout(id: "l", name: "Chords", objects: [box])
    let scene = ConfidenceSceneBuilder.scene(layout: layout, info: chordedInfo(), at: fixedDate)
    let texts: [StyledText] = (scene.layers.first { $0.kind == .slide }?.items ?? []).compactMap {
        if case .text(let styled) = $0.content { return styled }
        return nil
    }
    let chorded = texts.first { !$0.chords.isEmpty }

    #expect(chorded?.chords.map(\.symbol) == ["A", "D"])
}
