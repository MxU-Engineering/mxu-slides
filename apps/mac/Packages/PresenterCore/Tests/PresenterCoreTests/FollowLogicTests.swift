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
        #expect(Follow.banner(following: "Booth Mac", state: .lost(frozen: false), lastFire: nil, boothQuit: true).title == "Booth Mac quit.")
        #expect(Follow.banner(following: "Booth Mac", state: .gaveUp, lastFire: nil, boothQuit: true).title == "Booth Mac quit.", "still waiting after the retries ran out")
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
        #expect(!Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: true, boothQuit: true, now: .lost(frozen: false)), "a Quit isn't a failure")
        #expect(!Follow.takesOverOnItsOwn(automatic: true, backingUp: true, wasLive: true, now: .connecting))
    }

    @Test func theInChargeAndSteppedDownBannersNameTheOtherComputer() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        let at = Date(timeIntervalSince1970: 1_793_375_520)
        #expect(Follow.inChargeBanner(over: "Booth Mac", since: at, calendar: calendar).title == "This computer took over from Booth Mac at 11:52\u{202F}AM.")
        #expect(Follow.inChargeBanner(over: "Booth Mac", since: at, onItsOwn: true, calendar: calendar).title == "Booth Mac stopped answering, so this computer took over at 11:52\u{202F}AM.")
        #expect(Follow.inChargeBanner(over: "Booth Mac", since: at, boothStreamed: true, calendar: calendar).detail == "Booth Mac was streaming. Start Stream Here to send it from this computer.")
        #expect(Follow.steppedDownBanner(backup: "Backup Mac").title == "Backup Mac took over.")
        #expect(Follow.copiedLine(0) == "")
        #expect(Follow.copiedLine(1) == " 1 item copied here over the network.")
        #expect(Follow.copiedLine(3) == " 3 items copied here over the network.")
    }
}

@Suite struct FollowRoleStartTests {
    @Test func aFreshBackupTakesTheBoothsNumberSoItsTakeoverStands() {
        let fresh = FollowRole.start(booth: "booth")
        let booth = FollowRole(term: 4, inCharge: "booth")
        let joined = fresh.newer(booth) ?? fresh
        #expect(joined.term == 4)
        #expect(joined.handed(to: "backup").newer(booth) == nil, "the booth's old number never wins back a takeover")
        #expect(booth.newer(joined.handed(to: "backup"))?.inCharge == "backup")
    }
}

@Suite struct FollowHandBackTests {
    let took = Date(timeIntervalSince1970: 1000)

    @Test func aDroppedLinkGivesWayToTheSameBooth() {
        #expect(Follow.handsBackOnReturn(onItsOwn: true, frozen: false, since: took, now: took + 12, launchThen: "a", launchNow: "a"))
        #expect(!Follow.handsBackOnReturn(onItsOwn: true, frozen: false, since: took, now: took + 12, launchThen: "a", launchNow: "b"), "it relaunched: a crash")
        #expect(!Follow.handsBackOnReturn(onItsOwn: true, frozen: true, since: took, now: took + 12, launchThen: "a", launchNow: "a"), "it froze")
        #expect(!Follow.handsBackOnReturn(onItsOwn: false, frozen: false, since: took, now: took + 12, launchThen: "a", launchNow: "a"), "Take Over by hand")
        #expect(!Follow.handsBackOnReturn(onItsOwn: true, frozen: false, since: took, now: took + 61, launchThen: "a", launchNow: "a"), "gone over a minute")
        #expect(!Follow.handsBackOnReturn(onItsOwn: true, frozen: false, since: took, now: took + 12, launchThen: nil, launchNow: "a"), "never heard its launch")
        #expect(Follow.cameBackLine("Booth Mac", after: 12.4) == "Booth Mac came back after 12 seconds, so it answers again.")
    }

    @Test func theBoothNamesItsBackup() {
        #expect(Follow.boothBackupLine("Backup Mac", connected: true).hasPrefix("Backup Mac is backing up this computer"))
        #expect(Follow.boothBackupLine("Backup Mac", connected: false).hasPrefix("Backup Mac isn't connected."))
        #expect(Follow.backupDroppedBanner("Backup Mac").title == "Backup Mac stopped following.")
        #expect(Follow.boothBackupLine("Backup Mac", connected: true, inCharge: true).hasPrefix("Backup Mac took over"))
    }
}
