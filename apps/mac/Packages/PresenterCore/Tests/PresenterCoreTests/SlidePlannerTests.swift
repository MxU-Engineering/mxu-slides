import Foundation
import Testing
@testable import PresenterCore

private func box(_ name: String, w: Double, h: Double, size: Double? = nil) -> SlideObject {
    var object = SlideObject(id: UUID().uuidString, objectKind: .text, name: name, text: "")
    object.x = 0; object.y = 0; object.width = w; object.height = h
    if let size { object.textStyle = TextStyle(fontSize: size) }
    return object
}

private let theme = Theme(
    id: "t", name: "Sermon", fontFamily: "Helvetica", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000",
    slides: [
        Slide(id: "d1", name: "Points", objects: [box("Points", w: 1600, h: 600)]),
        Slide(id: "d2", name: "Scripture", objects: [box("Verse", w: 1600, h: 500, size: 60), box("Reference", w: 800, h: 80)]),
        Slide(id: "d3", name: "Big Quote", objects: [box("Left", w: 900, h: 700), box("Right", w: 400, h: 100)]),
        Slide(id: "d4", name: "Section Title", objects: [box("Title", w: 1800, h: 300)]),
        Slide(id: "d5", name: "Lyrics", objects: [box("Lyrics", w: 1600, h: 400)]),
    ])

private let planner = DeterministicSlidePlanner()

private func plan(_ groups: [MarkedGroup], theme: Theme? = theme, overrides: [String: SlideRowOverride] = [:]) -> [SlideRow] {
    planner.plan(groups, theme: theme, overrides: overrides).rows
}

@Test func scriptureGoesToTheVerseAndReferenceBoxesByName() {
    let rows = plan([MarkedGroup(id: "a", text: "For God so loved the world\nJohn 3:16")])
    #expect(rows[0].kind == .scripture && rows[0].themeSlideName == "Scripture")
    #expect(rows[0].parts == [[SlideBox(name: "Verse", text: "For God so loved the world"), SlideBox(name: "Reference", text: "John 3:16")]])
}

@Test func unnamedBoxesFillBySizeAndOneBoxStacksTheReference() {
    let sized = plan([MarkedGroup(id: "a", type: "scripture", text: "The Lord is my shepherd (Psalm 23:1)")],
                     overrides: ["a": SlideRowOverride(themeSlideName: "Big Quote")])
    #expect(sized[0].parts == [[SlideBox(name: "Left", text: "The Lord is my shepherd"), SlideBox(name: "Right", text: "Psalm 23:1")]])

    let one = plan([MarkedGroup(id: "b", text: "The Lord is my shepherd (Psalm 23:1)")],
                   overrides: ["b": SlideRowOverride(themeSlideName: "Points")])
    #expect(one[0].parts == [[SlideBox(name: "Points", text: "The Lord is my shepherd\nPsalm 23:1")]])
}

@Test func kindsFollowTheLadder() {
    let rows = plan([
        MarkedGroup(id: "typed", type: "quote", shape: .list, text: "Be the change\n- Gandhi"),
        MarkedGroup(id: "label", text: "Points: Love\nJoy\nPeace"),
        MarkedGroup(id: "design", text: "Section Title: The Big Idea"),
        MarkedGroup(id: "lyrics", text: "Verse 1\nAmazing grace\nChorus\nMy chains are gone"),
        MarkedGroup(id: "heading", shape: .heading, text: "Point One"),
        MarkedGroup(id: "list", shape: .list, text: "First\nSecond"),
        MarkedGroup(id: "body", text: "Just a paragraph of notes."),
    ])
    #expect(rows.map(\.kind) == [.quote, .points, .title, .lyrics, .title, .points, .body])
    #expect(rows[0].parts == [[SlideBox(name: "Left", text: "Be the change"), SlideBox(name: "Right", text: "Gandhi")]])
    #expect(rows[1].parts == [[SlideBox(name: "Points", text: "Love\nJoy\nPeace")]])
    #expect(rows[2].themeSlideName == "Section Title" && rows[2].parts == [[SlideBox(name: "Title", text: "The Big Idea")]])
    #expect(rows[3].lyrics?.sections.map(\.name) == ["Verse 1", "Chorus"] && rows[3].parts.isEmpty)
    #expect(rows[4].themeSlideName == "Section Title")

    #expect(rows[6].themeSlideName == nil && rows[6].parts == [[SlideBox(name: "Points", text: "Just a paragraph of notes.")]])
}

@Test func namedLinesAndOverridesWin() {
    let rows = plan([MarkedGroup(id: "a", type: "scripture", text: "Reference: Romans 8:28\nVerse: All things work together")],
                    overrides: ["a": SlideRowOverride(kind: .scripture, themeSlideName: "Scripture", linesPerSlide: 1)])
    #expect(rows[0].parts == [[SlideBox(name: "Verse", text: "All things work together"), SlideBox(name: "Reference", text: "Romans 8:28")]])
    #expect(rows[0].linesPerSlide == 1)
}

