import Metal
import QuartzCore
import simd

public struct VideoColorTransform: Sendable {

    public var ycbcrMatrix: simd_float3x3

    public var ycbcrOffset: SIMD3<Float>

    public var gamutToWorking: simd_float3x3

    public var premultipliedAlpha: Bool

    public init(
        ycbcrMatrix: simd_float3x3,
        ycbcrOffset: SIMD3<Float>,
        gamutToWorking: simd_float3x3,
        premultipliedAlpha: Bool
    ) {
        self.ycbcrMatrix = ycbcrMatrix
        self.ycbcrOffset = ycbcrOffset
        self.gamutToWorking = gamutToWorking
        self.premultipliedAlpha = premultipliedAlpha
    }
}

public enum MediaSurface: @unchecked Sendable {

    case ycbcrBiplanar(luma: MTLTexture, chroma: MTLTexture, transform: VideoColorTransform, retained: [AnyObject])

    case bgra(texture: MTLTexture, transform: VideoColorTransform, retained: [AnyObject])
}

public protocol MediaTextureSource: AnyObject, Sendable {

    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface?

    func liveCadence(for mediaID: String) -> LiveCadence?
}
