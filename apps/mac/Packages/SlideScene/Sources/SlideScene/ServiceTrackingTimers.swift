import Foundation

public enum ServiceTrackingTimers {
    public static let idPrefix = "service_tracking."
    public static let folderID = "service_tracking"
    public static let folderName = "Service Tracking"

    public enum Subject: String, CaseIterable, Sendable {
        case item, section, service, video

        public var title: String {
            switch self {
            case .item: "Item"
            case .section: "Section"
            case .service: "Service"
            case .video: "Video"
            }
        }
    }

    public enum Face: String, CaseIterable, Sendable {
        case remaining, elapsed
    }

    public static func faces(of subject: Subject) -> [Face] {
        Face.allCases
    }

    public enum LocalTiming: Sendable, Equatable {
        case local
    }

    public static func localTiming(fired: Bool) -> LocalTiming? {
        fired ? .local : nil
    }

    public static func localTimingEnds(
        firstFireAt: Date, servicePlannedSeconds: TimeInterval, lastFireAt: Date, itemPlannedSeconds: TimeInterval
    ) -> Date {
        guard servicePlannedSeconds > 0 else { return lastFireAt.addingTimeInterval(3600) }
        return max(firstFireAt.addingTimeInterval(servicePlannedSeconds), lastFireAt.addingTimeInterval(itemPlannedSeconds + 900))
    }

    public static func plannedSeconds(durations: [Int?]) -> TimeInterval {
        TimeInterval(durations.reduce(0) { $0 + ($1 ?? 0) })
    }

    public static func id(_ subject: Subject, _ face: Face) -> String {
        "\(idPrefix)\(subject.rawValue).\(face.rawValue)"
    }

    public static func name(_ subject: Subject, _ face: Face) -> String {
        "\(subject.title) \(face == .remaining ? "Remaining" : "Elapsed")"
    }

    public static func isPermanent(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    public static func subjectAndFace(of id: String) -> (Subject, Face)? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let parts = id.dropFirst(idPrefix.count).split(separator: ".")
        guard parts.count == 2, let subject = Subject(rawValue: String(parts[0])), let face = Face(rawValue: String(parts[1])) else { return nil }
        return (subject, face)
    }

    public static func description(_ subject: Subject, _ face: Face) -> String {
        switch (subject, face) {
        case (.item, .remaining): "Counts down the current service item from its length. Runs from the moment this Mac fires the item."
        case (.item, .elapsed): "Counts up from the moment this Mac fired the current service item."
        case (.section, .remaining): "Counts down the items under the current header from their combined length, starting at the first one fired."
        case (.section, .elapsed): "Counts up from the first item fired under the current header."
        case (.service, .remaining): "Counts down the service's combined item lengths, starting at the first item fired on this Mac."
        case (.service, .elapsed): "Counts up from the moment the first item was fired."
        case (.video, .remaining): "Counts down the video playing for the current item."
        case (.video, .elapsed): "Counts up from the start of the video playing for the current item."
        }
    }

    public static var allIDs: [String] {
        Subject.allCases.flatMap { subject in faces(of: subject).map { id(subject, $0) } }
    }

    public static func remaining(
        _ subject: Subject, plannedSeconds: TimeInterval, remainingSeconds: TimeInterval?,
        running: Bool, now: Date, warnings: [TimerWarning] = TimerWarning.defaults
    ) -> TimerSnapshot {
        guard let remainingSeconds else { return idle(subject, .remaining) }
        let planned = max(plannedSeconds, 0)
        return TimerSnapshot(
            id: id(subject, .remaining), name: name(subject, .remaining), mode: .countdown,
            isRunning: running, runningSince: running ? now : nil,
            banked: planned - remainingSeconds, durationSeconds: planned, warnings: warnings)
    }

    public static func elapsed(
        _ subject: Subject, elapsedSeconds: TimeInterval, limitSeconds: TimeInterval = 0,
        running: Bool, now: Date, warnings: [TimerWarning] = TimerWarning.defaults
    ) -> TimerSnapshot {
        TimerSnapshot(
            id: id(subject, .elapsed), name: name(subject, .elapsed), mode: .countUp,
            isRunning: running, runningSince: running ? now : nil,
            banked: max(elapsedSeconds, 0), durationSeconds: max(limitSeconds, 0), warnings: warnings)
    }

    public static func idle(_ subject: Subject, _ face: Face) -> TimerSnapshot {
        TimerSnapshot(
            id: id(subject, face), name: name(subject, face),
            mode: face == .remaining ? .countdown : .countUp, isRunning: false)
    }
}

extension ServiceTrackingTimers {

    public struct Merge: Equatable, Sendable {
        public var timers: [TimerSnapshot]
        public var board: TimerBoard

        public var timersChanged: Bool

        public var userTimersChanged: Bool
        public var boardChanged: Bool
    }

    public static func merge(system: [TimerSnapshot], into timers: [TimerSnapshot], board: TimerBoard) -> Merge {
        let user = timers.filter { !isPermanent($0.id) }
        var merged = user + system
        var nextBoard = board
        nextBoard.ensureFolder(id: folderID, name: folderName)
        nextBoard.reconcile(with: merged.map(\.id))
        for timer in system where nextBoard.folder(containing: timer.id)?.id != folderID {
            nextBoard.moveTimer(id: timer.id, intoFolder: folderID)
        }
        let order = nextBoard.allTimerIDs
        merged.sort { a, b in
            (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
        return Merge(
            timers: merged, board: nextBoard,
            timersChanged: merged != timers,
            userTimersChanged: merged.filter { !isPermanent($0.id) } != user,
            boardChanged: nextBoard != board)
    }
}
