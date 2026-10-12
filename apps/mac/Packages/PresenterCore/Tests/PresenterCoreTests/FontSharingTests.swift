import Foundation
import Testing

@testable import PresenterCore

@Suite struct FontSharingTests {
    private func sfntData(fsType: UInt16) -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        data.append(contentsOf: Array("OS/2".utf8))
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 10])
        data.append(contentsOf: [0, 4, 0, 0, 0, 0, 0, 0, UInt8(fsType >> 8), UInt8(fsType & 0xFF)])
        return data
    }

    private struct Run: Encodable { var fontName: String? }
    private struct Style: Encodable { var fontName: String; var runs: [Run] }
    private struct Object: Encodable { var style: Style }
    private struct Slide: Encodable { var objects: [Object] }
    private struct Deck: Encodable { var fontFamily: String; var slides: [Slide] }

    @Test func aDocumentNamesEveryFontItsStylesAndThemeUse() {
        let deck = Deck(fontFamily: "Gotham", slides: [
            Slide(objects: [Object(style: Style(fontName: "Gotham-Bold", runs: [Run(fontName: "Gotham-BookItalic"), Run(fontName: nil)]))]),
            Slide(objects: [Object(style: Style(fontName: "", runs: []))]),
        ])
        #expect(FontSharing.names(in: deck) == ["Gotham", "Gotham-Bold", "Gotham-BookItalic"])
    }

    @Test func onlyEmbeddableFontsOutsideTheSystemFoldersAreShared() {
        #expect(FontSharing.isSystem(path: "/System/Library/Fonts/Helvetica.ttc"))
        #expect(FontSharing.isSystem(path: "/Library/Apple/System/Library/Fonts/X.ttf"))
        #expect(!FontSharing.isSystem(path: "/Users/someone/Library/Fonts/Gotham.otf"))
        #expect(!FontSharing.isSystem(path: "/Library/Fonts/Gotham.otf"), "installed for every user, not shipped")
        #expect(FontSharing.isShareable(path: "/Users/someone/Library/Fonts/Gotham.ttf", data: sfntData(fsType: 0)))
        #expect(FontSharing.isShareable(path: "/Users/someone/Library/Fonts/Gotham.ttf", data: sfntData(fsType: 0x0008)), "editable embedding")
        #expect(!FontSharing.isShareable(path: "/Users/someone/Library/Fonts/Gotham.ttf", data: sfntData(fsType: 0x0002)), "restricted license")
        #expect(!FontSharing.isShareable(path: "/System/Library/Fonts/Gotham.ttf", data: sfntData(fsType: 0)))
        #expect(!FontSharing.isShareable(path: "/Users/someone/notes.txt", data: Data("hello".utf8)))
    }

    @Test func theFilesToCarryAreTheOnesNotAlreadyShared() {
        let gotham = URL(fileURLWithPath: "/Users/someone/Library/Fonts/Gotham.otf")
        let faces: [String: [FontSharing.Face]] = [
            "Gotham-Bold": [.init(name: "Gotham-Bold", family: "Gotham", url: gotham)],
            "Gotham": [.init(name: "Gotham-Bold", family: "Gotham", url: gotham), .init(name: "Gotham-Book", family: "Gotham", url: gotham)],
            "Helvetica": [.init(name: "Helvetica", family: "Helvetica", url: URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc"))],
        ]
        let files = FontSharing.filesToShare(names: ["Gotham", "Gotham-Bold", "Helvetica", "Missing"], shared: ["Gotham-Book"]) { faces[$0] ?? [] }
        #expect(Array(files.keys) == [gotham], "system and unresolved fonts never go")
        #expect(files[gotham]?.map(\.name) == ["Gotham-Bold"], "one entry per file; a face already shared is not asked for again")
        #expect(FontSharing.filesToShare(names: ["Gotham-Bold"], shared: ["Gotham-Bold"]) { faces[$0] ?? [] }.isEmpty)
    }

    @Test func aLandedFileIsRegisteredOnlyWhenThisMacLacksAFace() {
        #expect(FontSharing.needsInstall(faces: ["Gotham-Bold", "Gotham-Book"]) { $0 == "Gotham-Bold" })
        #expect(!FontSharing.needsInstall(faces: ["Helvetica"]) { _ in true }, "an installed copy keeps winning")
        #expect(FontSharing.needsInstall(faces: []) { _ in true }, "a file whose faces are unknown lands")
    }

    @Test func coreTextResolvesOnlyExactNames() {
        let helvetica = FontSharing.resolve("Helvetica")
        #expect(!helvetica.isEmpty)
        #expect(helvetica.allSatisfy { FontSharing.isSystem(path: $0.url.path) })
        #expect(FontSharing.resolve("DefinitelyNotAFont-XYZ").isEmpty, "a fallback font is never the font asked for")
        #expect(FontSharing.isAvailable("Helvetica"))
        #expect(!FontSharing.isAvailable("DefinitelyNotAFont-XYZ"))
    }

    @Test func aFileBecomesADocumentByItsHashAndLandsUnderFonts() throws {
        let system = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Andale Mono.ttf")
        try #require(FileManager.default.fileExists(atPath: system.path))
        #expect(FontSharing.document(forFileAt: system) == nil, "a font macOS ships never goes")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-sharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent("Andale Mono.ttf")
        try FileManager.default.copyItem(at: system, to: copy)
        let document = try #require(FontSharing.document(forFileAt: copy))
        #expect(document.id == (try BlobStore.sha256(of: copy)), "the same file is the same document on every computer")
        #expect(document.family == "Andale Mono")
        #expect(document.faces == ["AndaleMono"])
        #expect(document.ext == "ttf")

        let landed = try FontActivator.install(blobURL: copy, hash: document.id, ext: document.ext, libraryRoot: root)
        #expect(landed.path.hasSuffix("/fonts/\(document.id).ttf"))
        #expect(FileManager.default.fileExists(atPath: landed.path))
    }
}
