import PresenterCore
import Testing

@Suite struct DashboardSettingsLogicTests {
    @Test func remoteControlReadsOffUnlessThisComputerIsOnDashboards() {
        #expect(DashboardSettingsLogic.remoteControlShowsOn(signedIn: true, onDashboards: true, hasDashboards: true, saved: true))
        #expect(!DashboardSettingsLogic.remoteControlShowsOn(signedIn: false, onDashboards: true, hasDashboards: true, saved: true))
        #expect(!DashboardSettingsLogic.remoteControlShowsOn(signedIn: true, onDashboards: false, hasDashboards: true, saved: true))
        #expect(!DashboardSettingsLogic.remoteControlShowsOn(signedIn: true, onDashboards: true, hasDashboards: false, saved: true))
        #expect(!DashboardSettingsLogic.remoteControlShowsOn(signedIn: true, onDashboards: true, hasDashboards: true, saved: false))
    }

    @Test func remoteControlCanOnlyChangeWhileOnDashboards() {
        #expect(DashboardSettingsLogic.remoteControlEnabled(registered: true, onDashboards: true, hasDashboards: true))
        #expect(!DashboardSettingsLogic.remoteControlEnabled(registered: true, onDashboards: false, hasDashboards: true))
        #expect(!DashboardSettingsLogic.remoteControlEnabled(registered: false, onDashboards: true, hasDashboards: true))
    }
}
