import Foundation

public enum NDIRuntimeConfig {
    public static let fileName = "ndi-config.v1.json"
    static let environmentKey = "NDI_CONFIG_DIR"

    public static var sharedDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MxU Slides/NDI", isDirectory: true)
    }

    static func configJSON(allowedAdapterIPs: [String]) -> Data {
        let ndi: [String: Any] = allowedAdapterIPs.isEmpty
            ? [:]
            : ["adapters": ["allowed": allowedAdapterIPs]]

        return try! JSONSerialization.data(
            withJSONObject: ["ndi": ndi], options: [.sortedKeys])
    }

    public static func activate(
        directory: URL = sharedDirectory, allowedAdapterIPs: [String]
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try configJSON(allowedAdapterIPs: allowedAdapterIPs)
            .write(to: directory.appendingPathComponent(fileName), options: .atomic)
        adopt(directory: directory)
    }

    public static func adopt(directory: URL = sharedDirectory) {
        setenv(environmentKey, directory.path, 1)
    }
}
