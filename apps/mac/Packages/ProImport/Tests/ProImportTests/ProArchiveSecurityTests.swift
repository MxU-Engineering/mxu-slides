import Foundation
import Testing
@testable import ProImport

struct ProArchiveSecurityTests {
    @Test(arguments: ["../outside", "missing", "safe.pro"])
    func rejectsArchiveContainingASymbolicLink(target: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("safe.pro"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: target)
        let archive = root.appendingPathComponent("unsafe.probundle")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qy", archive.path, "link", "safe.pro"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        #expect(throws: (any Error).self) { try ProPresenterImporter.extractBundle(archive) }
    }
}
