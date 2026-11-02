import Foundation

public enum ZipExtract {
    public struct Failure: LocalizedError {
        public var detail: String
        public var errorDescription: String? { detail.isEmpty ? "ditto could not extract the file" : detail }
    }

    public static func extract(_ url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
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
            throw Failure(detail: detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try ImportArchiveValidation.validateExtractedFiles(in: destination)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwX", destination.path]
        try chmod.run()
        chmod.waitUntilExit()
        return destination
    }
}
