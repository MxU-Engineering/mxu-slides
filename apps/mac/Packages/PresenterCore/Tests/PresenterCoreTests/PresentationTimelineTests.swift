import Automerge
import Foundation
import Testing
@testable import PresenterCore

private typealias T = PresentationTimelines

private let blocks = [
    TimelinePlayedBlock(sectionId: "v", slideIds: ["v1", "v2"]),
    TimelinePlayedBlock(sectionId: "c", slideIds: ["c1"]),
    TimelinePlayedBlock(sectionId: "v", slideIds: ["v1", "v2"]),
    TimelinePlayedBlock(sectionId: "c", slideIds: ["c1"]),
]

private func slide(_ id: String, at: Double, occurrence: Int) -> TimelineCue {
    T.slideCue(id: id, at: at, anchor: T.anchor(occurrence: occurrence, in: blocks)!)
}

private func block(_ id: String, _ lane: TimelineLane, at: Double, duration: Double? = nil, ref: String) -> TimelineCue {
    TimelineCue(
        id: id, lane: lane.rawValue, at: at, duration: duration,
        mediaId: [.videos, .stillGraphics, .loopingVideos, .audio].contains(lane) ? ref : nil,
        overlayId: lane == .overlays ? ref : nil, alertId: lane == .alerts ? ref : nil,
        liveInputId: lane == .videoInput ? ref : nil)
}

@Test func v140PresentationDecodesWithNoTimelines() throws {
    let json = """
    {"id":"p","name":"Song","presentationKind":"deck","themeId":"","slides":[]}
    """
    let decoded = try JSONDecoder().decode(Presentation.self, from: Data(json.utf8))
    #expect(decoded.timelines == nil)
}

@Test func timelinesRoundTripThroughTheDocument() throws {
    var presentation = Presentation(id: "p", name: "Song", presentationKind: .deck, themeId: "", slides: [])
    presentation.timelines = [PresentationTimeline(
        id: "t", arrangementId: "a", timecodeEnabled: true, timecodeStart: 108_000, length: 240,
        cues: [
            slide("s", at: 1.5, occurrence: 4),
            block("o", .overlays, at: 2, duration: 8, ref: "lower-third"),
            TimelineCue(id: "x", lane: "actions", at: 3, actions: [SlideAction(id: "a1", kind: .timerStart, timerId: "t1")]),
        ])]
    let document = Document()
    try AutomergeEncoder(doc: document).encode(presentation)
    let decoded = try AutomergeDecoder(doc: document).decode(Presentation.self)
    #expect(decoded.timelines == presentation.timelines)
    #expect(DeckField.all.contains { $0.key == "timelines" })
}

@Test func eachArrangementHasItsOwnTimeline() {
    var presentation = Presentation(id: "p", name: "Song", presentationKind: .deck, themeId: "", slides: [])
    let base = PresentationTimeline(id: "base", timecodeEnabled: false, timecodeStart: 0, cues: [])
    let live = PresentationTimeline(id: "live", arrangementId: "a", timecodeEnabled: false, timecodeStart: 0, cues: [])
    presentation.timelines = T.replacing(live, in: T.replacing(base, in: nil))
    #expect(T.timeline(for: nil, in: presentation)?.id == "base")
    #expect(T.timeline(for: "", in: presentation)?.id == "base")
    #expect(T.timeline(for: "a", in: presentation)?.id == "live")
    #expect(T.timeline(for: "other", in: presentation) == nil)
}

@Test func aRepeatedChorusIsADifferentCueEachTime() {

    let first = slide("1", at: 0, occurrence: 2)
    let second = slide("2", at: 0, occurrence: 5)
    #expect(first.slideId == "c1" && second.slideId == "c1")
    #expect(first.sectionOccurrence == 0 && second.sectionOccurrence == 1)
    #expect(T.occurrence(of: first, in: blocks) == 2)
    #expect(T.occurrence(of: second, in: blocks) == 5)
}

@Test func anArrangementEditOrphansItsCuesInsteadOfMisfiring() {
    let secondChorus = slide("2", at: 0, occurrence: 5)

    #expect(T.occurrence(of: secondChorus, in: Array(blocks.prefix(3))) == nil)

    let moved = [TimelinePlayedBlock(sectionId: "c", slideIds: [])] + Array(blocks.dropFirst(2))
    #expect(T.occurrence(of: slide("1", at: 0, occurrence: 2), in: moved) == nil)
}

