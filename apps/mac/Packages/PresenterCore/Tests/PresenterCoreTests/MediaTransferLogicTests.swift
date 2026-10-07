import Foundation
import Testing
@testable import PresenterCore

@Suite struct MediaTransferLogicTests {
    @Test func downloadFirstMovesTheAskedKeysToTheFrontInTheOrderAsked() {
        let queue = ["down:a", "up:b", "down:c", "down:d"]
        #expect(MediaTransferLogic.prioritized(queue, first: ["down:d", "down:c"]) == ["down:d", "down:c", "down:a", "up:b"])
        #expect(MediaTransferLogic.prioritized(queue, first: ["down:zz"]) == queue, "a key not queued changes nothing")
        #expect(MediaTransferLogic.prioritized(queue, first: ["down:c", "down:c"]) == ["down:c", "down:a", "up:b", "down:d"], "asked twice moves once")
    }

    @Test func theRateSmoothsSamplesAndWaitsOutBursts() {
        var rate = MediaTransferLogic.Rate()
        rate.record(movedBytes: 0, at: 10)
        #expect(rate.bytesPerSecond == nil, "one reading is not a rate")
        rate.record(movedBytes: 1_000, at: 11)
        #expect(rate.bytesPerSecond == 1_000)
        rate.record(movedBytes: 1_500, at: 11.2)
        #expect(rate.bytesPerSecond == 1_000, "a callback 0.2 s later waits for the next sample")
        rate.record(movedBytes: 3_000, at: 12)
        #expect(abs((rate.bytesPerSecond ?? 0) - 1_300) < 0.001, "2000 B/s blended 30/70 into 1000")
        rate.reset()
        #expect(rate.bytesPerSecond == nil)
    }

    @Test func timeLeftNeedsAMovingRate() {
        #expect(MediaTransferLogic.secondsLeft(remainingBytes: 10_000, bytesPerSecond: 1_000) == 10)
        #expect(MediaTransferLogic.secondsLeft(remainingBytes: 10_000, bytesPerSecond: nil) == nil)
        #expect(MediaTransferLogic.secondsLeft(remainingBytes: 10_000, bytesPerSecond: 0) == nil, "stalled")
    }

    @Test func labelsReadTheWayAnOperatorSaysThem() {
        #expect(MediaTransferLogic.timeLeftLabel(20) == "less than a minute")
        #expect(MediaTransferLogic.timeLeftLabel(250) == "about 4 min")
        #expect(MediaTransferLogic.timeLeftLabel(3_600) == "about 1 h")
        #expect(MediaTransferLogic.timeLeftLabel(4_200) == "about 1 h 10 min")
        #expect(["next", "2nd", "3rd", "4th", "11th", "12th", "21st", "22nd", "113th"]
            == [1, 2, 3, 4, 11, 12, 21, 22, 113].map(MediaTransferLogic.placeLabel))
        #expect(MediaTransferLogic.sizeLabel(180_000_000) == "180 MB")
    }
}
