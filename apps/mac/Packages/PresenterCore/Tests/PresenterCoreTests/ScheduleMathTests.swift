import Foundation
import Testing
@testable import PresenterCore

private var chicago: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    return calendar
}

private func date(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
    calendar: Calendar = chicago
) -> Date {
    calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func weekly(days: [Int]?, at time: String, id: String = "c") -> ScheduleCondition {
    ScheduleCondition(id: id, kind: .weekly, days: days, timeOfDay: time)
}

private func trigger(
    id: String, _ conditions: [ScheduleCondition], enabled: Bool? = nil
) -> ScheduleTrigger {
    ScheduleTrigger(id: id, name: id, conditions: conditions, actions: [], enabled: enabled)
}

@Test func weeklyNextDueFindsTheComingSunday() {

    let after = date(2026, 7, 8, 12, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: [1], at: "09:00"), after: after, calendar: chicago)
    #expect(due == date(2026, 7, 12, 9, 0))
}

@Test func secondsCarryThroughDueAndSatisfied() {

    let after = date(2026, 7, 8, 12, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: [1], at: "08:52:30"), after: after, calendar: chicago)
    #expect(due == date(2026, 7, 12, 8, 52).addingTimeInterval(30))

    let condition = weekly(days: [1], at: "08:52:30")
    let justBefore = date(2026, 7, 12, 8, 52).addingTimeInterval(29)
    let onTheSecond = date(2026, 7, 12, 8, 52).addingTimeInterval(30)
    #expect(!ScheduleMath.satisfied(condition, at: justBefore, calendar: chicago))
    #expect(ScheduleMath.satisfied(condition, at: onTheSecond, calendar: chicago))

    #expect(ScheduleMath.nextDue(
        for: weekly(days: [1], at: "08:52:xx"), after: after, calendar: chicago) == nil)

    let oneOff = ScheduleCondition(id: "o", kind: .oneTime, date: "2026-07-12T08:52:30")
    #expect(ScheduleMath.nextDue(for: oneOff, after: after, calendar: chicago)
        == date(2026, 7, 12, 8, 52).addingTimeInterval(30))
}

@Test func snoozeGatesUntilTheMomentPasses() {

    var snoozed = trigger(id: "t", [weekly(days: [1], at: "09:00")])
    snoozed.disabledUntil = "2026-07-12T09:00:01"
    let before = date(2026, 7, 12, 9, 0)
    let at = date(2026, 7, 12, 9, 0).addingTimeInterval(1)
    #expect(ScheduleMath.snoozed(snoozed, at: before, calendar: chicago))
    #expect(!ScheduleMath.snoozed(snoozed, at: at, calendar: chicago))
    #expect(ScheduleMath.snoozeExpiry(snoozed, at: before, calendar: chicago) == at)
    #expect(ScheduleMath.snoozeExpiry(snoozed, at: at, calendar: chicago) == nil)

    var broken = snoozed
    broken.disabledUntil = "not-a-date"
    #expect(!ScheduleMath.snoozed(broken, at: before, calendar: chicago))
    #expect(!ScheduleMath.snoozed(
        trigger(id: "t2", [weekly(days: [1], at: "09:00")]), at: before, calendar: chicago))
}

@Test func plannedEndClosesTheGateForGood() {

    var series = trigger(id: "t", [weekly(days: [1], at: "09:00")])
    series.enabledUntil = "2026-07-12T23:59:59"
    let before = date(2026, 7, 12, 9, 0)
    let at = date(2026, 7, 12, 23, 59).addingTimeInterval(59)
    #expect(!ScheduleMath.ended(series, at: before, calendar: chicago))
    #expect(ScheduleMath.ended(series, at: at, calendar: chicago))
    #expect(ScheduleMath.ended(series, at: date(2026, 8, 1, 0, 0), calendar: chicago))

    var broken = series
    broken.enabledUntil = "not-a-date"
    #expect(!ScheduleMath.ended(broken, at: at, calendar: chicago))
    #expect(!ScheduleMath.ended(
        trigger(id: "t2", [weekly(days: [1], at: "09:00")]), at: at, calendar: chicago))
}

