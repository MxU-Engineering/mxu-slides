import CoreGraphics
import ImageIO
import Metal
import RenderEngine
import simd

struct StillImage {
    let url: URL

    let size: CGSize
    let surface: MediaSurface

    static func load(url: URL, device: MTLDevice) throws -> StillImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { throw MediaEngineError.imageDecodeFailed(url) }
        return try make(image: image, url: url, device: device)
    }

    static func make(image: CGImage, url: URL, device: MTLDevice) throws -> StillImage {
        let width = image.width
        let height = image.height
        guard
            width > 0, height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),

            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw MediaEngineError.imageDecodeFailed(url) }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw MediaEngineError.imageDecodeFailed(url) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead

        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MediaEngineError.textureAllocationFailed(url)
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: context.bytesPerRow
        )

        let transform = VideoColorTransform(
            ycbcrMatrix: matrix_identity_float3x3,
            ycbcrOffset: .zero,
            gamutToWorking: ColorMath.identityGamut,
            premultipliedAlpha: true
        )
        return StillImage(
            url: url,
            size: CGSize(width: width, height: height),
            surface: .bgra(texture: texture, transform: transform, retained: [])
        )
    }
}
