import CoreVideo
import Metal
import RenderEngine
import simd

public enum MediaEngineError: Error {
    case noMetalTextureCache
    case noVideoTrack(URL)
    case authoringFailed(String)
    case imageDecodeFailed(URL)
    case textureAllocationFailed(URL)
    case captureSetupFailed(String)
}

final class SurfaceFactory: @unchecked Sendable {
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw MediaEngineError.noMetalTextureCache
        }
        textureCache = cache
    }

    func makeSurface(from pixelBuffer: CVPixelBuffer) -> MediaSurface? {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return makeYCbCrSurface(pixelBuffer, fullRange: false)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return makeYCbCrSurface(pixelBuffer, fullRange: true)
        case kCVPixelFormatType_32BGRA:
            return makeBGRASurface(pixelBuffer)
        default:
            return nil
        }
    }

    private func makeYCbCrSurface(_ pixelBuffer: CVPixelBuffer, fullRange: Bool) -> MediaSurface? {
        guard
            let luma = planeTexture(pixelBuffer, plane: 0, format: .r8Unorm),
            let chroma = planeTexture(pixelBuffer, plane: 1, format: .rg8Unorm)
        else { return nil }

        let (matrix, offset) = ColorMath.ycbcrToRGB(ycbcrCoefficients(of: pixelBuffer), fullRange: fullRange)
        let transform = VideoColorTransform(
            ycbcrMatrix: matrix,
            ycbcrOffset: offset,
            gamutToWorking: gamutToP3(of: pixelBuffer),
            premultipliedAlpha: false
        )
        return .ycbcrBiplanar(
            luma: luma.texture,
            chroma: chroma.texture,
            transform: transform,
            retained: [luma.holder, chroma.holder, pixelBuffer]
        )
    }

    private func makeBGRASurface(_ pixelBuffer: CVPixelBuffer) -> MediaSurface? {
        guard let bgra = planeTexture(pixelBuffer, plane: nil, format: .bgra8Unorm) else { return nil }
        let transform = VideoColorTransform(
            ycbcrMatrix: matrix_identity_float3x3,
            ycbcrOffset: .zero,
            gamutToWorking: gamutToP3(of: pixelBuffer),
            premultipliedAlpha: isPremultiplied(pixelBuffer)
        )
        return .bgra(texture: bgra.texture, transform: transform, retained: [bgra.holder, pixelBuffer])
    }

    private func planeTexture(
        _ pixelBuffer: CVPixelBuffer,
        plane: Int?,
        format: MTLPixelFormat
    ) -> (texture: MTLTexture, holder: AnyObject)? {
        let width = plane.map { CVPixelBufferGetWidthOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetWidth(pixelBuffer)
        let height = plane.map { CVPixelBufferGetHeightOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            format, width, height, plane ?? 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (texture, cvTexture)
    }

    private func attachment(_ pixelBuffer: CVPixelBuffer, _ key: CFString) -> CFString? {
        guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil) else { return nil }
        return (value as! CFString)
    }

    private func ycbcrCoefficients(of pixelBuffer: CVPixelBuffer) -> ColorMath.YCbCrCoefficients {
        switch attachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey) {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: .bt601
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: .bt2020
        default: .bt709
        }
    }

    private func gamutToP3(of pixelBuffer: CVPixelBuffer) -> simd_float3x3 {
        switch attachment(pixelBuffer, kCVImageBufferColorPrimariesKey) {
        case kCVImageBufferColorPrimaries_P3_D65: ColorMath.identityGamut
        case kCVImageBufferColorPrimaries_ITU_R_2020: ColorMath.bt2020ToDisplayP3
        default: ColorMath.bt709ToDisplayP3
        }
    }

    private func isPremultiplied(_ pixelBuffer: CVPixelBuffer) -> Bool {

        attachment(pixelBuffer, kCVImageBufferAlphaChannelModeKey)
            != kCVImageBufferAlphaChannelMode_StraightAlpha
    }
}