@Test func seriesCompletedOnTheFinalFireOnly() {

    var series = trigger(id: "t", [weekly(days: [1], at: "09:00")])
    series.enabledUntil = "2026-07-19T23:59:59"

    #expect(!ScheduleMath.seriesCompleted(
        series, firedAt: date(2026, 7, 12, 9, 0), calendar: chicago))

    #expect(ScheduleMath.seriesCompleted(
        series, firedAt: date(2026, 7, 19, 9, 0), calendar: chicago))

    #expect(!ScheduleMath.seriesCompleted(
        trigger(id: "t2", [weekly(days: [1], at: "09:00")]),
        firedAt: date(2026, 7, 19, 9, 0), calendar: chicago))

    var oneOff = trigger(id: "t3", [ScheduleCondition(
        id: "o", kind: .oneTime, date: "2026-07-12T09:00")])
    oneOff.enabledUntil = "2026-07-19T23:59:59"
    #expect(ScheduleMath.seriesCompleted(
        oneOff, firedAt: date(2026, 7, 12, 9, 0), calendar: chicago))
}

@Test func excludedDaySkipsToTheFollowingWeek() {

    var condition = weekly(days: [1], at: "09:00")
    condition.excludedDates = ["2026-07-12"]
    let after = date(2026, 7, 8, 12, 0)
    #expect(ScheduleMath.nextDue(for: condition, after: after, calendar: chicago)
        == date(2026, 7, 19, 9, 0))
    #expect(!ScheduleMath.satisfied(condition, at: date(2026, 7, 12, 10, 0), calendar: chicago))
    #expect(ScheduleMath.satisfied(condition, at: date(2026, 7, 19, 10, 0), calendar: chicago))
}

@Test func consecutiveExclusionsAndJunkEntriesStillResolve() {

    var condition = weekly(days: [1], at: "09:00")
    condition.excludedDates = ["2026-07-12", "2026-07-19", "christmas"]
    let after = date(2026, 7, 8, 12, 0)
    #expect(ScheduleMath.nextDue(for: condition, after: after, calendar: chicago)
        == date(2026, 7, 26, 9, 0))
}

@Test func weeklySameDayLaterTimeStaysToday() {

    let sundayEarly = date(2026, 7, 12, 8, 0)
    let condition = weekly(days: [1], at: "09:00")
    #expect(
        ScheduleMath.nextDue(for: condition, after: sundayEarly, calendar: chicago)
            == date(2026, 7, 12, 9, 0))
    let sundayLate = date(2026, 7, 12, 9, 30)
    #expect(
        ScheduleMath.nextDue(for: condition, after: sundayLate, calendar: chicago)
            == date(2026, 7, 19, 9, 0))
}

@Test func weeklyDueMomentItselfIsStrictlyAfter() {

    let dueMoment = date(2026, 7, 12, 9, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: [1], at: "09:00"), after: dueMoment, calendar: chicago)
    #expect(due == date(2026, 7, 19, 9, 0))
}

@Test func weeklyMultipleDaysPickTheEarliest() {

    let after = date(2026, 7, 8, 12, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: [1, 5], at: "19:00"), after: after, calendar: chicago)
    #expect(due == date(2026, 7, 9, 19, 0))
}

@Test func weeklyAbsentDaysMeansEveryDay() {
    let after = date(2026, 7, 8, 12, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: nil, at: "13:00"), after: after, calendar: chicago)
    #expect(due == date(2026, 7, 8, 13, 0))
}

@Test func weeklyRidesDSTBothDirections() {

    let condition = weekly(days: [1], at: "09:00")

    let beforeSpring = date(2026, 3, 7, 12, 0)
    let springDue = ScheduleMath.nextDue(for: condition, after: beforeSpring, calendar: chicago)
    #expect(springDue == date(2026, 3, 8, 9, 0))
    let springParts = chicago.dateComponents([.hour, .minute], from: springDue!)
    #expect(springParts.hour == 9 && springParts.minute == 0)

    let beforeFall = date(2026, 10, 31, 12, 0)
    let fallDue = ScheduleMath.nextDue(for: condition, after: beforeFall, calendar: chicago)
    #expect(fallDue == date(2026, 11, 1, 9, 0))
    let fallParts = chicago.dateComponents([.hour, .minute], from: fallDue!)
    #expect(fallParts.hour == 9 && fallParts.minute == 0)
}

