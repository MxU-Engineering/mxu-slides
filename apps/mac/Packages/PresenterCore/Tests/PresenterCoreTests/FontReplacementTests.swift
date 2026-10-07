import Foundation
import Testing
@testable import PresenterCore

struct FontReplacementTests {
    @Test func rewritesBaseLineAndRunFontNames() {
        var style = TextStyle()
        style.fontName = "Aptos Slab"
        style.lineStyles = [LineStyleOverride(lineIndex: 1, fontName: "Aptos Slab-Bold")]
        var object = SlideObject(id: "o", objectKind: .text, name: "Text", text: "a\nb")
        object.textStyle = style
        object.styleRuns = [
            TextStyleRun(line: 0, column: 0, length: 1, fontName: "Aptos Slab-Italic"),
            TextStyleRun(line: 0, column: 1, length: 1, underline: true),
        ]
        let presentation = Presentation(
            id: "p", name: "Deck", presentationKind: .deck, themeId: "",
            slides: [Slide(id: "s", name: "1", objects: [object])]
        )

        let replaced = FontReplacement.applying([
            "Aptos Slab": "Avenir-Book",
            "Aptos Slab-Bold": "Avenir-Heavy",
            "Aptos Slab-Italic": "Avenir-BookOblique",
        ], to: presentation)

        let out = replaced.slides[0].objects[0]
        #expect(out.textStyle?.fontName == "Avenir-Book")
        #expect(out.textStyle?.lineStyles?[0].fontName == "Avenir-Heavy")
        #expect(out.styleRuns?[0].fontName == "Avenir-BookOblique")

        #expect(out.styleRuns?[1] == TextStyleRun(line: 0, column: 1, length: 1, underline: true))
        #expect(FontReplacement.applying([:], to: presentation) == presentation)
    }
}
