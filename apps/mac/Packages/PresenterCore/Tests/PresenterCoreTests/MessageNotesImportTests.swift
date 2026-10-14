import AppKit
import Foundation
import Testing
@testable import PresenterCore

private let outline = """
Abba and Kiss
Gal. 4:1-7

(Fall Student Event)

The Gospel is marked by love more than law and freedom more than legalism

Gal. 4:1 – What I am saying is that as long as an heir is underage, he is no different from a slave, although he owns the whole estate.

Gal. 4:2-3 – The heir is subject to guardians and trustees until the time set by his father. So also, when we were underage, we were in slavery under the elemental spiritual forces of the world.

Sin makes us suspicious

(diagrammed) Gal. 4:4-5 – But when the set time had fully come, God sent his Son, born of a woman, born under the law, to redeem those under the law, that we might receive adoption to sonship.

Jesus makes us sons and daughters

Ps. 42:7 – Deep calls to deep at the roar of your waterfalls; all your breakers and your waves have gone over me. By day the Lord commands his steadfast love, and at night his song is with me (unbelievable intimacy)

(Back to TV – 4-5 & 6-7 diagrammed)

The Spirit makes us secure

Lu. 15:20 – And he arose and came to his father. But while he was still a long way off, his father saw him and felt compassion, and ran and embraced him and kissed him.

“We are born into this world looking for someone looking for us.” – Curt Thompson

Next Steps – YNTD, prayer, & baptisms
Offering Moment – Montreal Church plant – (picture)

Campus Connect
"""

@Test func anOutlineReadsAsTitlePointsScriptureAndQuotes() {
    let parsed = MessageNotes.parse(outline)
    #expect(parsed.title == "Abba and Kiss")
    #expect(parsed.blocks.map(\.kind) == [
        .title, .skip, .point, .scripture, .scripture, .point, .scripture, .point, .scripture, .skip,
        .point, .scripture, .quote, .skip, .skip, .skip,
    ])
    #expect(parsed.blocks[0].detail == "Gal. 4:1-7")
    #expect(parsed.blocks[3].detail == "Gal. 4:1")
    #expect(parsed.blocks[3].text.hasPrefix("What I am saying"))
    #expect(parsed.blocks[4].detail == "Gal. 4:2-3")
    #expect(parsed.blocks[6].detail == "Gal. 4:4-5")
    #expect(parsed.blocks[6].cues == ["diagrammed"])
    #expect(parsed.blocks[6].text.hasPrefix("But when the set time"))
    #expect(parsed.blocks[8].detail == "Ps. 42:7")
    #expect(parsed.blocks[8].text.hasSuffix("his song is with me"))
    #expect(parsed.blocks[8].cues == ["unbelievable intimacy"])
    #expect(parsed.blocks[11].detail == "Lu. 15:20")
    #expect(parsed.blocks[12].text == "We are born into this world looking for someone looking for us.")
    #expect(parsed.blocks[12].detail == "Curt Thompson")
}

@Test func scriptureIsFoundHoweverTheReferenceIsWritten() {
    func read(_ line: String) -> MessageNotes.Block {
        MessageNotes.parse("Title\n\n" + line).blocks[1]
    }
    #expect(read("John 3:16 For God so loved the world").kind == .scripture)
    #expect(read("John 3:16 says it all").kind == .point)
    #expect(read("Read John 3:16").kind == .point)
    #expect(read("For God so loved the world (John 3:16)").detail == "John 3:16")
    #expect(read("For God so loved the world. – John 3:16 NIV").detail == "John 3:16 NIV")
    #expect(read("Jesus wept. John 11:35").kind == .point)
    let translated = read("John 11:35 – Jesus wept. (ESV)")
    #expect(translated.text == "Jesus wept.")
    #expect(translated.detail == "John 11:35 (ESV)")

    let stacked = MessageNotes.parse("Title\n\nRomans 5:8\nBut God shows his love for us").blocks[1]
    #expect(stacked.kind == .scripture)
    #expect(stacked.detail == "Romans 5:8")
    #expect(stacked.text == "But God shows his love for us")
    let trailing = MessageNotes.parse("Title\n\nBut God shows his love for us\n– Romans 5:8").blocks[1]
    #expect(trailing.kind == .scripture)
    #expect(trailing.detail == "Romans 5:8")
}