@Test func longTextSplitsAtTheMeasuredFitAndRepeatsTheReference() {
    let fit = NoteSlideBuilder.fit(of: theme.slides![1].objects[0], theme: theme)
    #expect(fit == NoteSlideBuilder.Fit(lines: 6, charsPerLine: 53))
    let verse = (1 ... 8).map { "Line \($0)" }.joined(separator: "\n")
    let rows = plan([MarkedGroup(id: "a", text: verse + "\nJohn 1:1-8")])
    #expect(rows[0].parts.count == 2)
    #expect(rows[0].parts[0][0].text == (1 ... 6).map { "Line \($0)" }.joined(separator: "\n"))
    #expect(rows[0].parts[1] == [SlideBox(name: "Verse", text: "Line 7\nLine 8"), SlideBox(name: "Reference", text: "John 1:1-8")])

    let wrapped = plan([MarkedGroup(id: "b", text: String(repeating: "word ", count: 40))],
                       overrides: ["b": SlideRowOverride(themeSlideName: "Scripture", linesPerSlide: 2)])
    #expect(wrapped[0].parts.count == 1 && wrapped[0].kind == .body)
    let two = DeterministicSlidePlanner.chunk(["short", String(repeating: "x", count: 100), "tail"], linesPerSlide: 2, charsPerLine: 50)
    #expect(two == ["short", String(repeating: "x", count: 100), "tail"])

    let pasted = "10 You, however, know all about my teaching, my way of life, my purpose, faith, patience, love, endurance, 11 persecutions, sufferings. 12 In fact, everyone who wants to live a godly life will be persecuted, 13 while evildoers go from bad to worse.\n2 Timothy 3:10-13"
    let passage = plan([MarkedGroup(id: "d", text: pasted)], overrides: ["d": SlideRowOverride(linesPerSlide: 2)])
    #expect(passage[0].kind == .scripture && passage[0].parts.count >= 2)
    #expect(passage[0].parts[0][0].text.hasPrefix("10 You, however") && passage[0].parts.last?[0].text.hasSuffix("bad to worse.") == true)
    #expect(passage[0].parts.allSatisfy { $0.contains(SlideBox(name: "Reference", text: "2 Timothy 3:10-13")) })
    #expect(DeterministicSlidePlanner.pieces(of: "One. Two 3 Three") == ["One.", "Two", "3 Three"])

    let title = plan([MarkedGroup(id: "c", shape: .heading, text: "One\nTwo\nThree")], overrides: ["c": SlideRowOverride(linesPerSlide: 1)])
    #expect(title[0].parts.count == 1)
}

@Test func noThemeStillBuildsPlainSlides() {
    let rows = plan([MarkedGroup(id: "a", text: "Grace upon grace (John 1:16)")], theme: nil)
    #expect(rows[0].kind == .scripture && rows[0].themeSlideName == nil)
    #expect(rows[0].parts == [[SlideBox(name: "Text", text: "Grace upon grace\nJohn 1:16")]])

    #expect(NoteSlideBuilder.fit(of: nil, theme: nil) == NoteSlideBuilder.Fit(lines: 7, charsPerLine: 32))
}

@Test func theBuilderMakesThemeInheritingSlidesAndLyricsSections() {
    let rows = plan([
        MarkedGroup(id: "s", text: "For God so loved the world\nJohn 3:16"),
        MarkedGroup(id: "l", text: "Verse 1\nAmazing grace\nChorus\nMy chains\nVerse 1"),
    ])
    let built = NoteSlideBuilder.build(SlidePlan(rows: rows))
    #expect(built.slides.count == 3)
    let scripture = built.slides[0]
    #expect(scripture.themeSlideName == "Scripture" && scripture.objects.map(\.name) == ["Verse", "Reference"])
    #expect(scripture.objects.allSatisfy { $0.textStyle == nil && $0.x == nil && $0.width == nil })
    #expect(built.groupBySlideId[scripture.id] == "s")
    #expect(built.sections.map(\.name) == ["Verse 1", "Chorus"])
    #expect(built.slides[1].themeSlideName == "Lyrics" && built.slides[1].sectionId == built.sections[0].id)
    #expect(built.arrangement?.sectionIds.count == 3, "Verse 1 repeats")
    #expect(built.groupBySlideId[built.slides[2].id] == "l")
}

private let emailTheme = Theme(
    id: "e", name: "Message", fontFamily: "Helvetica", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000",
    slides: [
        Slide(id: "e1", name: "Points", objects: [box("Title", w: 1800, h: 160), box("Points", w: 1600, h: 600, size: 60)]),
        Slide(id: "e2", name: "Scripture", objects: [box("Verse", w: 1600, h: 500, size: 60), box("Reference", w: 800, h: 80)]),
        Slide(id: "e3", name: "Body", objects: [box("Text", w: 1600, h: 700, size: 60)]),
    ])

@Test func numberedLinesArePointsAndAShortFirstLineIsTheTitle() {
    let rows = plan([MarkedGroup(id: "a", text: "Four Voices Influencing Your Life\n1. Mockers : Reject God\n2. Neutrals : Replace God")], theme: emailTheme)
    #expect(rows[0].kind == .points && rows[0].themeSlideName == "Points")
    #expect(rows[0].parts == [[SlideBox(name: "Title", text: "Four Voices Influencing Your Life"), SlideBox(name: "Points", text: "1. Mockers : Reject God\n2. Neutrals : Replace God")]])

    let bullets = plan([MarkedGroup(id: "b", text: "Remember\n- Pray\n- Read\n• Give")])
    #expect(bullets[0].kind == .points && bullets[0].parts == [[SlideBox(name: "Points", text: "Remember\n- Pray\n- Read\n• Give")]])

    let spaced = plan([MarkedGroup(id: "c", text: "1. Many voices\n\n2. Not a given\n\n3. What you believe")], theme: emailTheme)
    #expect(spaced[0].parts.count == 1 && spaced[0].parts[0] == [SlideBox(name: "Points", text: "1. Many voices\n2. Not a given\n3. What you believe")])
    #expect(DeterministicSlidePlanner.isPointLine("10) Ten") && !DeterministicSlidePlanner.isPointLine("2024 was a year") && !DeterministicSlidePlanner.isPointLine("-no space"))
}

