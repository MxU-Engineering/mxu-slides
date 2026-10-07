import Foundation
import PresenterCore
import XCTest
@testable import SlideScene

final class SlideBulkEditTests: XCTestCase {
    private func slide(
        _ id: String, section: String? = nil, actions: [SlideAction]? = nil,
        advance: AutoAdvance? = nil
    ) -> Slide {
        Slide(
            id: id, name: id,
            objects: [SlideObject(id: "\(id)-o1", objectKind: .text, name: "Text", text: id)],
            sectionId: section, actions: actions, autoAdvance: advance
        )
    }

    private func presentation(_ slides: [Slide]) -> Presentation {
        Presentation(
            id: "p1", name: "Deck", presentationKind: .song, themeId: "", slides: slides)
    }

    func testSlideIDsDedupeArrangedOccurrencesInGridOrder() {

        let arranged = [slide("s1"), slide("s2"), slide("s3"), slide("s2")]
        XCTAssertEqual(
            SlideBulkEdit.slideIDs(occurrences: [3, 0, 1], slides: arranged),
            ["s1", "s2"],
            "occurrences of one slide collapse to one edit, grid order kept"
        )
        XCTAssertEqual(
            SlideBulkEdit.slideIDs(occurrences: [7], slides: arranged), [],
            "stale indices never resolve"
        )
    }

    func testAddActionLandsFreshIDCopiesAndReturnsPairs() {
        var doc = presentation([slide("s1"), slide("s2"), slide("s3")])
        let template = SlideAction(id: "menu-id", kind: .fireMedia)
        let pairs = SlideBulkEdit.addAction(template, to: ["s1", "s3"], in: &doc)

        XCTAssertEqual(pairs.map(\.slideID), ["s1", "s3"])
        XCTAssertEqual(doc.slides[0].actions?.count, 1)
        XCTAssertNil(doc.slides[1].actions, "untargeted slide untouched")
        let ids = [doc.slides[0].actions![0].id, doc.slides[2].actions![0].id]
        XCTAssertEqual(Set(ids).count, 2, "each slide gets its own action id")
        XCTAssertFalse(ids.contains("menu-id"), "the template id is never reused")
        XCTAssertEqual(pairs.map(\.actionID), ids, "pairs point at the landed actions")
    }

    func testAddActionTakesCallerMintedIDs() {
        let template = SlideAction(id: "menu-id", kind: .fireMedia)
        let minted = ["s1": "a-one", "s3": "a-three"]
        var first = presentation([slide("s1"), slide("s2"), slide("s3")])
        var second = first
        let pairs = SlideBulkEdit.addAction(template, to: ["s1", "s3"], in: &first, actionIDs: minted)
        SlideBulkEdit.addAction(template, to: ["s1", "s3"], in: &second, actionIDs: minted)
        XCTAssertEqual(first, second)
        XCTAssertEqual(pairs.map(\.actionID), ["a-one", "a-three"])
    }

    func testActionKindsUnionOrderedByFirstAppearance() {
        let slides = [
            slide("s1", actions: [SlideAction(id: "a1", kind: .clearAll)]),
            slide("s2", actions: [
                SlideAction(id: "a2", kind: .fireMedia),
                SlideAction(id: "a3", kind: .clearAll),
            ]),
            slide("s3", actions: [SlideAction(id: "a4", kind: .midiOut)]),
        ]
        XCTAssertEqual(
            SlideBulkEdit.actionKinds(on: ["s1", "s2"], in: slides),
            [.clearAll, .fireMedia],
            "union across the selection only, no duplicates"
        )
    }

    func testRemoveActionsByKindAndAll() {
        var doc = presentation([
            slide("s1", actions: [
                SlideAction(id: "a1", kind: .clearAll),
                SlideAction(id: "a2", kind: .fireMedia),
            ]),
            slide("s2", actions: [SlideAction(id: "a3", kind: .clearAll)]),
        ])
        SlideBulkEdit.removeActions(ofKind: .clearAll, from: ["s1", "s2"], in: &doc)
        XCTAssertEqual(doc.slides[0].actions?.map(\.kind), [.fireMedia])
        XCTAssertNil(doc.slides[1].actions, "empty collapses to absent (the schema rule)")

        SlideBulkEdit.removeActions(ofKind: nil, from: ["s1"], in: &doc)
        XCTAssertNil(doc.slides[0].actions, "nil kind sweeps everything")
    }