@Test func asidesProseAndUnboldedLinesStayOffTheScreen() {
    let prose = String(repeating: "This is the story I tell here. ", count: 8)
    let parsed = MessageNotes.parse("Title\n\nGod is near\n\n" + prose + "\n\n• Welcome\n\nPrayer changes things")
    #expect(parsed.blocks.map(\.kind) == [.title, .point, .skip, .skip, .point])

    let hinted = MessageNotes.parse(
        "Title\n\nGod is near\n\nremember the camping story\n\nJohn 1:1 – In the beginning",
        hints: [
            "God is near": .init(bold: true), "remember the camping story": .init(bold: false),
            "John 1:1 – In the beginning": .init(bold: false),
        ], boldOnly: true)
    #expect(hinted.blocks.map(\.kind) == [.title, .point, .skip, .scripture])
}

@Test func aLineCanBeToldWhatItIs() {
    let text = "Title\n\nNext Steps – pray\n\nGod is near\n\nHe will never leave you"
    let parsed = MessageNotes.parse(text, overrides: [
        "Next Steps – pray": .point, "God is near": .skip, "He will never leave you": .scripture, "Title": .point,
    ])
    #expect(parsed.title == nil)
    #expect(parsed.blocks.map(\.kind) == [.point, .point, .skip, .scripture])
    #expect(parsed.blocks[3].detail == nil)
}

private func built(style: String? = nil, themed: Bool = true) -> Presentation {
    let theme = themed ? StarterPack.cleanGeometric.makeTheme() : nil
    return MessageNotes.makePresentation(
        MessageNotes.parse(outline, hints: ["Sin makes us suspicious": .init(bold: true, underlined: ["suspicious"])]),
        themeId: theme?.id ?? "", theme: theme, style: style)
}

private func box(_ presentation: Presentation, _ slide: Int, _ name: String) -> SlideObject? {
    presentation.slides[slide].objects.first { $0.name == name }
}

@Test func eachKindCanTakeItsOwnTheme() {
    let deck = StarterPack.cleanGeometric.makeTheme()
    guard let other = StarterPack.allCases.map({ $0.makeTheme() }).first(where: { $0.id != deck.id }) else { return }
    let presentation = MessageNotes.makePresentation(
        MessageNotes.parse(outline), themeId: deck.id, theme: deck, kindThemes: [.scripture: other, .point: deck])
    let parsed = MessageNotes.parse(outline)
    let kinds = parsed.blocks.filter { $0.kind != .skip }.map(\.kind)
    #expect(kinds.count == presentation.slides.count)
    for (kind, slide) in zip(kinds, presentation.slides) {
        #expect(slide.themeId == (kind == .scripture ? other.id : nil))
    }
}

@Test func slidesLandOnTheMatchingDesigns() {
    let presentation = built()
    #expect(presentation.name == "Abba and Kiss")
    #expect(presentation.slides.map(\.themeSlideName) == [
        "Section Title", "Point", "Verse + Reference", "Verse + Reference", "Point", "Verse + Reference",
        "Point", "Verse + Reference", "Point", "Verse + Reference", "Quote",
    ])
    #expect(box(presentation, 0, "Section Title")?.text == "Abba and Kiss")
    #expect(box(presentation, 0, "Kicker")?.text == "Gal. 4:1-7")
    #expect(box(presentation, 1, "Kicker")?.text == "")
    #expect(box(presentation, 2, "Reference")?.text == "Gal. 4:1")
    let verseY = StarterPack.cleanGeometric.makeTheme()
        .design(named: "Verse + Reference")?.objects.first { $0.name == "Verse" }?.y
    #expect((box(presentation, 2, "Reference")?.y ?? -.infinity) > (verseY ?? .infinity))
    #expect(box(presentation, 4, "Point")?.styleRuns == [TextStyleRun(line: 0, column: 13, length: 10, underline: true)])
}

@Test func markdownVersePassageKeepsItsReferenceBelowTheFinalVerse() throws {
    let parsed = MessageNotes.parse("""
    ***15*** *To give a human example, brothers: even with a man-made covenant, no one annuls it or adds to it once it has been ratified.*

    ***16*** *Now the promises were made to Abraham and to his offspring. It does not say, “And to offsprings,” referring to many, but referring to one, “And to your offspring,” who is Christ.*

    *Galatians 3:15-16*
    """)

    #expect(parsed.blocks.map(\.kind) == [.scripture, .scripture])
    #expect(parsed.blocks.map(\.detail) == ["15", "16"])
    #expect(parsed.blocks.map(\.text) == [
        "To give a human example, brothers: even with a man-made covenant, no one annuls it or adds to it once it has been ratified.",
        "Now the promises were made to Abraham and to his offspring. It does not say, “And to offsprings,” referring to many, but referring to one, “And to your offspring,” who is Christ.",
    ])
    #expect(parsed.blocks[1].passageReference == "Galatians 3:15-16")

    let presentation = MessageNotes.makePresentation(
        parsed, theme: StarterPack.cleanGeometric.makeTheme())
    let verse = try #require(box(presentation, 1, "Verse"))
    let reference = try #require(box(presentation, 1, "Reference"))
    #expect(verse.text.hasPrefix("16 Now the promises"))
    #expect(reference.text == "Galatians 3:15-16")
    #expect((reference.y ?? -.infinity) >= (verse.y ?? 0) + (verse.height ?? 0))
    #expect((reference.y ?? 0) - ((verse.y ?? 0) + (verse.height ?? 0)) >= 48)

    let unthemed = MessageNotes.makePresentation(parsed, theme: nil)
    let plainVerse = try #require(unthemed.slides[1].objects.first)
    #expect(plainVerse.text.hasPrefix("16 Now the promises"))
    #expect(plainVerse.text.hasSuffix("\nGalatians 3:15-16"))
}

