import Foundation
import Testing
@testable import PresenterCore

private typealias S = SongTransitions

@Test func absentOrUnknownTransitionsAreStop() {
    #expect(S.kind(nil) == .stop)
    #expect(S.kind(SongTransition(kind: "segue")) == .stop)
    #expect(S.kind(SongTransition(kind: "crossfade")) == .crossfade)
    #expect(S.plan(.stop, end: 300, length: 5) == nil, "Stop arms nothing: today's behavior")
}

@Test func lengthsArePlaybacksUnlessTyped() {
    #expect(S.length(SongTransition(kind: "fade")) == 5)
    #expect(S.length(SongTransition(kind: "crossfade")) == 5)
    #expect(S.length(SongTransition(kind: "crossfade", seconds: 12)) == 12)

    #expect(S.length(SongTransition(kind: "overlap"), lastSection: 3.5, nextFirstSection: 8) == 3.5)
    #expect(S.length(SongTransition(kind: "overlap"), lastSection: 20, nextFirstSection: 4) == 4)
    #expect(S.length(SongTransition(kind: "overlap"), lastSection: 20, nextFirstSection: nil) == 5)
    #expect(S.length(SongTransition(kind: "overlap", seconds: 9), lastSection: 3) == 9)
    #expect(S.length(SongTransition(kind: "fade", seconds: 0)) == 5, "zero reads as unset")
}

@Test func eachTransitionHandsOverWhereTheTableSays() {
    let fade = S.plan(.fade, end: 300, length: 5)
    #expect(fade == S.Plan(kind: .fade, nextAt: 300, fadeFrom: 295, fadeSeconds: 5, fadeInSeconds: 0, end: 300))
    let overlap = S.plan(.overlap, end: 300, length: 4)
    #expect(overlap == S.Plan(kind: .overlap, nextAt: 296, fadeFrom: nil, fadeSeconds: 0, fadeInSeconds: 0, end: 300))
    let crossfade = S.plan(.crossfade, end: 300, length: 5)
    #expect(crossfade == S.Plan(kind: .crossfade, nextAt: 295, fadeFrom: 295, fadeSeconds: 5, fadeInSeconds: 5, end: 300))

    #expect(S.plan(.crossfade, end: 3, length: 5)?.nextAt == 0)
}

@Test func normalPlayCrossesTheHandoverOnce() {
    let plan = S.plan(.overlap, end: 300, length: 4)!
    #expect(!S.due(plan, from: 295.9, to: 295.99))
    #expect(S.due(plan, from: 295.99, to: 296.02))
    #expect(!S.due(plan, from: 296.02, to: 296.05), "fires once")
}

@Test func aJumpPastTheHandoverStartsItAtOnceShortened() {
    let crossfade = S.plan(.crossfade, end: 300, length: 5)!
    #expect(S.landing(crossfade, at: 200) == nil, "before it: nothing yet")
    #expect(S.landing(crossfade, at: 298) == S.Plan(
        kind: .crossfade, nextAt: 298, fadeFrom: 298, fadeSeconds: 2, fadeInSeconds: 2, end: 300))
    let fade = S.plan(.fade, end: 300, length: 5)!
    #expect(S.landing(fade, at: 297) == S.Plan(
        kind: .fade, nextAt: 300, fadeFrom: 297, fadeSeconds: 3, fadeInSeconds: 0, end: 300), "B still waits for A's end")
    let overlap = S.plan(.overlap, end: 300, length: 4)!
    #expect(S.landing(overlap, at: 299)?.nextAt == 299)
    #expect(S.landing(overlap, at: 299)?.fadeFrom == nil, "overlap never fades")
}

@Test func aManualJumpAlwaysCrossfades() {

    #expect(S.manualCrossfade(nil) == 5)
    #expect(S.manualCrossfade(SongTransition(kind: "stop", seconds: 3)) == 3)
    #expect(S.manualPlan(at: 61, seconds: 5) == S.Plan(
        kind: .crossfade, nextAt: 61, fadeFrom: 61, fadeSeconds: 5, fadeInSeconds: 5, end: 66))
}

@Test func onlySlidesOwnClockArmsAGo() {
    #expect(S.arms(.crossfade, ownClock: true, recording: false, cancelled: false))
    #expect(!S.arms(.crossfade, ownClock: false, recording: false, cancelled: false), "timecode decides (S5)")
    #expect(!S.arms(.fade, ownClock: true, recording: true, cancelled: false), "a take is one song")
    #expect(!S.arms(.overlap, ownClock: true, recording: false, cancelled: true), "Cancel Transition: this song stops at its end")
    #expect(!S.arms(.stop, ownClock: true, recording: false, cancelled: false))
}

