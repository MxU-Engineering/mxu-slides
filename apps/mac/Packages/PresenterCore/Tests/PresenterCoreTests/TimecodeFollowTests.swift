import Foundation
import Testing
@testable import PresenterCore

@Suite struct TimecodeClockTests {
    private let fps = 30.0

    private func feed(
        _ clock: inout TimecodeClock, _ numbers: some Sequence<Int>, from start: Double, reverse: Bool = false
    ) -> Double {
        var time = start
        for n in numbers {
            time += 1 / fps
            clock.receive(LTCFrame(label: LTCSignal.label(n, nominal: 30), reverse: reverse), rate: .fps30, hostTime: time)
        }
        return time
    }

    @Test func locksAfterThreeGoodFrames() {
        var clock = TimecodeClock()
        #expect(clock.reading(at: 0).state == .noInput)
        var time = feed(&clock, [100, 101], from: 0)
        #expect(clock.reading(at: time).state == .locking)
        #expect(!clock.reading(at: time).live)
        time = feed(&clock, [102], from: time)
        let reading = clock.reading(at: time)
        #expect(reading.state == .locked)
        #expect(reading.live)

        #expect(abs((reading.position ?? 0) - 103 / fps) < 1e-9)

        #expect(abs((clock.reading(at: time + 0.02).position ?? 0) - (103 / fps + 0.02)) < 1e-9)
    }

    @Test func noiseNeverLocks() {
        var clock = TimecodeClock()
        var time = 0.0
        for n in [5, 900, 31, 4000, 77] { time = feed(&clock, [n], from: time) }
        #expect(clock.reading(at: time).state == .locking)
    }

    @Test func dropoutFreewheelsThenStopsAndHolds() {
        var clock = TimecodeClock()
        let time = feed(&clock, 0..<30, from: 0)
        let freewheel = clock.reading(at: time + 0.3)
        #expect(freewheel.state == .freewheel)
        #expect(!freewheel.live)
        #expect(abs((freewheel.position ?? 0) - (1 + 0.3)) < 1e-9)
        let stopped = clock.reading(at: time + 2)
        #expect(stopped.state == .stopped)

        #expect(stopped.position == 1)
    }

    @Test func signalBackWithinTheFreewheelIsStillLocked() {
        var clock = TimecodeClock()
        var time = feed(&clock, 0..<30, from: 0)

        time = feed(&clock, 39..<41, from: time + 0.3)
        #expect(clock.reading(at: time).state == .locked)
    }

    @Test func aGapFreeJumpNeedsTwoFrames() {
        var clock = TimecodeClock()
        var time = feed(&clock, 0..<30, from: 0)

        time = feed(&clock, [900], from: time)
        #expect(abs((clock.reading(at: time).position ?? 0) - 31 / fps) < 1e-9)

        time = feed(&clock, [600, 601], from: time)
        let reading = clock.reading(at: time)
        #expect(reading.state == .locked)
        #expect(abs((reading.position ?? 0) - 602 / fps) < 1e-9)
    }

    @Test func afterStoppingItLocksAfresh() {
        var clock = TimecodeClock()
        var time = feed(&clock, 0..<30, from: 0)
        time = feed(&clock, [300], from: time + 5)
        #expect(clock.reading(at: time).state == .locking)
        time = feed(&clock, [301, 302], from: time)
        #expect(clock.reading(at: time).state == .locked)
    }

    @Test func reverseIsReadAndNeverLive() {
        var clock = TimecodeClock()
        let time = feed(&clock, (200..<230).reversed(), from: 0, reverse: true)
        let reading = clock.reading(at: time)
        #expect(reading.state == .locked)
        #expect(reading.reverse)
        #expect(!reading.live)

        #expect((clock.reading(at: time + 0.1).position ?? 0) < (reading.position ?? 0))
    }
}

infix operator ≈: ComparisonPrecedence

private func ≈ (lhs: TimecodeFollow.Command?, rhs: TimecodeFollow.Command) -> Bool {
    func rounded(_ c: TimecodeFollow.Command) -> TimecodeFollow.Command {
        let r = { (x: Double) in (x * 1e6).rounded() / 1e6 }
        switch c {
        case .play(let id, let from, let to): return .play(itemID: id, from: r(from), to: r(to))
        case .land(let id, let at): return .land(itemID: id, at: r(at))
        }
    }
    return lhs.map(rounded) == rounded(rhs)
}

@Suite struct TimecodeFollowTests {

    private let songs = [
        TimecodeFollow.Song(itemID: "a", startFrames: 108_000, length: 120),
        TimecodeFollow.Song(itemID: "b", startFrames: 216_000, length: 120),
        TimecodeFollow.Song(itemID: "c", startFrames: 324_000, length: 120),
    ]

    private func live(_ seconds: Double, rate: TimecodeRate = .fps30) -> TimecodeClock.Reading {
        TimecodeClock.Reading(state: .locked, position: seconds, rate: rate)
    }

