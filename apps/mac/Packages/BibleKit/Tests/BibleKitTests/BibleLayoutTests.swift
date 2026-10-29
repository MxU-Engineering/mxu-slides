import Foundation
import PresenterCore
import SlideScene
import Testing
@testable import BibleKit

@Suite struct BibleLayoutTests {
    private let translation = BibleTranslation(id: "NIV", name: "New International Version", copyright: "Copyright © 1973, 1978, 1984, 2011 by Biblica, Inc. Used by permission. All rights reserved.", verses: [])
    private let verse = BibleVerse(book: "JHN", chapter: 3, verse: 16, text: "Example text for layout testing.")

    @Test func arbitraryThemeBlockIDsControlAllThreeRolesAndInheritGeometry() throws {
        let heading = SlideObject(id: "heading", objectKind: .text, name: "Heading", text: "", x: 30, y: 40, width: 1000, height: 90,
                                  textStyle: TextStyle(fontName: "HelveticaNeue", fontSize: 36, colorHex: "#FF0000FF"))
        let body = SlideObject(id: "body", objectKind: .text, name: "Body", text: "", x: 80, y: 200, width: 1400, height: 600)
        let credit = SlideObject(id: "credit", objectKind: .text, name: "Credit", text: "", x: 90, y: 900, width: 1300, height: 80,
                                 textStyle: TextStyle(fontName: "HelveticaNeue", fontSize: 24, colorHex: "#00FF00FF"))
        let template = Slide(id: "design", name: "Custom", objects: [heading, body, credit])
        var mapping = BibleBlockMapping(); mapping.verse = "body"; mapping.reference = "heading"; mapping.copyright = "credit"
        let page = try #require(BibleSlides.pages(verses: [verse]).first)
        let slide = BibleSlides.slide(page: page, translation: translation, themeID: "theme", design: "Custom", template: template, mapping: mapping, shortCopyright: true)
        let text = Dictionary(uniqueKeysWithValues: slide.objects.map { ($0.name, $0.text) })
        #expect(text["Body"] == verse.text || text["Body"] == "16 " + verse.text)
        #expect(text["Heading"] == "John 3:16 (NIV)")
        #expect(text["Credit"] == "NIV © 1973, 1978, 1984, 2011 Biblica, Inc. All rights reserved.")
        let assignments = SlideSceneBuilder.placeholderAssignments(for: slide.objects, in: template)
        for object in slide.objects {
            let target = try #require(assignments[object.id])
            #expect(SlideSceneBuilder.frame(for: object, placeholder: target) == SlideSceneBuilder.frame(for: target))
            #expect(object.textStyle == nil) // Later theme styling still applies.
        }
        #expect(slide.notes?.contains(translation.copyright) == true)
    }

    @Test func copyrightUsesNamedBlockOrAnExplicitFooterWithoutStealingAnotherRole() throws {
        let template = Slide(id: "design", name: "Bible", objects: [
            SlideObject(id: "v", objectKind: .text, name: "Verse", text: ""),
            SlideObject(id: "r", objectKind: .text, name: "Reference", text: ""),
            SlideObject(id: "c", objectKind: .text, name: "Copyright", text: "", x: 500, y: 80, width: 1000, height: 100),
        ])
        let page = try #require(BibleSlides.pages(verses: [verse]).first)
        let automatic = BibleSlides.slide(page: page, translation: translation, themeID: "theme", template: template)
        #expect(automatic.objects.first(where: { $0.name == "Copyright" })?.x == nil)
        var mapping = BibleBlockMapping(); mapping.copyright = BibleBlockMapping.footer
        let footer = BibleSlides.slide(page: page, translation: translation, themeID: "theme", template: template, mapping: mapping)
        #expect(footer.objects.first(where: { $0.name == "Copyright" })?.y == 1020)
        let twoBlocks = Slide(id: "two", name: "Bible", objects: Array(template.objects.prefix(2)))
        #expect(BibleBlockMapping().resolved(in: twoBlocks).copyright == nil)
        #expect(BibleBlockMapping().resolved(in: twoBlocks).reference?.id == "r")
    }

    @Test func shortNoticesRetainActualEditionYearsAndUnknownNoticesAreNotGuessed() {
        let nlt = BibleTranslation(id: "NLT", name: "NLT", copyright: "Holy Bible, New Living Translation. Copyright © 2014 Tyndale House Publishers. All rights reserved.", verses: [])
        #expect(BibleCopyright.short(nlt) == "NLT © 2014 Tyndale House Publishers. All rights reserved.")
        let msg = BibleTranslation(id: "MSG", name: "The Message", copyright: "The Message © 1993, 2002, 2018 by Eugene H. Peterson. Used by permission of NavPress.", verses: [])
        #expect(BibleCopyright.short(msg).contains("1993, 2002, 2018 Eugene H. Peterson"))
        let unknown = BibleTranslation(id: "NIV", name: "NIV", copyright: "Unrecognized local publisher notice", verses: [])
        #expect(BibleCopyright.short(unknown) == unknown.copyright)
    }

    @Test func savedESVProvenanceCountsVersesOnceAcrossPaginationAndRepeatedInsertions() throws {
        let translation = BibleTranslation(id: "ESV", name: "ESV", copyright: ESVClient.copyright, source: "https://api.esv.org", verses: [])
        let long = BibleVerse(book: "JHN", chapter: 3, verse: 16, text: Array(repeating: "A test sentence.", count: 100).joined(separator: " "))
        let slides = BibleSlides.pages(verses: [long], maxCharacters: 150).map { BibleSlides.slide(page: $0, translation: translation) }
        #expect(slides.count > 1)
        let ids = ESVStorage.ids(in: slides + slides)
        #expect(ids == ["JHN.3.16"])
        #expect(throws: Never.self) { try ESVStorage.validate(pending: [long], saved: ids) }
    }

    @Test func localStorageLimitsRejectExcessWithoutDeletingDocuments() throws {
        let corpus = try BibleCorpus(.bundledWEB())
        let verses = try corpus.passage("Genesis 1:1–20:18")
        let saved = Set(verses.prefix(500).map(\.id))
        #expect(saved.count == 500)
        #expect(throws: Never.self) { try ESVStorage.validate(pending: Array(verses.prefix(5)), saved: saved) }
        #expect(throws: ESVError.self) { try ESVStorage.validate(pending: [verses[500]], saved: saved) }
        let obadiah = try corpus.passage("Obadiah 1")
        #expect(throws: Never.self) { try ESVStorage.validate(pending: Array(obadiah.prefix(10)), saved: []) }
        #expect(throws: ESVError.self) { try ESVStorage.validate(pending: Array(obadiah.prefix(11)), saved: []) }
        #expect(saved.count == 500)
    }
}
