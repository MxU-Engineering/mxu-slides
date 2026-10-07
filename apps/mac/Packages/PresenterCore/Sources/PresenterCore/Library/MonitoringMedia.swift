import Foundation

public enum MonitoringMedia {

    public static func wanted(
        onAir: [String: Bool?], monitoring: [String: Bool?]
    ) -> [String: Bool?] {
        onAir.merging(monitoring) { onAir, _ in onAir }
    }

    public static func liveInputs(onAir: [String: Bool?], prefix: String) -> Set<String> {
        Set(onAir.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }
}