    @Test func resolverPicksTheWindowHoldingTheTimecode() {
        #expect(TimecodeFollow.song(containing: 3600 + 10, rate: .fps30, in: songs)?.song.itemID == "a")
        #expect(TimecodeFollow.song(containing: 7200 + 119.9, rate: .fps30, in: songs)?.song.itemID == "b")

        #expect(TimecodeFollow.song(containing: 3600 + 120, rate: .fps30, in: songs) == nil)
        #expect(TimecodeFollow.song(containing: 0, rate: .fps30, in: songs) == nil)

        let overlapping = [songs[1], TimecodeFollow.Song(itemID: "x", startFrames: 216_000 + 300, length: 60)]
        #expect(TimecodeFollow.song(containing: 7200 + 20, rate: .fps30, in: overlapping)?.song.itemID == "b")

        let start = TimecodeRate.fps2997.seconds(TimecodeLabel(hours: 2, minutes: 0, seconds: 0, frames: 0))
        let position = TimecodeFollow.song(containing: start + 60, rate: .fps2997, in: songs)?.position
        #expect(abs((position ?? 0) - 60) < 1e-9)
    }

    @Test func anOpenEndedTimelineKeepsATailOtherSongsBeat() {
        let timeline = PresentationTimeline(
            id: "t", timecodeEnabled: true, timecodeStart: 108_000,
            cues: [TimelineCue(id: "s", lane: "slide", at: 30, slideId: "x")])
        let song = TimecodeFollow.Song(itemID: "a", timeline: timeline)
        #expect(song.length == 30)
        #expect(song.tail == 1)

        #expect(TimecodeFollow.song(containing: 3600 + 30.02, rate: .fps30, in: [song])?.song.itemID == "a")

        let next = TimecodeFollow.Song(itemID: "b", startFrames: 108_000 + 900, length: 60)
        #expect(TimecodeFollow.song(containing: 3600 + 30.02, rate: .fps30, in: [song, next])?.song.itemID == "b")

        var fixed = timeline
        fixed.length = 30
        #expect(TimecodeFollow.Song(itemID: "a", timeline: fixed).tail == 0)
    }

    @Test func stationSettingsNeverSyncOrBackUp() {
        for key in TimecodeStation.keys {
            #expect(!WorkspaceSetting.allCases.contains { $0.carries(key) }, "\(key)")
            #expect(!BackupSettings.isPortable(key), "\(key)")
        }
    }

    @Test func songStartPlaysFromTheTopWithActions() {
        var follow = TimecodeFollow()

        #expect(follow.step(live(3600.1), songs: songs) ≈ .play(itemID: "a", from: -PresentationTimelines.frame, to: 0.1))
    }

    @Test func normalPlayCrossesStepByStep() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600.1), songs: songs)
        let step = follow.step(live(3600.1 + 1.0 / 30), songs: songs)
        guard case .play(let id, let from, let to) = step else { Issue.record("\(String(describing: step))"); return }
        #expect(id == "a")
        #expect(abs(from - 0.1) < 1e-9)
        #expect(abs(to - (0.1 + 1.0 / 30)) < 1e-9)
    }

    @Test func midSongStartLandsWithoutActions() {
        var follow = TimecodeFollow()
        #expect(follow.step(live(3600 + 45), songs: songs) ≈ .land(itemID: "a", at: 45))
    }

    @Test func jumpsBothWaysLand() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600 + 30), songs: songs)

        #expect(follow.step(live(3600 + 50), songs: songs) ≈ .land(itemID: "a", at: 50))

        #expect(follow.step(live(3600 + 19), songs: songs) ≈ .land(itemID: "a", at: 19))

        #expect(follow.step(live(3600 + 0.05), songs: songs)?.itemID == "a")
        if case .land? = follow.step(live(3600 + 0.05), songs: songs) { Issue.record("a restart lands") }
    }

    @Test func playbacksResumeStepBackIsIgnored() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600 + 30), songs: songs)

        #expect(follow.step(live(3600 + 30 - 2.0 / 30), songs: songs) == nil)

        let step = follow.step(live(3600 + 30 + 1.0 / 30), songs: songs)
        guard case .play(_, let from, _) = step else { Issue.record("\(String(describing: step))"); return }
        #expect(from == 30)

        #expect(follow.step(live(3600 + 30 - 3.0 / 30), songs: songs) ≈ .land(itemID: "a", at: 30 - 3.0 / 30))
    }

    @Test func silenceFreewheelAndRewindHold() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600 + 30), songs: songs)
        for state in [TimecodeClock.State.freewheel, .stopped, .locking, .noInput] {
            #expect(follow.step(TimecodeClock.Reading(state: state, position: 3600 + 31, rate: .fps30), songs: songs) == nil)
        }
        #expect(follow.step(TimecodeClock.Reading(state: .locked, position: 3600 + 20, rate: .fps30, reverse: true), songs: songs) == nil)

        #expect(follow.step(live(3600 + 20), songs: songs) ≈ .land(itemID: "a", at: 20))
    }

    @Test func aDropoutCatchesUpOnReturn() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600 + 30), songs: songs)

        #expect(follow.step(live(3600 + 30.4), songs: songs) ≈ .play(itemID: "a", from: 30, to: 30.4))
    }

    @Test func outsideEveryWindowHoldsThenTheNextSongEnters() {
        var follow = TimecodeFollow()
        _ = follow.step(live(3600 + 100), songs: songs)
        #expect(follow.step(live(3600 + 130), songs: songs) == nil)
        #expect(follow.step(live(7200 + 0.2), songs: songs) ≈ .play(itemID: "b", from: -PresentationTimelines.frame, to: 0.2))

        #expect(follow.step(live(10800 + 61), songs: songs) ≈ .land(itemID: "c", at: 61))
    }

    @Test func noSongsNoCommands() {
        var follow = TimecodeFollow()
        #expect(follow.step(live(3600 + 10), songs: []) == nil)
    }
}