@Test func sectionsTakeTheTimeFromTheirFirstCueToTheNext() {

    let cues = [
        slide("a", at: 0, occurrence: 0), slide("b", at: 5, occurrence: 1),
        slide("c", at: 10, occurrence: 2), slide("d", at: 25, occurrence: 3),
    ]
    let spans = T.sectionSpans(cues, blocks: blocks, length: 40)
    #expect(spans.map(\.block) == [0, 1, 2])
    #expect(spans.map(\.sectionId) == ["v", "c", "v"])
    #expect(spans.map(\.start) == [0, 10, 25])
    #expect(spans.map(\.end) == [10, 25, 40])
}

@Test func normalPlayFiresEachCueOnceWithItsActions() {
    let cues = [
        slide("s1", at: 0, occurrence: 0),
        slide("s2", at: 4, occurrence: 1),
        block("bg", .loopingVideos, at: 0, ref: "motion"),
        block("ov", .overlays, at: 2, duration: 3, ref: "lower-third"),
        TimelineCue(id: "act", lane: "actions", at: 4.5),
        block("fg", .videos, at: 6, duration: 0.5, ref: "bumper"),
    ]
    var live: T.Live = []
    var fired: [T.Effect] = []
    var last = -T.frame
    for tick in stride(from: 0.0, through: 7, by: 1.0 / 30) {
        let effects = T.crossing(cues, blocks: blocks, from: last, to: tick, live: live)
        for effect in effects {
            if case .fire(_, let id) = effect { live.insert(id) }
        }
        fired += effects
        last = tick
    }
    #expect(fired == [
        .fire(lane: .loopingVideos, id: "motion"),
        .showSlide(occurrence: 0, actions: true),
        .fire(lane: .overlays, id: "lower-third"),
        .showSlide(occurrence: 1, actions: true),
        .runActions(cueId: "act"),

        .clear(lane: .overlays, id: "lower-third"),
        .fire(lane: .videos, id: "bumper"),

        .clear(lane: .videos, id: "bumper"),
    ])
}

@Test func aPlayingBackgroundNeverRetriggers() {

    let cues = [block("bg", .loopingVideos, at: 1, ref: "motion")]
    #expect(T.crossing(cues, blocks: blocks, from: 0, to: 2, live: ["motion"]).isEmpty)
    #expect(T.crossing(cues, blocks: blocks, from: 0, to: 2, live: []) == [.fire(lane: .loopingVideos, id: "motion")])
}

@Test func aBackgroundHasNoOutPoint() {

    let cues = [block("bg", .loopingVideos, at: 0, duration: 2, ref: "motion")]
    #expect(T.crossing(cues, blocks: blocks, from: 1, to: 3, live: ["motion"]).isEmpty)
}

@Test func slidesCrossedInOneStepShowOnlyTheLast() {
    let cues = [slide("a", at: 1, occurrence: 0), slide("b", at: 1.5, occurrence: 1)]
    #expect(T.crossing(cues, blocks: blocks, from: 0, to: 2, live: []) == [.showSlide(occurrence: 1, actions: true)])
}

@Test func orphanedSlideCuesNeverFire() {
    let orphan = TimelineCue(id: "o", lane: "slide", at: 1, sectionId: "gone", slideId: "x")
    #expect(T.crossing([orphan], blocks: blocks, from: 0, to: 2, live: []).isEmpty)
    #expect(T.landing([orphan], blocks: blocks, at: 2, live: []).isEmpty)
}

@Test func aJumpShowsTheSlideWithoutItsActionsAndNeverRunsActions() {
    let cues = [
        slide("s1", at: 0, occurrence: 0),
        slide("s2", at: 10, occurrence: 1),
        TimelineCue(id: "act", lane: "actions", at: 9),
    ]
    #expect(T.landing(cues, blocks: blocks, at: 12, live: []) == [.showSlide(occurrence: 1, actions: false)])
    #expect(T.landing(cues, blocks: blocks, at: 5, live: []) == [.showSlide(occurrence: 0, actions: false)])
}

