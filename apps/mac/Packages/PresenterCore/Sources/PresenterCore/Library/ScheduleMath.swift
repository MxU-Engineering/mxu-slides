import Foundation

public enum ScheduleMath {

    public static let misfireGrace: TimeInterval = 60

    static func parseTimeOfDay(_ raw: String) -> (hour: Int, minute: Int, second: Int)? {
        let parts = raw.split(separator: ":")
        guard (2 ... 3).contains(parts.count),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = parts.count == 3 ? (Int(parts[2]) ?? -1) : 0
        guard (0...59).contains(second) else { return nil }
        return (hour, minute, second)
    }

    public static func parseLocalDate(_ raw: String, calendar: Calendar) -> Date? {
        let parts = raw.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let dateParts = parts[0].split(separator: "-")
        guard dateParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]),
              let day = Int(dateParts[2]),
              let time = parseTimeOfDay(String(parts[1]))
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        return calendar.date(from: components)
    }

    public static func localDayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isExcluded(
        _ date: Date, in condition: ScheduleCondition, calendar: Calendar
    ) -> Bool {
        guard let excluded = condition.excludedDates, !excluded.isEmpty else { return false }
        return excluded.contains(localDayString(date, calendar: calendar))
    }

    public static func snoozed(
        _ trigger: ScheduleTrigger, at now: Date, calendar: Calendar
    ) -> Bool {
        guard let raw = trigger.disabledUntil,
              let until = parseLocalDate(raw, calendar: calendar)
        else { return false }
        return now < until
    }

    public static func snoozeExpiry(
        _ trigger: ScheduleTrigger, at now: Date, calendar: Calendar
    ) -> Date? {
        guard let raw = trigger.disabledUntil,
              let until = parseLocalDate(raw, calendar: calendar),
              now < until
        else { return nil }
        return until
    }

    public static func plannedEnd(
        _ trigger: ScheduleTrigger, calendar: Calendar
    ) -> Date? {
        trigger.enabledUntil.flatMap { parseLocalDate($0, calendar: calendar) }
    }

    public static func ended(
        _ trigger: ScheduleTrigger, at now: Date, calendar: Calendar
    ) -> Bool {
        guard let end = plannedEnd(trigger, calendar: calendar) else { return false }
        return now >= end
    }

    public static func seriesCompleted(
        _ trigger: ScheduleTrigger, firedAt now: Date, calendar: Calendar
    ) -> Bool {
        guard let end = plannedEnd(trigger, calendar: calendar) else { return false }
        guard let next = nextDue(for: trigger, after: now, calendar: calendar) else { return true }
        return next >= end
    }

    public static func nextDue(
        for condition: ScheduleCondition, after: Date, calendar: Calendar
    ) -> Date? {
        switch condition.kind {
        case .weekly:
            guard let raw = condition.timeOfDay, let time = parseTimeOfDay(raw) else {
                return nil
            }

            let days = (condition.days?.isEmpty == false)
                ? condition.days!.filter { (1...7).contains($0) }
                : Array(1...7)
            guard !days.isEmpty else { return nil }
            return days.compactMap { weekday -> Date? in
                var match = DateComponents()
                match.hour = time.hour
                match.minute = time.minute
                match.second = time.second
                match.weekday = weekday

                var cursor = after

                for _ in 0 ... (condition.excludedDates?.count ?? 0) {
                    guard let candidate = calendar.nextDate(
                        after: cursor, matching: match, matchingPolicy: .nextTime,
                        direction: .forward) else { return nil }
                    if !isExcluded(candidate, in: condition, calendar: calendar) {
                        return candidate
                    }
                    cursor = candidate
                }
                return nil
            }.min()
        case .oneTime:
            guard let raw = condition.date,
                  let date = parseLocalDate(raw, calendar: calendar)
            else { return nil }
            return date > after ? date : nil
        case .timerReaches:
            return nil
        }
    }

    public static func nextDue(
        for trigger: ScheduleTrigger, after: Date, calendar: Calendar
    ) -> Date? {
        nextDueDetailed(for: trigger, after: after, calendar: calendar)?.due
    }

    static func nextDueDetailed(
        for trigger: ScheduleTrigger, after: Date, calendar: Calendar
    ) -> (due: Date, condition: ScheduleCondition)? {
        trigger.conditions
            .compactMap { condition in
                nextDue(for: condition, after: after, calendar: calendar)
                    .map { (due: $0, condition: condition) }
            }
            .min { $0.due < $1.due }
    }

    public static func satisfied(
        _ condition: ScheduleCondition, at now: Date, calendar: Calendar
    ) -> Bool {
        switch condition.kind {
        case .weekly:
            let weekday = calendar.component(.weekday, from: now)
            let days = (condition.days?.isEmpty == false)
                ? condition.days!
                : Array(1...7)
            guard days.contains(weekday) else { return false }

            guard !isExcluded(now, in: condition, calendar: calendar) else { return false }
            guard let raw = condition.timeOfDay else { return true }  
            guard let time = parseTimeOfDay(raw) else { return false }
            let parts = calendar.dateComponents([.hour, .minute, .second], from: now)
            return (parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
                >= (time.hour, time.minute, time.second)
        case .oneTime:
            guard let raw = condition.date,
                  let date = parseLocalDate(raw, calendar: calendar)
            else { return false }
            return now >= date
        case .timerReaches:
            return false
        }
    }

    public static func logicGateOpen(
        for trigger: ScheduleTrigger,
        firing condition: ScheduleCondition?,
        at now: Date,
        calendar: Calendar,
        timerSatisfied: (ScheduleCondition) -> Bool
    ) -> Bool {
        guard trigger.conditionLogic == .all else { return true }
        return trigger.conditions.allSatisfy { other in
            if let condition, other.id == condition.id { return true }
            if other.kind == .timerReaches { return timerSatisfied(other) }
            return satisfied(other, at: now, calendar: calendar)
        }
    }

    public struct Firing: Equatable, Sendable {
        public let triggerID: String
        public let dueAt: Date

        public let late: Bool
    }

    public struct SweepResult: Equatable, Sendable {

        public var firings: [Firing] = []

        public var missed: [Firing] = []

        public var gated: [Firing] = []

        public var lastDue: [String: Date]

        public var nextWake: Date?
    }

    public static func sweep(
        triggers: [ScheduleTrigger],
        gateOpen: (ScheduleTrigger) -> Bool,
        lastDue: [String: Date],
        from: Date,
        now: Date,
        grace: TimeInterval = misfireGrace,
        calendar: Calendar = .current,
        timerSatisfied: (ScheduleCondition) -> Bool = { _ in false }
    ) -> SweepResult {
        var result = SweepResult(lastDue: lastDue)
        for trigger in triggers {
            let open = gateOpen(trigger)
            var cursor = max(result.lastDue[trigger.id] ?? .distantPast, from)

            var remaining = 200
            while remaining > 0,
                  let hit = nextDueDetailed(for: trigger, after: cursor, calendar: calendar),
                  hit.due <= now
            {
                remaining -= 1
                let due = hit.due
                if open {
                    let age = now.timeIntervalSince(due)
                    if age > grace {
                        result.missed.append(
                            Firing(triggerID: trigger.id, dueAt: due, late: true))
                    } else if !logicGateOpen(
                        for: trigger, firing: hit.condition, at: now,
                        calendar: calendar, timerSatisfied: timerSatisfied)
                    {

                        result.gated.append(
                            Firing(triggerID: trigger.id, dueAt: due, late: false))
                    } else {
                        result.firings.append(
                            Firing(triggerID: trigger.id, dueAt: due, late: age > 1.5))
                    }
                }
                result.lastDue[trigger.id] = due
                cursor = due
            }
            if open, let upcoming = nextDue(for: trigger, after: now, calendar: calendar) {
                result.nextWake = result.nextWake.map { min($0, upcoming) } ?? upcoming
            }
        }
        result.firings.sort { $0.dueAt < $1.dueAt }
        return result
    }

    public static func spentOneOffDue(
        for trigger: ScheduleTrigger, asOf now: Date, calendar: Calendar
    ) -> Date? {
        guard !trigger.conditions.isEmpty else { return nil }
        var latest = Date.distantPast
        for condition in trigger.conditions {
            guard condition.kind == .oneTime,
                  let raw = condition.date,
                  let date = parseLocalDate(raw, calendar: calendar),
                  date <= now
            else { return nil }
            latest = max(latest, date)
        }
        return latest
    }

    public static func countdownCrossed(
        previous: Double, current: Double, threshold: Double
    ) -> Bool {
        previous > threshold && current <= threshold
    }

    public static func countUpCrossed(
        previous: Double, current: Double, threshold: Double
    ) -> Bool {
        previous < threshold && current >= threshold
    }
}
