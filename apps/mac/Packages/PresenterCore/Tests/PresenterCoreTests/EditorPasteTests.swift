import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PresenterCore

@Test func editorPastePrefersObjectsThenSlidesThenFilesThenImages() {
    let tiff = UTType.tiff.identifier
    #expect(EditorPaste.source(types: [EditorPaste.objectsType, EditorPaste.slidesType]) == .objects)
    #expect(EditorPaste.source(types: [EditorPaste.slideType, EditorPaste.slidesType]) == .slides)

    #expect(EditorPaste.source(types: [tiff, UTType.fileURL.identifier]) == .files)
    #expect(EditorPaste.source(types: ["com.apple.iWork.TSPNativeData", tiff]) == .image)
    #expect(EditorPaste.source(types: [UTType.utf8PlainText.identifier]) == nil)
    #expect(EditorPaste.imageType(in: [tiff, UTType.png.identifier]) == UTType.png.identifier)
}

@Test func pastedTIFFBecomesAPNGFileAndPNGIsKeptAsCopied() throws {
    let context = try #require(CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let image = try #require(context.makeImage())
    func encoded(_ type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fromTIFF = try #require(EditorPaste.writeImage(try encoded(.tiff), type: UTType.tiff.identifier, into: directory))
    #expect(fromTIFF.lastPathComponent == "Pasted Image.png")
    let source = try #require(CGImageSourceCreateWithURL(fromTIFF as CFURL, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
    #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 40)

    let png = try encoded(.png)
    let other = directory.appendingPathComponent("png")
    let kept = try #require(EditorPaste.writeImage(png, type: UTType.png.identifier, into: other))
    #expect(try Data(contentsOf: kept) == png)

    #expect(EditorPaste.writeImage(Data("not an image".utf8), type: UTType.tiff.identifier, into: directory.appendingPathComponent("bad")) == nil)
}
