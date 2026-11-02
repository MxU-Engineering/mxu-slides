import Foundation

public enum ScheduledBackup {
    public static let folderKey = "backup.scheduled.folder"
    public static let lastRunKey = "backup.scheduled.lastRun"
    public static let lastProblemKey = "backup.scheduled.lastProblem"
    public static let hour = 3
    public static let keep = 7

    public static func lastSlot(before now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    public static func nextSlot(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: lastSlot(before: now, calendar: calendar)) ?? now
    }

    public static func due(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastRun else { return true }
        return lastRun < lastSlot(before: now, calendar: calendar)
    }

    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "MxU Slides Library %04d-%02d-%02d.mxubackup", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func pruned(_ names: [String]) -> [String] {
        let ours = names.filter { $0.hasPrefix("MxU Slides Library ") && $0.hasSuffix(".mxubackup") }.sorted()
        return Array(ours.dropLast(keep))
    }

    public static func caption(folder: String?, lastRun: Date?, problem: String?, calendar: Calendar = .current) -> String {
        guard let folder else { return "Off. Choose a folder or drive to back up to every night." }
        let name = (folder as NSString).lastPathComponent
        if let problem { return "The last backup to \(name) didn't finish: \(problem)" }
        let last = lastRun.map { " Last: \($0.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).hour().minute()))." } ?? ""
        return "Every night at 3 AM to \(name), keeping the last \(keep).\(last)"
    }
}
