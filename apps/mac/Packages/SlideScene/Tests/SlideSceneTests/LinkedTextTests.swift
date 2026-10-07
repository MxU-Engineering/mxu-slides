import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let fixedDate = Date(timeIntervalSince1970: 1_784_800_000)

private func fixtureInfo(
    alert: CueAlert? = nil,
    alertVisible: Bool = true,
    timers: [TimerSnapshot] = []
) -> ConfidenceInfo {
    ConfidenceInfo(
        current: .init(body: "current line"),
        next: .init(body: "next line"),
        last: .init(body: "last line"),
        alert: alert,
        alertVisible: alertVisible,
        timers: timers,
        videoCountdown: VideoCountdown(
            name: "Bumper", duration: 120, position: 30,
            anchoredAt: fixedDate, isPlaying: false
        ),
        slidePosition: .init(index: 3, total: 12),
        currentItemName: "Amazing Grace",
        nextItemName: "Announcements",
        currentPresentationName: "Amazing Grace (Live in G)",
        nextServiceTitle: "Sunday Gathering"
    )
}

private func link(_ source: TextSourceKind) -> TextLink { TextLink(source: source) }

@Test func slideSourcesResolveCurrentNextLast() {
    let info = fixtureInfo()
    #expect(LinkedText.resolve(link(.currentSlide), info: info, at: fixedDate) == "current line")
    #expect(LinkedText.resolve(link(.nextSlide), info: info, at: fixedDate) == "next line")
    #expect(LinkedText.resolve(link(.lastSlide), info: info, at: fixedDate) == "last line")
}

@Test func namedPullReadsOneObjectOfTheSourceSlide() {

    var info = fixtureInfo()
    info.current = .init(body: "verse words\nJohn 3:16", objectTexts: [
        .init(name: "Verse", text: "verse words"),
        .init(name: "Reference", text: "John 3:16"),
    ])
    info.next = .init(body: "next words", objectTexts: [
        .init(name: "Verse", text: "next words"),
    ])
    var named = link(.currentSlide)
    named.sourceObjectName = "reference"
    #expect(LinkedText.resolve(named, info: info, at: fixedDate) == "John 3:16")
    named.sourceObjectName = "Chorus"
    #expect(LinkedText.resolve(named, info: info, at: fixedDate) == nil)
    var nextNamed = link(.nextSlide)
    nextNamed.sourceObjectName = "Verse"
    #expect(LinkedText.resolve(nextNamed, info: info, at: fixedDate) == "next words")
    #expect(LinkedText.resolve(link(.currentSlide), info: info, at: fixedDate) == "verse words\nJohn 3:16")

    info.nextStep = .init(body: "the coming step")
    nextNamed.includeSteps = true
    #expect(LinkedText.resolve(nextNamed, info: info, at: fixedDate) == "next words")
}

@Test func namedPullCarriesNoChords() {

    var info = fixtureInfo()
    info.current = .init(
        body: "verse words",
        chords: [ChordPlacement(line: 0, column: 0, symbol: "G")],
        objectTexts: [.init(name: "Verse", text: "verse words")]
    )
    var box = SlideObject(id: "b", objectKind: .text, name: "Pull", text: "")
    var named = link(.currentSlide)
    named.sourceObjectName = "Verse"
    box.textLink = named
    let resolved = LinkedText.resolvedObjects([box], info: info, at: fixedDate)[0]
    #expect(resolved.text == "verse words")
    #expect(resolved.chords == nil)
    box.textLink = link(.currentSlide)
    let whole = LinkedText.resolvedObjects([box], info: info, at: fixedDate)[0]
    #expect(whole.chords?.count == 1, "whole-slide reads keep their chords")
}

@Test func slideTextBuilderCarriesObjectTexts() {
    var verse = SlideObject(id: "v", objectKind: .text, name: "Verse", text: "verse words")
    verse.x = 0
    let reference = SlideObject(id: "r", objectKind: .text, name: "Reference", text: "John 3:16")
    let unnamed = SlideObject(id: "u", objectKind: .text, name: "", text: "orphan")
    let empty = SlideObject(id: "e", objectKind: .text, name: "Empty", text: "")
    let slide = Slide(id: "s", name: "V1", objects: [verse, reference, unnamed, empty])
    let text = ConfidenceSceneBuilder.slideText(for: slide, in: nil)
    #expect(text.objectTexts?.map(\.name) == ["Verse", "Reference"],
            "named, text-carrying objects only, document order")
}

@Test func emptySlideTextResolvesToNothing() {
    var info = fixtureInfo()
    info.last = .init(body: "")
    #expect(LinkedText.resolve(link(.lastSlide), info: info, at: fixedDate) == nil,
            "an empty body rides the empty-text gate, not an empty box")
}

