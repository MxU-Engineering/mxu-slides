import Foundation
import Testing
@testable import PresenterCore

private typealias C = TimelineClips

private func stem(_ id: String, at: Double, duration: Double?, inPoint: Double? = nil, channel: String = "keys") -> TimelineCue {
    TimelineCue(id: id, lane: TimelineTracks.lane(for: channel), at: at, duration: duration, mediaId: "audio-\(channel)", inPoint: inPoint)
}

private func ids() -> () -> String {
    var count = 0
    return { count += 1; return "n\(count)" }
}

private func read(_ cue: TimelineCue, at t: Double) -> Double? {
    guard t >= cue.at, t < cue.at + (cue.duration ?? .infinity) else { return nil }
    return (cue.inPoint ?? 0) + t - cue.at
}

@Test func aSplitKeepsEveryFrameWhereItWas() throws {
    var cue = stem("a", at: 2, duration: 10, inPoint: 1)
    cue.fadeIn = ClipFade(seconds: 1, shape: "sCurve")
    cue.fadeOut = ClipFade(seconds: 2)
    let (left, right) = try #require(C.split(cue, at: 5, in: [cue], newID: ids()))
    #expect(left.id == "a")
    #expect(right.id == "n1")
    #expect(left.at == 2 && left.duration == 3)
    #expect(right.at == 5 && right.duration == 7 && right.inPoint == 4)

    for t in [2.5, 4.9, 5, 8, 11.9] {
        #expect(read(t < 5 ? left : right, at: t) == read(cue, at: t))
    }
    #expect(left.fadeIn == cue.fadeIn && left.fadeOut == nil)
    #expect(right.fadeIn == nil && right.fadeOut == cue.fadeOut)

    #expect(C.split(cue, at: 2, in: [cue]) == nil)
    #expect(C.split(cue, at: 13, in: [cue]) == nil)

    #expect(C.split(TimelineCue(id: "s", lane: "slide", at: 1), at: 3, in: []) == nil)
}

@Test func splittingAtThePlayheadSplitsOnlyWhatItCrosses() {
    let a = stem("a", at: 0, duration: 10), b = stem("b", at: 0, duration: 10, channel: "bass")
    let c = stem("c", at: 6, duration: 4, channel: "pad")
    let split = C.splitting(["a", "c"], at: 4, in: [a, b, c], newID: ids())
    #expect(split.map(\.id) == ["a", "n1", "b", "c"])
}

@Test func trimmingAStartKeepsTheAudioInPlace() {
    let cue = stem("a", at: 4, duration: 10, inPoint: 1)
    let later = C.trimmedStart(cue, by: 2, end: 14)
    #expect(later.at == 6 && later.duration == 8 && later.inPoint == 3)
    #expect(read(later, at: 7) == read(cue, at: 7))

    let earlier = C.trimmedStart(cue, by: -3, end: 14)
    #expect(earlier.at == 3 && earlier.inPoint == nil && earlier.duration == 11)

    #expect(C.trimmedStart(cue, by: 20, end: 14).at == PresentationTimelines.snappedToFrame(14 - PresentationTimelines.frame))

    var faded = cue
    faded.fadeIn = ClipFade(seconds: 3)
    faded.fadeOut = ClipFade(seconds: 3)
    let short = C.trimmedStart(faded, by: 6, end: 14)
    #expect(short.duration == 4)
    #expect(short.fadeIn?.seconds == 3 && short.fadeOut?.seconds == 1)
}

@Test func theMusicLayersClipsTrimTheSameWay() {
    let music = TimelineCue(id: "m", lane: TimelineLane.audio.rawValue, at: 0, duration: 30, mediaId: "song")
    let trimmed = PresentationTimelines.edited(music, in: [music], mode: .trim, by: 5)
    #expect(trimmed.at == 5 && trimmed.inPoint == 5 && trimmed.duration == 25)

    let overlay = TimelineCue(id: "o", lane: TimelineLane.overlays.rawValue, at: 0, duration: 30, overlayId: "x")
    #expect(PresentationTimelines.edited(overlay, in: [overlay], mode: .trim, by: 5).inPoint == nil)
}

@Test func crossfadeOnlyOnAnOverlap() throws {
    let a = stem("a", at: 0, duration: 10)
    let b = stem("b", at: 8, duration: 10, inPoint: 30)
    let (left, right) = try #require(C.crossfaded(b, a, in: [a, b]))
    #expect(left.id == "a" && right.id == "b")
    #expect(left.fadeOut == ClipFade(seconds: 2, shape: "equalPower"))
    #expect(right.fadeIn == ClipFade(seconds: 2, shape: "equalPower"))

    #expect(left.at == 0 && left.duration == 10 && right.at == 8 && right.inPoint == 30)

    let butted = stem("c", at: 10, duration: 5)
    #expect(C.crossfaded(a, butted, in: [a, butted]) == nil)

    let bass = stem("d", at: 5, duration: 10, channel: "bass")
    #expect(C.crossfaded(a, bass, in: [a, bass]) == nil)
    #expect(C.overlapping(a, in: [a, b, butted, bass]).map(\.id) == ["b"])
}