@Test func weeklyNonexistentSpringForwardTimeStillResolves() {

    let after = date(2026, 3, 7, 12, 0)
    let due = ScheduleMath.nextDue(
        for: weekly(days: [1], at: "02:30"), after: after, calendar: chicago)
    #expect(due != nil)
    let parts = chicago.dateComponents([.year, .month, .day], from: due!)
    #expect(parts.month == 3 && parts.day == 8)
}

@Test func oneTimeFiresOnceAndNeverRematches() {
    let condition = ScheduleCondition(id: "c", kind: .oneTime, date: "2026-07-20T18:00")
    let before = date(2026, 7, 20, 17, 0)
    #expect(
        ScheduleMath.nextDue(for: condition, after: before, calendar: chicago)
            == date(2026, 7, 20, 18, 0))
    let past = date(2026, 7, 20, 18, 0)
    #expect(ScheduleMath.nextDue(for: condition, after: past, calendar: chicago) == nil)
}

@Test func brokenConditionsAreNoOpsNeverErrors() {
    let after = date(2026, 7, 8, 12, 0)
    for condition in [
        ScheduleCondition(id: "c1", kind: .weekly),  
        ScheduleCondition(id: "c2", kind: .weekly, days: [9], timeOfDay: "09:00"),
        ScheduleCondition(id: "c3", kind: .weekly, days: [1], timeOfDay: "25:99"),
        ScheduleCondition(id: "c4", kind: .oneTime, date: "not a date"),
        ScheduleCondition(id: "c5", kind: .timerReaches, timerId: "t", timerSeconds: 0),
    ] {
        #expect(ScheduleMath.nextDue(for: condition, after: after, calendar: chicago) == nil)
    }
}

@Test func sweepFiresOnTimeAndDedupesAgainstLastDue() {
    let sunday = trigger(id: "t1", [weekly(days: [1], at: "09:00")])
    let dueAt = date(2026, 7, 12, 9, 0)

    var result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 12, 8, 59), now: dueAt, calendar: chicago)
    #expect(result.firings == [ScheduleMath.Firing(triggerID: "t1", dueAt: dueAt, late: false)])
    #expect(result.missed.isEmpty)
    #expect(result.lastDue["t1"] == dueAt)

    result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in true }, lastDue: result.lastDue,
        from: date(2026, 7, 12, 8, 59), now: dueAt.addingTimeInterval(5), calendar: chicago)
    #expect(result.firings.isEmpty)
    #expect(result.nextWake == date(2026, 7, 19, 9, 0))
}

@Test func sweepGraceBoundaries() {
    let sunday = trigger(id: "t1", [weekly(days: [1], at: "09:00")])
    let dueAt = date(2026, 7, 12, 9, 0)

    var result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in true }, lastDue: [:],
        from: dueAt.addingTimeInterval(-3600), now: dueAt.addingTimeInterval(59),
        calendar: chicago)
    #expect(result.firings == [ScheduleMath.Firing(triggerID: "t1", dueAt: dueAt, late: true)])

    result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in true }, lastDue: [:],
        from: dueAt.addingTimeInterval(-3600), now: dueAt.addingTimeInterval(61),
        calendar: chicago)
    #expect(result.firings.isEmpty)
    #expect(result.missed.count == 1)
    #expect(result.lastDue["t1"] == dueAt)
}

@Test func sweepWalksEveryDueInTheWindow() {

    let daily = trigger(id: "t1", [weekly(days: nil, at: "09:00")])
    let now = date(2026, 7, 12, 9, 0)
    let result = ScheduleMath.sweep(
        triggers: [daily], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 9, 12, 0), now: now, calendar: chicago)
    #expect(result.missed.map(\.dueAt) == [date(2026, 7, 10, 9, 0), date(2026, 7, 11, 9, 0)])
    #expect(result.firings.map(\.dueAt) == [now])
    #expect(result.lastDue["t1"] == now)
}

@Test func sweepGateClosedConsumesSilently() {

    let sunday = trigger(id: "t1", [weekly(days: [1], at: "09:00")])
    let dueAt = date(2026, 7, 12, 9, 0)

    var result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in false }, lastDue: [:],
        from: dueAt.addingTimeInterval(-3600), now: dueAt.addingTimeInterval(10),
        calendar: chicago)
    #expect(result.firings.isEmpty)
    #expect(result.missed.isEmpty)
    #expect(result.lastDue["t1"] == dueAt)

    #expect(result.nextWake == nil)

    result = ScheduleMath.sweep(
        triggers: [sunday], gateOpen: { _ in true }, lastDue: result.lastDue,
        from: dueAt.addingTimeInterval(-3600), now: dueAt.addingTimeInterval(20),
        calendar: chicago)
    #expect(result.firings.isEmpty)
}

