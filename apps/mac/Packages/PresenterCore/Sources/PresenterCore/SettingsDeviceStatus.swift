import Foundation

public enum SettingsDeviceStatus {
    public static let notConnected = "Not connected"

    public static func showsNotConnected(assigned: String?, found: Bool) -> Bool {
        if let assigned, !assigned.isEmpty {
            !found
        } else {
            false
        }
    }

    public static func ndiFound(_ fragment: String, discovered: [String]?) -> Bool {
        if let discovered {
            discovered.contains { $0.localizedCaseInsensitiveContains(fragment) }
        } else {
            true
        }
    }
}
