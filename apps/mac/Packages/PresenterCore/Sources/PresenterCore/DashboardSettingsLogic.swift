import Foundation

public enum DashboardSettingsLogic {

    public static func remoteControlShowsOn(signedIn: Bool, onDashboards: Bool, hasDashboards: Bool, saved: Bool) -> Bool {
        signedIn && onDashboards && hasDashboards && saved
    }

    public static func remoteControlEnabled(registered: Bool, onDashboards: Bool, hasDashboards: Bool) -> Bool {
        registered && onDashboards && hasDashboards
    }
}