@Test func stanzasAndColonHeadingsShapeTheSplitAndTheTitleRepeats() {
    let stats = """
    Transformation in people who read the Bible 4x a week:

    Unwanted habits dropped:
    Excessive drinking: 62%
    Gambling: 45%
    Overeating: 20%

    Emotional health improved:
    Bitterness: 40%
    Anxiety and fear: 14%

    Spiritual practices increased:
    Giving to the church: 416%
    Sharing faith: 228%
    """

    let rows = plan([MarkedGroup(id: "a", text: stats)], theme: emailTheme)
    #expect(rows[0].kind == .body && rows[0].linesPerSlide == 9)
    let texts = rows[0].parts.map { $0[0].text }
    #expect(texts.count == 2)
    #expect(texts[0].hasPrefix("Transformation in people who read the Bible 4x a week:\nUnwanted habits dropped:") && texts[0].hasSuffix("Anxiety and fear: 14%"))
    #expect(texts[1] == "Spiritual practices increased:\nGiving to the church: 416%\nSharing faith: 228%")

    let two = DeterministicSlidePlanner.chunk(stanzas: [["a", "b"], ["c", "d"]], linesPerSlide: 3, charsPerLine: 50)
    #expect(two == ["a\nb", "c\nd"])
}

@Test func instructionsAndLinksStayOffTheScreen() {
    let rows = plan([
        MarkedGroup(id: "a", text: "2 Timothy 3:1-5 (bold “having a form of godliness, but denying its power”)"),
        MarkedGroup(id: "b", text: "https://youtu.be/-BWqzQU0JL4?si=1Ebg0sRPzZfDeIcT"),
        MarkedGroup(id: "c", text: "Psalm 1:1-6"),
    ], theme: emailTheme)
    #expect(rows[0].kind == .scripture)
    #expect(rows[0].parts == [[SlideBox(name: "Reference", text: "2 Timothy 3:1-5")]])
    #expect(rows[0].notes == "bold “having a form of godliness, but denying its power”")
    #expect(rows[1].kind == .media && rows[1].parts.isEmpty && rows[1].notes?.hasPrefix("https://youtu.be/") == true)
    #expect(rows[1].warning?.hasPrefix("Needs media") == true)
    #expect(rows[2].kind == .scripture && rows[2].parts == [[SlideBox(name: "Reference", text: "Psalm 1:1-6")]] && rows[2].notes == nil)
    let built = NoteSlideBuilder.build(SlidePlan(rows: rows))
    #expect(built.slides[0].notes == rows[0].notes && built.slides[1].objects.isEmpty && built.slides[1].notes == rows[1].notes)
}

@Test func thePastorsEmailMakesHisSlides() {
    let email = """
    Hey Everyone, this is the most up to date slide list for Sunday.

    [slide]
    What is the passage of scripture that has had the biggest impact on their life and why?

    [slide]
    Psalm 1:1-6

    [slide]
    1. There are many voices who’s words can impact your life.

    2. It’s not a given that you will choose God’s word above all other words.

    [slide]
    The Bible is God’s inspired word given to lead us to Jesus.

    [slide]
    https://youtu.be/-BWqzQU0JL4

    [slide]
    Four Voices Influencing Your Life
    1. Mockers : Reject God
    2. Neutrals : Replace God

    [slide]
    2 Timothy 3:1-5 (bold “having a form of godliness”)
    """
    let blocks = email.components(separatedBy: "\n").map { line in
        NoteBlock(type: .paragraph, runs: [NoteRun(text: line)])
    }
    let marked = NoteSlideMarks.markingByStructure(NoteBody(blocks: blocks, plainText: email))
    let rows = plan(NoteSlideBuilder.groups(in: marked), theme: emailTheme)
    #expect(rows.map(\.kind) == [.body, .scripture, .points, .body, .media, .points, .scripture])
    #expect(rows[2].parts.count == 1, "two numbered paragraphs, one slide")
    #expect(rows[5].parts[0].first?.text == "Four Voices Influencing Your Life")
    #expect(rows[6].notes == "bold “having a form of godliness”")
    #expect(NoteSlideBuilder.build(SlidePlan(rows: rows)).slides.count == 7)
}

private let messageSeries = Theme(
    id: "ms", name: "Message Series", fontFamily: "Gotham-Book", fontSize: 50, textColorHex: "#000", backgroundColorHex: "#fff",
    slides: [
        Slide(id: "m1", name: "Note", objects: [box("Default", w: 1575, h: 810, size: 55)]),
        Slide(id: "m2", name: "Point", objects: [box("Number", w: 751, h: 118, size: 53), box("Point", w: 1575, h: 554, size: 55)]),
        Slide(id: "m3", name: "List", objects: [box("Default", w: 1575, h: 810, size: 50)]),
        Slide(id: "m4", name: "Scripture", objects: [box("Reference", w: 714, h: 118, size: 53), box("Verse", w: 1575, h: 554, size: 50)]),
    ])

