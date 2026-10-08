import Foundation
import Testing
@testable import ProImport

struct ProArchiveSecurityTests {
    @Test func rejectsArchiveContainingASymbolicLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        let archive = root.appendingPathComponent("unsafe.probundle")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qy", archive.path, "link"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        #expect(throws: (any Error).self) { try ProPresenterImporter.extractBundle(archive) }
    }
}