@Test func quotesKeepTheirMarkAndAsidesBecomeSlideNotes() {
    let presentation = built()
    #expect(box(presentation, 10, "Quote")?.text == "We are born into this world looking for someone looking for us.")
    #expect(box(presentation, 10, "Quote Mark")?.text == "“")
    #expect(box(presentation, 10, "Source")?.text == "Curt Thompson")
    #expect(presentation.slides[0].notes == "Fall Student Event")
    #expect(presentation.slides[5].notes == "diagrammed")
    #expect(presentation.slides[7].notes == "unbelievable intimacy\nBack to TV – 4-5 & 6-7 diagrammed")
    #expect(presentation.slides[10].notes?.contains("Campus Connect") == true)
}

@Test func aStylePicksThatFoldersDesignsAndNoThemeStacksTheReference() {
    #expect(MessageNotes.styles(in: StarterPack.cleanGeometric.makeTheme()) == ["Full Slide", "Lower Thirds", "Side Thirds"])
    let thirds = built(style: "Lower Thirds")
    #expect(thirds.slides[1].themeSlideName == "Point (Lower Third)")
    #expect(thirds.slides[2].themeSlideName == "Verse + Reference (Lower Third)")

    let plain = built(themed: false)
    #expect(plain.slides[2].objects.map(\.text) == [
        "What I am saying is that as long as an heir is underage, he is no different from a slave, although he owns the whole estate.\nGal. 4:1",
    ])
    #expect(plain.slides[10].objects[0].text.hasSuffix("for us.”\n– Curt Thompson"))
}

@Test func pointsCanShareASlideAndRevealOneAtATime() throws {
    let parsed = MessageNotes.parse("Title\n\nPoint 1 – First point\n\nPoint 2 – Second point")
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, revealingPointIndices: [1, 2], fontSizes: [1: 72],
        newID: { UUID().uuidString })

    #expect(presentation.slides.count == 2)
    let point = try #require(presentation.slides[1].objects.first)
    #expect(point.text == "Point 1: First point\nPoint 2: Second point")
    #expect(point.textStyle?.fontSize == 72)
    #expect(point.animationSteps?.count == 2)
    #expect(point.animationSteps?.map(\.trigger) == [.onClick, .onClick])
    #expect(point.animationSteps?.map { $0.ranges ?? [] } == [
        [AnimationRange(line: 0, column: 0, length: "Point 1: First point".count)],
        [AnimationRange(line: 1, column: 0, length: "Point 2: Second point".count)],
    ])
}

@Test func onlySelectedPointSlidesAreGroupedForReveals() throws {
    let parsed = MessageNotes.parse("Title\n\nFirst point\n\nSecond point\n\nThird point")
    let groups = MessageNotes.slideGroups(in: parsed.blocks, revealingPointIndices: [2, 3])
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, revealingPointIndices: [2, 3], fontSizes: [1: 48, 2: 72, 3: 88])

    #expect(groups == [[0], [1], [2, 3]])
    #expect(presentation.slides.count == 3)
    #expect(presentation.slides[1].objects[0].text == "First point")
    #expect(presentation.slides[1].objects[0].animationSteps == nil)
    #expect(presentation.slides[1].objects[0].textStyle?.fontSize == 48)
    #expect(presentation.slides[2].objects[0].text == "Second point\nThird point")
    #expect(presentation.slides[2].objects[0].animationSteps?.count == 2)
    #expect(presentation.slides[2].objects[0].textStyle?.fontSize == 72)
}