@Test func sweepNextWakeIsTheEarliestAmongOpenTriggers() {
    let sunday = trigger(id: "t1", [weekly(days: [1], at: "09:00")])
    let thursday = trigger(id: "t2", [weekly(days: [5], at: "19:00")])
    let paused = trigger(id: "t3", [weekly(days: [4], at: "06:00")], enabled: false)
    let now = date(2026, 7, 8, 12, 0)  
    let result = ScheduleMath.sweep(
        triggers: [sunday, thursday, paused],
        gateOpen: { $0.enabled ?? true }, lastDue: [:],
        from: now, now: now, calendar: chicago)
    #expect(result.nextWake == date(2026, 7, 9, 19, 0))
}

@Test func sweepOrdersSimultaneousFiringsByDue() {
    let a = trigger(id: "a", [weekly(days: nil, at: "09:00")])
    let b = trigger(id: "b", [weekly(days: nil, at: "08:59")])
    let now = date(2026, 7, 12, 9, 0)
    let result = ScheduleMath.sweep(
        triggers: [a, b], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 12, 8, 58), now: now, calendar: chicago)
    #expect(result.firings.map(\.triggerID) == ["b", "a"])
}

@Test func satisfiedReadsTimeConditionsAsStates() {

    let now = date(2026, 7, 12, 10, 0)
    #expect(ScheduleMath.satisfied(weekly(days: [1], at: "09:00"), at: now, calendar: chicago))
    #expect(!ScheduleMath.satisfied(weekly(days: [1], at: "11:00"), at: now, calendar: chicago))
    #expect(!ScheduleMath.satisfied(weekly(days: [2], at: "09:00"), at: now, calendar: chicago))

    let dayOnly = ScheduleCondition(id: "c", kind: .weekly, days: [1])
    #expect(ScheduleMath.satisfied(dayOnly, at: now, calendar: chicago))
    #expect(!ScheduleMath.satisfied(dayOnly, at: date(2026, 7, 13, 10, 0), calendar: chicago))

    let past = ScheduleCondition(id: "c", kind: .oneTime, date: "2026-07-01T08:00")
    #expect(ScheduleMath.satisfied(past, at: now, calendar: chicago))
    let broken = ScheduleCondition(id: "c", kind: .weekly, days: [1], timeOfDay: "nope")
    #expect(!ScheduleMath.satisfied(broken, at: now, calendar: chicago))
}

@Test func allLogicGatesTheFiringMomentOnSiblings() {

    var trigger = ScheduleTrigger(
        id: "t1", name: "t1",
        conditions: [
            weekly(days: nil, at: "09:00", id: "time"),
            ScheduleCondition(id: "gate", kind: .weekly, days: [1]),
        ],
        actions: [], conditionLogic: .all
    )
    let sunday = date(2026, 7, 12, 9, 0)
    var result = ScheduleMath.sweep(
        triggers: [trigger], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 12, 8, 59), now: sunday, calendar: chicago)
    #expect(result.firings.count == 1)
    #expect(result.gated.isEmpty)

    let monday = date(2026, 7, 13, 9, 0)
    result = ScheduleMath.sweep(
        triggers: [trigger], gateOpen: { _ in true }, lastDue: result.lastDue,
        from: date(2026, 7, 13, 8, 59), now: monday, calendar: chicago)
    #expect(result.firings.isEmpty)
    #expect(result.gated.count == 1)
    #expect(result.lastDue["t1"] == monday)

    trigger.conditionLogic = nil
    result = ScheduleMath.sweep(
        triggers: [trigger], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 13, 8, 59), now: monday, calendar: chicago)
    #expect(result.firings.count == 1)
}

