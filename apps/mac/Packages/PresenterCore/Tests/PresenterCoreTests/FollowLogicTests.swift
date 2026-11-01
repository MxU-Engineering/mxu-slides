import Foundation
import Testing

@testable import PresenterCore

@Suite struct FollowLogicTests {
    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @Test func aBackupHoldsGearTheBoothAlreadyDroveAndRunsThePicture() {
        #expect(Follow.holds(.midiOut) && Follow.holds(.captureStart) && Follow.holds(.captureStop))
        #expect(!Follow.holds(.fireLiveInput) && !Follow.holds(.enableAudioInput) && !Follow.holds(.switchOutputPreset))
    }

    @Test func aScreenWithNoOutputHereIsNamed() {
        let defaults: [String: Any] = [
            "outputs.placeholderScreens": json([
                ["id": "A", "name": "Center", "deviceDisplayUUID": "D1"],
                ["id": "B", "name": "Stream", ],
                ["id": "C", "name": "Stage Left"],
                ["id": "D", "name": "Lobby"],
                ["id": "E", "name": "Wall"],
            ]),
            "ndi.screenBackings": ["B"],
            "syphon.screenBackings": ["E"],
            "decklink.screenBackings": json(["D": ["port": 1]]),
        ]
        #expect(Follow.unconnectedScreens(in: defaults) == ["Stage Left"])
        #expect(Follow.unconnectedScreens(in: [:]).isEmpty)
    }

    @Test func theBannerSaysWhereThePairStands() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let fire = Date(timeIntervalSince1970: 1_793_361_730)
        #expect(Follow.banner(following: "Booth Mac", state: .live, lastFire: fire, calendar: calendar).detail.hasPrefix("Last fire 8:02:10\u{202F}AM."))
        #expect(Follow.banner(following: "Booth Mac", state: .live, lastFire: nil, calendar: calendar).title == "Backing up Booth Mac.")
        #expect(Follow.banner(following: "Booth Mac", state: .lost(frozen: true), lastFire: nil).title == "Booth Mac froze.")
        #expect(Follow.banner(following: "Booth Mac", state: .lost(frozen: false), lastFire: nil).title == "Booth Mac stopped answering.")
        #expect(Follow.banner(following: "Booth Mac", state: .gaveUp, lastFire: nil).title == "Can't reach Booth Mac.")
    }

    @Test func theHigherTakeoverNumberStands() {
        let start = FollowRole(term: 0, inCharge: "booth")
        let tookOver = start.handed(to: "backup")
        #expect(tookOver == FollowRole(term: 1, inCharge: "backup"))
        #expect(start.newer(tookOver) == tookOver, "a booth that unfreezes hears it and steps down")
        #expect(tookOver.newer(start) == nil, "an older word never wins")
        let handedBack = tookOver.handed(to: "booth")
        #expect(handedBack.term == 2 && handedBack.inCharge == "booth")
    }

    @Test func aBackupTakesOverOnItsOwnOnlyAfterLosingALiveBooth() {
        #expect(Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: true, now: .lost(frozen: true)))
        #expect(Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: true, now: .lost(frozen: false)))
        #expect(!Follow.takesOverOnItsOwn(automatic: false, backingUp: true, wasLive: true, now: .lost(frozen: false)), "Wait for Take Over")
        #expect(!Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: false, now: .lost(frozen: false)), "never reached it")
        #expect(!Follow.takesOverOnItsOwn(automatic: true, backingUp: false, wasLive: true, now: .lost(frozen: false)), "already in charge")
        #expect(!Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: true, now: .connecting))
    }

    @Test func theInChargeAndSteppedDownBannersNameTheOtherComputer() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let at = Date(timeIntervalSince1970: 1_793_375_520)
        #expect(Follow.inChargeBanner(over: "Booth Mac", since: at, calendar: calendar).title == "This computer took over from Booth Mac at 11:52\u{202F}AM.")
        #expect(Follow.steppedDownBanner(backup: "Backup Mac").title == "Backup Mac took over.")
    }
}
