import Foundation
import Testing

@testable import PresenterCore

@Suite struct ScheduledBackupTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func runsOnceAfterEach3AMAndCatchesUpAMissedNight() {
        #expect(ScheduledBackup.due(lastRun: nil, now: at(2, 10), calendar: calendar), "never ran")
        #expect(!ScheduledBackup.due(lastRun: at(2, 3, 1), now: at(2, 23), calendar: calendar), "ran tonight already")
        #expect(ScheduledBackup.due(lastRun: at(1, 3, 1), now: at(2, 9), calendar: calendar), "the app was closed at 3 AM")
        #expect(!ScheduledBackup.due(lastRun: at(1, 23), now: at(2, 2, 59), calendar: calendar), "not 3 AM yet")
        #expect(ScheduledBackup.nextSlot(after: at(2, 10), calendar: calendar) == at(3, 3))
        #expect(ScheduledBackup.nextSlot(after: at(2, 1), calendar: calendar) == at(2, 3))
    }

    @Test func keepsTheNewestSevenOfItsOwnFiles() {
        let names = (1...9).map { ScheduledBackup.fileName(for: at($0, 3), calendar: calendar) } + ["Easter.mxubackup"]
        #expect(names[0] == "MxU Slides Library 2026-11-01.mxubackup")
        #expect(ScheduledBackup.pruned(names) == Array(names[0..<2]), "the two oldest go; other files stay")
    }

    @Test func theCaptionSaysWhereAndWhen() {
        #expect(ScheduledBackup.caption(folder: nil, lastRun: nil, problem: nil).hasPrefix("Off."))
        #expect(ScheduledBackup.caption(folder: "/Volumes/Backup/MxU", lastRun: nil, problem: nil, calendar: calendar) == "Every night at 3 AM to MxU, keeping the last 7.")
        #expect(ScheduledBackup.caption(folder: "/Volumes/Backup/MxU", lastRun: nil, problem: "The disk is full.").contains("didn't finish"))
    }
}
