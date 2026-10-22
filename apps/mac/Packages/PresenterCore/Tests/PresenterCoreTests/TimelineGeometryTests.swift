import Foundation
import Testing
@testable import PresenterCore

@Suite struct TimelineZoomTests {
    @Test func pinchScalesFromTheGestureStartWithinTheRange() {
        #expect(TimelineZoom.pinched(base: 120, magnification: 2) == 240)
        #expect(TimelineZoom.pinched(base: 120, magnification: 10) == 480)
        #expect(TimelineZoom.pinched(base: 120, magnification: 0.1) == 24)
    }

    @Test func buttonsStepByThirtyPercentWithinTheRange() {
        #expect(TimelineZoom.zoomedIn(100) == 130)
        #expect(TimelineZoom.zoomedIn(400) == 480)
        #expect(TimelineZoom.zoomedOut(130) == 100)
        #expect(TimelineZoom.zoomedOut(30) == 24)
    }

    @Test func fitPacksTheSecondsIntoTheViewportLessTheReserve() {
        #expect(TimelineZoom.fit(seconds: 4, viewportWidth: 600) == 121)
        #expect(TimelineZoom.fit(seconds: 0.1, viewportWidth: 600) == 480)
        #expect(TimelineZoom.fit(seconds: 100, viewportWidth: 600) == 24)
        #expect(TimelineZoom.fit(seconds: 0, viewportWidth: 600) == nil, "nothing to fit")
        #expect(TimelineZoom.fit(seconds: 4, viewportWidth: 140) == nil, "no room to fit")
    }
}

@Suite struct TimelineMapTests {

    private let map = TimelineMap(
        segments: [
            TimelineSegment(start: 0, displayDuration: 1, width: 120),
            TimelineSegment(
                start: 1.5, displayDuration: 0.6,
                width: TimelineSegment.width(displayDuration: 0.6, hasContent: false, pointsPerSecond: 120, floor: 96)
            ),
            TimelineSegment(start: 2.1, displayDuration: 2, width: 240),
        ],
        pointsPerSecond: 120
    )

    @Test func segmentWidthsFitContentAndFloorEmptySegments() {
        #expect(TimelineSegment.width(displayDuration: 0.5, hasContent: true, pointsPerSecond: 120, floor: 96) == 60)
        #expect(map.segments[1].width == 96)
        #expect(map.width == 456)
        #expect(map.x(ofSegment: 2) == 216)
    }

    @Test func timeMapsToXAndGapsPinToThePreviousEnd() {
        #expect(map.x(ofTime: 0.5) == 60)
        #expect(map.x(ofTime: 1.2) == 120, "the click gap pins to the first column's end")
        #expect(map.x(ofTime: 1.7) == 144)
        #expect(map.x(ofTime: 2.1) == 216)
        #expect(map.x(ofTime: 10) == 456, "past the end clamps inside the last column")
    }

    @Test func xMapsBackToTimeAndItsSegment() throws {
        let first = try #require(map.locate(x: 60))
        #expect(first.time == 0.5 && first.segment == 0)
        let second = try #require(map.locate(x: 132))
        #expect(abs(second.time - 1.6) < 1e-9 && second.segment == 1)
        let past = try #require(map.locate(x: 1000))
        #expect(abs(past.time - 4.1) < 1e-9 && past.segment == 2, "past the end lands at the last column's end")
        let before = try #require(map.locate(x: -5))
        #expect(before.time == 0 && before.segment == 0)
        #expect(TimelineMap(segments: [], pointsPerSecond: 120).locate(x: 10) == nil)
    }

    @Test func segmentUnderXAndBoundariesNearX() {
        #expect(map.segmentIndex(atX: 119) == 0)
        #expect(map.segmentIndex(atX: 120) == 1)
        #expect(map.segmentIndex(atX: 1000) == 2)
        #expect(TimelineMap(segments: [], pointsPerSecond: 120).segmentIndex(atX: 0) == nil)
        #expect(map.boundary(nearX: 130, tolerance: 12) == 1)
        #expect(map.boundary(nearX: 205, tolerance: 12) == 2)
        #expect(map.boundary(nearX: 170, tolerance: 12) == nil)
        #expect(map.boundary(nearX: 456, tolerance: 12) == nil, "the trailing edge is not a boundary")
    }
}

