import Foundation
import Observation
import PresenterCore
import SlideScene

@MainActor
@Observable
final class TimersController {
    private(set) var timers: [TimerSnapshot] = []

    private(set) var board = TimerBoard()
    private let render: RenderContext

    @ObservationIgnored var moveUndo: MoveUndoJournal?

    init(render: RenderContext) {
        self.render = render
        restore()
        restoreBoard()
        push()
    }

    func snapshot(id: String) -> TimerSnapshot? {
        timers.first { $0.id == id }
    }

    func setSystemTimers(_ system: [TimerSnapshot]) {
        let merged = ServiceTrackingTimers.merge(system: system, into: timers, board: board)
        if merged.timersChanged {
            timers = merged.timers
            publish()
        }
        if merged.userTimersChanged { save() }
        if merged.boardChanged {
            board = merged.board
            saveBoard()
        }
    }

    private static func isPermanent(_ id: String) -> Bool {
        ServiceTrackingTimers.isPermanent(id)
    }

    func snapshots(ids: [String]) -> [TimerSnapshot] {
        ids.compactMap { snapshot(id: $0) }
    }

    func importTimer(id: String, name: String, mode: TimerSnapshot.Mode, durationSeconds: TimeInterval = 0, targetTime: Date? = nil) {
        guard !Self.isPermanent(id) else { return }
        let snapshot = TimerSnapshot(
            id: id, name: name, mode: mode,
            durationSeconds: max(0, durationSeconds),
            targetTime: targetTime,
            armedAt: mode == .countdownToTime ? Date() : nil
        )
        if let existing = timers.firstIndex(where: { $0.id == id }) {
            timers[existing] = snapshot
        } else {
            timers.append(snapshot)
        }
        reconcileBoard()
        push()
    }

    func addCountdown(name: String = "Countdown", minutes: Int = 10) {
        addCountdown(name: name, seconds: TimeInterval(minutes * 60))
    }

    func addCountdown(name: String = "Countdown", seconds: TimeInterval) {
        timers.append(TimerSnapshot(
            name: name, mode: .countdown, durationSeconds: max(0, seconds)
        ))
        reconcileBoard()
        push()
    }

    func addCountdownToTime(name: String? = nil, hour: Int, minute: Int) {
        let target = Self.nextOccurrence(hour: hour, minute: minute)
        timers.append(TimerSnapshot(
            name: name ?? "Until \(Self.wallLabel(hour: hour, minute: minute))",
            mode: .countdownToTime, targetTime: target, armedAt: Date()
        ))
        reconcileBoard()
        push()
    }

    func addCountUp(name: String = "Count Up", limitSeconds: TimeInterval = 0) {
        timers.append(TimerSnapshot(
            name: name, mode: .countUp, durationSeconds: max(0, limitSeconds)
        ))
        reconcileBoard()
        push()
    }

    func setLimit(id: String, seconds: TimeInterval) {
        mutate(id) { $0.durationSeconds = max(0, seconds) }
    }

    func setWarnings(id: String, _ warnings: [TimerWarning]) {
        mutate(id) {
            $0.warnings = warnings.sorted { $0.remainingSeconds > $1.remainingSeconds }
        }
    }

    func moveTimer(id: String, beforeNode nodeID: String?) {
        guard !Self.isPermanent(id) else { return }
        let before = board.orderSnapshot
        board.moveTimer(id: id, beforeNode: nodeID)
        applyBoardOrder()
        registerMoveUndo(before: before)
    }

    func moveTimer(id: String, intoFolder folderID: String) {
        guard !Self.isPermanent(id), folderID != ServiceTrackingTimers.folderID else { return }
        let before = board.orderSnapshot
        board.moveTimer(id: id, intoFolder: folderID)
        applyBoardOrder()
        registerMoveUndo(before: before)
    }

    func moveFolder(id: String, beforeNode nodeID: String?) {
        let before = board.orderSnapshot
        board.moveFolder(id: id, beforeNode: nodeID)
        applyBoardOrder()
        registerMoveUndo(before: before)
    }