    func testSetAutoAdvanceWritesEveryTarget() {
        var doc = presentation([
            slide("s1", advance: AutoAdvance(delaySeconds: 3)),
            slide("s2"),
            slide("s3"),
        ])
        let advance = AutoAdvance(delaySeconds: 5, loopToStart: true)
        SlideBulkEdit.setAutoAdvance(advance, on: ["s1", "s2"], in: &doc)
        XCTAssertEqual(doc.slides[0].autoAdvance, advance)
        XCTAssertEqual(doc.slides[1].autoAdvance, advance)
        XCTAssertNil(doc.slides[2].autoAdvance, "untargeted slide untouched")

        SlideBulkEdit.setAutoAdvance(nil, on: ["s1"], in: &doc)
        XCTAssertNil(doc.slides[0].autoAdvance, "nil clears")
    }

    func testDuplicateSlidesInsertsFreshCopiesAfterEachSource() {
        var doc = presentation([slide("s1", section: "v1"), slide("s2"), slide("s3")])
        SlideBulkEdit.duplicateSlides(["s1", "s3"], in: &doc)

        XCTAssertEqual(doc.slides.count, 5)
        XCTAssertEqual(doc.slides.map(\.name), ["s1", "s1", "s2", "s3", "s3"])
        XCTAssertNotEqual(doc.slides[1].id, "s1", "copies carry fresh slide ids")
        XCTAssertEqual(doc.slides[1].sectionId, "v1", "copies stay in the source section")
        XCTAssertNotEqual(
            doc.slides[1].objects[0].id, doc.slides[0].objects[0].id,
            "object ids never alias across slides"
        )
    }

    func testDeleteSlidesNeverEmptiesTheDeck() {
        var doc = presentation([slide("s1"), slide("s2"), slide("s3")])
        XCTAssertTrue(SlideBulkEdit.deleteSlides(["s1", "s3"], in: &doc))
        XCTAssertEqual(doc.slides.map(\.id), ["s2"])

        XCTAssertFalse(
            SlideBulkEdit.deleteSlides(["s2"], in: &doc),
            "the last slide stays — an empty presentation has no canvas"
        )
        XCTAssertEqual(doc.slides.map(\.id), ["s2"])
    }

    func testBatchIsTheSelectionInSlideOrderOnlyWhenTheRowIsInIt() {
        let slides = [slide("s1"), slide("s2"), slide("s3")]
        XCTAssertEqual(
            SlideBulkEdit.batch(for: "s3", selected: ["s3", "s1"], slides: slides),
            ["s1", "s3"], "a multi-selected row acts for the whole selection, slide order"
        )
        XCTAssertEqual(
            SlideBulkEdit.batch(for: "s2", selected: ["s3", "s1"], slides: slides),
            ["s2"], "a row outside the selection acts alone"
        )
        XCTAssertEqual(
            SlideBulkEdit.batch(for: "s1", selected: ["s1"], slides: slides), ["s1"])
    }

    func testUniqueThemeSlideNameCountsPastTakenNamesCaseInsensitively() {
        XCTAssertEqual(SlideBulkEdit.uniqueThemeSlideName("Chorus", among: ["Verse"]), "Chorus")
        XCTAssertEqual(
            SlideBulkEdit.uniqueThemeSlideName("Chorus", among: ["chorus", "Chorus 2"]),
            "Chorus 3"
        )
    }

    func testMoveSlidesAppendsToTheDestinationWithUniqueNamesAndKeepsIDs() {
        var source = [slide("s1", section: "v1"), slide("s2"), slide("s3")]
        var destination = [slide("Lyrics"), slide("s3")]
        XCTAssertTrue(SlideBulkEdit.moveSlides(["s3", "s1"], from: &source, to: &destination))

        XCTAssertEqual(source.map(\.id), ["s2"])
        XCTAssertEqual(destination.map(\.id), ["Lyrics", "s3", "s1", "s3"], "ids travel — a move, not a copy")
        XCTAssertEqual(
            destination.map(\.name), ["Lyrics", "s3", "s1", "s3 2"],
            "source order, and a clashing category name counts up"
        )
        XCTAssertNil(destination[2].sectionId, "deck sections never enter a theme")
    }

    func testMoveSlidesRefusesToEmptyTheSourceOrMoveNothing() {
        var source = [slide("s1"), slide("s2")]
        var destination = [slide("Lyrics")]
        XCTAssertFalse(SlideBulkEdit.moveSlides(["s1", "s2"], from: &source, to: &destination))
        XCTAssertFalse(SlideBulkEdit.moveSlides(["missing"], from: &source, to: &destination))
        XCTAssertEqual(source.count, 2)
        XCTAssertEqual(destination.count, 1)
    }

