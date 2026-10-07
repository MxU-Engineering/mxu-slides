import Testing
@testable import AudioEngine

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let tracks = ["a", "b", "c"]

@Suite("PlaylistQueue order semantics")
struct PlaylistQueueTests {
    @Test func playAllStopsAtTheEnd() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none)
        queue.start()
        #expect(queue.currentEntryID == "a")
        #expect(queue.advanceAfterNaturalEnd() == "b")
        #expect(queue.advanceAfterNaturalEnd() == "c")
        #expect(queue.advanceAfterNaturalEnd() == nil)

        queue.start()
        #expect(queue.currentEntryID == "a")
    }

    @Test func loopPlaylistWraps() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .playlist)
        queue.start()
        #expect(queue.advanceAfterNaturalEnd() == "b")
        #expect(queue.advanceAfterNaturalEnd() == "c")
        #expect(queue.advanceAfterNaturalEnd() == "a")
    }

    @Test func loopSingleRepeatsOnNaturalEndButNextAdvances() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .single)
        queue.start()
        #expect(queue.advanceAfterNaturalEnd() == "a")
        #expect(queue.advanceAfterNaturalEnd() == "a")

        #expect(queue.next() == "b")
        #expect(queue.advanceAfterNaturalEnd() == "b")
    }

    @Test func explicitNextAtEndStopsWhenRepeatOff() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none)
        queue.start()
        _ = queue.next()
        _ = queue.next()
        #expect(queue.currentEntryID == "c")
        #expect(queue.next() == nil)
    }

    @Test func previousStepsBackAndClampsWithoutRepeat() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none)
        queue.start()
        _ = queue.next()
        #expect(queue.previous() == "a")
        #expect(queue.previous() == "a")
    }

    @Test func previousWrapsUnderRepeat() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .playlist)
        queue.start()
        #expect(queue.previous() == "c")
    }

    @Test func shufflePlaysEveryTrackOncePerPass() {
        var rng = SplitMix64(state: 7)
        var queue = PlaylistQueue(
            entryIDs: ["a", "b", "c", "d", "e"], repeatBehavior: .playlist, shuffled: true
        )
        queue.start(using: &rng)
        var pass: Set<String> = [queue.currentEntryID!]
        for _ in 0 ..< 4 {
            pass.insert(queue.advanceAfterNaturalEnd(using: &rng)!)
        }

        #expect(pass == Set(["a", "b", "c", "d", "e"]))
    }

    @Test func shuffleWrapReshuffles() {
        var rng = SplitMix64(state: 42)
        var queue = PlaylistQueue(
            entryIDs: tracks, repeatBehavior: .playlist, shuffled: true
        )
        queue.start(using: &rng)
        var firstPass: [String] = [queue.currentEntryID!]
        for _ in 0 ..< 2 { firstPass.append(queue.advanceAfterNaturalEnd(using: &rng)!) }
        var secondPass: [String] = []
        for _ in 0 ..< 3 { secondPass.append(queue.advanceAfterNaturalEnd(using: &rng)!) }
        #expect(Set(firstPass) == Set(tracks))
        #expect(Set(secondPass) == Set(tracks))
    }

    @Test func shuffleStartAtChosenTrackLeadsThePass() {
        var rng = SplitMix64(state: 1)
        var queue = PlaylistQueue(
            entryIDs: tracks, repeatBehavior: .playlist, shuffled: true
        )
        queue.start(at: "b", using: &rng)
        #expect(queue.currentEntryID == "b")
    }

    @Test func shuffleWithRepeatOffStopsAfterOnePass() {
        var rng = SplitMix64(state: 3)
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none, shuffled: true)
        queue.start(using: &rng)
        var played: [String] = [queue.currentEntryID!]
        while let id = queue.advanceAfterNaturalEnd(using: &rng) { played.append(id) }
        #expect(played.count == 3)
        #expect(Set(played) == Set(tracks))
    }

    @Test func toggleShuffleOnKeepsCurrentTrackLeading() {
        var rng = SplitMix64(state: 9)
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .playlist)
        queue.start()
        _ = queue.next()
        #expect(queue.currentEntryID == "b")
        queue.setShuffled(true, using: &rng)
        #expect(queue.currentEntryID == "b")

        let rest = [
            queue.advanceAfterNaturalEnd(using: &rng)!,
            queue.advanceAfterNaturalEnd(using: &rng)!,
        ]
        #expect(Set(rest) == Set(["a", "c"]))
    }

    @Test func toggleShuffleOffRestoresListOrder() {
        var rng = SplitMix64(state: 11)
        var queue = PlaylistQueue(
            entryIDs: tracks, repeatBehavior: .playlist, shuffled: true
        )
        queue.start(at: "b", using: &rng)
        queue.setShuffled(false, using: &rng)
        #expect(queue.currentEntryID == "b")
        #expect(queue.advanceAfterNaturalEnd(using: &rng) == "c")
    }

    @Test func updateEntriesKeepsCurrentAndAppendsNew() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none)
        queue.start()
        _ = queue.next()
        #expect(queue.currentEntryID == "b")
        queue.updateEntries(["a", "b", "c", "d"])
        #expect(queue.currentEntryID == "b")
        #expect(queue.advanceAfterNaturalEnd() == "c")
        #expect(queue.advanceAfterNaturalEnd() == "d")
    }

    @Test func updateEntriesRemovingCurrentParksTheQueue() {
        var queue = PlaylistQueue(entryIDs: tracks, repeatBehavior: .none)
        queue.start()
        _ = queue.next()
        queue.updateEntries(["a", "c"])
        #expect(queue.currentEntryID == nil)
    }

    @Test func emptyQueueAnswersNilEverywhere() {
        var queue = PlaylistQueue(entryIDs: [], repeatBehavior: .playlist, shuffled: true)
        queue.start()
        #expect(queue.currentEntryID == nil)
        #expect(queue.next() == nil)
        #expect(queue.previous() == nil)
        #expect(queue.advanceAfterNaturalEnd() == nil)
    }

    @Test func duplicateTracksAreDistinctPlays() {
        var queue = PlaylistQueue(entryIDs: ["a", "b", "a"], repeatBehavior: .none)
        queue.start()
        #expect(queue.advanceAfterNaturalEnd() == "b")
        #expect(queue.advanceAfterNaturalEnd() == "a")
        #expect(queue.advanceAfterNaturalEnd() == nil)
    }
}

