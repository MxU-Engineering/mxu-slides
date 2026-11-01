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
}
