import Foundation

public enum PPTXImportError: LocalizedError {
    case extractFailed(String)
    case invalidPackage(String)

    public var errorDescription: String? {
        switch self {
        case .extractFailed(let detail):
            return detail.isEmpty ? "ditto could not extract the file" : detail
        case .invalidPackage(let detail):
            return detail
        }
    }
}

enum PPTXArchive {

    nonisolated static func extract(_ url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, destination.path]
        let stderr = Pipe()
        ditto.standardError = stderr
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PPTXImportError.extractFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwX", destination.path]
        try chmod.run()
        chmod.waitUntilExit()

        return destination
    }
}