@Test func advancedOptionsCanOmitTitleAndInsertBlankSlides() {
    let parsed = MessageNotes.parse("Message title\n\nFirst point\n\nSecond point")
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, includeTitleSlide: false, blankSlidesBetweenSlides: true)

    #expect(presentation.name == "Message title")
    #expect(presentation.slides.count == 3)
    #expect(presentation.slides[0].objects[0].text == "First point")
    #expect(presentation.slides[1].objects.isEmpty)
    #expect(presentation.slides[2].objects[0].text == "Second point")
    #expect(MessageNotes.slideGroups(
        in: parsed.blocks, revealingPointIndices: [], includeTitleSlide: false) == [[1], [2]])
}

@Test func blankSlideCanBeAddedAtTheBeginning() throws {
    let parsed = MessageNotes.parse("Message title\n\nFirst point")
    let presentation = MessageNotes.makePresentation(parsed, theme: nil, blankSlideAtBeginning: true)

    #expect(presentation.slides.count == 3)
    #expect(presentation.slides[0].objects.isEmpty)
    #expect(presentation.slides[1].objects[0].text == "Message title")
    #expect(presentation.slides[2].objects[0].text == "First point")
}

@Test func blankSlidesDoNotSplitConsecutiveVersesInAPassage() throws {
    let parsed = MessageNotes.parse(
        "Title\n\nOpening point\n\nJohn 3:15-17 – 15 First verse. 16 Second verse. 17 Third verse.\n\nClosing point"
    ).splittingVerses()
    let presentation = MessageNotes.makePresentation(parsed, theme: nil, blankSlidesBetweenSlides: true)
    let verseSlides = presentation.slides.indices.filter { index in
        presentation.slides[index].objects.contains { $0.name == "Verse" }
    }

    #expect(verseSlides.count == 3)
    #expect(verseSlides[1] == verseSlides[0] + 1)
    #expect(verseSlides[2] == verseSlides[1] + 1)
    #expect(presentation.slides[verseSlides[2]].objects.contains { $0.text.contains("John 3:15-17") })
    #expect(presentation.slides[verseSlides[0] - 1].objects.isEmpty)
    #expect(presentation.slides[verseSlides[2] + 1].objects.isEmpty)
}

@Test func repeatedQuotedPassageReferencesStayTogetherAndSeparateVerseNumberFromReference() throws {
    let quotedReference = MessageNotes.parse("Title\n\nOpening point\n\n“John 3:16-17”")
    let quotedBlock = try #require(quotedReference.blocks.last)
    #expect(quotedBlock.kind == .scripture)
    #expect(quotedBlock.detail == "John 3:16-17")

    let source = MessageNotes.parse(
        "Title\n\nJohn 3:16-17 – First verse.\n\nJohn 3:16-17 – Second verse.")
    let presentation = MessageNotes.makePresentation(
        source, theme: StarterPack.cleanGeometric.makeTheme(), blankSlidesBetweenSlides: true)
    let verseSlides = presentation.slides.indices.filter {
        presentation.slides[$0].objects.contains { $0.name == "Verse" }
    }
    #expect(verseSlides.count == 2)
    #expect(verseSlides[1] == verseSlides[0] + 1)

    let trailing = MessageNotes.parse("Title\n\n17\nJohn 3:16-17")
    let trailingBlock = try #require(trailing.blocks.last)
    let trailingPresentation = MessageNotes.makePresentation(
        trailing, theme: StarterPack.cleanGeometric.makeTheme())
    let trailingSlide = try #require(trailingPresentation.slides.last)
    #expect(trailingBlock.kind == .scripture)
    #expect(trailingBlock.text == "17")
    #expect(trailingSlide.objects.first { $0.name == "Verse" }?.text == "17")
    #expect(trailingSlide.objects.first { $0.name == "Reference" }?.text == "John 3:16-17")
}

@Test func blankSlidesCanBeRemovedBetweenIndividuallyReferencedVerses() {
    let parsed = MessageNotes.parse(
        "Title\n\nJohn 3:15 – First verse.\n\nJohn 3:16 – Second verse.\n\nJohn 3:17 – Third verse.")
    let together = MessageNotes.makePresentation(
        parsed, theme: nil, blankSlidesBetweenSlides: true, keepScripturePassagesTogether: true)
    let separated = MessageNotes.makePresentation(
        parsed, theme: nil, blankSlidesBetweenSlides: true, keepScripturePassagesTogether: false)
    let togetherVerses = together.slides.indices.filter {
        together.slides[$0].objects.contains { $0.name == "Verse" }
    }
    let separatedVerses = separated.slides.indices.filter {
        separated.slides[$0].objects.contains { $0.name == "Verse" }
    }

    #expect(togetherVerses.count == 3)
    #expect(togetherVerses[1] == togetherVerses[0] + 1)
    #expect(togetherVerses[2] == togetherVerses[1] + 1)
    #expect(separatedVerses.count == 3)
    #expect(separatedVerses[1] == separatedVerses[0] + 2)
    #expect(separatedVerses[2] == separatedVerses[1] + 2)
}