    private func registerMoveUndo(before: TimerBoardOrder) {
        let after = board.orderSnapshot
        guard let moveUndo, before != after, before.membership == after.membership
        else { return }
        let apply: (TimerBoardOrder) -> Bool = { [weak self] order in
            guard let self,
                  !order.membership.isDisjoint(with: board.orderSnapshot.membership)
            else { return false }
            board.restore(order: order)
            applyBoardOrder()
            return true
        }
        moveUndo.registerMove(
            label: "Move Timer", undo: { apply(before) }, redo: { apply(after) }
        )
    }

    @discardableResult
    func addFolder(named name: String = "Folder") -> String {
        let id = board.addFolder(named: name)
        saveBoard()
        return id
    }

    func renameFolder(id: String, to name: String) {
        guard id != ServiceTrackingTimers.folderID else { return }
        let oldName = board.folder(id: id)?.name
        board.renameFolder(id: id, to: name)
        saveBoard()

        guard let oldName, let newName = board.folder(id: id)?.name, oldName != newName
        else { return }
        let apply: (String) -> Bool = { [weak self] value in
            guard let self, board.folder(id: id) != nil else { return false }
            board.renameFolder(id: id, to: value)
            saveBoard()
            return true
        }
        moveUndo?.registerEdit(
            key: "timerFolderName:\(id)", label: "Rename Folder",
            undo: { apply(oldName) }, redo: { apply(newName) }
        )
    }

    func setFolderCollapsed(id: String, _ collapsed: Bool) {
        board.setCollapsed(id: id, collapsed)
        saveBoard()
    }

    func removeFolder(id: String) {
        guard id != ServiceTrackingTimers.folderID else { return }
        board.removeFolder(id: id)
        applyBoardOrder()
    }

