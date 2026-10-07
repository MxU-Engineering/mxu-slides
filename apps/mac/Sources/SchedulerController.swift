import AppKit
import Foundation
import Observation
import PresenterCore
import SlideScene
import SwiftUI

@MainActor
@Observable
final class SchedulerController {

    struct RunRecord: Identifiable, Equatable, Codable {
        enum Outcome: String, Codable {

            case fired

            case late

            case missed
        }

        enum Source: String, Codable, Equatable {
            case schedule
            case timer
            case manual
        }

        let id: UUID
        let triggerID: String
        let name: String
        let at: Date
        let outcome: Outcome
        let source: Source

        init(
            triggerID: String, name: String, at: Date,
            outcome: Outcome, source: Source
        ) {
            id = UUID()
            self.triggerID = triggerID
            self.name = name
            self.at = at
            self.outcome = outcome
            self.source = source
        }
    }

    struct UpcomingFire: Equatable {
        let triggerID: String
        let name: String
        let date: Date
    }

    private unowned let model: AppModel
    private unowned let controls: ServiceControls
    private unowned let router: ActionRouter

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            DiagnosticsStore.shared.note("scheduler.enabled", detail: enabled ? "on" : "off")
            sweep()
        }
    }

    private(set) var nextFire: UpcomingFire?

    private(set) var history: [RunRecord] = []

    private(set) var upcoming: [String: Date] = [:]

    private var lastDue: [String: Date]
    private var lastSweep: Date
    private var wakeTask: Task<Void, Never>?
    private var timerWatchTask: Task<Void, Never>?

    @ObservationIgnored private var watchedTimerConditions: [(trigger: ScheduleTrigger, condition: ScheduleCondition)] = []
    @ObservationIgnored private var watchedBoard = SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])

    private var crossingState: [String: (stamp: Date?, value: Double)] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private var started = false

    private static let enabledKey = "scheduler.enabled"
    private static let lastDueKey = "scheduler.lastDue"
    private static let lastSweepKey = "scheduler.lastSweep"
    private static let runLogKey = "scheduler.runLog"
    private static let runLogLimit = 500

    init(model: AppModel, controls: ServiceControls, router: ActionRouter) {
        self.model = model
        self.controls = controls
        self.router = router

        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.lastDueKey),
           let map = try? JSONDecoder().decode([String: Date].self, from: data)
        {
            lastDue = map
        } else {
            lastDue = [:]
        }

        lastSweep = UserDefaults.standard.object(forKey: Self.lastSweepKey) as? Date ?? Date()
        if let data = UserDefaults.standard.data(forKey: Self.runLogKey),
           let log = try? JSONDecoder().decode([RunRecord].self, from: data)
        {
            history = log
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        try? await Task.sleep(for: .seconds(2))

        await model.resident.ready([.scheduleTrigger, .schedulerBoard])

        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter

        notificationTokens = [
            workspace.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.sweep() } },
            center.addObserver(
                forName: .NSSystemClockDidChange, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.sweep() } },
            center.addObserver(
                forName: .NSCalendarDayChanged, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.sweep() } },
        ]

        armObservation()
        sweep()
    }

    private func armObservation() {
        withObservationTracking {

            _ = model.version(of: .scheduleTrigger)
            _ = model.version(of: .schedulerBoard)

            _ = model.fillVersion(of: .scheduleTrigger)
            _ = model.fillVersion(of: .schedulerBoard)
            _ = controls.timers.timers
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                self.sweep()
                self.armObservation()
            }
        }
    }

    private func openTriggers() -> [ScheduleTrigger] {
        model.residentScheduleTriggers.filter { $0.archived != true }
    }

    private func gateOpen(_ trigger: ScheduleTrigger, board: SchedulerBoard) -> Bool {
        enabled && (trigger.enabled ?? true)
            && !ScheduleMath.snoozed(trigger, at: Date(), calendar: .current)

            && !ScheduleMath.ended(trigger, at: Date(), calendar: .current)
            && board.folderEnabled(forTrigger: trigger.id)
    }

    func sweep() {
        guard started else { return }
        let now = Date()
        let triggers = openTriggers()
        let board = model.schedulerBoard

        let result = ScheduleMath.sweep(
            triggers: triggers,
            gateOpen: { [self] in gateOpen($0, board: board) },
            lastDue: lastDue,
            from: lastSweep,
            now: now,
            timerSatisfied: { [self] in timerConditionSatisfied($0, at: now) }
        )

        for gated in result.gated {
            DiagnosticsStore.shared.note(
                "scheduler.gated",
                detail: "\(name(of: gated.triggerID, in: triggers)) — all-conditions gate closed")
        }
        for miss in result.missed {
            DiagnosticsStore.shared.note(
                "scheduler.missed",
                detail: "\(name(of: miss.triggerID, in: triggers)) due \(miss.dueAt)")
            record(
                RunRecord(
                    triggerID: miss.triggerID, name: name(of: miss.triggerID, in: triggers),
                    at: miss.dueAt, outcome: .missed, source: .schedule))
        }
        for firing in result.firings {
            guard let trigger = triggers.first(where: { $0.id == firing.triggerID }) else {
                continue
            }
            fire(trigger, source: .schedule, late: firing.late)
        }

        lastDue = result.lastDue
        lastSweep = now
        persistEngineState()

        var rows: [String: Date] = [:]
        for trigger in triggers where gateOpen(trigger, board: board) {
            rows[trigger.id] = ScheduleMath.nextDue(for: trigger, after: now, calendar: .current)
        }
        upcoming = rows
        nextFire = rows
            .min { $0.value < $1.value }
            .map { id, date in
                UpcomingFire(triggerID: id, name: name(of: id, in: triggers), date: date)
            }

        let snoozeWake = triggers
            .compactMap { ScheduleMath.snoozeExpiry($0, at: now, calendar: .current) }
            .min()
        let wake = [result.nextWake, snoozeWake].compactMap { $0 }.min()
        scheduleWake(at: wake, from: now)
        updateTimerWatch(triggers: triggers, board: board)
    }

    private func scheduleWake(at date: Date?, from now: Date) {
        wakeTask?.cancel()
        guard let date else {
            wakeTask = nil
            return
        }

        let interval = max(0, date.timeIntervalSince(now)) + 0.05
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.sweep() }
        }
    }

    private func updateTimerWatch(triggers: [ScheduleTrigger], board: SchedulerBoard) {
        let watched = watchedConditions(triggers: triggers, board: board)
        watchedTimerConditions = watched
        watchedBoard = board

        crossingState = crossingState.filter { key, _ in
            watched.contains { watchKey($0.trigger, $0.condition) == key }
        }
        guard !watched.isEmpty else {
            timerWatchTask?.cancel()
            timerWatchTask = nil
            return
        }
        guard timerWatchTask == nil else { return }
        timerWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.tickTimerWatch() }
            }
        }
    }

    private func watchedConditions(
        triggers: [ScheduleTrigger], board: SchedulerBoard
    ) -> [(trigger: ScheduleTrigger, condition: ScheduleCondition)] {
        triggers.filter { gateOpen($0, board: board) }.flatMap { trigger in
            trigger.conditions
                .filter { $0.kind == .timerReaches && !($0.timerId ?? "").isEmpty }
                .map { (trigger, $0) }
        }
    }

    private func watchKey(_ trigger: ScheduleTrigger, _ condition: ScheduleCondition) -> String {
        "\(trigger.id)/\(condition.id)"
    }

    private func tickTimerWatch() {
        let now = Date()
        for (trigger, condition) in watchedTimerConditions where gateOpen(trigger, board: watchedBoard) {
            let key = watchKey(trigger, condition)
            guard let timerID = condition.timerId,
                  let snapshot = controls.timers.snapshot(id: timerID),
                  snapshot.isLive
            else {

                crossingState[key] = nil
                continue
            }
            let threshold = condition.timerSeconds ?? 0
            let stamp: Date?
            let value: Double
            switch snapshot.mode {
            case .countdown, .countdownToTime:
                stamp = snapshot.runningSince ?? snapshot.targetTime
                value = snapshot.value(at: now)
            case .countUp:
                stamp = snapshot.runningSince
                value = snapshot.elapsed(at: now)
            }
            defer { crossingState[key] = (stamp, value) }

            guard let previous = crossingState[key], previous.stamp == stamp else { continue }
            let crossed = switch snapshot.mode {
            case .countdown, .countdownToTime:
                ScheduleMath.countdownCrossed(
                    previous: previous.value, current: value, threshold: threshold)
            case .countUp:
                ScheduleMath.countUpCrossed(
                    previous: previous.value, current: value, threshold: threshold)
            }
            if crossed {

                let gateOpen = ScheduleMath.logicGateOpen(
                    for: trigger, firing: condition, at: now, calendar: .current,
                    timerSatisfied: { [self] in timerConditionSatisfied($0, at: now) }
                )
                if gateOpen {
                    fire(trigger, source: .timer, late: false)
                } else {
                    DiagnosticsStore.shared.note(
                        "scheduler.gated",
                        detail: "\(trigger.name) — all-conditions gate closed")
                }
            }
        }
    }

    private func timerConditionSatisfied(
        _ condition: ScheduleCondition, at now: Date
    ) -> Bool {
        guard let timerID = condition.timerId,
              let snapshot = controls.timers.snapshot(id: timerID)
        else { return false }
        let threshold = condition.timerSeconds ?? 0
        switch snapshot.mode {
        case .countdown, .countdownToTime:
            return snapshot.value(at: now) <= threshold
        case .countUp:
            return snapshot.elapsed(at: now) >= threshold
        }
    }

    func runNow(triggerID: String) {
        guard let trigger = try? model.scheduleTrigger(triggerID) else { return }
        fire(trigger, source: .manual, late: false)
    }

    private func fire(_ trigger: ScheduleTrigger, source: RunRecord.Source, late: Bool) {
        fireNow(trigger, source: source, late: late)
    }

    private func fireNow(_ trigger: ScheduleTrigger, source: RunRecord.Source, late: Bool) {
        let crumb = switch source {
        case .schedule: late ? "scheduler.late" : "scheduler.fired"
        case .timer: "scheduler.timerFired"
        case .manual: "scheduler.runNow"
        }
        DiagnosticsStore.shared.note(crumb, detail: trigger.name)
        record(
            RunRecord(
                triggerID: trigger.id, name: trigger.name, at: Date(),
                outcome: late ? .late : .fired, source: source))
        router.execute(trigger.actions)

        if ScheduleMath.spentOneOffDue(
            for: trigger, asOf: Date(), calendar: .current) != nil
            || ScheduleMath.seriesCompleted(trigger, firedAt: Date(), calendar: .current)
        {
            DiagnosticsStore.shared.note("scheduler.archived", detail: trigger.name)
            model.updateScheduleTrigger(trigger.id) { $0.archived = true }
        }
    }

    private func record(_ entry: RunRecord) {
        history.insert(entry, at: 0)
        if history.count > Self.runLogLimit {
            history.removeLast(history.count - Self.runLogLimit)
        }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.runLogKey)
        }
    }

    private func persistEngineState() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(lastDue) {
            defaults.set(data, forKey: Self.lastDueKey)
        }
        defaults.set(lastSweep, forKey: Self.lastSweepKey)
    }

    private func name(of triggerID: String, in triggers: [ScheduleTrigger]) -> String {
        triggers.first { $0.id == triggerID }?.name ?? triggerID
    }
}

private struct SchedulerControllerKey: EnvironmentKey {
    static let defaultValue: SchedulerController? = nil
}

extension EnvironmentValues {
    var scheduler: SchedulerController? {
        get { self[SchedulerControllerKey.self] }
        set { self[SchedulerControllerKey.self] = newValue }
    }
}
