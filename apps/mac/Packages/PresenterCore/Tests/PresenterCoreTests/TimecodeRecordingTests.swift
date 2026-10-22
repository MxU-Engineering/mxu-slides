import Foundation
import Testing
@testable import PresenterCore

@Suite struct TimecodeRecordingTests {
    private func timeline(enabled: Bool, start: Int = 108_000) -> PresentationTimeline {
        PresentationTimeline(id: "t", timecodeEnabled: enabled, timecodeStart: start, cues: [])
    }

    private func reading(
        _ seconds: Double, state: TimecodeClock.State = .locked, rate: TimecodeRate = .fps30, reverse: Bool = false
    ) -> TimecodeClock.Reading {
        TimecodeClock.Reading(
            state: state, position: seconds, label: rate.label(seconds: seconds), rate: rate, reverse: reverse)
    }

    @Test func recordArmsForTimecodeOnlyOnAFollowingMac() {

        #expect(TimecodeRecording.mode(timeline: timeline(enabled: true), hasInput: true, follows: true) == .timecode(start: 108_000))
        #expect(TimecodeRecording.mode(timeline: nil, hasInput: true, follows: true) == .timecode(start: nil))

        #expect(TimecodeRecording.mode(timeline: timeline(enabled: false), hasInput: true, follows: true) == .ownClock)

        #expect(TimecodeRecording.mode(timeline: nil, hasInput: false, follows: true) == .ownClock)
        #expect(TimecodeRecording.mode(timeline: timeline(enabled: true), hasInput: true, follows: false) == .ownClock)
    }

    @Test func aNewSongStartsAtTheTimecodesHourAndMinute() {

        let take = TimecodeRecording(itemID: "a", start: nil)
        let at = 3600 + 600 + 42 + 17.0 / 30
        guard case .begin(let start, let position) = take.step(reading(at)) else {
            Issue.record("expected the take to begin")
            return
        }
        #expect(start == 126_000)
        #expect(abs(position - (42 + 17.0 / 30)) < 1e-9)
        #expect(TimecodeRecording.start(from: TimecodeLabel(hours: 2, minutes: 0, seconds: 59, frames: 29)) == 216_000)
    }

    @Test func aTakeWaitsForTheSongsStart() {
        let take = TimecodeRecording(itemID: "a", start: 108_000)

        #expect(take.step(reading(3599)) == .none)
        #expect(take.step(reading(3599, state: .stopped)) == .none)
        #expect(take.step(TimecodeClock.Reading(state: .noInput)) == .none)

        #expect(take.step(reading(3602.5)) == .begin(start: 108_000, at: 2.5))

        #expect(take.step(reading(3602.5, rate: .fps25)) == .begin(start: 108_000, at: 2.5))
    }

    @Test func aRunningTakeEndsWhenTimecodeStopsOnly() {
        var take = TimecodeRecording(itemID: "a", start: 108_000)
        take.started = true
        #expect(take.step(reading(3610)) == .none)

        #expect(take.step(reading(3610, state: .freewheel)) == .none)
        #expect(take.step(reading(3610, reverse: true)) == .none)

        #expect(take.step(reading(3610, state: .stopped)) == .end)
        #expect(take.step(TimecodeClock.Reading(state: .noInput)) == .end)
    }

    @Test func whileRecordingTimecodeFollowsOnlyThatSongWithNoEnd() throws {
        let take = TimecodeRecording(itemID: "b", start: 126_000)
        let songs = [
            TimecodeFollow.Song(itemID: "a", startFrames: 108_000, length: 30),
            TimecodeFollow.Song(itemID: "b", startFrames: 126_000, length: 1, tail: 1),
        ]
        let followed = take.songs(songs)
        #expect(followed.map(\.itemID) == ["b"])

        let found = try #require(TimecodeFollow.song(containing: 4200 + 600, rate: .fps30, in: followed))
        #expect(found.song.itemID == "b")
        #expect(abs(found.position - 600) < 1e-9)

        #expect(TimecodeFollow.song(containing: 3605, rate: .fps30, in: followed) == nil)
    }
}
