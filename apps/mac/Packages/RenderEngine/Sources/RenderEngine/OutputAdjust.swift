import CoreGraphics
import Foundation
import Metal
import QuartzCore

public struct OutputEdgeBlend: Codable, Equatable, Sendable {

    public var width: Double

    public var curve: Double

    public var intensity: Double?

    public var blackLift: Double?

    public init(
        width: Double, curve: Double = 2.2,
        intensity: Double? = nil, blackLift: Double? = nil
    ) {
        self.width = width
        self.curve = curve
        self.intensity = intensity
        self.blackLift = blackLift
    }
}

public struct OutputAdjustments: Codable, Equatable, Sendable {

    public var topLeft: CGPoint?
    public var topRight: CGPoint?
    public var bottomLeft: CGPoint?
    public var bottomRight: CGPoint?

    public var brightness: Double?

    public var contrast: Double?

    public var gamma: Double?

    public var blackLevel: Double?

    public var redLevel: Double?
    public var greenLevel: Double?
    public var blueLevel: Double?

    public var blendLeft: OutputEdgeBlend?
    public var blendRight: OutputEdgeBlend?
    public var blendTop: OutputEdgeBlend?
    public var blendBottom: OutputEdgeBlend?

    public var rotationDegrees: Double?

    public init() {}

    public var isNeutral: Bool {
        func zero(_ point: CGPoint?) -> Bool { (point ?? .zero) == .zero }
        func zero(_ value: Double?) -> Bool { (value ?? 0) == 0 }
        func off(_ blend: OutputEdgeBlend?) -> Bool { (blend?.width ?? 0) <= 0 }
        return zero(topLeft) && zero(topRight) && zero(bottomLeft) && zero(bottomRight)
            && zero(brightness) && zero(contrast) && zero(gamma) && zero(blackLevel)
            && zero(redLevel) && zero(greenLevel) && zero(blueLevel)
            && off(blendLeft) && off(blendRight) && off(blendTop) && off(blendBottom)
            && zero(rotationDegrees.map { $0.truncatingRemainder(dividingBy: 360) })
    }
}

enum OutputWarp {

    static func projectiveUVs(
        destinations: [CGPoint], sources: [CGPoint]
    ) -> [SIMD3<Double>]? {
        precondition(destinations.count == 4 && sources.count == 4)

        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let d = destinations[i], s = sources[i]
            matrix[i * 2] = [Double(d.x), Double(d.y), 1, 0, 0, 0,
                             -Double(s.x) * Double(d.x), -Double(s.x) * Double(d.y), Double(s.x)]
            matrix[i * 2 + 1] = [0, 0, 0, Double(d.x), Double(d.y), 1,
                                 -Double(s.y) * Double(d.x), -Double(s.y) * Double(d.y), Double(s.y)]
        }
        guard let h = solve(matrix) else { return nil }
        return destinations.map { d in
            let q = h[6] * Double(d.x) + h[7] * Double(d.y) + 1
            let uq = h[0] * Double(d.x) + h[1] * Double(d.y) + h[2]
            let vq = h[3] * Double(d.x) + h[4] * Double(d.y) + h[5]

            return SIMD3(uq, vq, q)
        }
    }

    private static func solve(_ input: [[Double]]) -> [Double]? {
        var m = input
        for column in 0..<8 {
            let pivot = (column..<8).max(by: { abs(m[$0][column]) < abs(m[$1][column]) })!
            guard abs(m[pivot][column]) > 1e-9 else { return nil }
            m.swapAt(column, pivot)
            let divisor = m[column][column]
            for k in column..<9 { m[column][k] /= divisor }
            for row in 0..<8 where row != column {
                let factor = m[row][column]
                guard factor != 0 else { continue }
                for k in column..<9 { m[row][k] -= factor * m[column][k] }
            }
        }
        return m.map { $0[8] }
    }
}

extension Compositor {

    struct OutputWarpVertexData {
        var posUV: SIMD4<Float>
        var q: SIMD4<Float>
    }

    struct OutputAdjustUniformsData {
        var color: SIMD4<Float>
        var rgb: SIMD4<Float>
        var blendLeft: SIMD4<Float>
        var blendRight: SIMD4<Float>
        var blendTop: SIMD4<Float>
        var blendBottom: SIMD4<Float>
        var sourceRect: SIMD4<Float>
    }