extension PlaylistQueueTests {
    @Test func shuffleWrapNeverPlaysTheSameEntryBackToBack() {
        var rng = SplitMix64(state: 5)
        var queue = PlaylistQueue(
            entryIDs: tracks, repeatBehavior: .playlist, shuffled: true
        )
        queue.start(using: &rng)
        var previous = queue.currentEntryID

        for _ in 0 ..< 60 {
            let next = queue.advanceAfterNaturalEnd(using: &rng)
            #expect(next != previous, "no back-to-back repeat across a shuffle wrap")
            previous = next
        }
    }

    @Test func positionInPassAdvancesEvenAcrossDuplicateTracks() {
        var queue = PlaylistQueue(entryIDs: ["s", "h", "s"], repeatBehavior: .playlist)
        queue.start()
        #expect(queue.positionInPass! == (1, 3))
        _ = queue.next()
        #expect(queue.positionInPass! == (2, 3))
        _ = queue.next()
        #expect(queue.positionInPass! == (3, 3))
    }
}

@Suite("CrossfadeCurve — the radio-segue shape (ADR-007)")
struct CrossfadeCurveTests {
    @Test func endpointsAreCleanHandoffs() {
        let start = CrossfadeCurve.gains(at: 0)
        let end = CrossfadeCurve.gains(at: 1)
        #expect(start.incoming == 0 && abs(start.outgoing - 1) < 0.001)
        #expect(abs(end.incoming - 1) < 0.001 && end.outgoing == 0)
    }

    @Test func outgoingRecedesAudiblyEarly() {

        let quarter = CrossfadeCurve.gains(at: 0.25)
        #expect(quarter.outgoing < 0.65)

        #expect(quarter.incoming < 0.2)
    }

    @Test func combinedLevelNeverExceedsOneSong() {

        for step in 0 ... 100 {
            let gains = CrossfadeCurve.gains(at: Double(step) / 100)
            let power = gains.incoming * gains.incoming + gains.outgoing * gains.outgoing
            #expect(power <= 1.001)
            #expect(power >= 0.32, "dip stays gentler than ~-5dB")
        }
    }

    @Test func bothSidesAreMonotonic() {
        var previous = CrossfadeCurve.gains(at: 0)
        for step in 1 ... 100 {
            let gains = CrossfadeCurve.gains(at: Double(step) / 100)
            #expect(gains.incoming >= previous.incoming)
            #expect(gains.outgoing <= previous.outgoing)
            previous = gains
        }
    }
}
