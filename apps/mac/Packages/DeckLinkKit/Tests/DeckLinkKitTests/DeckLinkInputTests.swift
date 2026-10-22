import CDeckLink
import CoreVideo
import Testing

@testable import DeckLinkKit

@Test func openingAMissingInputFailsWithAMessage() {
    #expect(throws: DeckLinkError.self) {
        _ = try DeckLinkInput(
            persistentID: .min, audioChannels: 2,
            onFrame: { _ in }, onFormat: { _ in })
    }
}

@Test func audioChannelsTakeTheMostTheSDKOffers() {
    #expect(DeckLinkInput.audioChannels(forMaximum: 0) == 2)
    #expect(DeckLinkInput.audioChannels(forMaximum: 2) == 2)
    #expect(DeckLinkInput.audioChannels(forMaximum: 8) == 8)
    #expect(DeckLinkInput.audioChannels(forMaximum: 16) == 16)
    #expect(DeckLinkInput.audioChannels(forMaximum: 64) == 16)
}

@Test func blendAveragesEachLineWithTheNext() {
    let source: [UInt8] = [10, 10, 20, 20, 31, 31]
    var destination = [UInt8](repeating: 0, count: 6)
    dlk_deinterlace_blend(source, 2, &destination, 2, 2, 3)
    #expect(destination == [15, 15, 26, 26, 31, 31])
}

private func frame(width: Int, height: Int, row: (Int) -> (y: UInt8, cb: UInt8, cr: UInt8)) -> [UInt8] {
    var bytes = [UInt8]()
    for line in 0..<height {
        let (y, cb, cr) = row(line)
        for _ in 0..<(width / 2) { bytes += [cb, y, cr, y] }
    }
    return bytes
}

private func bgraBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    return buffer!
}

private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return (0..<4).map { Int(base[offset + $0]) }
}

private func near(_ actual: [Int], _ expected: [Int], within tolerance: Int = 3) -> Bool {
    zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
}

@Test func videoRangeHDConvertsToBGRA() {
    let width = 8, height = 720

    let bytes = frame(width: width, height: height) { line in
        switch line % 3 {
        case 0: (16, 128, 128)
        case 1: (235, 128, 128)
        default: (63, 102, 240)
        }
    }
    let output = bgraBuffer(width: width, height: height)
    let converted = bytes.withUnsafeBytes {
        DeckLinkFrameConverter().convert(
            $0.baseAddress!, rowBytes: width * 2, width: width, height: height,
            interlaced: false, into: output)
    }
    #expect(converted)
    #expect(near(pixel(output, x: 0, y: 0), [0, 0, 0, 255]))
    #expect(near(pixel(output, x: 0, y: 1), [255, 255, 255, 255]))
    #expect(near(pixel(output, x: 0, y: 2), [0, 0, 255, 255]))
}

@Test func interlacedFramesLoseTheComb() {
    let width = 8, height = 720

    let bytes = frame(width: width, height: height) { line in
        line % 2 == 0 ? (16, 128, 128) : (235, 128, 128)
    }
    let output = bgraBuffer(width: width, height: height)
    let converter = DeckLinkFrameConverter()
    bytes.withUnsafeBytes {
        converter.convert(
            $0.baseAddress!, rowBytes: width * 2, width: width, height: height,
            interlaced: true, into: output)
    }
    let upper = pixel(output, x: 0, y: 10)
    let lower = pixel(output, x: 0, y: 11)
    #expect(near(upper, lower))
    #expect(upper[0] > 100 && upper[0] < 160)
}

@Test func aNonBGRADestinationIsRefused() {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_422YpCbCr8, nil, &buffer)
    let bytes = [UInt8](repeating: 128, count: 8 * 8 * 2)
    let converted = bytes.withUnsafeBytes {
        DeckLinkFrameConverter().convert(
            $0.baseAddress!, rowBytes: 16, width: 8, height: 8,
            interlaced: false, into: buffer!)
    }
    #expect(!converted)
}