@Test func allLogicAsksTheTimerClosureForTimerSiblings() {
    let trigger = ScheduleTrigger(
        id: "t1", name: "t1",
        conditions: [
            weekly(days: nil, at: "09:00", id: "time"),
            ScheduleCondition(id: "timer", kind: .timerReaches, timerId: "x", timerSeconds: 0),
        ],
        actions: [], conditionLogic: .all
    )
    let now = date(2026, 7, 12, 9, 0)
    let closed = ScheduleMath.sweep(
        triggers: [trigger], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 12, 8, 59), now: now, calendar: chicago,
        timerSatisfied: { _ in false })
    #expect(closed.firings.isEmpty && closed.gated.count == 1)
    let open = ScheduleMath.sweep(
        triggers: [trigger], gateOpen: { _ in true }, lastDue: [:],
        from: date(2026, 7, 12, 8, 59), now: now, calendar: chicago,
        timerSatisfied: { _ in true })
    #expect(open.firings.count == 1 && open.gated.isEmpty)
}

@Test func logicGateExcludesTheFiringConditionItself() {

    let condition = ScheduleCondition(
        id: "timer", kind: .timerReaches, timerId: "x", timerSeconds: 0)
    let trigger = ScheduleTrigger(
        id: "t1", name: "t1", conditions: [condition], actions: [],
        conditionLogic: .all
    )
    #expect(
        ScheduleMath.logicGateOpen(
            for: trigger, firing: condition, at: date(2026, 7, 12, 9, 0),
            calendar: chicago, timerSatisfied: { _ in false }))
}

@Test func countdownCrossingFiresOncePerPass() {

    #expect(ScheduleMath.countdownCrossed(previous: 5, current: 0, threshold: 0))
    #expect(!ScheduleMath.countdownCrossed(previous: 0, current: 0, threshold: 0))
    #expect(!ScheduleMath.countdownCrossed(previous: 0, current: -3, threshold: 0))

    #expect(ScheduleMath.countdownCrossed(previous: 2, current: -1, threshold: 0))

    #expect(!ScheduleMath.countdownCrossed(previous: 10, current: 5, threshold: 0))
}

@Test func countUpCrossingMirrors() {
    #expect(ScheduleMath.countUpCrossed(previous: 58, current: 60, threshold: 60))
    #expect(!ScheduleMath.countUpCrossed(previous: 60, current: 61, threshold: 60))
    #expect(!ScheduleMath.countUpCrossed(previous: 10, current: 20, threshold: 60))
}

private func oneTime(_ raw: String, id: String = "c") -> ScheduleCondition {
    ScheduleCondition(id: id, kind: .oneTime, date: raw)
}

@Test func spentOneOffNeedsEveryDatePassed() {
    let now = date(2026, 8, 10, 12, 0)

    let spent = trigger(
        id: "t",
        [oneTime("2026-08-09T18:00", id: "c1"), oneTime("2026-08-10T09:30", id: "c2")])
    #expect(
        ScheduleMath.spentOneOffDue(for: spent, asOf: now, calendar: chicago)
            == date(2026, 8, 10, 9, 30))

    let pending = trigger(
        id: "t",
        [oneTime("2026-08-09T18:00", id: "c1"), oneTime("2026-08-10T19:00", id: "c2")])
    #expect(ScheduleMath.spentOneOffDue(for: pending, asOf: now, calendar: chicago) == nil)
}

@Test func recurringAndBrokenConditionsNeverSpend() {

    let now = date(2026, 8, 10, 12, 0)
    for conditions in [
        [oneTime("2026-08-09T18:00", id: "c1"), weekly(days: [1], at: "09:00", id: "c2")],
        [oneTime("2026-08-09T18:00", id: "c1"),
         ScheduleCondition(id: "c2", kind: .timerReaches, timerId: "t1", timerSeconds: 0)],
        [oneTime("not a date")],
        [],
    ] {
        #expect(
            ScheduleMath.spentOneOffDue(
                for: trigger(id: "t", conditions), asOf: now, calendar: chicago) == nil)
    }
}

@Test func spentnessFlipsExactlyAtTheDueMoment() {

    let oneOff = trigger(id: "t", [oneTime("2026-08-10T09:30")])
    #expect(
        ScheduleMath.spentOneOffDue(
            for: oneOff, asOf: date(2026, 8, 10, 9, 0), calendar: chicago) == nil)
    #expect(
        ScheduleMath.spentOneOffDue(
            for: oneOff, asOf: date(2026, 8, 10, 9, 31), calendar: chicago)
            == date(2026, 8, 10, 9, 30))
}