@Test func serviceDataSourcesResolve() {
    let info = fixtureInfo()
    #expect(LinkedText.resolve(link(.slidePosition), info: info, at: fixedDate) == "3 of 12")
    #expect(LinkedText.resolve(link(.currentServiceItem), info: info, at: fixedDate) == "Amazing Grace")
    #expect(LinkedText.resolve(link(.nextServiceItem), info: info, at: fixedDate) == "Announcements")
    #expect(LinkedText.resolve(link(.nextServiceTitle), info: info, at: fixedDate) == "Sunday Gathering")
    #expect(LinkedText.resolve(link(.nextServiceTitle), info: ConfidenceInfo(), at: fixedDate) == nil)

    #expect(LinkedText.resolve(link(.currentPresentation), info: info, at: fixedDate)
        == "Amazing Grace (Live in G)")
}

@Test func videoCountdownResolvesFrozenRemaining() {

    let info = fixtureInfo()
    #expect(LinkedText.resolve(link(.videoCountdown), info: info, at: fixedDate) == "Bumper  1:30")
    #expect(
        LinkedText.resolve(link(.videoCountdown), info: info, at: fixedDate + 3600) == "Bumper  1:30"
    )
}

@Test func videoCountdownNamePrefixFollowsShowsVideoName() {

    let info = fixtureInfo()
    var bare = link(.videoCountdown)
    bare.showsVideoName = false
    #expect(LinkedText.resolve(bare, info: info, at: fixedDate) == "1:30")
    var named = link(.videoCountdown)
    named.showsVideoName = true
    #expect(LinkedText.resolve(named, info: info, at: fixedDate) == "Bumper  1:30")
}

@Test func videoCountdownReadsItsDeclaredLayer() {

    var info = fixtureInfo()
    info.videoCountdowns = [
        LayerKind.loopingVideos.rawValue: VideoCountdown(
            name: "Loop", duration: 240, position: 60,
            anchoredAt: fixedDate, isPlaying: false
        )
    ]
    var background = link(.videoCountdown)
    background.videoLayer = LayerKind.loopingVideos.rawValue
    background.showsVideoName = false
    #expect(LinkedText.resolve(background, info: info, at: fixedDate) == "3:00")
    #expect(
        LinkedText.resolve(link(.videoCountdown), info: info, at: fixedDate) == "Bumper  1:30",
        "absent videoLayer stays the foreground default"
    )
    var idle = link(.videoCountdown)
    idle.videoLayer = LayerKind.slide.rawValue
    #expect(LinkedText.resolve(idle, info: info, at: fixedDate) == nil)
}

@Test func clockUsesBoothDefaultWithoutAFormat() {
    let resolved = LinkedText.resolve(link(.clock), info: fixtureInfo(), at: fixedDate)
    #expect(resolved == ConfidenceSceneBuilder.clockString(fixedDate))
}

@Test func clockHonorsACustomFormat() {
    let custom = TextLink(source: .clock, clockFormat: "mm")
    let expected = Calendar.current.component(.minute, from: fixedDate)
    #expect(
        LinkedText.resolve(custom, info: fixtureInfo(), at: fixedDate)
            == String(format: "%02d", expected)
    )
}

@Test func timerPicksTheNamedTimer() {
    let sermon = TimerSnapshot(id: "sermon", name: "Sermon", mode: .countdown, banked: 60, durationSeconds: 300)
    let walkIn = TimerSnapshot(id: "walk-in", name: "Walk-in", mode: .countdown, banked: 30, durationSeconds: 600)
    let info = fixtureInfo(timers: [walkIn, sermon])
    let named = TextLink(source: .timer, timerId: "sermon")
    #expect(LinkedText.resolve(named, info: info, at: fixedDate) == "4:00")
}

@Test func timerHonorsTheLinkFormat() {
    let event = TimerSnapshot(id: "event", name: "Event", mode: .countdown, banked: 0, durationSeconds: 3 * 86400 + 30 * 60 + 12)
    let info = fixtureInfo(timers: [event])
    let abbreviated = TextLink(source: .timer, timerId: "event", timerFormat: .abbreviated)
    #expect(LinkedText.resolve(abbreviated, info: info, at: fixedDate) == "3d 0h 30m 12s")
    let words = TextLink(source: .timer, timerId: "event", timerFormat: .words)
    #expect(LinkedText.resolve(words, info: info, at: fixedDate) == "3 days 0 hours 30 minutes 12 seconds")
    #expect(LinkedText.resolve(TextLink(source: .timer, timerId: "event"), info: info, at: fixedDate) == "72:30:12",
            "absent = digits, so stored layouts keep their read")
    let video = TextLink(source: .videoCountdown, showsVideoName: false, timerFormat: .abbreviated)
    #expect(LinkedText.resolve(video, info: info, at: fixedDate) == "1m 30s")
}

