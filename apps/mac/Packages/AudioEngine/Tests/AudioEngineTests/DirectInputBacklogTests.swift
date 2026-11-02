import Testing

@testable import AudioEngine

@Test func aWindowSumsTheDriversViewAndReportsWhenItCloses() {
    var backlog = DirectInputBacklog()
    _ = backlog.record(
        audioMinusVideo: 0, queuedAudioFrames: 1_600, queuedVideoFrames: 1,
        stampAge: 0.008, droppedPictures: 4, at: 0)
    _ = backlog.record(
        audioMinusVideo: -0.002, queuedAudioFrames: 4_800, queuedVideoFrames: 0,
        stampAge: 1.2, droppedPictures: 6, at: 5)
    #expect(backlog.last == nil, "nothing to report until the window closes")
    _ = backlog.record(
        audioMinusVideo: nil, queuedAudioFrames: nil, queuedVideoFrames: nil,
        stampAge: nil, droppedPictures: 6, at: 10)
    let window = try! #require(backlog.last)
    #expect(window.offsetLow == -0.002)
    #expect(window.offsetHigh == 0)
    #expect(window.queuedAudioFrames == 4_800)
    #expect(window.queuedVideoFrames == 1)
    #expect(window.stampAge == 1.2)
    #expect(window.staleStamps == 1)
    #expect(window.droppedPictures == 2, "drops are counted per window")
    #expect(window.summary == "cardAV=-0.002..+0.000s queued=a100ms/v1 stampAge=1200ms stale=1 drops=2")
}

@Test func anOffsetMoveOfATenthOfASecondIsNoted() {
    var backlog = DirectInputBacklog()
    #expect(backlog.record(
        audioMinusVideo: 0, queuedAudioFrames: nil, queuedVideoFrames: nil,
        stampAge: nil, droppedPictures: 0, at: 0) == nil)
    #expect(backlog.record(
        audioMinusVideo: -0.05, queuedAudioFrames: nil, queuedVideoFrames: nil,
        stampAge: nil, droppedPictures: 0, at: 1) == nil, "jitter under 0.1 s stays quiet")
    let jump = backlog.record(
        audioMinusVideo: -2.5, queuedAudioFrames: nil, queuedVideoFrames: nil,
        stampAge: nil, droppedPictures: 0, at: 2)
    #expect(jump?.from == 0)
    #expect(jump?.to == -2.5)
    #expect(backlog.record(
        audioMinusVideo: -2.45, queuedAudioFrames: nil, queuedVideoFrames: nil,
        stampAge: nil, droppedPictures: 0, at: 3) == nil, "measured from the new offset")
}

@Test func aWindowWithoutOffsetsLeavesThemOutOfTheSummary() {
    var window = DirectInputBacklog.Window()
    window.queuedVideoFrames = 2
    #expect(window.summary == "queued=a0ms/v2 stampAge=0ms stale=0 drops=0")
}