    public static let fullSourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func encodeOutputPass(
        from source: MTLTexture,
        to target: MTLTexture,
        adjustments: OutputAdjustments,
        sourceRect: CGRect = Compositor.fullSourceRect,
        placement: CGRect? = nil,
        mask: MTLTexture? = nil,
        loadAction: MTLLoadAction = .clear,
        commandBuffer: MTLCommandBuffer
    ) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target

        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "compositor.outputAdjust"

        let width = Double(target.width)
        let height = Double(target.height)

        let placed = placement ?? Compositor.fullSourceRect
        let dest = CGRect(
            x: placed.minX * width, y: placed.minY * height,
            width: placed.width * width, height: placed.height * height
        )
        let theta = (adjustments.rotationDegrees ?? 0) * .pi / 180
        let cosT = cos(theta)
        let sinT = sin(theta)
        let boundsW = dest.width * abs(cosT) + dest.height * abs(sinT)
        let boundsH = dest.width * abs(sinT) + dest.height * abs(cosT)
        let scaleX = boundsW > 0 ? dest.width / boundsW : 1
        let scaleY = boundsH > 0 ? dest.height / boundsH : 1
        func ndc(_ restX: Double, _ restY: Double, _ offset: CGPoint?) -> CGPoint {
            let vx = restX - dest.midX
            let vy = restY - dest.midY

            let rx = (vx * cosT - vy * sinT) * scaleX
            let ry = (vx * sinT + vy * cosT) * scaleY
            let x = dest.midX + rx + Double(offset?.x ?? 0)
            let y = dest.midY + ry + Double(offset?.y ?? 0)
            return CGPoint(x: x / width * 2 - 1, y: 1 - y / height * 2)
        }
        let destinations = [
            ndc(dest.minX, dest.minY, adjustments.topLeft),
            ndc(dest.maxX, dest.minY, adjustments.topRight),
            ndc(dest.minX, dest.maxY, adjustments.bottomLeft),
            ndc(dest.maxX, dest.maxY, adjustments.bottomRight),
        ]

        let sources = [
            CGPoint(x: sourceRect.minX, y: sourceRect.minY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.minY),
            CGPoint(x: sourceRect.minX, y: sourceRect.maxY),
            CGPoint(x: sourceRect.maxX, y: sourceRect.maxY),
        ]
        let uvqs = OutputWarp.projectiveUVs(destinations: destinations, sources: sources)
            ?? sources.map { SIMD3(Double($0.x), Double($0.y), 1) }
        func vertex(_ index: Int) -> OutputWarpVertexData {
            OutputWarpVertexData(
                posUV: SIMD4(
                    Float(destinations[index].x), Float(destinations[index].y),
                    Float(uvqs[index].x), Float(uvqs[index].y)
                ),
                q: SIMD4(Float(uvqs[index].z), 0, 0, 0)
            )
        }

        var vertices = [vertex(0), vertex(1), vertex(2), vertex(1), vertex(3), vertex(2)]

        func edge(_ blend: OutputEdgeBlend?) -> SIMD4<Float> {
            guard let blend, blend.width > 0 else { return SIMD4(0, 1, 1, 0) }
            return SIMD4(
                Float(min(max(blend.width, 0), 1)),
                Float(blend.curve > 0 ? blend.curve : 1),
                Float(min(max(blend.intensity ?? 1, 0), 1)),
                Float(min(max(blend.blackLift ?? 0, 0), 1))
            )
        }
        var uniforms = OutputAdjustUniformsData(
            color: SIMD4(
                Float(adjustments.brightness ?? 0), Float(adjustments.contrast ?? 0),
                Float(adjustments.gamma ?? 0), Float(adjustments.blackLevel ?? 0)
            ),
            rgb: SIMD4(
                Float(adjustments.redLevel ?? 0), Float(adjustments.greenLevel ?? 0),
                Float(adjustments.blueLevel ?? 0), mask == nil ? 0 : 1
            ),
            blendLeft: edge(adjustments.blendLeft),
            blendRight: edge(adjustments.blendRight),
            blendTop: edge(adjustments.blendTop),
            blendBottom: edge(adjustments.blendBottom),
            sourceRect: SIMD4(
                Float(sourceRect.minX), Float(sourceRect.minY),
                Float(max(sourceRect.width, 1e-6)), Float(max(sourceRect.height, 1e-6))
            )
        )

        encoder.setRenderPipelineState(outputAdjustPipeline)
        encoder.setVertexBytes(
            &vertices, length: MemoryLayout<OutputWarpVertexData>.stride * 6, index: 0)
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<OutputAdjustUniformsData>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(mask ?? outputMaskFallback, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