@Test func theMessageSeriesThemePicksListForManyPointsAndNumberPlusPointForOne() {
    let rows = plan([
        MarkedGroup(id: "many", text: "1. There are many voices.\n2. It’s not a given.\n3. What you believe matters."),
        MarkedGroup(id: "one", text: "Four Voices Influencing Your Life\n1. Mockers : Reject God"),
        MarkedGroup(id: "body", text: "The Bible is God’s inspired word."),
        MarkedGroup(id: "ref", text: "Psalm 1:1-6"),
    ], theme: messageSeries)
    #expect(rows[0].kind == .points && rows[0].themeSlideName == "List")
    #expect(rows[0].parts.count == 1 && rows[0].parts[0] == [SlideBox(name: "Default", text: "1. There are many voices.\n2. It’s not a given.\n3. What you believe matters.")])

    #expect(rows[1].themeSlideName == "Point")
    #expect(rows[1].parts == [[SlideBox(name: "Number", text: "1."), SlideBox(name: "Point", text: "Four Voices Influencing Your Life\nMockers : Reject God")]])
    #expect(rows[2].themeSlideName == "Note" && rows[2].parts == [[SlideBox(name: "Default", text: "The Bible is God’s inspired word.")]])
    #expect(rows[3].themeSlideName == "Scripture" && rows[3].parts == [[SlideBox(name: "Reference", text: "Psalm 1:1-6")]])
    #expect(DeterministicSlidePlanner.splitPointNumber("2) Second").number == "2)" && DeterministicSlidePlanner.splitPointNumber("- Dash").number == nil)
}

@Test func aPartTheBoxCantHoldAtItsRealFontSplitsAgain() {
    let narrow = Theme(
        id: "n", name: "Narrow", fontFamily: "Helvetica", fontSize: 96, textColorHex: "#fff", backgroundColorHex: "#000",
        slides: [Slide(id: "d", name: "Body", objects: [box("Text", w: 800, h: 300)])])
    let text = "WWWWWWWWWWWWWWW\nMMMMMMMMMMMMMMM"
    #expect(NoteSlideBuilder.fit(of: narrow.slides?[0].objects[0], theme: narrow) == NoteSlideBuilder.Fit(lines: 2, charsPerLine: 16))
    #expect(!NoteSlideBuilder.fits(text, in: narrow.slides?[0].objects[0], theme: narrow))
    #expect(NoteSlideBuilder.fits("WWWWWWWWWWWWWWW", in: narrow.slides?[0].objects[0], theme: narrow))
    #expect(plan([MarkedGroup(id: "a", text: text)], theme: narrow)[0].parts.map { $0[0].text } == ["WWWWWWWWWWWWWWW", "MMMMMMMMMMMMMMM"])
    #expect(plan([MarkedGroup(id: "a", text: text)], theme: narrow, overrides: ["a": SlideRowOverride(linesPerSlide: 2)])[0].parts.count == 1)

    let wide = Theme(
        id: "w", name: "Wide", fontFamily: "Helvetica", fontSize: 96, textColorHex: "#fff", backgroundColorHex: "#000",
        slides: [Slide(id: "d", name: "Body", objects: [box("Text", w: 1600, h: 300)])])
    let thin = String(repeating: "i", count: 40) + "\n" + String(repeating: "l", count: 40)
    #expect(DeterministicSlidePlanner.chunk(thin.components(separatedBy: "\n"), linesPerSlide: 2, charsPerLine: 33).count == 2)
    #expect(plan([MarkedGroup(id: "t", text: thin)], theme: wide)[0].parts.map { $0[0].text } == [thin])

    let rules = "Backyard Ultra - Rules:\nComplete 4.167 miles, every hour, on the hour.\nWarnings given 3, 2, and 1 minute prior to each loop. All competitors must be in the starting corral before the starting whistle.\nYou win by being the last person standing and must complete an additional loop in order to win outright."
    let parts = plan([MarkedGroup(id: "r", type: "points", text: rules)], theme: nil)[0].parts
    #expect(parts.count >= 2 && parts.allSatisfy { NoteSlideBuilder.fits($0[0].text, in: nil, theme: nil) })
}

@Test func aLinkedVideoFileNameIsAVideoPlaceholderHoweverItWasMarked() {
    let link = "https://drive.google.com/file/d/1/view"
    let row = plan([MarkedGroup(id: "v", text: "Snoop.mp4", links: [link])], theme: nil)[0]
    #expect(row.kind == .video && row.notes == link && row.warning != nil && row.parts.isEmpty)
    #expect(plan([MarkedGroup(id: "w", text: "Snoop.mp4")], theme: nil)[0].kind == .body)
}

@Test func aColonLineOverAListIsThePointsHeading() {
    let warnings = MarkedGroup(id: "w", type: "points", text: "Three Warnings:\nDon’t forget Me\nDon’t test God")
    let list = plan([warnings], theme: messageSeries)[0]
    #expect(list.themeSlideName == "List" && list.parts == [[SlideBox(name: "Default", text: "Three Warnings\nDon’t forget Me\nDon’t test God")]])
    let point = plan([warnings], theme: messageSeries, overrides: ["w": SlideRowOverride(themeSlideName: "Point")])[0]
    #expect(point.parts == [
        [SlideBox(name: "Number", text: "1."), SlideBox(name: "Point", text: "Three Warnings\nDon’t forget Me")],
        [SlideBox(name: "Number", text: "2."), SlideBox(name: "Point", text: "Three Warnings\nDon’t test God")],
    ])
}

