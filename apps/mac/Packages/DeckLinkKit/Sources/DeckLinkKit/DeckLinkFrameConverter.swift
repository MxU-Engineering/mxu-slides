import Accelerate
import CDeckLink
import CoreVideo
import Foundation

public final class DeckLinkFrameConverter {
    private var hd = vImage_YpCbCrToARGB()
    private var sd = vImage_YpCbCrToARGB()
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0

    public init() {
        var range = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)

        var bt709 = vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 1.5748, Cr_G: -0.4681, Cb_G: -0.1873, Cb_B: 1.8556)
        var bt601 = vImage_YpCbCrToARGBMatrix(
            Yp: 1, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772)
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            &bt709, &range, &hd, kvImage422CbYpCrYp8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags))
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            &bt601, &range, &sd, kvImage422CbYpCrYp8, kvImageARGB8888,
            vImage_Flags(kvImageNoFlags))
    }

    deinit {
        scratch?.deallocate()
    }

    @discardableResult
    public func convert(
        _ bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int,
        interlaced: Bool, into destination: CVPixelBuffer
    ) -> Bool {
        if width > 0, height > 0,
            CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
            CVPixelBufferGetWidth(destination) >= width,
            CVPixelBufferGetHeight(destination) >= height,
            let source = interlaced
                ? blended(bytes, rowBytes: rowBytes, width: width, height: height) : bytes {
            CVPixelBufferLockBaseAddress(destination, [])
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }
            var sourceBuffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: source),
                height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: rowBytes)
            var destinationBuffer = vImage_Buffer(
                data: CVPixelBufferGetBaseAddress(destination), height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRow(destination))

            let toBGRA: [UInt8] = [3, 2, 1, 0]
            let error = withUnsafePointer(to: height >= 720 ? hd : sd) { info in
                vImageConvert_422CbYpCrYp8ToARGB8888(
                    &sourceBuffer, &destinationBuffer, info, toBGRA, 255,
                    vImage_Flags(kvImageNoFlags))
            }
            return destinationBuffer.data != nil && error == kvImageNoError
        } else {
            return false
        }
    }

    private func blended(
        _ bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int
    ) -> UnsafeRawPointer? {
        let size = rowBytes * height
        if scratchSize < size {
            scratch?.deallocate()
            scratch = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
            scratchSize = size
        }
        if let scratch {
            dlk_deinterlace_blend(
                bytes.assumingMemoryBound(to: UInt8.self), rowBytes,
                scratch.assumingMemoryBound(to: UInt8.self), rowBytes,
                width * 2, Int32(height))
        }
        return scratch.map { UnsafeRawPointer($0) }
    }
}
