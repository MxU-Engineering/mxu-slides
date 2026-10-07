import Testing

@testable import DeckLinkKit

@Test func runtimeProbeAnswersWithoutCrashing() {
    _ = DeckLinkRuntime.isAvailable
}

@Test func enumerationDegradesGracefully() {
    let devices = DeckLinkRuntime.devices()
    if !DeckLinkRuntime.isAvailable {
        #expect(devices.isEmpty)
    }
    for device in devices {
        #expect(!device.name.isEmpty)
    }
}

@Test func openingAMissingDeviceFailsWithAMessage() {

    #expect(throws: DeckLinkError.self) {
        _ = try DeckLinkOutput(
            persistentID: .min, modeID: 0, keying: .off)
    }
}

@Test func modeEnumerationDegradesGracefully() {

    #expect(DeckLinkRuntime.displayModes(persistentID: .min).isEmpty)
}
