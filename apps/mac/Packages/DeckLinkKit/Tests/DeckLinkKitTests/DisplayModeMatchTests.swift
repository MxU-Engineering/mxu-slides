import Testing
@testable import DeckLinkKit

@Suite struct DisplayModeMatchTests {
    private func mode(
        _ name: String, _ width: Int = 1920, _ height: Int = 1080,
        duration: Int64, scale: Int64, progressive: Bool = true
    ) -> DeckLinkDisplayMode {
        DeckLinkDisplayMode(
            name: name, modeID: UInt32(name.hashValue & 0xFFFF) + 1,
            width: width, height: height,
            frameDuration: duration, timeScale: scale, progressive: progressive)
    }

    @Test func fractionalSiblingBeatsExactRate() {

        let modes = [
            mode("1080p29.97", duration: 1001, scale: 30000),
            mode("1080p30", duration: 1000, scale: 30000),
        ]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match?.name == "1080p29.97")
    }

    @Test func fractionalSiblingFillsInWhenExactIsAbsent() {
        let modes = [
            mode("1080p25", duration: 1000, scale: 25000),
            mode("1080p29.97", duration: 1001, scale: 30000),
        ]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match?.name == "1080p29.97")
    }

    @Test func progressiveBeatsInterlacedAtTheSameRate() {
        let modes = [
            mode("1080i29.97", duration: 1001, scale: 30000, progressive: false),
            mode("1080p29.97", duration: 1001, scale: 30000),
        ]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match?.name == "1080p29.97")
    }

    @Test func geometryMismatchYieldsNothing() {
        let modes = [mode("720p30", 1280, 720, duration: 1000, scale: 30000)]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match == nil)
    }

    @Test func distantRatesNeverMatch() {

        let modes = [mode("1080p25", duration: 1000, scale: 25000)]
        let match = DeckLinkDisplayMode.bestMatch(
            width: 1920, height: 1080, framesPerSecond: 30, in: modes)
        #expect(match == nil)
    }
}