@Test func anIndividualBlankSlideCanBeRemovedWithoutRemovingOtherBlankSlides() throws {
    let parsed = MessageNotes.parse(
        "Title\n\nJohn 3:16-17 – First verse.\n\nJohn 3:16-17 – Second verse.\n\nClosing point")
    let allBlankSlides = MessageNotes.blankSlideSlots(
        in: parsed.blocks, blankSlidesBetweenSlides: true,
        keepScripturePassagesTogether: true, blankSlideAtBeginning: true)
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, blankSlidesBetweenSlides: true, blankSlideAtBeginning: true,
        removedBlankSlideSlots: [-1])

    #expect(allBlankSlides.count == 3)
    #expect(presentation.slides.count == 6)
    #expect(presentation.slides.first?.objects[0].text == "Title")
    #expect(presentation.slides.contains { $0.objects.isEmpty })
    let verses = presentation.slides.filter { slide in
        slide.objects.contains { $0.name == "Verse" }
    }
    #expect(verses.count == 2)
    let allRemoved = MessageNotes.makePresentation(
        parsed, theme: nil, blankSlidesBetweenSlides: true, blankSlideAtBeginning: true,
        removedBlankSlideSlots: allBlankSlides)
    #expect(allRemoved.slides.allSatisfy { !$0.objects.isEmpty })
}

@Test func blankSlidesCanBeAddedAtIndividualPreviewBoundaries() {
    let parsed = MessageNotes.parse("Title\n\nFirst point\n\nSecond point")
    let inserted = MessageNotes.makePresentation(
        parsed, theme: nil, additionalBlankSlideSlots: [2, 3])

    #expect(inserted.slides.count == 5)
    #expect(inserted.slides[2].objects.isEmpty)
    #expect(inserted.slides[4].objects.isEmpty)

    let oneRemoved = MessageNotes.makePresentation(
        parsed, theme: nil, additionalBlankSlideSlots: [2, 3], removedBlankSlideSlots: [2])
    #expect(oneRemoved.slides.count == 4)
    #expect(oneRemoved.slides[2].objects.first?.text == "Second point")
    #expect(oneRemoved.slides[3].objects.isEmpty)
}

@Test func anIndividualSlideCanOverrideItsThemeDesignAndFontSize() throws {
    let parsed = MessageNotes.parse("Title\n\nA point\n\nJohn 3:16 – A verse.")
    let theme = StarterPack.cleanGeometric.makeTheme()
    let pointDesign = try #require(MessageNotes.designNames(for: .point, in: theme, style: "Full Slide")
        .first(where: { $0 == "Point (Lower Third)" }))
    let verseDesign = try #require(MessageNotes.designNames(for: .scripture, in: theme, style: "Full Slide")
        .first(where: { $0 == "Verse + Reference (Lower Third)" }))
    let presentation = MessageNotes.makePresentation(
        parsed, theme: theme, style: "Full Slide",
        fontSizes: [1: 54], designOverrides: [1: pointDesign, 2: verseDesign])

    #expect(presentation.slides[1].themeSlideName == pointDesign)
    #expect(presentation.slides[1].objects.first(where: { $0.name == "Point" })?.textStyle?.fontSize == 54)
    #expect(presentation.slides[2].themeSlideName == verseDesign)
}

@Test func imageFilesAndFontFamilyAreAppliedToTheirSlides() throws {
    let parsed = MessageNotes.parse("Message title\n\nA point")
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, imageMediaIDs: [1: ["photo-id"]])

    let image = try #require(presentation.slides[1].objects.first)
    #expect(image.name == "Imported Image")
    #expect(image.fill?.mediaId == "photo-id")
    #expect(image.fill?.mediaScaleMode == .fill)
    #expect(image.opacity == 0.4)
}

@Test func imagesCanBeAddedToAnIndividuallyInsertedBlankSlide() throws {
    let parsed = MessageNotes.parse("Title\n\nFirst point\n\nSecond point")
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, blankSlideAtBeginning: true, additionalBlankSlideSlots: [2],
        blankSlideImageMediaIDs: [-1: ["opening-photo"], 2: ["blank-photo"]])

    #expect(presentation.slides.count == 5)
    #expect(presentation.slides[0].objects.first?.fill?.mediaId == "opening-photo")
    let blankImage = try #require(presentation.slides[3].objects.first)
    #expect(blankImage.name == "Imported Image")
    #expect(blankImage.fill?.mediaId == "blank-photo")
    #expect(presentation.slides[3].objects.allSatisfy { $0.objectKind == .shape })
}

