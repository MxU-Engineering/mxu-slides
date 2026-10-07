import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PPTXImport

struct TextureBakerTests {
    @Test func lgGridBakesFieldAndLines() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: output) }
        let bake = TextureBake(
            placeholderID: "p",
            kind: .pattern(preset: "lgGrid", foregroundHex: "000000FF", backgroundHex: "FFFFFFFF"),
            k: 2)
        #expect(TextureBaker.bake(bake, canvasWidth: 64, canvasHeight: 64, to: output))

        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = try #require(CGContext(
            data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))

        func red(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 64 + x) * 4] }

        #expect(red(1, 1) < 40, "grid line is foreground ink")
        #expect(red(8, 8) > 215, "cell interior is the background field")
        #expect(red(17, 8) < 40, "next grid line lands one cell over")
    }
}