@Test func plannerReadsGroupsFromANote() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .heading, level: 2, runs: [NoteRun(text: "Point one", slideGroup: "a")]),
        NoteBlock(type: .list, ordered: false, items: [NoteListItem(runs: [NoteRun(text: "First", slideGroup: "b", slideType: "points")])]),
    ], plainText: "")
    let groups = NoteSlideBuilder.groups(in: body)
    #expect(groups == [
        MarkedGroup(id: "a", type: nil, shape: .heading, text: "Point one"),
        MarkedGroup(id: "b", type: "points", shape: .list, text: "First"),
    ])
    #expect(NoteSlideBuilder.designName(for: .quote, in: theme) == "Big Quote")
    #expect(NoteSlideBuilder.designName(for: .body, in: theme) == nil)
}

@Test func blanksFollowTheirPassageAndCarryTheBlankSwitch() {
    let rows = plan([
        MarkedGroup(id: "s", text: "For God so loved the world, that he gave his only begotten Son, that whosoever believeth in him should not perish, but have everlasting life. For God sent not his Son into the world to condemn the world; but that the world through him might be saved. He that believeth on him is not condemned: but he that believeth not is condemned already, because he hath not believed in the name of the only begotten Son of God.\nJohn 3:16-18"),
        MarkedGroup(id: "p", text: "Points\n1. One\n2. Two"),
        MarkedGroup(id: "q", text: "A short quote"),
    ])
    let scriptureParts = rows[0].parts.count
    #expect(scriptureParts > 1, "the passage splits")
    let built = NoteSlideBuilder.build(
        SlidePlan(rows: rows), blanks: ["s": .afterPassage, "p": .afterSlide],
        blank: NoteSlideBuilder.BlankStyle(themeId: "logo-theme", themeSlideName: "Logo", actions: [SlidePresetChoice.preset("full").action()]))
    let isBlank = built.slides.map { built.blankFollows[$0.id] != nil }

    #expect(isBlank == Array(repeating: false, count: scriptureParts) + [true, false, true, false])
    let blank = built.slides[scriptureParts]
    #expect(blank.objects.isEmpty && blank.actions?.first?.presetId == "full" && built.groupBySlideId[blank.id] == nil)
    #expect(blank.themeSlideName == "Logo" && blank.themeId == "logo-theme", "a blank can wear a design")
    let logoTheme = Theme(id: "l", name: "Series", fontFamily: "Helvetica", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000",
                          slides: [Slide(id: "x", name: "Scripture", objects: []), Slide(id: "y", name: "Logo", objects: [])])
    #expect(NoteSlideBuilder.designName(for: .blank, in: logoTheme) == "Logo", "matched by name")
    #expect(built.group(of: blank.id) == "s" && built.blankFollows.count == 2)
    #expect(NoteSlideBuilder.build(SlidePlan(rows: rows)).blankFollows.isEmpty, "no blanks unless asked")
}

@Test func madeSlidesTakeTheirTypesSwitchTheRowOverridingIt() {
    let rows = plan([
        MarkedGroup(id: "s", text: "For God so loved the world\nJohn 3:16"),
        MarkedGroup(id: "p", text: "Points\n1. One\n2. Two"),
        MarkedGroup(id: "q", text: "A short quote"),
        MarkedGroup(id: "b", text: "Plain body text here"),
    ])
    var settings = SlideDesignMap()
    settings.setPreset(.preset("side"), for: .scripture)
    settings.otherPreset = .combo("full")
    var built = NoteSlideBuilder.build(SlidePlan(rows: rows), blanks: ["s": .afterPassage], blank: NoteSlideBuilder.BlankStyle())
    NoteSlideBuilder.attachingSwitches(
        to: &built, rows: rows, settings: settings,
        overrides: ["q": .none, "b": .chosen(.preset("lower"))])
    func switches(_ group: String) -> [String] {
        built.slides.filter { built.groupBySlideId[$0.id] == group }.flatMap { ($0.actions ?? []).map { $0.presetId ?? $0.comboId ?? "" } }
    }
    #expect(switches("s") == ["side"], "the type's own")
    #expect(switches("p") == ["full"], "all other slides, through a combo")
    #expect(switches("q").isEmpty, "the row said none")
    #expect(switches("b") == ["lower"], "the row's own")
    let blank = built.slides.first { built.blankFollows[$0.id] != nil }!
    #expect(blank.actions == nil, "blanks take the blank switch only")
    #expect(NoteSlideBuilder.presetChoice(for: .points, override: .typeDefault, settings: settings) == .combo("full"))
}

@Test func lookDesignsMatchTheKindInEachLookAndPicksWin() {
    let side = StarterPack.digital.makeTheme().scoped(toSlideFolder: "Side Thirds")
    let lower = StarterPack.cleanGeometric.makeTheme().scoped(toSlideFolder: "Lower Thirds")
    #expect(NoteSlideBuilder.lookDesigns(for: .scripture, looks: [side, lower], chosen: [:])
        == [side.id: "Verse + Reference (Side Third)", lower.id: "Verse + Reference (Lower Third)"])
    #expect(NoteSlideBuilder.lookDesigns(for: .points, looks: [side], chosen: [:]) == [side.id: "Point (Side Third)"])
    #expect(NoteSlideBuilder.lookDesigns(for: .body, looks: [side], chosen: [:]) == [:], "no Body design: the look's first")
    #expect(NoteSlideBuilder.lookDesigns(for: .scripture, looks: [side], chosen: [side.id: "Point (Side Third)"])
        == [side.id: "Point (Side Third)"])
}

