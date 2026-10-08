import Foundation
import Testing
@testable import PPTXImport

struct PPTXSecurityTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func rejectsExternalEntities() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("private.txt")
        try "PRIVATE_SENTINEL".write(to: secret, atomically: true, encoding: .utf8)
        let xml = "<!DOCTYPE root [<!ENTITY secret SYSTEM '\(secret.absoluteString)'>]><root>&secret;</root>"
        try xml.write(to: root.appendingPathComponent("slide.xml"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try PPTXPackage(root: root).document(at: "slide.xml") }
    }

    @Test func rejectsTraversalAndSymlinkParts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = PPTXPackage(root: root)
        #expect(throws: (any Error).self) { try package.fileURL(forPart: "../private.xml") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try package.fileURL(forPart: "link/private.xml") }
        #expect(try package.fileURL(forPart: "ppt/slides/slide1.xml").lastPathComponent == "slide1.xml")
    }

    @Test func rejectsArchiveContainingASymbolicLink() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.deletingLastPathComponent())
        let archive = root.appendingPathComponent("unsafe.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qy", archive.path, "link"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        #expect(throws: (any Error).self) { try PPTXArchive.extract(archive) }
    }
}
