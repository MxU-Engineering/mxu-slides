import Accelerate
import CoreGraphics
import Foundation
import Metal

public struct OutputMask: Codable, Equatable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable {

        case out

        case `in`
    }

    public var id: UUID
    public var name: String

    public var pathData: String
    public var mode: Mode

    public var feather: Double

    public var alwaysOn: Bool

    public var sliceIds: [UUID]?

    public init(
        id: UUID = UUID(),
        name: String,
        pathData: String,
        mode: Mode = .out,
        feather: Double = 0,
        alwaysOn: Bool = true,
        sliceIds: [UUID]? = nil
    ) {
        self.id = id
        self.name = name
        self.pathData = pathData
        self.mode = mode
        self.feather = feather
        self.alwaysOn = alwaysOn
        self.sliceIds = sliceIds
    }
}

public enum OutputMaskRaster {

    public static func texture(
        masks: [OutputMask], width: Int, height: Int, device: MTLDevice
    ) -> MTLTexture? {
        guard !masks.isEmpty, width > 0, height > 0 else { return nil }
        let count = width * height
        var coverage = [UInt8](repeating: 255, count: count)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        let scratchPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { scratchPointer.deallocate() }
        guard let context = CGContext(
            data: scratchPointer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 1, alpha: 1)

        var rasterizedAny = false
        for mask in masks {
            guard let path = SVGPathParser.path(from: mask.pathData, in: canvas) else { continue }
            scratchPointer.update(repeating: 0, count: count)
            context.addPath(path)
            context.fillPath()
            if mask.feather > 0 {
                blur(scratchPointer, width: width, height: height,
                     radius: mask.feather * Double(min(width, height)))
            }

            for index in 0..<count {
                let alpha = Int(scratchPointer[index])
                let factor = mask.mode == .out ? 255 - alpha : alpha
                coverage[index] = UInt8(Int(coverage[index]) * factor / 255)
            }
            rasterizedAny = true
        }
        guard rasterizedAny else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "outputMask.\(width)x\(height)"
        coverage.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width
            )
        }
        return texture
    }

    private static func blur(
        _ pointer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, radius: Double
    ) {
        let kernel = UInt32(max(3, Int(radius.rounded()) | 1))
        let count = width * height
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { scratch.deallocate() }
        var source = vImage_Buffer(
            data: pointer, height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width)
        var destination = vImage_Buffer(
            data: scratch, height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width)
        guard vImageTentConvolve_Planar8(
            &source, &destination, nil, 0, 0, kernel, kernel, 0,
            vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
        else { return }
        pointer.update(from: scratch, count: count)
    }
}
