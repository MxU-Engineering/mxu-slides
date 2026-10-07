import Testing

@testable import AudioEngine

@Test func returningDeviceStarts() {
    #expect(InputHotplug.decide(devicePresent: true, captureLive: false) == .start)
}

@Test func vanishedDeviceSuspends() {
    #expect(InputHotplug.decide(devicePresent: false, captureLive: true) == .suspend)
}

@Test func matchingStatesNeverChurn() {
    #expect(InputHotplug.decide(devicePresent: true, captureLive: true) == .none)
    #expect(InputHotplug.decide(devicePresent: false, captureLive: false) == .none)
}