@Suite struct TimecodeRulesTableTests {
    private let blocks = [
        TimelinePlayedBlock(sectionId: "v", slideIds: ["v1", "v2"]),
        TimelinePlayedBlock(sectionId: "c", slideIds: ["c1"]),
    ]

    private var cues: [TimelineCue] {
        [
            TimelineCue(id: "s0", lane: "slide", at: 0, sectionId: "v", sectionOccurrence: 0, slideId: "v1"),
            TimelineCue(id: "s1", lane: "slide", at: 10, sectionId: "v", sectionOccurrence: 0, slideId: "v2"),
            TimelineCue(id: "s2", lane: "slide", at: 20, sectionId: "c", sectionOccurrence: 0, slideId: "c1"),
            TimelineCue(id: "bg", lane: "loopingVideos", at: 0, mediaId: "loop"),
            TimelineCue(id: "ov", lane: "overlays", at: 5, duration: 10, overlayId: "lower"),
            TimelineCue(id: "act", lane: "actions", at: 12),
            TimelineCue(id: "track", lane: "audio", at: 0, duration: 30, mediaId: "stems"),
        ]
    }

    private func effects(_ command: TimecodeFollow.Command, live: PresentationTimelines.Live = []) -> [PresentationTimelines.Effect] {
        let effects = switch command {
        case .play(_, let from, let to):
            PresentationTimelines.crossing(cues, blocks: blocks, from: from, to: to, live: live)
        case .land(_, let at):
            PresentationTimelines.landing(cues, blocks: blocks, at: at, live: live)
        }
        return TimecodeFollow.underTimecode(effects)
    }

    @Test func playingThroughFiresEverythingInTime() {
        let songs = [TimecodeFollow.Song(itemID: "a", startFrames: 108_000, length: 30)]
        var follow = TimecodeFollow()
        var fired: [PresentationTimelines.Effect] = []
        var live = PresentationTimelines.Live()

        for frame in 3...(16 * 30) {
            let reading = TimecodeClock.Reading(state: .locked, position: 3600 + Double(frame) / 30, rate: .fps30)
            guard let command = follow.step(reading, songs: songs) else { continue }
            let step = effects(command, live: live)
            for case .fire(_, let id) in step { live.insert(id) }
            fired += step
        }
        #expect(fired == [
            .fire(lane: .loopingVideos, id: "loop"),
            .showSlide(occurrence: 0, actions: true),
            .fire(lane: .overlays, id: "lower"),
            .showSlide(occurrence: 1, actions: true),
            .runActions(cueId: "act"),

            .clear(lane: .overlays, id: "lower"),
        ])
    }

    @Test func aJumpShowsTheSlideWithoutActionsAndRunsNoActions() {
        let landed = effects(.land(itemID: "a", at: 13), live: ["loop"])

        #expect(landed == [.showSlide(occurrence: 1, actions: false), .fire(lane: .overlays, id: "lower")])
    }

    @Test func theBackingTrackNeverChasesTimecode() {
        let raw = PresentationTimelines.landing(cues, blocks: blocks, at: 13, live: [])
        #expect(raw.contains { if case .playAudio = $0 { true } else { false } })
        let followed = TimecodeFollow.underTimecode(raw + [.clear(lane: .audio, id: "stems")])
        #expect(followed == raw.filter { if case .playAudio = $0 { false } else { true } })
        #expect(followed.contains(.showSlide(occurrence: 1, actions: false)))
    }

    @Test func timecodeCanPlayTheAudioLane() {
        let raw = PresentationTimelines.landing(cues, blocks: blocks, at: 13, live: [])
        #expect(TimecodeFollow.underTimecode(raw, playsAudio: true) == raw)
        let track = TimelineCue(id: "t", lane: TimelineLane.audio.rawValue, at: 2, duration: 100, mediaId: "track")

        #expect(TimecodeFollow.audioSync([track], at: 12, playing: [:]) == [.playAudio(id: "track", from: 10)])

        #expect(TimecodeFollow.audioSync([track], at: 12, playing: ["track": 9.7]).isEmpty)

        #expect(TimecodeFollow.audioSync([track], at: 12, playing: ["track": 8]) == [.playAudio(id: "track", from: 10)])

        #expect(TimecodeFollow.audioSync([track], at: 150, playing: ["track": 140]) == [.clear(lane: .audio, id: "track")])
    }
}