@Test func edgeFadesAreOnExceptWhereTheAudioRunsOn() throws {
    let whole = stem("a", at: 0, duration: 10)
    #expect(C.edges(of: whole, in: [whole]) == (true, true))

    let (left, right) = try #require(C.split(whole, at: 4, in: [whole], newID: ids()))
    #expect(C.edges(of: left, in: [left, right]) == (true, false))
    #expect(C.edges(of: right, in: [left, right]) == (false, true))

    let moved = PresentationTimelines.moved(right, by: 1)
    #expect(C.edges(of: left, in: [left, moved]) == (true, true))
    #expect(C.edges(of: moved, in: [left, moved]) == (true, true))

    var off = whole
    off.edgeFades = false
    #expect(C.edges(of: off, in: [off]) == (false, false))
}

@Test func copyAndPasteKeepTheirSpacing() {
    let a = stem("a", at: 4, duration: 6), b = stem("b", at: 7, duration: 6, channel: "bass")
    let clipboard = C.copied([a, b], all: [a, b])
    #expect(clipboard.map(\.at) == [0, 3])
    let pasted = C.pasted(clipboard, at: 20, newID: ids())
    #expect(pasted.map(\.id) == ["n1", "n2"])
    #expect(pasted.map(\.at) == [20, 23])
    #expect(pasted.map(\.lane) == [a.lane, b.lane])
}

@Test func copyingARangeCutsClipsToIt() {
    var a = stem("a", at: 0, duration: 10)
    a.fadeIn = ClipFade(seconds: 1)
    a.fadeOut = ClipFade(seconds: 1)
    let slide = TimelineCue(id: "s", lane: TimelineLane.slide.rawValue, at: 5, sectionId: "v", slideId: "x")
    let early = TimelineCue(id: "s0", lane: TimelineLane.slide.rawValue, at: 1)
    let all = [a, slide, early]
    let copied = C.copied(all, range: 4 ... 8, all: all)
    #expect(copied.map(\.id) == ["a", "s"])
    let piece = copied[0]
    #expect(piece.at == 0 && piece.duration == 4 && piece.inPoint == 4)
    #expect(piece.fadeIn == nil && piece.fadeOut == nil)
    #expect(copied[1].at == 1)
}

@Test func rippleDeleteMovesEverythingAfterUpAndButtsTheCut() throws {

    let keys = stem("k", at: 0, duration: 60)
    let late = stem("p", at: 45, duration: 10, channel: "pad")
    let inside = stem("i", at: 25, duration: 5, channel: "bass")
    let tail = stem("t", at: 30, duration: 20, inPoint: 2, channel: "gtr")
    let slides = [10.0, 25, 41].enumerated().map { TimelineCue(id: "s\($0)", lane: TimelineLane.slide.rawValue, at: $1) }
    let overlay = TimelineCue(id: "o", lane: TimelineLane.overlays.rawValue, at: 15, duration: 30, overlayId: "lower")
    let timeline = PresentationTimeline(
        id: "t", timecodeEnabled: false, timecodeStart: 0, length: 60,
        cues: [keys, late, inside, tail, overlay] + slides)
    let result = C.rippleDeleted(timeline, range: 20 ... 40, newID: ids())
    let byID = Dictionary(result.cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    let head = try #require(byID["k"]), bridge = try #require(byID["n1"])
    #expect(head.at == 0 && head.duration == 20)
    #expect(bridge.at == 20 && bridge.duration == 20 && bridge.inPoint == 40)
    #expect(bridge.fadeIn == nil && head.fadeOut == nil)

    #expect(byID["p"]?.at == 25)
    #expect(byID["i"] == nil)
    #expect(byID["t"]?.at == 20 && byID["t"]?.duration == 10 && byID["t"]?.inPoint == 12)

    #expect(byID["s0"]?.at == 10 && byID["s1"] == nil && byID["s2"]?.at == 21)

    #expect(byID["o"]?.at == 15 && byID["o"]?.duration == 10)
    #expect(result.length == 40)

    #expect(read(bridge, at: 25) == read(keys, at: 45))
}

@Test func shapeNamesMatchTheEngines() {

    #expect(C.Shape.allCases.map(\.rawValue) == ["linear", "sCurve", "equalPower", "fast", "slow"])
    #expect(C.Shape("unknown") == .linear && C.Shape(nil) == .linear)
}
