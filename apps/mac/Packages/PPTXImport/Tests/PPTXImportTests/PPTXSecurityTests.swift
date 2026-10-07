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
        try "<root/>".write(to: root.appendingPathComponent("safe.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("internal.xml").path, withDestinationPath: "safe.xml")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling.xml").path, withDestinationPath: "missing.xml")
        #expect(throws: (any Error).self) { try package.document(at: "internal.xml") }
        #expect(throws: (any Error).self) { try package.fileURL(forPart: "dangling.xml") }
        let traversal = package.resolveTarget("../../../private.xml", relativeTo: "ppt/slides/slide1.xml")
        #expect(throws: (any Error).self) { try package.fileURL(forPart: traversal) }
        let absoluteTraversal = package.resolveTarget("/../private.xml", relativeTo: "ppt/slides/slide1.xml")
        #expect(throws: (any Error).self) { try package.fileURL(forPart: absoluteTraversal) }
        #expect(package.resolveTarget("../media/image.png", relativeTo: "ppt/slides/slide1.xml") == "ppt/media/image.png")
        #expect(try package.fileURL(forPart: "ppt/slides/slide1.xml").lastPathComponent == "slide1.xml")
    }

    @Test(arguments: ["<!DOCTYPE root>", "<!DOCTYPE root [<!ENTITY text 'internal entity'>]>"])
    func rejectsDTDDeclarations(declaration: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = "<?xml version='1.0' encoding='UTF-16'?>\(declaration)<root/>"
        try xml.data(using: .utf16)!.write(to: root.appendingPathComponent("slide.xml"))
        #expect(throws: PPTXImportError.self) { try PPTXPackage(root: root).document(at: "slide.xml") }
    }

    @Test func acceptsOrdinaryXMLAndBuiltInEntities() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<root>A &amp; B</root>".write(to: root.appendingPathComponent("slide.xml"), atomically: true, encoding: .utf8)
        #expect(try PPTXPackage(root: root).document(at: "slide.xml").rootElement()?.stringValue == "A & B")
    }

    @Test(arguments: ["../outside", "missing", "safe.xml"])
    func rejectsArchiveContainingASymbolicLink(target: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "<root/>".write(to: root.appendingPathComponent("safe.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: target)
        let archive = root.appendingPathComponent("unsafe.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-qy", archive.path, "link", "safe.xml"]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        #expect(throws: (any Error).self) { try PPTXArchive.extract(archive) }
    }
}
