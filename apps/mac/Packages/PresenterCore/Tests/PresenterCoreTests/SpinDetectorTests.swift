import Foundation
import Testing

@testable import PresenterCore

@Suite struct SpinDetectorTests {

    private func run(
        _ detector: inout SpinDetector, from start: Double, to end: Double,
        pass: Double, gap: Double, inputs: [Double] = []
    ) -> [(at: Double, event: SpinDetector.Event)] {
        var events: [(Double, SpinDetector.Event)] = []
        var time = start
        var nextAsk = start
        var pending = inputs.sorted()
        while time < end {
            while let input = pending.first, input <= time {
                detector.input(at: input)
                pending.removeFirst()
            }
            detector.passBegan(at: time)
            time += pass
            detector.passEnded(at: time)
            time += gap
            while nextAsk <= time {
                if let event = detector.evaluate(at: nextAsk) { events.append((nextAsk, event)) }
                nextAsk += 0.1
            }
        }
        return events
    }

    @Test func aLayoutLoopWithNoInputIsASpin() {
        var detector = SpinDetector()

        let events = run(&detector, from: 100, to: 104, pass: 0.004, gap: 0.0005)
        let began = events.first
        guard case .began(let spin, let dropped)? = began?.event else {
            Issue.record("no spin reported: \(events)")
            return
        }

        #expect(began!.at > 102.6 && began!.at < 103.1, "reported once the window filled: \(began!.at)")
        #expect(spin.share >= SpinDetector.busyShare && spin.share <= 1)
        #expect(dropped == 0)
        #expect(spin.detail.hasPrefix("main busy 8") || spin.detail.hasPrefix("main busy 9"))
        #expect(spin.detail.hasSuffix("no input for launch"))
        #expect(events.count == 1, "one spin, reported once while it runs")
        #expect(detector.isSpinning)
    }

    @Test func inputInsideTheWindowIsNotASpin() {
        var detector = SpinDetector()

        let drags = stride(from: 100.0, to: 106, by: 1.0 / 60).map { $0 }
        let events = run(&detector, from: 100, to: 106, pass: 0.014, gap: 0.002, inputs: drags)
        #expect(events.isEmpty)

        var later = SpinDetector()
        let quietAfter = run(&later, from: 100, to: 107, pass: 0.014, gap: 0.002, inputs: [100.5])
        guard case .began(let spin, _)? = quietAfter.first?.event else {
            Issue.record("no spin 3 s after the last input: \(quietAfter)")
            return
        }
        #expect(quietAfter.first!.at >= 103.5)
        #expect(spin.quietFor >= 3)
    }

    @Test func steadyWorkBelowTheLineIsNotASpin() {
        var detector = SpinDetector()

        #expect(run(&detector, from: 0, to: 10, pass: 0.004, gap: 0.03).isEmpty)

        var busier = SpinDetector()
        #expect(run(&busier, from: 0, to: 10, pass: 0.007, gap: 0.003).isEmpty)
    }

    @Test func onePassThatNeverEndsIsASpinWhileItRuns() {
        var detector = SpinDetector()
        detector.passBegan(at: 50)
        #expect(detector.evaluate(at: 52) == nil)
        guard case .began(let spin, _)? = detector.evaluate(at: 53.05) else {
            Issue.record("a 3 s pass still running is a spin")
            return
        }
        #expect(spin.share == 1)
        #expect(abs(spin.since - 50.05) < 0.001)
    }

    @Test func aSpinEndsWhenTheLoadDropsAndSaysHowLongItRan() {
        var detector = SpinDetector()
        _ = run(&detector, from: 0, to: 20, pass: 0.009, gap: 0.001)
        #expect(detector.isSpinning)

        var ended: SpinDetector.Spin?
        var time = 20.0
        while ended == nil, time < 25 {
            time += 0.1
            if case .ended(let spin)? = detector.evaluate(at: time) { ended = spin }
        }
        let spin = try! #require(ended)

        #expect(spin.lasted > 20 && spin.lasted < 22.5, "from the window's start to the drop: \(spin.lasted)")
        #expect(spin.peakShare > 0.85)
        #expect(spin.endDetail.hasPrefix("lasted "))
        #expect(!detector.isSpinning)
    }

    @Test func spinsAreRateLimited() {
        var detector = SpinDetector()
        var began = 0
        var dropped: [Int] = []

        var start = 0.0
        while start < 120 {
            for (_, event) in run(&detector, from: start, to: start + 4, pass: 0.009, gap: 0.001) {
                if case .began(_, let skipped) = event { began += 1; dropped.append(skipped) }
            }
            for step in 1...40 { _ = detector.evaluate(at: start + 4 + Double(step) * 0.1) }
            start += 8
        }
        #expect(began <= 2 * SpinDetector.spinsPerMinute + 1, "at most \(SpinDetector.spinsPerMinute) a minute (\(began))")
        #expect(dropped.contains { $0 > 0 }, "a line after a dropped one says how many went missing")
    }
}
