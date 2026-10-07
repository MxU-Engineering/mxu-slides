import Foundation
import Testing
@testable import PresenterCore

@MainActor
struct FontActivatorTests {

    private func sfntData(fsType: UInt16) -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00])          
        data.append(contentsOf: [0x00, 0x01])                      
        data.append(contentsOf: [0, 0, 0, 0, 0, 0])                
        data.append(contentsOf: Array("OS/2".utf8))                
        data.append(contentsOf: [0, 0, 0, 0])                      
        data.append(contentsOf: [0, 0, 0, 28])                     
        data.append(contentsOf: [0, 0, 0, 10])                     

        data.append(contentsOf: [0, 4, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: [UInt8(fsType >> 8), UInt8(fsType & 0xFF)])
        return data
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func storesValidFontContentAddressedAndDedupes() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("font1.fntdata")
        try sfntData(fsType: 0).write(to: source)

        let stored = try #require(FontActivator.store(dataURL: source, libraryRoot: root))
        #expect(stored.pathExtension == "ttf")
        #expect(stored.deletingLastPathComponent().lastPathComponent == "fonts")
        #expect(FileManager.default.fileExists(atPath: stored.path))

        let again = FontActivator.store(dataURL: source, libraryRoot: root)
        #expect(again == stored)
        let contents = try FileManager.default.contentsOfDirectory(atPath: stored.deletingLastPathComponent().path)
        #expect(contents.count == 1)
    }

    @Test func restrictedLicenseEmbeddingIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let restricted = root.appendingPathComponent("restricted.fntdata")
        try sfntData(fsType: 0x0002).write(to: restricted)
        #expect(FontActivator.store(dataURL: restricted, libraryRoot: root) == nil)

        let preview = root.appendingPathComponent("preview.fntdata")
        try sfntData(fsType: 0x0004).write(to: preview)
        #expect(FontActivator.store(dataURL: preview, libraryRoot: root) != nil)
    }

    @Test func odttfObfuscationUnwindsFromTheGUIDName() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clear = sfntData(fsType: 0)
        let guid = "B14E9DBF-345A-4B32-9C09-2EA65B7A9A02"
        let key = try #require(FontActivator.guidBytes(fromPartName: "\(guid).fntdata"))
        var obfuscated = clear
        let reversedKey = Array(key.reversed())
        for index in 0..<32 { obfuscated[index] ^= reversedKey[index % 16] }
        let source = root.appendingPathComponent("\(guid).fntdata")
        try obfuscated.write(to: source)

        let stored = try #require(FontActivator.store(dataURL: source, libraryRoot: root))
        #expect(try Data(contentsOf: stored) == clear)
    }

    @Test func garbageDataIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("font1.fntdata")
        try Data("definitely not a font".utf8).write(to: garbage)
        #expect(FontActivator.store(dataURL: garbage, libraryRoot: root) == nil)
    }
}