private func options(_ change: (inout SlideOptions) -> Void) -> SlideOptions {
    var options = SlideOptions()
    change(&options)
    return options
}

@Test func revealOnePerClickGivesEachPointItsOwnFadeIn() {
    let group = MarkedGroup(id: "a", text: "Remember\n- Pray\n- Read")
    let off = DeterministicSlidePlanner().plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(off.parts[0][0].revealLines == nil)
    let on = DeterministicSlidePlanner(options: options { $0.revealPoints = true }).plan([group], theme: theme, overrides: [:]).rows[0]

    #expect(on.parts[0][0].revealLines == [1, 2])
    let object = NoteSlideBuilder.build(SlidePlan(rows: [on])).slides[0].objects[0]
    let steps = try! #require(object.animationSteps)
    #expect(steps.map(\.trigger) == [.onClick, .onClick] && steps.allSatisfy { $0.kind == .in && $0.animation == .fade })
    #expect(steps.map { $0.ranges ?? [] } == [[AnimationRange(line: 1, column: 0, length: 6)], [AnimationRange(line: 2, column: 0, length: 6)]])

    let one = DeterministicSlidePlanner(options: options { $0.revealPoints = true })
        .plan([MarkedGroup(id: "b", type: "points", text: "Big idea: Grace wins.")], theme: theme, overrides: [:]).rows[0]
    #expect(one.parts[0][0].revealLines == nil)
}

@Test func aLabelledLineIsAPointUnderItsLabel() {
    let rows = DeterministicSlidePlanner().plan([
        MarkedGroup(id: "a", text: "Next step: Write it down."),
        MarkedGroup(id: "b", text: "Chorus: Holy, holy"),
    ], theme: emailTheme, overrides: [:]).rows
    #expect(rows[0].kind == .points)
    #expect(rows[0].parts == [[SlideBox(name: "Title", text: "Next step"), SlideBox(name: "Points", text: "Write it down.")]])
    #expect(rows[1].kind != .points)
    #expect(DeterministicSlidePlanner.labelledPoint("A very long label here: words") == nil)
    #expect(DeterministicSlidePlanner.labelledPoint("Next step: one\ntwo") == nil)
}

@Test func aQuoteWithItsNameOnTheSameLineSplitsAtTheDash() {
    let row = DeterministicSlidePlanner().plan(
        [MarkedGroup(id: "a", type: "quote", text: "“Faith is the first step.” — Martin Luther King Jr.")], theme: theme, overrides: [:]).rows[0]
    #expect(row.parts == [[SlideBox(name: "Left", text: "“Faith is the first step.”"), SlideBox(name: "Right", text: "Martin Luther King Jr.")]])
    #expect(DeterministicSlidePlanner.readsAsQuote("“Be still.”") && !DeterministicSlidePlanner.readsAsQuote("Be still."))
}

@Test func oneVersePerSlideCarriesEachVersesReferenceAndTheFullOneLast() {
    let group = MarkedGroup(id: "a", text: "Philippians 4:6–7 (ESV)\n6 Do not be anxious about anything. 7 And the peace of God will guard your hearts.")
    let split = DeterministicSlidePlanner(options: options { $0.scriptureSplit = .oneVerse }).plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(split.parts == [
        [SlideBox(name: "Verse", text: "6 Do not be anxious about anything."), SlideBox(name: "Reference", text: "Philippians 4:6")],
        [SlideBox(name: "Verse", text: "7 And the peace of God will guard your hearts."), SlideBox(name: "Reference", text: "Philippians 4:6–7 (ESV)")],
    ])
    let bare = DeterministicSlidePlanner(options: options { $0.scriptureSplit = .oneVerse; $0.verseNumbers = false })
        .plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(bare.parts.map { $0[0].text } == ["Do not be anxious about anything.", "And the peace of God will guard your hearts."])
    let fit = DeterministicSlidePlanner(options: options { $0.verseNumbers = false }).plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(fit.parts.map { $0[0].text } == ["Do not be anxious about anything. And the peace of God will guard your hearts."])

    let single = DeterministicSlidePlanner(options: options { $0.scriptureSplit = .oneVerse })
        .plan([MarkedGroup(id: "b", text: "Psalm 46:1 – God is our refuge")], theme: theme, overrides: [:]).rows[0]
    #expect(single.parts.count == 1)
}

@Test func blanksSkipTheVersesOfOnePassageUnlessAskedFor() {
    let rows = DeterministicSlidePlanner(options: options { $0.scriptureSplit = .oneVerse }).plan([
        MarkedGroup(id: "s", text: "John 1:1–2\n1 In the beginning was the Word. 2 The same was in the beginning with God."),
        MarkedGroup(id: "p", text: "1. One\n2. Two"),
    ], theme: theme, overrides: [:]).rows
    let blanks: [String: BlankPlacement] = ["s": .afterSlide, "p": .afterSlide]
    func shape(_ options: SlideOptions) -> [Bool] {
        let built = NoteSlideBuilder.build(SlidePlan(rows: rows), blanks: blanks, blank: .init(), options: options)
        return built.slides.map { built.blankFollows[$0.id] != nil }
    }
    #expect(shape(SlideOptions()) == [false, false, true, false, true])
    #expect(shape(options { $0.blanksBetweenVerses = true }) == [false, true, false, true, false, true])
}

