import Accelerate
import CoreGraphics
import Metal

enum LinearRaster {
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

    static func makeContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        guard pixelWidth > 0, pixelHeight > 0, let space = colorSpace,
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 32,
                bytesPerRow: pixelWidth * 16,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context
    }

    static func cgColor(_ color: SceneColor) -> CGColor? {
        guard let space = colorSpace else { return nil }
        let linear = color.linear
        return CGColor(colorSpace: space, components: [linear.x, linear.y, linear.z, linear.w])
    }

    static func makeTexture(from context: CGContext, device: MTLDevice) -> MTLTexture? {
        guard let data = context.data else { return nil }
        let pixelWidth = context.width
        let pixelHeight = context.height
        let componentCount = pixelWidth * pixelHeight * 4
        var half = [UInt16](repeating: 0, count: componentCount)
        var source = vImage_Buffer(
            data: data, height: 1, width: vImagePixelCount(componentCount),
            rowBytes: componentCount * 4
        )
        let converted = half.withUnsafeMutableBytes { buffer -> Bool in
            var destination = vImage_Buffer(
                data: buffer.baseAddress!, height: 1, width: vImagePixelCount(componentCount),
                rowBytes: componentCount * 2
            )
            return vImageConvert_PlanarFtoPlanar16F(&source, &destination, 0) == kvImageNoError
        }
        guard converted else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        half.withUnsafeBytes { buffer in
            texture.replace(
                region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: pixelWidth * 8
            )
        }
        return texture
    }
}
