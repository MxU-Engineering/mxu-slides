import Testing

@testable import AudioEngine

private func openInput(at time: Double = 10) -> DirectInputLiveness {
    var liveness = DirectInputLiveness()
    liveness.running = true
    liveness.opened(at: time)
    return liveness
}

@Test func aQuietOpenReopensAfterThreeSeconds() {
    var liveness = openInput()
    #expect(!liveness.shouldReopen(at: 12.9))
    #expect(liveness.shouldReopen(at: 13.1))
    liveness.arrived(at: 13)
    #expect(!liveness.shouldReopen(at: 15.9), "an arrival restarts the watch")
}

@Test func onlyAGoodOpenIsWatched() {
    var liveness = openInput()
    liveness.opening()
    #expect(!liveness.shouldReopen(at: 100), "an unanswered open is not silence")
    var stopped = openInput()
    stopped.stopped()
    #expect(!stopped.shouldReopen(at: 100))
}

@Test func failuresRetryAndNoteEachMessageOnce() {
    var liveness = openInput()
    #expect(liveness.failed("device not found", current: true) == .retry(note: true))
    #expect(liveness.failed("device not found", current: true) == .ignore, "one retry at a time")
    #expect(!liveness.shouldReopen(at: 100), "a queued retry is not reopened twice")
    liveness.retrying()
    #expect(liveness.failed("device not found", current: true) == .retry(note: false))
    liveness.retrying()
    #expect(liveness.failed("in use by another app", current: true) == .retry(note: true))
    liveness.retrying()
    liveness.opened(at: 50)
    #expect(liveness.lastError == nil)
    #expect(liveness.failed("device not found", current: true) == .retry(note: true), "a fresh episode notes again")
}

@Test func staleOrStoppedFailuresAreIgnored() {
    var liveness = openInput()
    #expect(liveness.failed("helper unreachable", current: false) == .ignore)
    liveness.stopped()
    #expect(liveness.failed("helper unreachable", current: true) == .ignore)
}