@Test func timerPatternOutranksTheFormat() {
    let event = TimerSnapshot(id: "event", name: "Event", mode: .countdown, banked: 0, durationSeconds: 1046.42)
    let info = fixtureInfo(timers: [event])
    let pattern = TextLink(source: .timer, timerId: "event", timerFormat: .words, timerPattern: "m:ss.f")
    #expect(LinkedText.resolve(pattern, info: info, at: fixedDate) == "17:26.4")
    let empty = TextLink(source: .timer, timerId: "event", timerFormat: .abbreviated, timerPattern: "")
    #expect(LinkedText.resolve(empty, info: info, at: fixedDate) == "17m 26s", "empty = the format read")
    let video = TextLink(source: .videoCountdown, showsVideoName: false, timerPattern: "S")
    #expect(LinkedText.resolve(video, info: info, at: fixedDate) == "90")
}

@Test func subSecondTickFollowsTheFractionPattern() {
    #expect(LinkedText.ticksSubSecond(TextLink(source: .timer, timerPattern: "s.fff")))
    #expect(LinkedText.ticksSubSecond(TextLink(source: .videoCountdown, timerPattern: "ss.f")))
    #expect(!LinkedText.ticksSubSecond(TextLink(source: .timer, timerPattern: "m:ss")))
    #expect(!LinkedText.ticksSubSecond(TextLink(source: .timer, timerFormat: .words)))
    #expect(!LinkedText.ticksSubSecond(TextLink(source: .clock, timerPattern: "s.f")), "a clock never reads a timer pattern")
}

@Test func timerFallsBackToThePrimary() {

    let idle = TimerSnapshot(id: "idle", name: "Idle", mode: .countdown, banked: 0, durationSeconds: 600)
    let running = TimerSnapshot(
        id: "live", name: "Live", mode: .countdown, isRunning: true,
        runningSince: fixedDate, banked: 100, durationSeconds: 300
    )
    let info = fixtureInfo(timers: [idle, running])
    #expect(LinkedText.resolve(link(.timer), info: info, at: fixedDate) == "3:20")
}

@Test func deletedTimerRendersNothing() {
    let info = fixtureInfo(timers: [TimerSnapshot(id: "a", name: "A", mode: .countUp)])
    let dangling = TextLink(source: .timer, timerId: "gone")
    #expect(LinkedText.resolve(dangling, info: info, at: fixedDate) == nil,
            "a deleted timer is a no-op, never an error")
}

@Test func stageMessageReadsTheConfidenceAlert() {
    let info = fixtureInfo(alert: CueAlert(message: "Mics hot", behavior: .persist, target: .confidence))
    #expect(LinkedText.resolve(link(.stageMessage), info: info, at: fixedDate) == "Mics hot")
}

@Test func stageMessageRespectsTheFlashOffBeat() {
    let info = fixtureInfo(
        alert: CueAlert(message: "Mics hot", behavior: .flash, target: .confidence),
        alertVisible: false
    )
    #expect(LinkedText.resolve(link(.stageMessage), info: info, at: fixedDate) == nil,
            "the linked box blinks in step with the banner")
}

@Test func stageMessageIgnoresAudienceOnlyAlerts() {
    let info = fixtureInfo(alert: CueAlert(message: "Nursery", behavior: .persist, target: .audience))
    #expect(LinkedText.resolve(link(.stageMessage), info: info, at: fixedDate) == nil)
}

@Test func resolvedObjectsLeavesUnlinkedObjectsUntouched() {
    let plain = SlideObject(id: "a", objectKind: .text, name: "Static", text: "hello")
    let out = LinkedText.resolvedObjects([plain], info: fixtureInfo(), at: fixedDate)
    #expect(out == [plain])
}

@Test func resolvedObjectsSubstitutesLinkedText() {
    var linked = SlideObject(id: "b", objectKind: .text, name: "Next", text: "stored text is ignored")
    linked.textLink = link(.nextSlide)
    let out = LinkedText.resolvedObjects([linked], info: fixtureInfo(), at: fixedDate)
    #expect(out[0].text == "next line")
    #expect(out[0].id == "b")
}

@Test func resolvedObjectsPreservesEverythingButTextAndInk() {
    var linked = SlideObject(id: "c", objectKind: .text, name: "Clock", text: "")
    linked.textLink = link(.clock)
    linked.maskObjectId = "mask-target"
    linked.groupId = "group-1"
    let out = LinkedText.resolvedObjects([linked], info: fixtureInfo(), at: fixedDate)
    #expect(out[0].maskObjectId == "mask-target")
    #expect(out[0].groupId == "group-1")
}

