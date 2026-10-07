import Foundation
import Testing

@testable import PresenterCore

@Suite struct PerfLineLimiterTests {
    @Test func admitsThePerMinuteBudgetPerKindThenCountsWhatItDrops() {
        var limiter = PerfLineLimiter(perMinute: 3)
        for second in 0..<3 { #expect(limiter.admit("storm", now: Double(second)) == 0) }
        #expect(limiter.admit("storm", now: 10) == nil)
        #expect(limiter.admit("storm", now: 20) == nil)

        #expect(limiter.admit("slowOpen", now: 20) == 0)

        #expect(limiter.admit("storm", now: 60) == 2)
        #expect(limiter.admit("storm", now: 61) == 0)
    }

    @Test func annotatesOnlyWhenLinesWereDropped() {
        #expect(PerfLineLimiter.annotate("x", dropped: 0) == "x")
        #expect(PerfLineLimiter.annotate("x", dropped: 4) == "x (+4 dropped)")
    }

    @Test func runLoopModesPrintShort() {
        #expect(RunLoopModeName.short("kCFRunLoopDefaultMode") == "default")
        #expect(RunLoopModeName.short("NSEventTrackingRunLoopMode") == "tracking")
        #expect(RunLoopModeName.short("NSModalPanelRunLoopMode") == "modal")
        #expect(RunLoopModeName.short(nil) == "none")
        #expect(RunLoopModeName.short("com.example.custom") == "com.example.custom")
    }
}

@Suite struct MainPassMeterTests {
    private func opens(_ kinds: [(String, Int)], msEach: Int) -> MainPassOpens {
        var tally = MainPassOpens()
        for (kind, count) in kinds {
            for _ in 0..<count { tally.record(.milliseconds(msEach), kind: kind) }
        }
        return tally
    }

    @Test func bucketsCountEveryPassOverEachLineAndThePulseStartsOver() {
        var meter = MainPassMeter()
        for ms in [5.0, 17, 60, 120, 300] {
            _ = meter.finish(ms: ms, opens: MainPassOpens(), sqlStatements: 0, now: 0)
        }
        #expect(meter.over == [4, 3, 2, 1])
        #expect(meter.drainPulse() == "passes >16:4 >50:3 >100:2 >250:1")
        #expect(meter.drainPulse() == "passes >16:0 >50:0 >100:0 >250:0")
    }

    @Test func aPassOf100msOrMoreEarnsALineNamingItsOpensAndStatements() {
        var meter = MainPassMeter()
        #expect(meter.finish(ms: 99, opens: MainPassOpens(), sqlStatements: 1, now: 0) == nil)
        let long = meter.finish(
            ms: 143, opens: opens([("media", 12), ("presentations", 1)], msEach: 2), sqlStatements: 4, now: 1
        )
        #expect(long?.detail(mode: "default") == "default 143 ms, opens media×12 presentations×1 26.0 ms, sql 4")
        let quiet = meter.finish(ms: 250, opens: MainPassOpens(), sqlStatements: 0, now: 2)
        #expect(quiet?.detail(mode: "tracking") == "tracking 250 ms, opens none, sql 0")
    }

    @Test func atMostTwentyPassLinesAMinute() {
        var meter = MainPassMeter()
        let lines = (0..<25).compactMap { index in
            meter.finish(ms: 120, opens: MainPassOpens(), sqlStatements: 0, now: Double(index))
        }
        #expect(lines.count == MainPassMeter.linesPerMinute)

        #expect(meter.over[2] == 25)
        let next = meter.finish(ms: 120, opens: MainPassOpens(), sqlStatements: 0, now: 61)
        #expect(next?.detail(mode: "default").hasSuffix("(+5 dropped)") == true)
    }
}

@Suite struct HitchStackLineTests {
    private func frame(_ index: Int, app: Bool) -> StackFrame {
        StackFrame(
            address: UInt(0x1000 + index), image: app ? "MxU Slides" : "SwiftUI",
            imageBase: app ? 0x1000 : 0x9000, symbol: "f\(index)", symbolStart: UInt(0x1000 + index)
        )
    }

    @Test func keepsTheLeafEightThenTheFirstEightAppFramesPastThem() {

        let appIndices: Set<Int> = Set([3, 35]).union(20...29)
        let frames = (0..<40).map { frame($0, app: appIndices.contains($0)) }
        let chosen = HitchStackLine.chosen(frames, isApp: { $0.image == "MxU Slides" })
        #expect(chosen == [
            "f0+0", "f1+0", "f2+0", "f3+0", "f4+0", "f5+0", "f6+0", "f7+0",
            "…",
            "f20+0", "f21+0", "f22+0", "f23+0", "f24+0", "f25+0", "f26+0", "f27+0",
            "…",
        ])
    }

    @Test func aShortStackPrintsWholeWithoutMarkers() {
        let frames = (0..<5).map { frame($0, app: $0 == 4) }
        #expect(HitchStackLine.chosen(frames, isApp: { $0.image == "MxU Slides" })
            == ["f0+0", "f1+0", "f2+0", "f3+0", "f4+0"])
        #expect(HitchStackLine.chosen([], isApp: { _ in true }).isEmpty)
    }

    @Test func theCapBoundsTheLine() {
        let frames = (0..<40).map { frame($0, app: true) }
        let chosen = HitchStackLine.chosen(frames, isApp: { _ in true }, leaf: 8, app: 30, cap: 24)
        #expect(chosen.filter { $0 != "…" }.count == 24)
    }

    @Test func movementSaysWhetherTheStackMoved() {
        let first = RawStack(addresses: [1, 2, 3, 4])
        #expect(HitchStackLine.movement(from: first, to: first) == "unchanged")
        #expect(HitchStackLine.movement(from: first, to: RawStack(addresses: [9, 8, 3, 4]))
            == "moved, 2 of 4 frames shared from the root")
    }

    @Test func detailFormatsTheHeadAndFrames() {
        #expect(HitchStackLine.detail(mode: "default", blockedMS: 121.4, loadAddress: 0x1_04f3_c000, movement: nil, frames: ["a+1", "b+2"])
            == "default 121 ms, load 0x104f3c000 | a+1 ← b+2")
        #expect(HitchStackLine.detail(mode: "tracking", blockedMS: 1620, loadAddress: 0x10, movement: "unchanged", frames: [])
            == "tracking 1620 ms, stack unchanged, load 0x10 | (no frames)")
    }
}

@Suite struct HitchCaptureGateTests {
    @Test func firstCapturesAreTwoSecondsApartAndTheFollowUpIsExempt() {
        var gate = HitchCaptureGate()
        #expect(gate.admitFirst(now: 100) == 0)
        #expect(gate.admitFirst(now: 101) == nil)

        #expect(gate.admitFollowUp(now: 101.5) == 0)

        #expect(gate.admitFirst(now: 103) == nil)
        #expect(gate.admitFirst(now: 103.5) == 0)
    }

    @Test func atMostThirtyStackLinesAMinute() {
        var gate = HitchCaptureGate()
        var admitted = 0

        for stall in 0..<17 {
            let start = 1_000 + Double(stall) * 3.5
            if gate.admitFirst(now: start) != nil { admitted += 1 }
            if gate.admitFollowUp(now: start + 1.5) != nil { admitted += 1 }
        }
        #expect(admitted == HitchCaptureGate.linesPerMinute)
    }
}
