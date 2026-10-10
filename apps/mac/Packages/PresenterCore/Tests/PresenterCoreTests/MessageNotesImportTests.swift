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
    #expect(box(presentation, 4, "Point")?.styleRuns == [TextStyleRun(line: 0, column: 13, length: 10, underline: true)])
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
    #expect(numbered.map(\.detail) == ["John 3:16 (NIV)", "John 3:17 (NIV)", "John 3:18 (NIV)"])
    #expect(numbered.map(\.text) == [
        "For God so loved the world.", "For God did not send his Son to condemn.",
        "Whoever believes in him is not condemned.",
    ])
    #expect(numbered.map(\.cues) == [["read slowly"], [], []])

    let unnumbered = split("Lu. 15:18-19 – I will arise and go to my father, and I will say to him, “Father, I have sinned against heaven and before you. I am no longer worthy to be called your son. Treat me as one of your hired servants.”")
    #expect(unnumbered.map(\.detail) == ["Lu. 15:18-19", "Lu. 15:18-19"])
    #expect(unnumbered.map(\.text) == [
        "I will arise and go to my father, and I will say to him, “Father, I have sinned against heaven and before you.",
        "I am no longer worthy to be called your son. Treat me as one of your hired servants.”",
    ])

    #expect(split("Gal. 4:4-5 – But when the set time had fully come, God sent his Son, that we might receive adoption.").count == 1)
    #expect(split("Gal. 4:1 – What I am saying is this. An heir is no different from a slave.").count == 1)
    #expect(split("Rom 8:28, 31 – We know that God works. If God is for us, who can be against us?").count == 1)
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
    #expect(parsed.blocks[3].detail == "Galatians 4:19")
    #expect(parsed.blocks[3].text.hasPrefix("my little children"))
    #expect(parsed.blocks[4].detail == "Galatians 4:20")
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
    #expect(parsed.blocks[6...9].map(\.detail) == ["Galatians 3:19", "Galatians 3:20", "Galatians 3:21", "Galatians 3:22"])
    #expect(parsed.blocks[6].text == "Why then the law? It was added because of transgressions.")
    #expect(parsed.blocks[8].text == "Is the law then contrary to the promises of God? Certainly not!")
    #expect(parsed.blocks[6].underlined.isEmpty)
}