    private func applyBoardOrder() {
        let order = board.allTimerIDs
        timers.sort { a, b in
            (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
        push()
        saveBoard()
    }

    private func reconcileBoard() {
        board.reconcile(with: timers.map(\.id))
        saveBoard()
    }

    func rename(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !Self.isPermanent(id) else { return }
        let oldName = snapshot(id: id)?.name
        mutate(id) { $0.name = trimmed }

        guard let oldName, oldName != trimmed else { return }
        let apply: (String) -> Bool = { [weak self] value in
            guard let self, snapshot(id: id) != nil else { return false }
            mutate(id) { $0.name = value }
            return true
        }
        moveUndo?.registerEdit(
            key: "timerName:\(id)", label: "Rename Timer",
            undo: { apply(oldName) }, redo: { apply(trimmed) }
        )
    }

    func setDuration(id: String, seconds: TimeInterval) {
        mutate(id) {
            $0.durationSeconds = max(0, seconds)
            $0.banked = 0
            $0.runningSince = $0.isRunning ? Date() : nil
        }
    }

    func setTarget(id: String, hour: Int, minute: Int) {
        mutate(id) {
            $0.targetTime = Self.nextOccurrence(hour: hour, minute: minute)
            $0.armedAt = Date()
        }
    }

    func remove(id: String) {
        guard !Self.isPermanent(id) else { return }
        timers.removeAll { $0.id == id }
        reconcileBoard()
        push()
    }

    func configure(
        id: String, mode: TimerSnapshot.Mode? = nil,
        durationSeconds: TimeInterval? = nil,
        hour: Int? = nil, minute: Int? = nil
    ) {
        mutate(id) {
            let newMode = mode ?? $0.mode
            let modeChanged = newMode != $0.mode
            $0.mode = newMode
            if let durationSeconds {
                $0.durationSeconds = max(0, durationSeconds)
            }
            if newMode == .countdownToTime {
                if let hour {
                    $0.targetTime = Self.nextOccurrence(hour: hour, minute: minute ?? 0)
                }
                if modeChanged || hour != nil { $0.armedAt = Date() }
            }
            if modeChanged || (newMode == .countdown && durationSeconds != nil) {
                $0.banked = 0
                $0.runningSince = $0.isRunning ? Date() : nil
            }
        }
    }

    func start(id: String) {
        mutate(id) {
            guard !$0.isRunning else { return }
            $0.isRunning = true
            $0.runningSince = Date()
        }
    }

    func pause(id: String) {
        mutate(id) {
            guard $0.isRunning else { return }
            $0.banked = $0.elapsed(at: Date())
            $0.isRunning = false
            $0.runningSince = nil
        }
    }

    func toggle(id: String) {
        guard let timer = timers.first(where: { $0.id == id }) else { return }
        timer.isRunning ? pause(id: id) : start(id: id)
    }

    func reset(id: String) {
        mutate(id) {
            $0.banked = 0
            $0.isRunning = false
            $0.runningSince = nil
            if $0.mode == .countdownToTime, let target = $0.targetTime {

                let parts = Calendar.current.dateComponents([.hour, .minute], from: target)
                $0.targetTime = Self.nextOccurrence(
                    hour: parts.hour ?? 0, minute: parts.minute ?? 0
                )
                $0.armedAt = Date()
            }
        }
    }

    private func mutate(_ id: String, _ change: (inout TimerSnapshot) -> Void) {
        guard !Self.isPermanent(id), let index = timers.firstIndex(where: { $0.id == id }) else { return }
        change(&timers[index])
        push()
    }

    private func push() {
        publish()
        save()
    }

    private func publish() {
        var info = render.confidenceInfo
        info.timers = timers
        render.confidenceInfo = info
    }

    private struct PersistedTimer: Codable {
        var id: String
        var name: String
        var mode: String
        var durationSeconds: TimeInterval
        var hour: Int?
        var minute: Int?

        var warnings: [TimerWarning]?
    }

    private static let defaultsKey = "serviceControls.timers"

    private func save() {
        let configs = timers.filter { !Self.isPermanent($0.id) }.map { timer in
            let wall = timer.targetTime.map {
                Calendar.current.dateComponents([.hour, .minute], from: $0)
            }
            return PersistedTimer(
                id: timer.id, name: timer.name,
                mode: Self.modeKey(timer.mode),
                durationSeconds: timer.durationSeconds,
                hour: wall?.hour, minute: wall?.minute,
                warnings: timer.warnings == TimerWarning.defaults ? nil : timer.warnings
            )
        }
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let configs = try? JSONDecoder().decode([PersistedTimer].self, from: data)
        else { return }
        timers = configs.compactMap { config in
            guard let mode = Self.mode(forKey: config.mode) else { return nil }
            return TimerSnapshot(
                id: config.id, name: config.name, mode: mode,
                durationSeconds: config.durationSeconds,
                targetTime: config.hour.map {
                    Self.nextOccurrence(hour: $0, minute: config.minute ?? 0)
                },
                armedAt: config.hour != nil ? Date() : nil,
                warnings: config.warnings ?? TimerWarning.defaults
            )
        }
    }

    private static let boardKey = "serviceControls.timerBoard"

    private func saveBoard() {
        if let data = try? JSONEncoder().encode(board) {
            UserDefaults.standard.set(data, forKey: Self.boardKey)
        }
    }

    private func restoreBoard() {
        if let data = UserDefaults.standard.data(forKey: Self.boardKey),
           let saved = try? JSONDecoder().decode(TimerBoard.self, from: data) {
            board = saved
        }
        board.reconcile(with: timers.map(\.id))
        let order = board.allTimerIDs
        timers.sort { a, b in
            (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
    }

    private static func modeKey(_ mode: TimerSnapshot.Mode) -> String {
        switch mode {
        case .countdown: "countdown"
        case .countdownToTime: "countdownToTime"
        case .countUp: "countUp"
        }
    }

    private static func mode(forKey key: String) -> TimerSnapshot.Mode? {
        switch key {
        case "countdown": .countdown
        case "countdownToTime": .countdownToTime
        case "countUp": .countUp
        case "elapsed": .countUp 
        default: nil
        }
    }

    static func nextOccurrence(hour: Int, minute: Int, after date: Date = Date()) -> Date {
        Calendar.current.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime
        ) ?? date
    }

    static func wallLabel(hour: Int, minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
    }
}
