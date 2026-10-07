import Foundation
import Testing

@testable import PresenterCore

@Suite struct BodyStormMeterTests {
    private let timeline = 0
    private let sidebar = 1

    private func drive(
        _ meter: inout BodyStormMeter, view: Int, rate: Double, from start: Double, seconds: Double
    ) -> [(at: Double, storm: BodyStormMeter.Storm)] {
        var storms: [(Double, BodyStormMeter.Storm)] = []
        for step in 0..<Int(seconds * rate) {
            let time = start + Double(step) / rate
            if let storm = meter.tick(view, now: time) { storms.append((time, storm)) }
        }
        return storms
    }

    @Test func thePlayheadStormIsReportedOnceAfterTwoSeconds() {
        var meter = BodyStormMeter(limits: [20, 20])
        let storms = drive(&meter, view: timeline, rate: 30, from: 10.0, seconds: 5)
        #expect(storms.count == 1, "one line per run: \(storms)")
        let first = try! #require(storms.first)
        #expect(first.storm.view == timeline)
        #expect(first.storm.perSecond == 30)
        #expect(first.storm.seconds == 2)
        #expect(first.at >= 12 && first.at < 12.1, "reported as the second whole second closes")
    }

    @Test func aBurstUnderTwoSecondsIsNotAStorm() {
        var meter = BodyStormMeter(limits: [20, 20])

        #expect(drive(&meter, view: sidebar, rate: 25, from: 3.0, seconds: 1).isEmpty)
        #expect(drive(&meter, view: sidebar, rate: 2, from: 4.0, seconds: 3).isEmpty)

        #expect(drive(&meter, view: timeline, rate: 20, from: 7.0, seconds: 6).isEmpty)
    }

    @Test func aQuietGapEndsTheRunAndANewRunReportsAgain() {
        var meter = BodyStormMeter(limits: [20, 20])
        #expect(drive(&meter, view: timeline, rate: 40, from: 0, seconds: 4).count == 1)

        #expect(drive(&meter, view: timeline, rate: 40, from: 7, seconds: 4).count == 1)
    }

    @Test func eachViewHasItsOwnLimit() {
        var meter = BodyStormMeter(limits: [20, 70])
        var storms: [BodyStormMeter.Storm] = []

        for step in 0..<240 {
            let time = Double(step) / 60
            if let storm = meter.tick(timeline, now: time) { storms.append(storm) }
            if let storm = meter.tick(sidebar, now: time) { storms.append(storm) }
        }
        #expect(storms.map(\.view) == [timeline])
    }

    @Test func aMarkCountsEveryEvaluationSinceTheLast() {
        var meter = BodyStormMeter(limits: [20, 20])
        _ = drive(&meter, view: timeline, rate: 30, from: 0, seconds: 2)
        _ = drive(&meter, view: sidebar, rate: 4, from: 2, seconds: 0.5)
        #expect(meter.drainMark(names: ["timeline", "sidebar"]) == "bodies timeline 60 sidebar 2")
        #expect(meter.drainMark(names: ["timeline", "sidebar"]) == "bodies none")
    }

    @Test func thePulseNamesEachViewsPeakRate() {
        var meter = BodyStormMeter(limits: [20, 20])
        _ = drive(&meter, view: timeline, rate: 30, from: 0, seconds: 3)
        _ = drive(&meter, view: sidebar, rate: 5, from: 3, seconds: 2)

        #expect(meter.drainPulse(names: ["timeline", "sidebar"]) == "bodies peak/s timeline 30 sidebar 5")
        #expect(meter.drainPulse(names: ["timeline", "sidebar"]) == "bodies peak/s none")
    }
}