@Test func blankSlideCanBeInsertedAfterAnImageBearingBlankSlide() throws {
    let parsed = MessageNotes.parse("Title\n\nFirst point\n\nSecond point")
    let presentation = MessageNotes.makePresentation(
        parsed, theme: nil, additionalBlankSlideSlots: [2],
        blankSlideAfterSlots: [2], blankSlideImageMediaIDs: [2: ["photo-on-blank"]])

    #expect(presentation.slides.count == 5)
    #expect(presentation.slides[2].objects.first?.fill?.mediaId == "photo-on-blank")
    #expect(presentation.slides[3].objects.isEmpty)
    #expect(presentation.slides[4].objects.first?.text == "Second point")

    let removed = MessageNotes.makePresentation(
        parsed, theme: nil, additionalBlankSlideSlots: [2],
        blankSlideAfterSlots: [2], removedBlankSlideAfterSlots: [2],
        blankSlideImageMediaIDs: [2: ["photo-on-blank"]])
    #expect(removed.slides.count == 4)
    #expect(removed.slides[2].objects.first?.fill?.mediaId == "photo-on-blank")
    #expect(removed.slides[3].objects.first?.text == "Second point")
}

@Test func fullScriptureReferenceCannotBeHidden() {
    let parsed = MessageNotes.parse("Title\n\nJohn 3:16 – For God so loved the world")
    let shown = MessageNotes.makePresentation(parsed, theme: nil)
    let numbersHidden = MessageNotes.makePresentation(parsed, theme: nil, showVerseNumbers: false)

    #expect(shown.slides[1].objects[0].text == "For God so loved the world\nJohn 3:16")
    #expect(numbersHidden.slides[1].objects[0].text == "For God so loved the world\nJohn 3:16")
}

@Test func aWordDocumentKeepsItsBoldAndUnderlines() throws {
    let regular = NSFont.systemFont(ofSize: 12)
    let bold = NSFont.boldSystemFont(ofSize: 12)
    let rich = NSMutableAttributedString()
    rich.append(NSAttributedString(string: "Sin makes us ", attributes: [.font: bold]))
    rich.append(NSAttributedString(
        string: "suspicious", attributes: [.font: bold, .underlineStyle: NSUnderlineStyle.single.rawValue]))
    rich.append(NSAttributedString(string: "\n\nthe camping story\n", attributes: [.font: regular]))
    let data = try rich.data(
        from: NSRange(location: 0, length: rich.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    let loaded = try #require(MessageNotesFile.load(data, filename: "notes.docx"))
    #expect(loaded.text.contains("Sin makes us suspicious\n\nthe camping story"))
    #expect(loaded.hints["Sin makes us suspicious"] == .init(bold: true, underlined: ["suspicious"]))
    #expect(loaded.hints["the camping story"] == .init(bold: false))
    #expect(MessageNotesFile.load(Data("Title\nPoint".utf8), filename: "notes.txt")?.text == "Title\nPoint")
    #expect(MessageNotesFile.extensions.contains("pages"))
    #expect(MessageNotesFile.extensions.contains("pptx"))
    #expect(MessageNotesFile.load(Data("not a Pages document".utf8), filename: "notes.pages") == nil)
    #expect(MessageNotesFile.load(Data("not a PowerPoint document".utf8), filename: "notes.pptx") == nil)
}

@MainActor @Test func aPDFsWrappedLinesComeBackAsParagraphs() throws {
    let regular = NSFont(name: "Helvetica", size: 12)!
    let bold = NSFont(name: "Helvetica-Bold", size: 12)!
    let verse = "John 3:16 – For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life. For God did not send his Son into the world to condemn the world."
    let rich = NSMutableAttributedString()
    rich.append(NSAttributedString(string: "Abba and Kiss\n\nSin makes us suspicious\n\n", attributes: [.font: bold]))
    rich.append(NSAttributedString(string: verse + "\n\n", attributes: [.font: bold]))
    rich.append(NSAttributedString(string: "tell the camping story here\n", attributes: [.font: regular]))
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 600))
    view.textStorage?.setAttributedString(rich)
    let loaded = try #require(MessageNotesFile.load(view.dataWithPDF(inside: view.bounds), filename: "notes.pdf"))
    #expect(loaded.text == "Abba and Kiss\n\nSin makes us suspicious\n\n" + verse + "\n\ntell the camping story here")
    #expect(loaded.hints["Sin makes us suspicious"]?.bold == true)
    #expect(loaded.hints["tell the camping story here"]?.bold == false)
    let parsed = MessageNotes.parse(loaded.text, hints: loaded.hints, boldOnly: true)
    #expect(parsed.blocks.map(\.kind) == [.title, .point, .scripture, .skip])
}

