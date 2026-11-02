import CoreVideo
import Metal
import RenderEngine

final class SRGBEncodePass: @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private static let pipelines = Locked<[UInt64: MTLComputePipelineState]>([:])

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void encodeSRGB(texture2d<float, access::read> source [[texture(0)]],
                           texture2d<float, access::write> target [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
        float4 color = source.read(gid);
        float alpha = clamp(color.a, 0.0, 1.0);
        float3 rgb = alpha > 0.0 ? color.rgb / alpha : float3(0.0);

        const float3x3 p3ToSRGB = float3x3(
            float3( 1.2249401, -0.0420569, -0.0196376),
            float3(-0.2249404,  1.0420571, -0.0786361),
            float3( 0.0,        0.0,        1.0982735));
        rgb = clamp(p3ToSRGB * rgb, 0.0, 1.0);
        float3 encoded = select(1.055 * pow(rgb, 1.0 / 2.4) - 0.055,
                                12.92 * rgb, rgb <= 0.0031308);
        target.write(float4(encoded * alpha, alpha), gid);
    }
    """

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let cached = Self.pipelines.withLock { $0[device.registryID] }
        guard let pipeline = cached ?? {
            guard let library = try? device.makeLibrary(source: Self.source, options: nil),
                  let function = library.makeFunction(name: "encodeSRGB")
            else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }() else { return nil }
        Self.pipelines.withLock { $0[device.registryID] = pipeline }
        queue.label = "outputEngine.srgbEncode"
        self.queue = queue
        self.pipeline = pipeline
    }

    func encode(_ texture: MTLTexture, into pixelBuffer: CVPixelBuffer) -> Bool {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return false }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: texture.width, height: texture.height,
            mipmapped: false)
        descriptor.usage = [.shaderWrite]
        guard let target = queue.device.makeTexture(
                  descriptor: descriptor, iosurface: surface, plane: 0),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(target, index: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (texture.width + 15) / 16, height: (texture.height + 15) / 16,
                depth: 1),
            threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}