@Suite struct TimelineBlockEditTests {
    @Test func thePressPointPicksTheMode() {

        #expect(TimelineBlockEdit.mode(pressX: 145, frameMinX: 50, frameWidth: 100) == .stretch)
        #expect(TimelineBlockEdit.mode(pressX: 55, frameMinX: 50, frameWidth: 100) == .trim)
        #expect(TimelineBlockEdit.mode(pressX: 100, frameMinX: 50, frameWidth: 100) == .move)

        #expect(TimelineBlockEdit.mode(pressX: 25, frameMinX: 0, frameWidth: 30) == .stretch)
        #expect(TimelineBlockEdit.mode(pressX: 5, frameMinX: 0, frameWidth: 30) == .move)
    }

    @Test func theLiveSpanFollowsTheModeAndKeepsAMinimumWidth() {
        #expect(TimelineBlockEdit.liveSpan(x: 10, width: 50, mode: .move, delta: 20) == (30, 50))
        #expect(TimelineBlockEdit.liveSpan(x: 10, width: 50, mode: .stretch, delta: 20) == (10, 70))
        #expect(TimelineBlockEdit.liveSpan(x: 10, width: 50, mode: .stretch, delta: -40) == (10, 26))
        #expect(TimelineBlockEdit.liveSpan(x: 10, width: 50, mode: .trim, delta: 10) == (20, 40))
        #expect(TimelineBlockEdit.liveSpan(x: 10, width: 20, mode: nil, delta: 99) == (10, 26))
    }

    @Test func theLiveDurationSnapsLikeTheWrite() {
        #expect(TimelineBlockEdit.liveDuration(1, mode: .stretch, delta: 7, pointsPerSecond: 120) == 1.05)
        #expect(TimelineBlockEdit.liveDuration(1, mode: .trim, delta: 60, pointsPerSecond: 120) == 0.5)
        #expect(TimelineBlockEdit.liveDuration(0.3, mode: .trim, delta: 600, pointsPerSecond: 120) == 0.05)
        #expect(TimelineBlockEdit.liveDuration(1, mode: .move, delta: 600, pointsPerSecond: 120) == 1)
    }

    @Test func aDragSnapsTheNearestEdgeWithinReach() {

        #expect(TimelineBlockEdit.snappedDelta(20, edges: [100], targets: [124, 300]) == 24)

        #expect(TimelineBlockEdit.snappedDelta(20, edges: [100, 150], targets: [125, 172]) == 22)

        #expect(TimelineBlockEdit.snappedDelta(20, edges: [100], targets: [130]) == 20)
    }

    @Test func durationLabelsShowTwoDecimalsOnlyWhenNeeded() {
        #expect(TimelineBlockEdit.durationLabel(0.4) == "0.4s")
        #expect(TimelineBlockEdit.durationLabel(0.45) == "0.45s")
        #expect(TimelineBlockEdit.durationLabel(2) == "2.0s")
    }
}

@Suite struct TimelineControlsSweepTests {
    @Test func theAnimatorDrawsThroughTheSharedControls() throws {
        let sweep = try SourceSweep.app()
        let panel = try #require(sweep.file("AnimationTimelinePanel.swift")).text
        for control in [
            "TimelineTransportButtons(", "TimelineScrubStrip(", "TimelineBlockCard(", ".timelineBlockGestures(",
            "TimelineZoomControls(", ".timelinePinchZoom(", "TimelineScreenAnchor(", "TimelineMap(",
        ] {
            #expect(panel.contains(control), "the animator uses \(control)")
        }
        for fork in ["MagnifyGesture", "Timer(", "NSViewRepresentable", "RoundedRectangle(cornerRadius: 2)"] {
            #expect(!panel.contains(fork), "\(fork) belongs in TimelineControls.swift, shared by every timeline")
        }
    }
}

@Suite struct TimelineFollowTests {
    @Test func holdsWhileThePlayheadIsInView() {
        #expect(TimelineFollow.scroll(playheadX: 50, shown: 0...400, contentWidth: 2000) == nil)
        #expect(TimelineFollow.scroll(playheadX: 383, shown: 0...400, contentWidth: 2000) == nil)
    }

    @Test func runningOffTheRightPutsItNearTheLeft() {

        #expect(TimelineFollow.scroll(playheadX: 390, shown: 0...400, contentWidth: 2000) == 330)
    }

    @Test func aSeekOrAManualScrollOffEitherSideBringsItBack() {

        #expect(TimelineFollow.scroll(playheadX: 900, shown: 137...537, contentWidth: 2000) == 840)
        #expect(TimelineFollow.scroll(playheadX: 100, shown: 600...1000, contentWidth: 2000) == 40)
    }

    @Test func clampsToTheContent() {
        #expect(TimelineFollow.scroll(playheadX: 1995, shown: 1000...1400, contentWidth: 2000) == 1600)
        #expect(TimelineFollow.scroll(playheadX: 20, shown: 300...700, contentWidth: 2000) == 0)
    }
}