@Test func markdownAndDashBulletsAreJustLines() {
    let parsed = MessageNotes.parse("# Abba and Kiss\n\n- Sin makes us suspicious\n- Gal. 4:1 – What I am saying")
    #expect(parsed.title == "Abba and Kiss")
    #expect(parsed.blocks.map(\.text) == ["Abba and Kiss", "Sin makes us suspicious", "What I am saying"])
    #expect(parsed.blocks[2].kind == .scripture)
}

@Test func aPassageSplitsIntoAVersePerSlide() {
    func split(_ line: String) -> [MessageNotes.Block] {
        Array(MessageNotes.parse("Title\n\n" + line).splittingVerses().blocks.dropFirst())
    }
    let numbered = split("(read slowly) John 3:16-18 (NIV) – 16 For God so loved the world. 17 For God did not send his Son to condemn. 18Whoever believes in him is not condemned.")
    #expect(numbered.map(\.detail) == ["16", "17", "18"])
    #expect(numbered.map(\.passageReference) == [nil, nil, "John 3:16-18 (NIV)"])
    #expect(numbered.map(\.text) == [
        "For God so loved the world.", "For God did not send his Son to condemn.",
        "Whoever believes in him is not condemned.",
    ])
    #expect(numbered.map(\.cues) == [["read slowly"], [], []])

    let unnumbered = split("Lu. 15:18-19 – I will arise and go to my father, and I will say to him, “Father, I have sinned against heaven and before you. I am no longer worthy to be called your son. Treat me as one of your hired servants.”")
    #expect(unnumbered.map(\.detail) == ["18", "19"])
    #expect(unnumbered.map(\.passageReference) == [nil, "Lu. 15:18-19"])
    #expect(unnumbered.map(\.text) == [
        "I will arise and go to my father, and I will say to him, “Father, I have sinned against heaven and before you.",
        "I am no longer worthy to be called your son. Treat me as one of your hired servants.”",
    ])

    #expect(split("Gal. 4:4-5 – But when the set time had fully come, God sent his Son, that we might receive adoption.").count == 1)
    #expect(split("Gal. 4:1 – What I am saying is this. An heir is no different from a slave.").count == 1)
    #expect(split("Rom 8:28, 31 – We know that God works. If God is for us, who can be against us?").count == 1)
}

@Test func splitVerseSlidesShowItsNumberAndKeepTheFullPassageAtTheEnd() {
    let source = MessageNotes.parse("Title\n\nJohn 3:15-16 – 15 For God so loved the world. 16 Whoever believes in him.")
    let theme = StarterPack.cleanGeometric.makeTheme()
    let presentation = MessageNotes.makePresentation(source.splittingVerses(), theme: theme)
    let numbersHidden = MessageNotes.makePresentation(
        source.splittingVerses(), theme: theme, showVerseNumbers: false)

    #expect(box(presentation, 1, "Verse")?.text == "15 For God so loved the world.")
    #expect(box(presentation, 1, "Reference")?.text == "")
    #expect(box(presentation, 2, "Verse")?.text == "16 Whoever believes in him.")
    #expect(box(presentation, 2, "Reference")?.text == "John 3:15-16")
    #expect(box(numbersHidden, 1, "Verse")?.text == "For God so loved the world.")
    #expect(box(numbersHidden, 2, "Verse")?.text == "Whoever believes in him.")
    #expect(box(numbersHidden, 1, "Reference")?.text.isEmpty ?? true)
    #expect(box(numbersHidden, 2, "Reference")?.text == "John 3:15-16")
}