@Test func theNotesUnderlinesStayOnTheSlideInOrder() {
    let group = MarkedGroup(
        id: "a", type: "points", text: "Everything that can be shaken will be shaken\nWhat God builds can’t be shaken",
        underlines: ["shaken", "can’t", "missing"])
    let row = DeterministicSlidePlanner().plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(row.parts[0][0].styleRuns == [
        TextStyleRun(line: 0, column: 23, length: 6, underline: true), TextStyleRun(line: 1, column: 16, length: 5, underline: true),
    ])
    #expect(NoteSlideBuilder.build(SlidePlan(rows: [row])).slides[0].objects[0].styleRuns == row.parts[0][0].styleRuns)
    let off = DeterministicSlidePlanner(options: options { $0.keepUnderlines = false }).plan([group], theme: theme, overrides: [:]).rows[0]
    #expect(off.parts[0][0].styleRuns == nil)
}

@Test func wordsInParenthesesGoToTheNotesUnlessTurnedOff() {
    let groups = [
        MarkedGroup(id: "a", text: "Grace is a gift (hold up the envelope), not a wage."),
        MarkedGroup(id: "b", text: "2 Timothy 3:1-5 (bold 'having a form')\nBut know this"),
    ]
    let on = DeterministicSlidePlanner().plan(groups, theme: theme, overrides: [:]).rows
    #expect(on[0].parts[0][0].text == "Grace is a gift, not a wage." && on[0].notes == "hold up the envelope")
    #expect(on[1].notes == "bold 'having a form'")

    let off = DeterministicSlidePlanner(options: options { $0.parenthesesToNotes = false }).plan(groups, theme: theme, overrides: [:]).rows
    #expect(off[0].parts[0][0].text == "Grace is a gift (hold up the envelope), not a wage." && off[0].notes == nil)
    #expect(off[1].notes == "bold 'having a form'")

    let lyrics = DeterministicSlidePlanner().plan(
        [MarkedGroup(id: "c", type: "lyrics", text: "Verse 1\nHoly (x2)\nChorus\nWorthy")], theme: theme, overrides: [:]).rows[0]
    #expect(lyrics.lyrics?.sections.flatMap(\.slides).contains { $0.contains("(x2)") } == true)
}

@Test func updateFromNoteMovesTheUnderlinesWithTheWordsAndPlansWithTheOptions() {
    let old = MarkedGroup(id: "a", type: "points", text: "Grace wins\nLove stays", underlines: ["wins"])
    let row = DeterministicSlidePlanner().plan([old], theme: theme, overrides: [:]).rows[0]
    let slides = NoteSlideBuilder.build(SlidePlan(rows: [row])).slides
    #expect(slides[0].objects[0].styleRuns == [TextStyleRun(line: 0, column: 6, length: 4, underline: true)])
    let edited = MarkedGroup(id: "a", type: "points", text: "Grace always wins\nLove stays", underlines: ["wins"])
    let reveal = options { $0.revealPoints = true }
    #expect(!NoteSlideUpdate.isBehind(old, slides: slides, theme: theme, options: reveal))
    let next = try! #require(NoteSlideUpdate.replan(edited, like: slides, theme: theme, options: reveal))
    #expect(next.parts[0][0].revealLines == [0, 1])
    let updated = NoteSlideUpdate.updating(slides, to: next).updated[0].objects[0]
    #expect(updated.text == "Grace always wins\nLove stays")
    #expect(updated.styleRuns == [TextStyleRun(line: 0, column: 13, length: 4, underline: true)])
}

@Test func aQuoteFillsTheQuoteBoxNotTheQuotationMark() {
    let theme = StarterPack.cleanGeometric.makeTheme()
    let group = MarkedGroup(id: "q", type: "quote",
                            text: "“Faith is taking the first step even when you don’t see the whole staircase.” — Martin Luther King Jr.")
    let row = DeterministicSlidePlanner().plan([group], theme: theme, overrides: [:]).rows[0]
    let boxes = row.parts[0]

    #expect(boxes.first { $0.name == "Quote" }?.text == "Faith is taking the first step even when you don’t see the whole staircase.")
    #expect(boxes.first { $0.name == "Source" }?.text == "Martin Luther King Jr.")

    #expect(boxes.first { $0.name == "Quote Mark" }?.text == "“")
    let slide = NoteSlideBuilder.build(SlidePlan(rows: [row])).slides[0]
    #expect(slide.objects.first { $0.name == "Quote Mark" }?.text == "“")
}

@Test func aTitlesSecondLineGoesInTheSmallerBox() {
    let theme = StarterPack.cleanGeometric.makeTheme()
    let group = MarkedGroup(id: "t", type: "title", shape: .heading, text: "Unshakable\nHebrews 12:25–29 · Kingdom Come, week 4")
    let boxes = DeterministicSlidePlanner().plan([group], theme: theme, overrides: [:]).rows[0].parts[0]
    #expect(boxes.first { $0.name == "Section Title" }?.text == "Unshakable")
    #expect(boxes.first { $0.name == "Kicker" }?.text == "Hebrews 12:25–29 · Kingdom Come, week 4")

    let one = DeterministicSlidePlanner().plan([MarkedGroup(id: "u", type: "title", text: "Unshakable")], theme: theme, overrides: [:]).rows[0].parts[0]
    #expect(one.map(\.name) == ["Section Title"])
}