@Test func aJumpFiresTheOverlaysItLandsInAndClearsTheRest() {
    let cues = [
        block("a", .overlays, at: 0, duration: 5, ref: "title"),
        block("b", .overlays, at: 10, duration: 5, ref: "lyrics-bug"),
    ]

    #expect(T.landing(cues, blocks: blocks, at: 12, live: ["title"])
        == [.clear(lane: .overlays, id: "title"), .fire(lane: .overlays, id: "lyrics-bug")])

    #expect(T.landing(cues, blocks: blocks, at: 12, live: ["lyrics-bug", "hand-fired"]).isEmpty)
}

@Test func aJumpFiresABackgroundOnlyWhenItIsADifferentOne() {
    let cues = [
        block("one", .loopingVideos, at: 0, ref: "blue"),
        block("two", .loopingVideos, at: 30, ref: "red"),
    ]

    #expect(T.landing(cues, blocks: blocks, at: 20, live: ["blue"]).isEmpty)
    #expect(T.landing(cues, blocks: blocks, at: 40, live: ["blue"]) == [.fire(lane: .loopingVideos, id: "red")])
}

@Test func aJumpFiresAForegroundVideoOnlyInsideItsBlock() {
    let cues = [block("fg", .videos, at: 10, duration: 5, ref: "bumper")]
    #expect(T.landing(cues, blocks: blocks, at: 12, live: []) == [.fire(lane: .videos, id: "bumper")])
    #expect(T.landing(cues, blocks: blocks, at: 16, live: []).isEmpty)
    #expect(T.landing(cues, blocks: blocks, at: 12, live: ["bumper"]).isEmpty)

    #expect(T.landing(cues, blocks: blocks, at: 16, live: ["bumper"]) == [.clear(lane: .videos, id: "bumper")])
}

@Test func reRecordingReplacesOnlyTheSlideCuesAfterIt() {
    let cues = [
        slide("early", at: 2, occurrence: 0),
        slide("late", at: 8, occurrence: 1),
        block("ov", .overlays, at: 9, duration: 2, ref: "title"),
    ]
    let kept = T.recording(cues, from: 5)
    #expect(kept.map(\.id) == ["early", "ov"])
    let recorded = T.recorded(slide("new", at: 6, occurrence: 2), into: kept)
    #expect(recorded.map(\.id) == ["early", "new", "ov"])

    #expect(T.recorded(slide("again", at: 6.01, occurrence: 3), into: recorded).map(\.id) == ["early", "again", "ov"])
}

@Test func nudgesSnapToFramesAndStopAtZero() {
    let cue = slide("s", at: 1, occurrence: 0)
    #expect(T.moved(cue, by: T.frame).at == T.snappedToFrame(1 + 1.0 / 30))
    #expect(T.moved(cue, by: -5).at == 0)
}

@Test func cardDragsMoveStretchAndTrimOnFrames() {
    let overlay = block("o", .overlays, at: 2, duration: 4, ref: "x")
    let point = slide("s", at: 3, occurrence: 0)
    let cues = [overlay, point]
    #expect(T.edited(overlay, in: cues, mode: .move, by: 1).at == 3)
    #expect(T.edited(overlay, in: cues, mode: .stretch, by: 1).duration == 5)
    let trimmed = T.edited(overlay, in: cues, mode: .trim, by: 1)
    #expect(trimmed.at == 3 && trimmed.duration == 3)

    #expect(T.edited(overlay, in: cues, mode: .trim, by: 10).at == T.snappedToFrame(6 - T.frame))

    let open = block("v", .videos, at: 2, ref: "clip")
    #expect(T.edited(open, in: [open], mode: .stretch, by: -10, openEnd: 30).duration == 18)

    #expect(T.edited(point, in: cues, mode: .stretch, by: 1).at == 4)
}

@Test func lengthIsTheLastEndUnlessSet() {
    let cues = [slide("s", at: 3, occurrence: 0), block("o", .overlays, at: 4, duration: 6, ref: "x"), block("b", .loopingVideos, at: 12, ref: "y")]
    var timeline = PresentationTimeline(id: "t", timecodeEnabled: false, timecodeStart: 0, cues: cues)
    #expect(T.length(timeline) == 12)
    timeline.length = 90
    #expect(T.length(timeline) == 90)
}