@Test func emptySourceResolvesToEmptyText() {
    var linked = SlideObject(id: "d", objectKind: .text, name: "Next", text: "stale")
    linked.textLink = link(.nextSlide)
    var info = fixtureInfo()
    info.next = nil
    let out = LinkedText.resolvedObjects([linked], info: info, at: fixedDate)
    #expect(out[0].text.isEmpty, "no next slide = the box goes dark, not stale")
}

@Test func timerWarningInkOverridesTheStyledColor() {

    let timer = TimerSnapshot(id: "t", name: "T", mode: .countdown, banked: 280, durationSeconds: 300)
    var linked = SlideObject(id: "e", objectKind: .text, name: "Timer", text: "")
    linked.textLink = link(.timer)
    linked.textStyle = TextStyle(colorHex: "#FFFFFFFF")
    let out = LinkedText.resolvedObjects([linked], info: fixtureInfo(timers: [timer]), at: fixedDate)
    #expect(out[0].textStyle?.colorHex == TimerWarning.amberHex,
            "§8.3: an active warning outruns styling — red means a problem")
}

@Test func usesWarningColorFalseKeepsTheStyledColor() {
    let timer = TimerSnapshot(id: "t", name: "T", mode: .countdown, banked: 280, durationSeconds: 300)
    var linked = SlideObject(id: "f", objectKind: .text, name: "Timer", text: "")
    linked.textLink = TextLink(source: .timer, usesWarningColor: false)
    linked.textStyle = TextStyle(colorHex: "#FFFFFFFF")
    let out = LinkedText.resolvedObjects([linked], info: fixtureInfo(timers: [timer]), at: fixedDate)
    #expect(out[0].textStyle?.colorHex == "#FFFFFFFF")
}

@Test func healthyTimerKeepsTheStyledColor() {
    let timer = TimerSnapshot(id: "t", name: "T", mode: .countdown, banked: 0, durationSeconds: 300)
    var linked = SlideObject(id: "g", objectKind: .text, name: "Timer", text: "")
    linked.textLink = link(.timer)
    linked.textStyle = TextStyle(colorHex: "#AABBCCFF")
    let out = LinkedText.resolvedObjects([linked], info: fixtureInfo(timers: [timer]), at: fixedDate)
    #expect(out[0].textStyle?.colorHex == "#AABBCCFF")
}

@Test func isTimeVaryingTruthTable() {
    #expect(LinkedText.isTimeVarying(link(.clock)))
    #expect(LinkedText.isTimeVarying(link(.timer)))
    #expect(LinkedText.isTimeVarying(link(.videoCountdown)))
    #expect(!LinkedText.isTimeVarying(link(.currentSlide)))
    #expect(!LinkedText.isTimeVarying(link(.nextSlide)))
    #expect(!LinkedText.isTimeVarying(link(.lastSlide)))
    #expect(!LinkedText.isTimeVarying(link(.slidePosition)))
    #expect(!LinkedText.isTimeVarying(link(.currentServiceItem)))
    #expect(!LinkedText.isTimeVarying(link(.nextServiceItem)))
    #expect(!LinkedText.isTimeVarying(link(.nextServiceTitle)))
    #expect(!LinkedText.isTimeVarying(link(.stageMessage)))
}

@Test func namedTimerPreviewsWithTheSampleTimer() {

    let named = TextLink(source: .timer, timerId: "item-remaining", timerPattern: "m:ss.f")
    #expect(LinkedText.sampleText(for: named) == "17:26.4")
    var object = SlideObject(id: "t", objectKind: .text, name: "Timer", text: "")
    object.textLink = named
    let previewed = LinkedText.previewObjects([object])
    #expect(previewed.first?.text == "17:26.4")
    #expect(previewed.first?.textLink?.timerId == "item-remaining")
    #expect(LinkedText.resolve(named, info: LinkedText.previewInfo, at: LinkedText.previewDate) == nil,
            "the live read still renders nothing for a timer the room lacks")
}

@Test func everySourceHasAVisiblePreview() {

    for source in TextSourceKind.allCases {
        #expect(!LinkedText.sampleText(for: TextLink(source: source)).isEmpty,
                "previewInfo leaves \(source.rawValue) dark")
    }
}

@Test func authoringHidesNextServiceTitleUnlessAlreadyLinked() {
    #expect(!LinkedText.authoringSources(current: nil).contains(.nextServiceTitle))
    #expect(!LinkedText.authoringSources(current: .clock).contains(.nextServiceTitle))
    #expect(LinkedText.authoringSources(current: .nextServiceTitle).contains(.nextServiceTitle))
    #expect(LinkedText.authoringSources(current: nil).count == TextSourceKind.allCases.count - 1)
}