@Test func aServiceItemCarriesItsTransition() throws {
    var item = ServiceItem(id: "a", itemKind: .presentation, name: "A", refId: "deck")
    item.transition = SongTransition(kind: "overlap", seconds: 3)
    let decoded = try JSONDecoder().decode(ServiceItem.self, from: JSONEncoder().encode(item))
    #expect(decoded.transition == SongTransition(kind: "overlap", seconds: 3))
    let older = try JSONDecoder().decode(ServiceItem.self, from: Data(#"{"id":"b","itemKind":"presentation","name":"B","refId":"d"}"#.utf8))
    #expect(older.transition == nil)
}

@Test func aServicesPlanReadsTheTimelinesEndAndSections() {
    typealias T = PresentationTimelines
    let aBlocks = [TimelinePlayedBlock(sectionId: "v", slideIds: ["v1"]), TimelinePlayedBlock(sectionId: "c", slideIds: ["c1"])]
    let a = PresentationTimeline(id: "a", timecodeEnabled: false, timecodeStart: 0, length: 300, cues: [
        T.slideCue(id: "v1", at: 0, anchor: T.anchor(occurrence: 0, in: aBlocks)!),
        T.slideCue(id: "c1", at: 290, anchor: T.anchor(occurrence: 1, in: aBlocks)!),
    ])
    let bBlocks = [TimelinePlayedBlock(sectionId: "i", slideIds: ["i1"]), TimelinePlayedBlock(sectionId: "v", slideIds: ["v1"])]
    let b = PresentationTimeline(id: "b", timecodeEnabled: false, timecodeStart: 0, cues: [
        T.slideCue(id: "i1", at: 0, anchor: T.anchor(occurrence: 0, in: bBlocks)!),
        T.slideCue(id: "v1", at: 3, anchor: T.anchor(occurrence: 1, in: bBlocks)!),
    ])

    let overlap = S.plan(SongTransition(kind: "overlap"), timeline: a, blocks: aBlocks, next: (b, bBlocks))
    #expect(overlap?.nextAt == 297)
    #expect(overlap?.end == 300, "A's end is its set length")

    #expect(S.plan(SongTransition(kind: "overlap"), timeline: a, blocks: aBlocks)?.nextAt == 295)
    #expect(S.plan(nil, timeline: a, blocks: aBlocks) == nil)
}

@Test func aGoHandsOverOnTheTickThatReachesIt() {
    let plan = S.plan(.crossfade, end: 300, length: 5)!

    #expect(S.step(plan, position: 290, inPlayer: false, playerHandedOver: false) == .play(to: 290))

    #expect(S.step(plan, position: 295.02, inPlayer: false, playerHandedOver: false) == .handOver(at: 295))

    #expect(S.step(plan, position: 295.2, inPlayer: true, playerHandedOver: false) == .play(to: 295))
    #expect(S.step(plan, position: 295.1, inPlayer: true, playerHandedOver: true) == .handOver(at: 295))

    #expect(S.step(plan, position: 295.5, inPlayer: true, playerHandedOver: false) == .handOver(at: 295))
}

@Test func theNextThingIsTheRunOrdersNextFireableItem() {
    let song = ServiceItem(id: "s", itemKind: .presentation, name: "Song", refId: "d")
    let video = ServiceItem(id: "v", itemKind: .media, name: "Video", refId: "m")
    #expect(S.nextStart(song, hasTimeline: true) == .playTimeline)
    #expect(S.nextStart(song, hasTimeline: false) == .fire, "a slides-only song fires its first slide")
    #expect(S.nextStart(video, hasTimeline: false) == .fire)
    #expect(S.nextStart(nil, hasTimeline: false) == .nothing)
}

@Test func onlyAManualPlayOnAnotherSongCrossfades() {
    #expect(S.manualJumpCrossfades(anotherSong: true, playing: true, stemsSounding: true, handingOver: false))
    #expect(!S.manualJumpCrossfades(anotherSong: true, playing: true, stemsSounding: true, handingOver: true), "a go's own handover")
    #expect(!S.manualJumpCrossfades(anotherSong: true, playing: true, stemsSounding: false, handingOver: false), "no stems: nothing to fade")
    #expect(!S.manualJumpCrossfades(anotherSong: false, playing: true, stemsSounding: true, handingOver: false), "the same song: a jump")
    #expect(!S.manualJumpCrossfades(anotherSong: true, playing: false, stemsSounding: true, handingOver: false))
}

@Test func theDrawnLevelsAreThePlayersCurves() {
    let crossfade = S.plan(.crossfade, end: 300, length: 4)!
    #expect(S.levels(crossfade, at: 290) == (1, 0))
    let middle = S.levels(crossfade, at: 298)
    #expect(abs(middle.outgoing - cos(Double.pi / 4)) < 1e-9 && abs(middle.incoming - sin(Double.pi / 4)) < 1e-9, "equal power")
    #expect(S.levels(crossfade, at: 300) == (0, 1))
    let fade = S.plan(.fade, end: 300, length: 4)!
    #expect(abs(S.levels(fade, at: 298).outgoing - 0.5) < 1e-9, "a raised cosine, half way down")
    #expect(S.levels(fade, at: 299).incoming == 0, "the next song waits for the end")
    let overlap = S.plan(.overlap, end: 300, length: 4)!
    #expect(S.levels(overlap, at: 299) == (1, 1), "both at full level")
}
