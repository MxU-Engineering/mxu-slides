import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PresenterCore

@Suite struct PosterDecodeTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeImage(to url: URL, width: Int, height: Int, alpha: Bool, type: UTType) throws {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func anOpaqueOriginalReadsTheDiskPoster() throws {
        let directory = try makeDirectory()
        let original = directory.appendingPathComponent("original.png")
        let disk = directory.appendingPathComponent("m1.fingerprint.jpg")
        try writeImage(to: original, width: 64, height: 32, alpha: false, type: .png)
        try writeImage(to: disk, width: 16, height: 16, alpha: false, type: .jpeg)
        #expect(PosterDecode.image(original: original, diskPoster: disk)?.width == 16)

        let absent = directory.appendingPathComponent("m1.other.jpg")
        #expect(PosterDecode.image(original: original, diskPoster: absent)?.width == 64)
        #expect(PosterDecode.image(original: original, diskPoster: nil)?.width == 64)
    }

    @Test func anOriginalWithAlphaAlwaysDecodes() throws {
        let directory = try makeDirectory()
        let original = directory.appendingPathComponent("lower-third.png")
        let disk = directory.appendingPathComponent("m1.fingerprint.jpg")
        try writeImage(to: original, width: 64, height: 32, alpha: true, type: .png)
        try writeImage(to: disk, width: 16, height: 16, alpha: false, type: .jpeg)
        let poster = try #require(PosterDecode.image(original: original, diskPoster: disk))
        #expect(poster.width == 64)
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(poster.alphaInfo), "the poster keeps its transparency")
    }

    @Test func anUnreadableDiskPosterFallsBackToTheOriginal() throws {
        let directory = try makeDirectory()
        let original = directory.appendingPathComponent("original.jpg")
        let disk = directory.appendingPathComponent("m1.fingerprint.jpg")
        try writeImage(to: original, width: 64, height: 32, alpha: false, type: .jpeg)
        try Data([1, 2, 3]).write(to: disk)
        #expect(PosterDecode.image(original: original, diskPoster: disk)?.width == 64)
    }

    @Test func postersDownsampleToTheLongestEdge() throws {
        let directory = try makeDirectory()
        let original = directory.appendingPathComponent("wide.png")
        try writeImage(to: original, width: 2048, height: 1024, alpha: false, type: .png)
        let poster = try #require(PosterDecode.downsampled(url: original))
        #expect(poster.width == PosterDecode.maxPixelSize && poster.height == PosterDecode.maxPixelSize / 2)
    }
}