@Test func aHeadedOutlineWithReferencesAboveNumberedVersesReadsTheSame() {
    let text = """
    No Longer | “Doormats and Derrieres” | Galatians 4:8-20


    We don’t just fight WITH each other, but we also fight FOR each other.

    Our Motive Must Be Love

    Galatians 4:19-20
    19 my little children, for whom I am again in the anguish of childbirth until Christ is formed in you! 20 I wish I could be present with you now and change my tone, for I am perplexed about you.

    To tell the truth but be unloving is harsh.
    To love but not tell the truth is enabling.

    Proverbs 27:6
    [6] Faithful are the wounds of a friend; profuse are the kisses of an enemy.
    """
    let hints: [String: MessageNotes.Hint] = [
        "Our Motive Must Be Love": .init(bold: true),
        "We don’t just fight WITH each other, but we also fight FOR each other.": .init(bold: false),
    ]
    let parsed = MessageNotes.parse(text, hints: hints).splittingVerses()
    #expect(parsed.title == "Doormats and Derrieres")
    #expect(parsed.blocks[0].detail == "No Longer · Galatians 4:8-20")
    #expect(parsed.blocks.map(\.kind) == [.title, .point, .point, .scripture, .scripture, .point, .scripture])
    #expect(parsed.blocks[3].detail == "19")
    #expect(parsed.blocks[3].text.hasPrefix("my little children"))
    #expect(parsed.blocks[4].detail == "20")
    #expect(parsed.blocks[4].passageReference == "Galatians 4:19-20")
    #expect(parsed.blocks[4].text.hasPrefix("I wish I could"))
    #expect(parsed.blocks[5].text == "To tell the truth but be unloving is harsh.\nTo love but not tell the truth is enabling.")
    #expect(parsed.blocks[6].text == "Faithful are the wounds of a friend; profuse are the kisses of an enemy.")
}

@Test func labelledAndNumberedOutlinesRead() {
    let text = """
    Series: No Longer
    Title: Doormats
    Text: Galatians 4:8-20

    Big Idea: Love tells the truth

    1. Our motive must be love
    (John 3:16) For God so loved the world
    Illustration: the camping trip
    Point 2 – Our message must be the truth
    Quote: “Truth without love is harsh.” – Tim Keller
    """
    let parsed = MessageNotes.parse(text)
    #expect(parsed.title == "Doormats")
    #expect(parsed.blocks.map(\.kind) == [.skip, .title, .point, .point, .scripture, .skip, .point, .quote])
    #expect(parsed.blocks[1].detail == "Galatians 4:8-20")
    #expect(parsed.blocks[2].text == "Love tells the truth")
    #expect(parsed.blocks[2].detail == "Big Idea")
    #expect(parsed.blocks[3].text == "1. Our motive must be love")
    #expect(parsed.blocks[4].detail == "John 3:16")
    #expect(parsed.blocks[6].detail == "Point 2")
    #expect(parsed.blocks[7].detail == "Tim Keller")
    let theme = StarterPack.cleanGeometric.makeTheme()
    let slide = MessageNotes.slide(
        for: parsed.blocks[2], design: MessageNotes.design(for: .point, in: theme, style: nil), newID: { UUID().uuidString })
    #expect(slide.objects.map(\.text) == ["Big Idea", "Love tells the truth"])
}

@Test func aRunSheetHeaderCuesAndAPassageOverSeveralParagraphsRead() {
    let text = """
    Lifepoint Lewis Center 9-27-26   No Longer     Galatians 3:15-29    The unexpected conflict

    Welcome guests & those listening online ~ Child dedication on Oct 4th

    Picture of Rocky & Mick

    The Series: “No Longer"
    Big idea: The Gospel is marked by love more than law

       We need to understand the purpose of the law

    Galatians 3:19-22 – 19 Why then the law? It was added because of transgressions.[a] 20 Now an intermediary implies more than one, but God is one.
    21 Is the law then contrary to the promises of God? Certainly not! 22 But the Scripture imprisoned everything under sin.

    Next Steps / Next 30 Days ~ Giving slide ~ Offering Moment (Chad will handle the closing)
    """
    let hints: [String: MessageNotes.Hint] = [
        "Galatians 3:19-22 – 19 Why then the law? It was added because of transgressions.[a] 20 Now an intermediary implies more than one, but God is one.":
            .init(bold: false, underlined: ["Galatians 3:19-22 –", "a"]),
    ]
    let parsed = MessageNotes.parse(text, hints: hints).splittingVerses()
    #expect(parsed.title == "The unexpected conflict")
    #expect(parsed.blocks[0].detail == "No Longer · Galatians 3:15-29")
    #expect(parsed.blocks.map(\.kind) == [
        .title, .skip, .skip, .skip, .point, .point, .scripture, .scripture, .scripture, .scripture, .skip,
    ])
    #expect(parsed.blocks[4].detail == "Big idea")
    #expect(parsed.blocks[6...9].map(\.detail) == ["19", "20", "21", "22"])
    #expect(parsed.blocks[9].passageReference == "Galatians 3:19-22")
    #expect(parsed.blocks[6].text == "Why then the law? It was added because of transgressions.")
    #expect(parsed.blocks[8].text == "Is the law then contrary to the promises of God? Certainly not!")
    #expect(parsed.blocks[6].underlined.isEmpty)
}
