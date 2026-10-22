import PresenterCore
import Testing

@Suite struct SettingsDeviceStatusTests {
    @Test func assignedButMissingIsNotConnected() {
        #expect(SettingsDeviceStatus.showsNotConnected(assigned: "uid-1", found: false))
        #expect(!SettingsDeviceStatus.showsNotConnected(assigned: "uid-1", found: true))
    }

    @Test func nothingAssignedIsNeverMissing() {
        #expect(!SettingsDeviceStatus.showsNotConnected(assigned: nil, found: false))
        #expect(!SettingsDeviceStatus.showsNotConnected(assigned: "", found: false))
    }

    @Test func ndiMatchesByNameFragment() {
        let discovered = ["MCK-PROPRESENTER.LOCAL (Scan Converter)", "LOCALHOST (ProPresenter Drawing)"]
        #expect(SettingsDeviceStatus.ndiFound("scan converter", discovered: discovered))
        #expect(!SettingsDeviceStatus.ndiFound("Camera 2", discovered: discovered))
    }

    @Test func ndiIsFoundUntilTheFirstSearchAnswers() {
        #expect(SettingsDeviceStatus.ndiFound("Camera 2", discovered: nil))
        #expect(!SettingsDeviceStatus.ndiFound("Camera 2", discovered: []))
    }
}
