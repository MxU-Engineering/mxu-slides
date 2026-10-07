import Foundation
import Testing
@testable import PresenterCore

struct RunOnlyPasscodeTests {
    @Test func recordRoundTripsAndRejectsWrongPIN() {
        let record = RunOnlyPasscode.record(for: "4207")
        #expect(RunOnlyPasscode.matches("4207", record: record))
        #expect(!RunOnlyPasscode.matches("4208", record: record))
        #expect(!RunOnlyPasscode.matches("", record: record))
        #expect(!record.contains("4207"), "record must never carry the PIN in clear")
    }

    @Test func saltsDiffer() {

        let a = RunOnlyPasscode.record(for: "123456")
        let b = RunOnlyPasscode.record(for: "123456")
        #expect(a != b)
        #expect(RunOnlyPasscode.matches("123456", record: a))
        #expect(RunOnlyPasscode.matches("123456", record: b))
    }

    @Test func garbageRecordsNeverMatch() {
        #expect(!RunOnlyPasscode.matches("1234", record: ""))
        #expect(!RunOnlyPasscode.matches("1234", record: "nonsense"))
        #expect(!RunOnlyPasscode.matches("1234", record: "zz$zz"))
    }

    @Test func pinRule() {
        #expect(RunOnlyPasscode.isValid(pin: "1234"))
        #expect(RunOnlyPasscode.isValid(pin: "123456"))
        #expect(!RunOnlyPasscode.isValid(pin: "123"))
        #expect(!RunOnlyPasscode.isValid(pin: "1234567"))
        #expect(!RunOnlyPasscode.isValid(pin: "12a4"))
        #expect(!RunOnlyPasscode.isValid(pin: "١٢٣٤"), "non-ASCII digits can't be typed back at the booth")
    }

    @Test func fiveWrongTriesThenEachWaits() {
        let start = Date(timeIntervalSince1970: 1_000)
        var attempts = RunOnlyAttempts()
        for _ in 0 ..< 4 { attempts.noteFailure(at: start) }
        #expect(attempts.secondsLeft(at: start) == 0)
        attempts.noteFailure(at: start)
        #expect(attempts.secondsLeft(at: start) == 30)
        #expect(attempts.secondsLeft(at: start.addingTimeInterval(29.5)) == 1)
        #expect(attempts.secondsLeft(at: start.addingTimeInterval(30)) == 0)
        attempts.noteFailure(at: start.addingTimeInterval(30))
        #expect(attempts.secondsLeft(at: start.addingTimeInterval(31)) == 29, "every try past five waits again")
        attempts.noteSuccess()
        #expect(attempts == RunOnlyAttempts())
    }

    @Test func runOnlyKeysRunTheServiceAndNeverEdit() {
        for command in [KeyCommand.nextSlide, .previousSlide, .clearAll, .videoPlayPause, .toggleSidebar, .toggleRightPanels] {
            #expect(command.runsInRunOnly, "\(command)")
        }
        for command in [KeyCommand.newPresentation, .newSlide, .newService, .modeEdit, .modeScheduler, .boldSelection, .findInLibrary] {
            #expect(!command.runsInRunOnly, "\(command)")
        }
        #expect(GeneratedKeyKind.combo.runsInRunOnly)
        #expect(GeneratedKeyKind.timerStart.runsInRunOnly)
        #expect(!GeneratedKeyKind.outputPreset.runsInRunOnly)
        #expect(!KeyBindingTarget.generated(GeneratedKey(.outputPreset, "p")).runsInRunOnly)
    }
}