@Test func aListIsSeveralPointsAndALabelTakesTheKicker() {
    let theme = StarterPack.cleanGeometric.makeTheme()
    let list = MarkedGroup(id: "p", type: "points", shape: .list,
                           text: "Everything that can be shaken will be shaken\nWhat God builds can’t be shaken\nSo we worship with reverence and awe")
    let row = DeterministicSlidePlanner().plan([list], theme: theme, overrides: [:]).rows[0]
    #expect(row.themeSlideName == "Points")
    #expect(row.parts.count == 1)

    let design = theme.slides?.first { $0.name == "Points" }
    #expect(design?.objects.first { $0.name == "Points" }?.textStyle?.paragraphSpacing == 28)
    let labelled = MarkedGroup(id: "n", type: "points", text: "Next step: Write down one thing you’re holding onto that can be shaken.")
    let boxes = DeterministicSlidePlanner().plan([labelled], theme: theme, overrides: [:]).rows[0].parts[0]
    #expect(boxes.first { $0.name == "Kicker" }?.text == "Next step")
    #expect(boxes.first { $0.name == "Point" }?.text == "Write down one thing you’re holding onto that can be shaken.")
}

@Test func anUpdateOntoAnotherDesignTakesItsBoxesAndOrderIsNotBehind() {
    let theme = StarterPack.cleanGeometric.makeTheme()
    let list = MarkedGroup(id: "p", type: "points", shape: .list,
                           text: "Everything that can be shaken will be shaken\nWhat God builds can’t be shaken\nSo we worship with reverence and awe")
    var old = NoteSlideBuilder.build(SlidePlan(rows: [DeterministicSlidePlanner().plan([list], theme: theme, overrides: [:]).rows[0]])).slides[0]
    old.themeSlideName = "Point"
    old.objects = old.objects.map { var o = $0; if o.objectKind == .text { o.name = "Point" }; return o }
    let row = DeterministicSlidePlanner().plan([list], theme: theme, overrides: [:]).rows[0]
    let updated = NoteSlideUpdate.updating([old], to: row).updated[0]
    #expect(updated.id == old.id)
    #expect(updated.themeSlideName == "Points")
    #expect(updated.objects.filter { $0.objectKind == .text }.map(\.name) == ["Points"])

    let quote = MarkedGroup(id: "q", type: "quote", text: "“Faith is taking the first step.” — Martin Luther King Jr.")
    var slides = NoteSlideBuilder.build(SlidePlan(rows: [DeterministicSlidePlanner().plan([quote], theme: theme, overrides: [:]).rows[0]])).slides
    slides[0].objects.append(slides[0].objects.removeFirst())
    #expect(!NoteSlideUpdate.isBehind(quote, slides: slides, theme: theme))
}

@Test func anOwnTypeTakesItsDesignSplitAndRevealAndKeysItsSwitch() {
    var withNotice = theme
    withNotice.slides?.append(Slide(id: "d6", name: "Notice", objects: [box("Text", w: 1600, h: 600)]))
    let opts = options { $0.ownTypes = [.init(name: "Notice", split: .paragraph), .init(name: "Ask", reveal: true)] }
    let rows = DeterministicSlidePlanner(options: opts).plan([
        MarkedGroup(id: "a", type: "Notice", text: "Notice: Camp signups close Friday\nBring a friend\n\nSee Pastor Dan"),
        MarkedGroup(id: "b", text: "ask: What are you rooted in?\nWhat holds?"),
        MarkedGroup(id: "c", type: "Notice", text: "Camp signups close Friday"),
    ], theme: withNotice, overrides: [:]).rows
    #expect(rows.map(\.kind) == [.body, .body, .body] && rows.map(\.ownType) == ["Notice", "Ask", "Notice"])
    #expect(rows[0].themeSlideName == "Notice", "a design named like the type")
    #expect(rows[0].parts.map { $0[0].text } == ["Camp signups close Friday\nBring a friend", "See Pastor Dan"], "one paragraph per slide, label gone")
    #expect(rows[1].parts == [[SlideBox(name: "Points", text: "What are you rooted in?\nWhat holds?", revealLines: [0, 1])]], "no design named Ask: the theme's first")
    #expect(rows[2].parts[0][0].text == "Camp signups close Friday" && rows[2].typeKey == "Notice")
    var settings = SlideDesignMap()
    settings.setPreset(.preset("lower"), forType: "Notice")
    settings.otherPreset = .preset("full")
    var built = NoteSlideBuilder.build(SlidePlan(rows: rows))
    NoteSlideBuilder.attachingSwitches(to: &built, rows: rows, settings: settings, overrides: [:])
    let switches = built.slides.map { ($0.actions ?? []).map { $0.presetId ?? "" } }
    #expect(switches == [["lower"], ["lower"], ["full"], ["lower"]], "the own type's switch, All other for the rest")

    let overridden = DeterministicSlidePlanner(options: opts).plan(
        [MarkedGroup(id: "a", type: "Notice", text: "Notice: Hi")], theme: withNotice, overrides: ["a": SlideRowOverride(kind: .quote)]).rows[0]
    #expect(overridden.kind == .quote && overridden.ownType == nil)
}

@Test func asideRangesAreWhatTheNotesTake() {
    let text = "Baptism recap (video below) (NIV)\nGrace (John 3:16) (\nThen (pause here)"
    #expect(DeterministicSlidePlanner.asideRanges(in: text).map { String(text[$0]) } == ["(video below)", "(pause here)"])
    #expect(NoteSlides.inlineMarkerLabelLength(in: "Slide 2: Baptism recap") == 9)
}
