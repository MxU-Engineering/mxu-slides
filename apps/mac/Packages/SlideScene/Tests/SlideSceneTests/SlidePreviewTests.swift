import PresenterCore
import Testing
@testable import SlideScene

@Test func previewLeadsWithTheBottomMostTextBox() {

    let slide = Slide(id: "s", name: "", objects: [
        SlideObject(id: "bg", objectKind: .media, name: "BG", text: "", mediaId: "m"),
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "How I live for the moments\nsecond line"),
        SlideObject(id: "label", objectKind: .text, name: "Label", text: "Verse 1"),
    ])
    #expect(SlidePreview.line(for: slide) == "How I live for the moments")
}

@Test func previewSkipsEmptyBoxesAndBlankLeadingLines() {
    let slide = Slide(id: "s", name: "", objects: [
        SlideObject(id: "ghost", objectKind: .text, name: "Ghost", text: ""),
        SlideObject(id: "shape", objectKind: .shape, name: "Box", text: ""),
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "  \nSo will I"),
    ])
    #expect(SlidePreview.line(for: slide) == "So will I")
}

@Test func rowTextNameOutranksPreviewUnlessItIsTheBackgroundMedia() {

    let named = Slide(id: "v", name: "Verse 1", objects: [
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "Be Thou my vision"),
    ])
    #expect(SlidePreview.rowText(for: named, backgroundMediaName: nil) == .name)
    let mediaNamed = Slide(id: "s", name: "GlassPrism_02_4K.mp4", objects: [
        SlideObject(id: "lyrics", objectKind: .text, name: "Lyrics", text: "The lights went out"),
    ])
    #expect(
        SlidePreview.rowText(for: mediaNamed, backgroundMediaName: "GlassPrism_02_4K")
            == .preview("The lights went out"),
        "extension-tolerant match — cue label keeps .mp4, adopted media may not"
    )
}

@Test func rowTextMediaOnlyCuesShowTheBareNumber() {

    let mediaOnly = Slide(id: "m", name: "Maxed Out.mp4", objects: [],
                          background: CueMedia(mediaId: "x", layer: .stillGraphics))
    #expect(SlidePreview.rowText(for: mediaOnly, backgroundMediaName: "Maxed Out.mp4") == .number)
    let nilLayer = Slide(id: "n", name: "Maxed Out.mp4", objects: [],
                         background: CueMedia(mediaId: "x"))
    #expect(SlidePreview.rowText(for: nilLayer, backgroundMediaName: "Maxed Out.mp4") == .number)
    let bare = Slide(id: "b", name: "", objects: [
        SlideObject(id: "ghost", objectKind: .text, name: "Text Placeholder", text: ""),
    ])
    #expect(SlidePreview.rowText(for: bare, backgroundMediaName: nil) == .number)
}

@Test func rowTextForegroundVideoCuesKeepTheirFilename() {

    let bumper = Slide(id: "f", name: "Bumper Video.mp4", objects: [],
                       background: CueMedia(mediaId: "x", layer: .videos))
    #expect(SlidePreview.rowText(for: bumper, backgroundMediaName: "Bumper Video.mp4") == .name)
}

@Test func previewIsEmptyForTextlessSlides() {
    let mediaOnly = Slide(id: "s", name: "", objects: [
        SlideObject(id: "bg", objectKind: .media, name: "BG", text: "", mediaId: "m"),
    ])
    #expect(SlidePreview.line(for: mediaOnly).isEmpty)
    #expect(SlidePreview.line(for: Slide(id: "b", name: "", objects: [])).isEmpty)
}
