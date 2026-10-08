import Foundation

public enum ImportArchiveValidation {
    public enum ValidationError: LocalizedError {
        case unsafeEntry(String)
        case unreadableArchive

        public var errorDescription: String? {
            switch self {
            case .unsafeEntry(let name): "The archive contains an unsafe file: \(name)."
            case .unreadableArchive: "The extracted archive could not be inspected."
            }
        }
    }

    /// Validate before reading imported content or recursively changing permissions.
    /// ZIP symbolic links could otherwise expose files outside the extraction folder.
    public static func validateExtractedFiles(in root: URL) throws {
        var traversalFailed = false
        guard let entries = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            errorHandler: { _, _ in traversalFailed = true; return false }
        ) else { throw ValidationError.unreadableArchive }
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else {
                throw ValidationError.unsafeEntry(url.lastPathComponent)
            }
        }
        if traversalFailed { throw ValidationError.unreadableArchive }
    }
}