@Test func timecodeStartsReadAndWriteAsFramesAt30() {
    #expect(T.timecode(frames: 108_000) == "01:00:00:00")
    #expect(T.timecode(frames: 3600 * 30 + 61 * 30 + 29) == "01:01:01:29")
    #expect(T.frames(timecode: "01:01:01:29") == 3600 * 30 + 61 * 30 + 29)
    #expect(T.frames(timecode: "02:10:00") == (2 * 3600 + 600) * 30)
    #expect(T.frames(timecode: "00:00:00;15") == 15)
    #expect(T.frames(timecode: "00:61:00:00") == nil)
    #expect(T.frames(timecode: "00:00:00:30") == nil)
    #expect(T.frames(timecode: "nonsense") == nil)
}

@Test func overlappingStartsAreFoundAndAFreeHourSuggested() {
    let hour = 3600 * 30
    let songA = T.Window(id: "a", start: hour, length: 300 * 30)
    let songB = T.Window(id: "b", start: 2 * hour, length: 300 * 30)
    let mine = T.Window(id: "me", start: hour + 60 * 30, length: 240 * 30)
    #expect(T.overlaps(mine, in: [songA, songB]).map(\.id) == ["a"])
    #expect(T.overlaps(T.Window(id: "me", start: hour + 300 * 30, length: 10), in: [songA]).isEmpty)
    #expect(T.suggestedStart(length: mine.length, avoiding: [songA, songB], id: "me") == 3 * hour)

    #expect(T.suggestedStart(length: mine.length, avoiding: [T.Window(id: "me", start: hour, length: 10)], id: "me") == hour)
}

@Test func laneIdsReadV141SpellingsAndKeepUnknownOnesQuiet() {

    #expect(TimelineLane(id: "slides") == .slide)
    #expect(TimelineLane(id: "foregroundVideos") == .videos)
    #expect(TimelineLane(id: "background") == .loopingVideos)
    #expect(TimelineLane(id: "videoInput") == .videoInput)
    let unknown = TimelineCue(id: "x", lane: "customLayer7", at: 1, mediaId: "m")
    #expect(unknown.kind == nil)
    #expect(T.crossing([unknown], blocks: blocks, from: 0, to: 2, live: []).isEmpty)
    #expect(T.landing([unknown], blocks: blocks, at: 1.5, live: []).isEmpty)
}

@Test func everyLayerLaneFiresAndComesDownAtItsOutPoint() {

    let cues = [
        block("a", .alerts, at: 1, duration: 2, ref: "welcome"),
        block("s", .stillGraphics, at: 1, duration: 2, ref: "logo"),
        block("i", .videoInput, at: 1, duration: 2, ref: "camera-1"),
    ]
    let effects = T.crossing(cues, blocks: blocks, from: 0, to: 4, live: [])
    #expect(effects == [
        .fire(lane: .alerts, id: "welcome"), .fire(lane: .stillGraphics, id: "logo"), .fire(lane: .videoInput, id: "camera-1"),
        .clear(lane: .alerts, id: "welcome"), .clear(lane: .stillGraphics, id: "logo"), .clear(lane: .videoInput, id: "camera-1"),
    ])

    #expect(T.landing(cues, blocks: blocks, at: 2, live: ["camera-1"])
        == [.fire(lane: .alerts, id: "welcome"), .fire(lane: .stillGraphics, id: "logo")])
    #expect(T.landing(cues, blocks: blocks, at: 5, live: ["welcome", "camera-1"])
        == [.clear(lane: .alerts, id: "welcome"), .clear(lane: .videoInput, id: "camera-1")])
}

@Test func aBackingTrackFollowsThePlayhead() {

    let cues = [block("t", .audio, at: 2, duration: 180, ref: "track")]
    let started = T.crossing(cues, blocks: blocks, from: 1.99, to: 2.02, live: [])
    guard case .playAudio("track", let from, "t")? = started.first, started.count == 1 else {
        Issue.record("the track starts once: \(started)")
        return
    }
    #expect(abs(from - 0.02) < 0.001)
    #expect(T.crossing(cues, blocks: blocks, from: 181, to: 183, live: ["track"]) == [.endAudio(id: "track", clip: "t")])
    #expect(T.landing(cues, blocks: blocks, at: 62, live: ["track"]) == [.playAudio(id: "track", from: 60, clip: "t")])
    #expect(T.landing(cues, blocks: blocks, at: 190, live: ["track"]) == [.clear(lane: .audio, id: "track")])
}
