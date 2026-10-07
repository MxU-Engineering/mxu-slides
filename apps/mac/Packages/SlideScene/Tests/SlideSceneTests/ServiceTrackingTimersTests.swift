import XCTest
@testable import SlideScene

final class ServiceTrackingTimersTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRemainingCountsDownFromTheAnchorAndFreezesWhenNotRunning() {
        let running = ServiceTrackingTimers.remaining(.item, plannedSeconds: 1800, remainingSeconds: 1500, running: true, now: now)
        XCTAssertEqual(running.id, "service_tracking.item.remaining")
        XCTAssertEqual(running.name, "Item Remaining")
        XCTAssertEqual(running.value(at: now), 1500, accuracy: 0.001)
        XCTAssertEqual(running.value(at: now + 10), 1490, accuracy: 0.001)
        XCTAssertTrue(ServiceTrackingTimers.isPermanent(running.id))

        let paused = ServiceTrackingTimers.remaining(.item, plannedSeconds: 1800, remainingSeconds: 1500, running: false, now: now)
        XCTAssertEqual(paused.value(at: now + 60), 1500, accuracy: 0.001)

        let overrun = ServiceTrackingTimers.remaining(.item, plannedSeconds: 300, remainingSeconds: -30, running: true, now: now)
        XCTAssertEqual(overrun.urgency(at: now), .overrun)
    }

    func testFiresStartLocalTiming() {
        XCTAssertNil(ServiceTrackingTimers.localTiming(fired: false))
        XCTAssertEqual(ServiceTrackingTimers.localTiming(fired: true), .local)
    }

    func testLocalTimingEndsWhenThePlannedServiceWouldOrPastAnItemRunningOver() {
        let hour: TimeInterval = 3600
        XCTAssertEqual(ServiceTrackingTimers.localTimingEnds(firstFireAt: now, servicePlannedSeconds: hour, lastFireAt: now + 300, itemPlannedSeconds: 300), now + hour, "walked away early: the planned service's end")
        XCTAssertEqual(ServiceTrackingTimers.localTimingEnds(firstFireAt: now, servicePlannedSeconds: hour, lastFireAt: now + 3000, itemPlannedSeconds: 1200), now + 3000 + 1200 + 900, "the message runs over the plan")
        XCTAssertEqual(ServiceTrackingTimers.localTimingEnds(firstFireAt: now, servicePlannedSeconds: 0, lastFireAt: now + 60, itemPlannedSeconds: 0), now + 60 + hour, "no lengths: an hour after the last fire")
        XCTAssertEqual(ServiceTrackingTimers.plannedSeconds(durations: [300, nil, 1200]), 1500)
    }

    func testElapsedCountsUpAndUnplannedRemainingIsIdle() {
        let elapsed = ServiceTrackingTimers.elapsed(.service, elapsedSeconds: 600, running: true, now: now)
        XCTAssertEqual(elapsed.mode, .countUp)
        XCTAssertEqual(elapsed.elapsed(at: now + 5), 605, accuracy: 0.001)

        let idle = ServiceTrackingTimers.remaining(.item, plannedSeconds: 0, remainingSeconds: nil, running: true, now: now)
        XCTAssertFalse(idle.isRunning)
        XCTAssertEqual(idle.value(at: now + 100), 0, accuracy: 0.001)
        XCTAssertEqual(ServiceTrackingTimers.allIDs.count, 8)
    }

    func testRetiredPreAndPostServiceIDsStayPermanentAndDropOnMerge() {
        let retired = TimerSnapshot(id: "service_tracking.pre_service.remaining", name: "Pre-Service Remaining", mode: .countdown)
        XCTAssertTrue(ServiceTrackingTimers.isPermanent(retired.id))
        XCTAssertNil(ServiceTrackingTimers.subjectAndFace(of: retired.id))

        let board = TimerBoard(nodes: [.timer(retired.id)])
        let merged = ServiceTrackingTimers.merge(system: systemSet(at: now, running: false), into: [retired], board: board)
        XCTAssertFalse(merged.timers.contains { $0.id == retired.id })
        XCTAssertFalse(merged.board.allTimerIDs.contains(retired.id))
        XCTAssertFalse(merged.userTimersChanged)
    }

    func testPermanentIDsParseBackToTheirSubjectAndFace() {
        for id in ServiceTrackingTimers.allIDs {
            let parsed = ServiceTrackingTimers.subjectAndFace(of: id)
            XCTAssertNotNil(parsed)
            if let (subject, face) = parsed {
                XCTAssertEqual(ServiceTrackingTimers.id(subject, face), id)
                XCTAssertFalse(ServiceTrackingTimers.description(subject, face).isEmpty)
            }
        }
        XCTAssertNil(ServiceTrackingTimers.subjectAndFace(of: "user-timer"))
    }

    private func systemSet(at date: Date, running: Bool) -> [TimerSnapshot] {
        [
            ServiceTrackingTimers.remaining(.item, plannedSeconds: 300, remainingSeconds: 200, running: running, now: date),
            ServiceTrackingTimers.idle(.video, .remaining),
        ]
    }

    func testMergeFilesThePermanentSetAndFlagsEveryStoreTheFirstTime() {
        let user = TimerSnapshot(id: "user-1", name: "Walk-in", mode: .countdown, durationSeconds: 600)
        let merged = ServiceTrackingTimers.merge(system: systemSet(at: now, running: false), into: [user], board: TimerBoard())

        XCTAssertEqual(merged.timers.map(\.id), ["service_tracking.item.remaining", "service_tracking.video.remaining", "user-1"])
        XCTAssertEqual(merged.board.folder(id: ServiceTrackingTimers.folderID)?.timerIDs,
                       ["service_tracking.item.remaining", "service_tracking.video.remaining"])
        XCTAssertTrue(merged.timersChanged)
        XCTAssertTrue(merged.boardChanged)
        XCTAssertFalse(merged.userTimersChanged, "one user timer has nowhere to move")
    }

    func testTheSameSetAgainMovesNothing() {
        let user = TimerSnapshot(id: "user-1", name: "Walk-in", mode: .countdown, durationSeconds: 600)
        let first = ServiceTrackingTimers.merge(system: systemSet(at: now, running: false), into: [user], board: TimerBoard())
        let again = ServiceTrackingTimers.merge(system: systemSet(at: now + 5, running: false), into: first.timers, board: first.board)
        XCTAssertEqual(again.timers, first.timers)
        XCTAssertFalse(again.timersChanged, "idle faces carry no anchor, so a later refresh is the same list")
        XCTAssertFalse(again.userTimersChanged)
        XCTAssertFalse(again.boardChanged)
    }

    func testANewAnchorRepublishesWithoutSavingAnything() {
        let first = ServiceTrackingTimers.merge(system: systemSet(at: now, running: true), into: [], board: TimerBoard())
        let later = ServiceTrackingTimers.merge(system: systemSet(at: now + 5, running: true), into: first.timers, board: first.board)
        XCTAssertTrue(later.timersChanged, "a running face re-anchors at the refresh")
        XCTAssertFalse(later.userTimersChanged)
        XCTAssertFalse(later.boardChanged)
    }

    func testUserTimersReorderedByTheBoardAreSaved() {
        let a = TimerSnapshot(id: "a", name: "A", mode: .countdown)
        let b = TimerSnapshot(id: "b", name: "B", mode: .countdown)
        let board = TimerBoard(nodes: [.timer("b"), .timer("a")])
        let merged = ServiceTrackingTimers.merge(system: [], into: [a, b], board: board)
        XCTAssertEqual(merged.timers.map(\.id), ["b", "a"])
        XCTAssertTrue(merged.userTimersChanged)
    }
}