    func testAdoptedForThemeDedupesWithinThePastedBatchToo() {
        let adopted = SlideBulkEdit.adoptedForTheme(
            [slide("Bible", section: "x"), slide("Bible")], existing: [slide("Bible")])
        XCTAssertEqual(adopted.map(\.name), ["Bible 2", "Bible 3"])
        XCTAssertNil(adopted[0].sectionId)

        var unnamed = slide("x")
        unnamed.name = ""
        XCTAssertEqual(
            SlideBulkEdit.adoptedForTheme([unnamed], existing: [slide("Category")]).map(\.name),
            ["Category 2"], "an unnamed deck slide needs a category name"
        )
    }

    func testDraggedSlideReadsTheTilePayloadAndNothingElse() {
        let payload = SlideBulkEdit.slideDragPayload(presentationID: "p1", slideID: "s2")
        XCTAssertEqual(payload, "mxuslide::p1::s2")
        XCTAssertEqual(SlideBulkEdit.draggedSlide(in: payload)?.presentationID, "p1")
        XCTAssertEqual(SlideBulkEdit.draggedSlide(in: payload)?.slideID, "s2")
        XCTAssertNil(SlideBulkEdit.draggedSlide(in: "mxueditslide::s1,s2"))
        XCTAssertNil(SlideBulkEdit.draggedSlide(in: "pltrk::p1::t1"))
        XCTAssertNil(SlideBulkEdit.draggedSlide(in: "mxuslide::p1"))
    }

    func testInsertSlidesLandsBeforeTheAnchorInItsSection() {
        var doc = presentation([slide("s1", section: "verse"), slide("s2", section: "chorus")])
        let arriving = [slide("x1", section: "other-deck"), slide("x2", section: nil)]
        SlideBulkEdit.insertSlides(arriving, before: "s2", in: &doc)

        XCTAssertEqual(doc.slides.map(\.id), ["s1", "x1", "x2", "s2"])
        XCTAssertEqual(
            doc.slides.map(\.sectionId), ["verse", "chorus", "chorus", "chorus"],
            "another deck's section id never lands; the neighbor's does")
    }

    func testInsertSlidesWithNoAnchorLandsAtTheEnd() {
        var doc = presentation([slide("s1", section: "verse")])
        SlideBulkEdit.insertSlides([slide("x1")], before: nil, in: &doc)
        SlideBulkEdit.insertSlides([slide("x2")], before: "gone", in: &doc)

        XCTAssertEqual(doc.slides.map(\.id), ["s1", "x1", "x2"])
        XCTAssertEqual(doc.slides.map(\.sectionId), ["verse", "verse", "verse"])
    }

    func testInsertSlidesAfterTheAnchorAdoptsItsSection() {
        var doc = presentation([slide("s1", section: "verse"), slide("s2", section: "chorus")])
        SlideBulkEdit.insertSlides([slide("x1", section: "elsewhere")], after: "s1", in: &doc)
        SlideBulkEdit.insertSlides([slide("x2")], after: nil, in: &doc)
        SlideBulkEdit.insertSlides([slide("x3")], after: "gone", in: &doc)

        XCTAssertEqual(doc.slides.map(\.id), ["s1", "x1", "s2", "x2", "x3"])
        XCTAssertEqual(
            doc.slides.map(\.sectionId), ["verse", "verse", "chorus", "chorus", "chorus"],
            "after the verse's last slide stays IN the verse; no anchor = the end")
    }

    func testMoveSlideBeforeAdoptsTheNeighborsSectionAndNilMeansTheEnd() {
        var doc = presentation([
            slide("s1", section: "verse"), slide("s2", section: "chorus"), slide("s3", section: "chorus"),
        ])
        SlideBulkEdit.moveSlide("s3", before: "s1", in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s3", "s1", "s2"])
        XCTAssertEqual(doc.slides[0].sectionId, "verse")

        SlideBulkEdit.moveSlide("s1", before: nil, in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s3", "s2", "s1"])
        XCTAssertEqual(doc.slides[2].sectionId, "chorus", "the end adopts the last slide's section")
        SlideBulkEdit.moveSlide("s2", before: "s2", in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s3", "s2", "s1"], "onto itself: unchanged")
    }

    func testMoveSlideAfterReachesTheEndOfADeckAndOfASection() {
        var doc = presentation([
            slide("s1", section: "verse"), slide("s2", section: "chorus"), slide("s3", section: "chorus"),
        ])
        SlideBulkEdit.moveSlide("s1", after: "s3", in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s2", "s3", "s1"])
        XCTAssertEqual(doc.slides[2].sectionId, "chorus")

        SlideBulkEdit.moveSlide("s3", after: "s2", in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s2", "s3", "s1"], "already there: unchanged")
        SlideBulkEdit.moveSlide("s1", after: "s1", in: &doc)
        XCTAssertEqual(doc.slides.map(\.id), ["s2", "s3", "s1"], "onto itself: unchanged")
    }
}
