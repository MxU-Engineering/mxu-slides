import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

public enum CompositorError: Error {
    case noMetalDevice
    case pipelineCreationFailed(String)
    case renderFailed(String)
}

public struct RenderedFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: Data

    public var cgImage: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let provider = CGDataProvider(data: data as CFData)
        else { return nil }
        let info = CGBitmapInfo(rawValue:
            CGBitmapInfo.floatComponents.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        )
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
            space: space, bitmapInfo: info, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

struct SceneTransform {
    let scale: CGFloat
    let offset: CGPoint

    init(scale: CGFloat, offset: CGPoint) {
        self.scale = scale
        self.offset = offset
    }

    init(canvasSize: CGSize, targetSize: CGSize, inset: CGFloat = 0) {
        let s = min(
            max(targetSize.width - 2 * inset, 1) / canvasSize.width,
            max(targetSize.height - 2 * inset, 1) / canvasSize.height
        )
        scale = s
        offset = CGPoint(
            x: (targetSize.width - canvasSize.width * s) / 2,
            y: (targetSize.height - canvasSize.height * s) / 2
        )
    }

    func pixelRect(_ sceneRect: CGRect) -> CGRect {
        CGRect(
            x: sceneRect.origin.x * scale + offset.x,
            y: sceneRect.origin.y * scale + offset.y,
            width: sceneRect.width * scale,
            height: sceneRect.height * scale
        )
    }
}

public final class Compositor: @unchecked Sendable {

    public static let pixelFormat: MTLPixelFormat = .rgba16Float

    public static var workingColorSpaceName: CFString { CGColorSpace.extendedLinearDisplayP3 }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private enum FragmentKind: String, CaseIterable {
        case solid = "compositor_solid"
        case textured = "compositor_textured"
        case videoYCbCr = "compositor_video_ycbcr"
        case videoRGBA = "compositor_video_rgba"

        case videoYCbCrMasked = "compositor_video_ycbcr_masked"
        case videoRGBAMasked = "compositor_video_rgba_masked"

        case maskedComposite = "compositor_masked"

        case colorAdjust = "compositor_color_adjust"
        case hueRotate = "compositor_hue_rotate"
        case invert = "compositor_invert"
        case posterize = "compositor_posterize"
        case pixelate = "compositor_pixelate"
        case vignette = "compositor_vignette"

        case warp = "compositor_warp"
        case echo = "compositor_echo"
        case scatter = "compositor_scatter"
        case stainedGlass = "compositor_stained_glass"
        case grain = "compositor_grain"
        case ghostTrails = "compositor_ghost_trails"

        case glitch = "compositor_glitch"
        case burn = "compositor_burn"

        case tint = "compositor_tint"
    }

    private struct PipelineKey: Hashable {
        let fragment: FragmentKind
        let blend: SceneBlendMode
    }

    private let pipelines: [PipelineKey: MTLRenderPipelineState]

    private let replacePipeline: MTLRenderPipelineState

    let outputAdjustPipeline: MTLRenderPipelineState

    let outputMaskFallback: MTLTexture

    private let buildPipelines: [SceneBlendMode: MTLRenderPipelineState]

    private var outputIntermediates: [String: MTLTexture] = [:]

    private struct CachedTexture {
        let texture: MTLTexture
        var lastUsed: CFTimeInterval
    }

    static let cacheTTL: CFTimeInterval = 10

    private static let sweepInterval: CFTimeInterval = 1

    private struct CachedStrip {
        let strip: PathTextStrip.Strip
        var lastUsed: CFTimeInterval
    }

    private var textTextures: [TextRasterizer.Key: CachedTexture] = [:]
    private var shapeTextures: [ShapeRasterizer.Key: CachedTexture] = [:]
    private var stripTextures: [PathTextStrip.Key: CachedStrip] = [:]

    private struct FlatPathKey: Hashable {
        let pathData: String
        let x, y, width, height: CGFloat
    }
    private struct CachedFlatPath {
        let path: PathTextLayout.FlatPath
        var lastUsed: CFTimeInterval
    }
    private var flatPaths: [FlatPathKey: CachedFlatPath] = [:]

    private struct ScratchBucket {
        var free: [MTLTexture] = []
        var lastUsed: CFTimeInterval = 0
    }

    private var scratchPool: [String: ScratchBucket] = [:]
    private var scratchBusy: [MTLTexture] = []

    private var blurKernels: [Int: MPSImageGaussianBlur] = [:]
    private let supportsMPS: Bool

    private func blurKernel(sigma: Float) -> MPSImageGaussianBlur? {
        guard supportsMPS, sigma > 0 else { return nil }
        let key = Int((sigma * 1000).rounded())
        if let kernel = blurKernels[key] { return kernel }
        if blurKernels.count > 64 { blurKernels.removeAll(keepingCapacity: true) }
        let kernel = MPSImageGaussianBlur(device: device, sigma: sigma)
        kernel.edgeMode = .clamp
        blurKernels[key] = kernel
        return kernel
    }

    private func acquireScratch(width: Int, height: Int) -> MTLTexture? {
        let key = "\(width)x\(height)"
        if var bucket = scratchPool[key], let texture = bucket.free.popLast() {
            bucket.lastUsed = cacheClock
            scratchPool[key] = bucket
            scratchBusy.append(texture)
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var bucket = scratchPool[key] ?? ScratchBucket()
        bucket.lastUsed = cacheClock
        scratchPool[key] = bucket
        scratchBusy.append(texture)
        return texture
    }

    private func recycleScratch() {
        for texture in scratchBusy {
            let key = "\(texture.width)x\(texture.height)"
            var bucket = scratchPool[key] ?? ScratchBucket()
            bucket.free.append(texture)
            bucket.lastUsed = cacheClock
            scratchPool[key] = bucket
        }
        scratchBusy.removeAll(keepingCapacity: true)
    }

    private struct EffectHistory {
        let texture: MTLTexture
        var lastUsed: CFTimeInterval
    }

    private var effectHistories: [String: EffectHistory] = [:]

    public static let historyGap: CFTimeInterval = 0.5

    private func effectHistory(
        key: String, width: Int, height: Int
    ) -> (texture: MTLTexture, elapsed: CFTimeInterval)? {
        guard let entry = effectHistories[key],
              entry.texture.width == width, entry.texture.height == height
        else { return nil }
        let elapsed = cacheClock - entry.lastUsed
        guard elapsed >= 0, elapsed <= Self.historyGap else { return nil }
        return (entry.texture, elapsed)
    }

    private func storeEffectHistory(key: String, texture: MTLTexture) {
        effectHistories[key] = EffectHistory(texture: texture, lastUsed: cacheClock)
    }

    private func makeHistoryTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private var cacheClock: CFTimeInterval = 0
    private var lastSweep: CFTimeInterval = 0

    var cacheClockOverride: (() -> CFTimeInterval)?

    private let encodeLock = NSLock()

    public var mediaSource: (any MediaTextureSource)? {
        get { mediaSourceBox.value.value }
        set { mediaSourceBox.value = WeakSource(value: newValue) }
    }

    private struct WeakSource {
        weak var value: (any MediaTextureSource)?
    }

    private let mediaSourceBox = Locked(WeakSource())

    private struct VideoUniformsGPU {
        var ycbcrMatrix: simd_float3x3
        var ycbcrOffset: SIMD3<Float>
        var gamutToWorking: simd_float3x3
        var params: SIMD4<Float>

        init(_ transform: VideoColorTransform, opacity: Double) {
            ycbcrMatrix = transform.ycbcrMatrix
            ycbcrOffset = transform.ycbcrOffset
            gamutToWorking = transform.gamutToWorking
            params = SIMD4(transform.premultipliedAlpha ? 1 : 0, Float(opacity), 0, 0)
        }
    }

    public convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noMetalDevice
        }
        try self.init(device: device)
    }

    public init(device: MTLDevice) throws {
        self.device = device
        self.supportsMPS = MPSSupportsMTLDevice(device)
        guard let queue = device.makeCommandQueue() else {
            throw CompositorError.pipelineCreationFailed("makeCommandQueue returned nil")
        }
        commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: ShaderSource.metal, options: nil)
        } catch {
            throw CompositorError.pipelineCreationFailed("shader library: \(error)")
        }
        guard let vertexFunction = library.makeFunction(name: "compositor_vertex") else {
            throw CompositorError.pipelineCreationFailed("missing vertex function")
        }

        func makePipeline(
            fragment: MTLFunction,
            blend: SceneBlendMode,
            label: String,
            vertex: MTLFunction? = nil
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = vertex ?? vertexFunction
            descriptor.fragmentFunction = fragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Compositor.pixelFormat
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add

            switch blend {
            case .normal:
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .add:
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
            case .screen:

                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            case .multiply:

                attachment.sourceRGBBlendFactor = .destinationColor
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            }
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw CompositorError.pipelineCreationFailed("\(label): \(error)")
            }
        }

        var built: [PipelineKey: MTLRenderPipelineState] = [:]
        for fragment in FragmentKind.allCases {
            guard let function = library.makeFunction(name: fragment.rawValue) else {
                throw CompositorError.pipelineCreationFailed("missing \(fragment.rawValue)")
            }
            for blend in SceneBlendMode.allCases {
                built[PipelineKey(fragment: fragment, blend: blend)] = try makePipeline(
                    fragment: function,
                    blend: blend,
                    label: "compositor.\(fragment.rawValue).\(blend.rawValue)"
                )
            }
        }
        pipelines = built

        let replaceDescriptor = MTLRenderPipelineDescriptor()
        replaceDescriptor.label = "compositor.textured.replace"
        replaceDescriptor.vertexFunction = vertexFunction
        replaceDescriptor.fragmentFunction = library.makeFunction(name: FragmentKind.textured.rawValue)
        replaceDescriptor.colorAttachments[0]!.pixelFormat = Compositor.pixelFormat
        replaceDescriptor.colorAttachments[0]!.isBlendingEnabled = false
        replacePipeline = try device.makeRenderPipelineState(descriptor: replaceDescriptor)

        guard let warpVertex = library.makeFunction(name: "output_warp_vertex"),
              let warpFragment = library.makeFunction(name: "output_adjust_fragment")
        else {
            throw CompositorError.pipelineCreationFailed("missing output adjust functions")
        }
        let outputDescriptor = MTLRenderPipelineDescriptor()
        outputDescriptor.label = "compositor.outputAdjust"
        outputDescriptor.vertexFunction = warpVertex
        outputDescriptor.fragmentFunction = warpFragment
        outputDescriptor.colorAttachments[0]!.pixelFormat = Compositor.pixelFormat
        outputDescriptor.colorAttachments[0]!.isBlendingEnabled = false
        outputAdjustPipeline = try device.makeRenderPipelineState(descriptor: outputDescriptor)

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false
        )
        fallbackDescriptor.usage = [.shaderRead]
        fallbackDescriptor.storageMode = .shared
        guard let fallback = device.makeTexture(descriptor: fallbackDescriptor) else {
            throw CompositorError.pipelineCreationFailed("mask fallback texture")
        }
        fallback.label = "compositor.outputMaskFallback"
        var full: UInt8 = 255
        fallback.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &full, bytesPerRow: 1
        )
        outputMaskFallback = fallback

        guard let buildFragment = library.makeFunction(name: "compositor_build") else {
            throw CompositorError.pipelineCreationFailed("missing compositor_build")
        }
        var animationSteps: [SceneBlendMode: MTLRenderPipelineState] = [:]
        for blend in SceneBlendMode.allCases {
            animationSteps[blend] = try makePipeline(
                fragment: buildFragment, blend: blend,
                label: "compositor.build.\(blend.rawValue)", vertex: warpVertex
            )
        }
        buildPipelines = animationSteps
    }

    private func pipeline(_ fragment: FragmentKind, _ blend: SceneBlendMode) -> MTLRenderPipelineState {
        pipelines[PipelineKey(fragment: fragment, blend: blend)]!
    }

    public func render(
        scene: RenderScene,
        into drawable: CAMetalDrawable,
        at hostTime: CFTimeInterval,
        transparentBackground: Bool = false,
        adjustments: OutputAdjustments? = nil,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        mask: MTLTexture? = nil,
        inset: CGFloat = 0
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let plan = outputPassPlan(
               adjustments: adjustments, sourceRect: sourceRect,
               placement: placement, mask: mask, canvasSize: scene.canvasSize,
               targetWidth: drawable.texture.width, targetHeight: drawable.texture.height),
           let intermediate = outputIntermediate(
               width: plan.intermediateWidth, height: plan.intermediateHeight) {
            encode(
                scene: scene, into: intermediate, commandBuffer: commandBuffer,
                hostTime: hostTime, transparentBackground: transparentBackground
            )
            encodeOutputPass(
                from: intermediate, to: drawable.texture,
                adjustments: plan.adjustments, sourceRect: plan.sourceRect,
                placement: plan.placement, mask: mask, commandBuffer: commandBuffer
            )
        } else {
            encode(
                scene: scene, into: drawable.texture, commandBuffer: commandBuffer,
                hostTime: hostTime, transparentBackground: transparentBackground, inset: inset
            )
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func outputPassPlan(
        adjustments: OutputAdjustments?, sourceRect: CGRect?, placement: CGRect?,
        mask: MTLTexture?, canvasSize: CGSize, targetWidth: Int, targetHeight: Int
    ) -> (
        adjustments: OutputAdjustments, sourceRect: CGRect, placement: CGRect?,
        intermediateWidth: Int, intermediateHeight: Int
    )? {
        let crop = sourceRect.flatMap { $0 == Compositor.fullSourceRect ? nil : $0 }
        let land = placement.flatMap { $0 == Compositor.fullSourceRect ? nil : $0 }
        let corrections = adjustments.flatMap { $0.isNeutral ? nil : $0 }
        guard crop != nil || corrections != nil || mask != nil || land != nil else { return nil }
        let rect = crop ?? Compositor.fullSourceRect
        if crop == nil, land == nil {

            return (corrections ?? OutputAdjustments(), rect, nil, targetWidth, targetHeight)
        }

        let canvasWidth = max(canvasSize.width, 1)
        let canvasHeight = max(canvasSize.height, 1)
        let contentWidth = Double(targetWidth) * (land?.width ?? 1)
        let contentHeight = Double(targetHeight) * (land?.height ?? 1)
        let scale = max(
            contentWidth / (rect.width * canvasWidth),
            contentHeight / (rect.height * canvasHeight),
            0.01
        )
        return (
            corrections ?? OutputAdjustments(), rect, land,
            max(1, Int((canvasWidth * scale).rounded())),
            max(1, Int((canvasHeight * scale).rounded()))
        )
    }

    public func render(
        scene: RenderScene, into texture: MTLTexture, at hostTime: CFTimeInterval,
        adjustments: OutputAdjustments? = nil,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        mask: MTLTexture? = nil
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let plan = outputPassPlan(
               adjustments: adjustments, sourceRect: sourceRect,
               placement: placement, mask: mask, canvasSize: scene.canvasSize,
               targetWidth: texture.width, targetHeight: texture.height),
           let intermediate = outputIntermediate(
               width: plan.intermediateWidth, height: plan.intermediateHeight) {
            encode(scene: scene, into: intermediate, commandBuffer: commandBuffer, hostTime: hostTime)
            encodeOutputPass(
                from: intermediate, to: texture,
                adjustments: plan.adjustments, sourceRect: plan.sourceRect,
                placement: plan.placement, mask: mask, commandBuffer: commandBuffer
            )
        } else {
            encode(scene: scene, into: texture, commandBuffer: commandBuffer, hostTime: hostTime)
        }
        commandBuffer.commit()
    }

    private func outputIntermediate(width: Int, height: Int) -> MTLTexture? {
        let key = "\(width)x\(height)"
        if let cached = outputIntermediates[key] { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "compositor.outputIntermediate.\(key)"
        outputIntermediates[key] = texture
        return texture
    }

    public func render(
        scene: RenderScene,
        into texture: MTLTexture,
        at hostTime: CFTimeInterval,
        transparentBackground: Bool = false,
        adjustments: OutputAdjustments? = nil,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        mask: MTLTexture? = nil,
        completion: @escaping @Sendable () -> Void
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        if let plan = outputPassPlan(
               adjustments: adjustments, sourceRect: sourceRect,
               placement: placement, mask: mask, canvasSize: scene.canvasSize,
               targetWidth: texture.width, targetHeight: texture.height),
           let intermediate = outputIntermediate(
               width: plan.intermediateWidth, height: plan.intermediateHeight) {
            encode(
                scene: scene, into: intermediate, commandBuffer: commandBuffer,
                hostTime: hostTime, transparentBackground: transparentBackground)
            encodeOutputPass(
                from: intermediate, to: texture,
                adjustments: plan.adjustments, sourceRect: plan.sourceRect,
                placement: plan.placement, mask: mask, commandBuffer: commandBuffer
            )
        } else {
            encode(
                scene: scene, into: texture, commandBuffer: commandBuffer,
                hostTime: hostTime, transparentBackground: transparentBackground)
        }
        commandBuffer.addCompletedHandler { _ in completion() }
        commandBuffer.commit()
    }

    public struct OutputCompositeLayer: @unchecked Sendable {
        public let scene: RenderScene
        public let sourceRect: CGRect?
        public let placement: CGRect?
        public let adjustments: OutputAdjustments?
        public let mask: MTLTexture?

        public init(
            scene: RenderScene, sourceRect: CGRect? = nil, placement: CGRect? = nil,
            adjustments: OutputAdjustments? = nil, mask: MTLTexture? = nil
        ) {
            self.scene = scene
            self.sourceRect = sourceRect
            self.placement = placement
            self.adjustments = adjustments
            self.mask = mask
        }
    }

    public func render(
        composite layers: [OutputCompositeLayer],
        into drawable: CAMetalDrawable,
        at hostTime: CFTimeInterval
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeComposite(layers, into: drawable.texture, commandBuffer: commandBuffer, hostTime: hostTime)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public func render(
        composite layers: [OutputCompositeLayer],
        into texture: MTLTexture,
        at hostTime: CFTimeInterval,
        completion: @escaping @Sendable () -> Void
    ) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodeComposite(layers, into: texture, commandBuffer: commandBuffer, hostTime: hostTime)
        commandBuffer.addCompletedHandler { _ in completion() }
        commandBuffer.commit()
    }

    private func encodeComposite(
        _ layers: [OutputCompositeLayer], into target: MTLTexture,
        commandBuffer: MTLCommandBuffer, hostTime: CFTimeInterval
    ) {
        guard !layers.isEmpty else { return }
        for (index, layer) in layers.enumerated() {
            let plan = outputPassPlan(
                adjustments: layer.adjustments, sourceRect: layer.sourceRect,
                placement: layer.placement, mask: layer.mask,
                canvasSize: layer.scene.canvasSize,
                targetWidth: target.width, targetHeight: target.height
            ) ?? (
                OutputAdjustments(), Compositor.fullSourceRect, nil,
                target.width, target.height
            )
            guard let intermediate = outputIntermediate(
                width: plan.intermediateWidth, height: plan.intermediateHeight)
            else { continue }
            encode(
                scene: layer.scene, into: intermediate, commandBuffer: commandBuffer,
                hostTime: hostTime
            )
            encodeOutputPass(
                from: intermediate, to: target,
                adjustments: plan.adjustments, sourceRect: plan.sourceRect,
                placement: plan.placement, mask: layer.mask,
                loadAction: index == 0 ? .clear : .load,
                commandBuffer: commandBuffer
            )
        }
    }

    public func present(
        texture: MTLTexture, into drawable: CAMetalDrawable, sourceRect: CGRect? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodePresent(
            texture: texture, into: drawable.texture,
            sourceRect: sourceRect, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public func present(texture: MTLTexture, into target: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        encodePresent(texture: texture, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
    }

    private func encodePresent(
        texture: MTLTexture,
        into target: MTLTexture,
        sourceRect: CGRect? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.label = "compositor.present"

        let targetSize = CGSize(width: target.width, height: target.height)
        let uv = sourceRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)

        let regionSize = CGSize(
            width: max(Double(texture.width) * uv.width, 1),
            height: max(Double(texture.height) * uv.height, 1)
        )
        let transform = SceneTransform(canvasSize: regionSize, targetSize: targetSize)
        let pixelRect = transform.pixelRect(
            CGRect(origin: .zero, size: regionSize)
        )
        var vertices = Self.quadVertices(
            pixelRect: pixelRect, targetSize: targetSize, uvRect: uv)
        var opacity = Float(1)
        encoder.setRenderPipelineState(pipeline(.textured, .normal))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    public func readback(texture: MTLTexture) throws -> RenderedFrame {
        if let fence = commandQueue.makeCommandBuffer() {
            fence.commit()
            fence.waitUntilCompleted()
        }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * MemoryLayout<UInt16>.size * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return RenderedFrame(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    public func renderFrame(
        scene: RenderScene,
        width: Int,
        height: Int,
        at hostTime: CFTimeInterval = 0,
        transparentBackground: Bool = false,
        inset: CGFloat = 0
    ) throws -> RenderedFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw CompositorError.renderFailed("could not create offscreen target")
        }

        encodeLock.lock()
        encode(
            scene: scene, into: texture, commandBuffer: commandBuffer,
            hostTime: hostTime, transparentBackground: transparentBackground, inset: inset
        )
        commandBuffer.commit()
        encodeLock.unlock()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw CompositorError.renderFailed("\(error)")
        }
        return try readback(texture: texture)
    }

    private func encode(
        scene: RenderScene,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        hostTime: CFTimeInterval,
        transparentBackground: Bool = false,
        inset: CGFloat = 0
    ) {
        cacheClock = cacheClockOverride?() ?? CACurrentMediaTime()
        let targetSize = CGSize(width: texture.width, height: texture.height)
        let transform = SceneTransform(canvasSize: scene.canvasSize, targetSize: targetSize, inset: inset)

        let resolved = AnimationEvaluator.resolve(scene, hostTime: hostTime)
        let scene = resolved.scene
        let motions = resolved.motions

        let maskPlan = buildMaskPlan(
            scene: scene, motions: motions, transform: transform,
            commandBuffer: commandBuffer, hostTime: hostTime
        )

        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.storeAction = .store

        attachment.clearColor = transparentBackground
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard var encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            recycleScratch()
            return
        }
        encoder.label = "compositor.scene"

        if !transparentBackground {
            let backgroundFrame = CGRect(origin: .zero, size: scene.canvasSize)
            drawSolid(
                scene.background,
                item: RenderItem(id: "scene.background", frame: backgroundFrame, content: .solid(scene.background)),
                pixelRect: transform.pixelRect(backgroundFrame),
                targetSize: targetSize,
                encoder: encoder
            )
        }

        for layer in scene.layers where !layer.isHidden {
            for item in layer.items {

                if item.matteGroup != nil { continue }

                if item.effectsApplyBelow, !item.effects.isEmpty {
                    guard let resumed = applyAdjustmentLayer(
                        item, target: texture, transform: transform,
                        targetSize: targetSize, commandBuffer: commandBuffer,
                        hostTime: hostTime, ending: encoder
                    ) else {
                        recycleScratch()
                        return
                    }
                    encoder = resumed
                }
                if let prepared = maskPlan.composites[item.id] {
                    if let motion = motions[item.id] {
                        drawBuildComposite(
                            prepared, item: item, motion: motion, transform: transform,
                            targetSize: targetSize, encoder: encoder
                        )
                    } else {
                        drawMaskedComposite(
                            prepared, item: item, targetSize: targetSize, encoder: encoder
                        )
                    }
                    continue
                }
                if item.maskedBy != nil, !item.maskOut, maskPlan.missingMattes.contains(item.id) {

                    continue
                }
                drawItem(item, transform: transform, targetSize: targetSize, encoder: encoder, hostTime: hostTime)
            }
        }

        encoder.endEncoding()
        recycleScratch()
        sweepCachesIfDue()
    }

    private func drawItem(
        _ item: RenderItem,
        transform: SceneTransform,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {
        switch item.content {
        case .solid(let color):
            drawSolid(
                color, item: item,
                pixelRect: transform.pixelRect(item.frame),
                targetSize: targetSize, encoder: encoder
            )
        case .text(let text):
            drawText(
                text, item: item,
                pixelRect: transform.pixelRect(item.frame),
                scale: transform.scale,
                targetSize: targetSize, encoder: encoder, hostTime: hostTime
            )
        case .shape(let style):
            drawShape(
                style, item: item, transform: transform,
                targetSize: targetSize, encoder: encoder, hostTime: hostTime
            )
        case .media(let id, let scaleMode, let sourceRect):
            drawMedia(
                id: id, scaleMode: scaleMode, sourceRect: sourceRect, item: item,
                pixelRect: transform.pixelRect(item.frame),
                targetSize: targetSize, encoder: encoder, hostTime: hostTime
            )
        }
    }

    private struct PreparedComposite {
        let content: MTLTexture
        let contentRect: CGRect

        let matte: MTLTexture?
        let matteRect: CGRect
        let knockout: Bool
    }

    private struct MaskPlan {
        var composites: [String: PreparedComposite] = [:]

        var missingMattes: Set<String> = []
    }

    private func targetSpaceBounds(for item: RenderItem, transform: SceneTransform) -> CGRect {
        var pad: CGFloat = 0
        switch item.content {
        case .shape(let style):
            pad = ShapeRasterizer.padding(for: style) * transform.scale
        case .text(let text):
            if let pathData = text.pathData, !pathData.isEmpty {

                pad = (CGFloat(text.fontSize) * 2 + abs(CGFloat(text.pathOffset))) * transform.scale
            }
        case .solid, .media:
            break
        }

        if !item.effectsApplyBelow {
            for effect in item.effects {
                switch effect.kind {
                case .blur(let radius):
                    pad += CGFloat(radius) * 3 * transform.scale
                case .warp(let amount, _, _), .scatter(let amount, _, _, _):

                    pad += CGFloat(amount) * transform.scale
                case .stainedGlass(let cellSize, _, _, _):

                    pad += CGFloat(cellSize) * transform.scale
                case .ghostTrails(_, let drift, _, _):

                    pad += CGFloat(drift) * 12 * transform.scale
                case .glitch(let amount, _):

                    pad += CGFloat(amount) * 40 * transform.scale
                default:
                    break
                }
            }
        }
        var rect = transform.pixelRect(item.frame).insetBy(dx: -pad, dy: -pad)
        if item.rotationDegrees != 0 {
            let radians = item.rotationDegrees * .pi / 180
            let c = abs(cos(radians))
            let sn = abs(sin(radians))
            let w = rect.width * c + rect.height * sn
            let h = rect.width * sn + rect.height * c
            rect = CGRect(
                x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h
            )
        }
        return CGRect(
            x: rect.origin.x.rounded(.down),
            y: rect.origin.y.rounded(.down),
            width: max(rect.width.rounded(.up), 1),
            height: max(rect.height.rounded(.up), 1)
        )
    }

    private func renderIntermediate(
        items: [RenderItem],
        bounds: CGRect,
        transform: SceneTransform,
        commandBuffer: MTLCommandBuffer,
        hostTime: CFTimeInterval,
        label: String
    ) -> MTLTexture? {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              let scratch = acquireScratch(width: width, height: height),
              let encoder = makeIntermediatePass(into: scratch, commandBuffer: commandBuffer, label: label)
        else { return nil }
        let cropTransform = SceneTransform(
            scale: transform.scale,
            offset: CGPoint(x: transform.offset.x - bounds.origin.x, y: transform.offset.y - bounds.origin.y)
        )
        for item in items {
            drawItem(
                item, transform: cropTransform,
                targetSize: CGSize(width: width, height: height),
                encoder: encoder, hostTime: hostTime
            )
        }
        encoder.endEncoding()
        return scratch
    }

    private func encodeFragmentEffect(
        _ kind: FragmentKind, params: SIMD4<Float>, params2: SIMD4<Float>? = nil,
        source: MTLTexture, secondary: MTLTexture? = nil, commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let dest = acquireScratch(width: source.width, height: source.height),
              let encoder = makeIntermediatePass(
                  into: dest, commandBuffer: commandBuffer,
                  label: "compositor.effect.\(kind.rawValue)"
              )
        else { return nil }
        let size = CGSize(width: dest.width, height: dest.height)
        var vertices = Self.quadVertices(
            pixelRect: CGRect(origin: .zero, size: size), targetSize: size
        )
        var params = params
        encoder.setRenderPipelineState(pipeline(kind, .normal))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        if var params2 {
            encoder.setFragmentBytes(&params2, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        }
        encoder.setFragmentTexture(source, index: 0)
        if let secondary { encoder.setFragmentTexture(secondary, index: 1) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        return dest
    }

    private func makeIntermediatePass(
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        label: String,
        load: Bool = false
    ) -> MTLRenderCommandEncoder? {
        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = texture

        attachment.loadAction = load ? .load : .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return nil
        }
        encoder.label = label
        return encoder
    }

    private func applyEffects(
        _ effects: [SceneEffect],
        to source: MTLTexture,
        scale: CGFloat,
        commandBuffer: MTLCommandBuffer,
        historyKey: String,
        hostTime: CFTimeInterval
    ) -> MTLTexture {
        var current = source
        for (index, effect) in effects.enumerated() {
            var processed: MTLTexture?
            switch effect.kind {
            case .warp(let amount, let noiseScale, let speed):

                processed = encodeFragmentEffect(
                    .warp,
                    params: SIMD4(
                        Float(amount * scale), Float(max(noiseScale * scale, 1)),
                        Float(hostTime * speed), 0
                    ),
                    source: current, commandBuffer: commandBuffer
                )
            case .scatter(let amount, let size, let speed, let smooth):

                let roll = speed > 0.001 ? floor(hostTime * 60 * speed) : 0
                processed = encodeFragmentEffect(
                    .scatter,
                    params: SIMD4(
                        Float(amount * scale), Float(roll), Float(max(size * scale, 1)), Float(smooth)
                    ),
                    source: current, commandBuffer: commandBuffer
                )
            case .stainedGlass(let cellSize, let leading, let jitter, let speed):
                processed = encodeFragmentEffect(
                    .stainedGlass,
                    params: SIMD4(
                        Float(max(cellSize * scale, 2)), Float(leading * scale),
                        Float(jitter), Float(hostTime * speed)
                    ),
                    source: current, commandBuffer: commandBuffer
                )
            case .grain(let amount, let size, let speed):
                let roll = speed > 0.001 ? floor(hostTime * 60 * speed) : 0
                processed = encodeFragmentEffect(
                    .grain,
                    params: SIMD4(Float(amount), Float(max(size * scale, 1)), Float(roll), 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .glitch(let amount, let phase):

                processed = encodeFragmentEffect(
                    .glitch,
                    params: SIMD4(Float(amount), Float(phase), Float(40 * scale), 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .burn(let amount, let phase):
                processed = encodeFragmentEffect(
                    .burn,
                    params: SIMD4(Float(amount), Float(phase), 0, 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .tint(let color, let amount):

                let target = color.linear
                processed = encodeFragmentEffect(
                    .tint,
                    params: SIMD4(
                        Float(target.x), Float(target.y), Float(target.z),
                        Float(min(max(amount, 0), 1))
                    ),
                    source: current, commandBuffer: commandBuffer
                )
            case .echo, .ghostTrails:

                let fade: Double
                var fragment = FragmentKind.echo
                var params2: SIMD4<Float>?
                switch effect.kind {
                case .ghostTrails(let f, let drift, let fieldScale, let speed):
                    fade = f
                    fragment = .ghostTrails
                    params2 = SIMD4(
                        Float(drift * scale), Float(max(fieldScale * scale, 1)),
                        Float(hostTime * speed), 0
                    )
                case .echo(let f): fade = f
                default: fade = 1
                }
                let key = "\(historyKey)#\(index)"
                let width = current.width, height = current.height
                let previous = effectHistory(key: key, width: width, height: height)
                let history: MTLTexture
                if let previous {
                    history = previous.texture
                } else if let fresh = makeHistoryTexture(width: width, height: height) {
                    history = fresh
                } else {
                    continue
                }

                let elapsed = previous.map { max($0.elapsed, 1.0 / 240) } ?? 1.0 / 60
                let keep = pow(0.1, elapsed / max(fade, 0.01))
                guard let dest = encodeFragmentEffect(
                    fragment,
                    params: SIMD4(Float(min(keep, 0.999)), previous == nil ? 0 : 1, 0, 0),
                    params2: params2,
                    source: current, secondary: history, commandBuffer: commandBuffer
                ) else { continue }

                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.label = "compositor.echo.history"
                    blit.copy(from: dest, to: history)
                    blit.endEncoding()
                    storeEffectHistory(key: key, texture: history)
                }
                processed = dest
            case .blur(let radius):
                let sigma = Float(radius * scale)
                guard sigma > 0.01,
                      let kernel = blurKernel(sigma: sigma),
                      let dest = acquireScratch(width: current.width, height: current.height)
                else { continue }
                kernel.encode(
                    commandBuffer: commandBuffer,
                    sourceTexture: current, destinationTexture: dest
                )
                processed = dest
            case .colorAdjust(let brightness, let contrast, let saturation, let hue):
                processed = encodeFragmentEffect(
                    .colorAdjust,
                    params: SIMD4(
                        Float(brightness), Float(contrast), Float(saturation),
                        Float(hue * .pi / 180)
                    ),
                    source: current, commandBuffer: commandBuffer
                )
            case .hueRotate(let degrees):
                processed = encodeFragmentEffect(
                    .hueRotate,
                    params: SIMD4(Float(degrees * .pi / 180), 0, 0, 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .invert:
                processed = encodeFragmentEffect(
                    .invert, params: SIMD4(repeating: 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .posterize(let levels):
                processed = encodeFragmentEffect(
                    .posterize,
                    params: SIMD4(Float(min(max(levels, 2), 32)), 0, 0, 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .pixelate(let size):

                processed = encodeFragmentEffect(
                    .pixelate,
                    params: SIMD4(Float(max(size * scale, 1)), 0, 0, 0),
                    source: current, commandBuffer: commandBuffer
                )
            case .vignette(let strength):
                processed = encodeFragmentEffect(
                    .vignette,
                    params: SIMD4(Float(min(max(strength, 0), 1.5)), 0, 0, 0),
                    source: current, commandBuffer: commandBuffer
                )
            }
            guard let processed else { continue }

            if effect.opacity < 0.999,
               let mixed = acquireScratch(width: current.width, height: current.height),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "compositor.effectMix.copy"
                blit.copy(from: current, to: mixed)
                blit.endEncoding()
                if let encoder = makeIntermediatePass(
                    into: mixed, commandBuffer: commandBuffer,
                    label: "compositor.effectMix", load: true
                ) {
                    let size = CGSize(width: mixed.width, height: mixed.height)
                    var vertices = Self.quadVertices(
                        pixelRect: CGRect(origin: .zero, size: size), targetSize: size
                    )
                    var opacity = Float(effect.opacity)
                    encoder.setRenderPipelineState(pipeline(.textured, .normal))
                    encoder.setVertexBytes(
                        &vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0
                    )
                    encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
                    encoder.setFragmentTexture(processed, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    encoder.endEncoding()
                    current = mixed
                } else {
                    current = processed
                }
            } else {
                current = processed
            }
        }
        return current
    }

    private func applyAdjustmentLayer(
        _ item: RenderItem,
        target: MTLTexture,
        transform: SceneTransform,
        targetSize: CGSize,
        commandBuffer: MTLCommandBuffer,
        hostTime: CFTimeInterval,
        ending encoder: MTLRenderCommandEncoder
    ) -> MTLRenderCommandEncoder? {
        let pixelRect = transform.pixelRect(item.frame)
        let region = CGRect(
            x: pixelRect.origin.x.rounded(), y: pixelRect.origin.y.rounded(),
            width: pixelRect.width.rounded(), height: pixelRect.height.rounded()
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(target.width), height: CGFloat(target.height)))
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return encoder }

        encoder.endEncoding()

        let width = Int(region.width)
        let height = Int(region.height)
        guard let snapshot = acquireScratch(width: width, height: height),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return resumeScenePass(into: target, commandBuffer: commandBuffer) }
        blit.label = "compositor.adjustment.snapshot"
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: Int(region.minX), y: Int(region.minY), z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: snapshot, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        let processed = applyEffects(
            item.effects, to: snapshot, scale: transform.scale, commandBuffer: commandBuffer,
            historyKey: item.id, hostTime: hostTime
        )

        guard let resumed = resumeScenePass(into: target, commandBuffer: commandBuffer) else {
            return nil
        }
        var vertices = Self.quadVertices(pixelRect: region, targetSize: targetSize)
        var opacity = Float(1)

        resumed.setRenderPipelineState(replacePipeline)
        resumed.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        resumed.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        resumed.setFragmentTexture(processed, index: 0)
        resumed.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        return resumed
    }

    private func resumeScenePass(
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLRenderCommandEncoder? {
        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .load
        attachment.storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return nil
        }
        encoder.label = "compositor.scene.resumed"
        return encoder
    }

    private func intermediateItem(_ item: RenderItem, stripShadow: Bool) -> RenderItem {
        var copy = item
        copy.opacity = 1
        copy.blendMode = .normal
        guard stripShadow else { return copy }

        switch copy.content {
        case .shape(var style):
            style.shadow = nil
            copy.content = .shape(style)
        case .text(var text):
            text.shadow = nil
            copy.content = .text(text)
        case .solid, .media:
            break
        }
        return copy
    }

    private func buildMaskPlan(
        scene: RenderScene,
        motions: [String: AnimationMotion] = [:],
        transform: SceneTransform,
        commandBuffer: MTLCommandBuffer,
        hostTime: CFTimeInterval
    ) -> MaskPlan {
        var plan = MaskPlan()

        var matteItems: [String: [RenderItem]] = [:]
        var maskedItems: [RenderItem] = []
        var effectItems: [RenderItem] = []
        for layer in scene.layers where !layer.isHidden {
            for item in layer.items {
                if let group = item.matteGroup {
                    matteItems[group, default: []].append(item)
                }
                if item.maskedBy != nil, item.matteGroup == nil {
                    maskedItems.append(item)
                } else if item.matteGroup == nil,
                          (!item.effects.isEmpty && !item.effectsApplyBelow) || motions[item.id] != nil {

                    effectItems.append(item)
                }
            }
        }
        guard !maskedItems.isEmpty || !effectItems.isEmpty else { return plan }

        var mattes: [String: (texture: MTLTexture, rect: CGRect)] = [:]
        for (group, items) in matteItems {
            let bounds = items.dropFirst().reduce(targetSpaceBounds(for: items[0], transform: transform)) {
                $0.union(targetSpaceBounds(for: $1, transform: transform))
            }
            guard let texture = renderIntermediate(
                items: items.map { intermediateItem($0, stripShadow: true) },
                bounds: bounds, transform: transform,
                commandBuffer: commandBuffer, hostTime: hostTime,
                label: "compositor.matte.\(group)"
            ) else { continue }
            mattes[group] = (texture, bounds)
        }

        for item in maskedItems {
            guard let matte = item.maskedBy.flatMap({ mattes[$0] }) else {
                plan.missingMattes.insert(item.id)
                continue
            }
            let bounds = targetSpaceBounds(for: item, transform: transform)
            guard var content = renderIntermediate(
                items: [intermediateItem(item, stripShadow: false)],
                bounds: bounds, transform: transform,
                commandBuffer: commandBuffer, hostTime: hostTime,
                label: "compositor.maskedContent.\(item.id)"
            ) else { continue }
            if !item.effects.isEmpty, !item.effectsApplyBelow {

                content = applyEffects(
                    item.effects, to: content, scale: transform.scale, commandBuffer: commandBuffer,
                    historyKey: item.id, hostTime: hostTime
                )
            }
            plan.composites[item.id] = PreparedComposite(
                content: content, contentRect: bounds,
                matte: matte.texture, matteRect: matte.rect,
                knockout: item.maskOut
            )
        }

        for item in effectItems {
            let bounds = targetSpaceBounds(for: item, transform: transform)
            guard let content = renderIntermediate(
                items: [intermediateItem(item, stripShadow: false)],
                bounds: bounds, transform: transform,
                commandBuffer: commandBuffer, hostTime: hostTime,
                label: "compositor.effectContent.\(item.id)"
            ) else { continue }
            plan.composites[item.id] = PreparedComposite(
                content: item.effects.isEmpty || item.effectsApplyBelow ? content : applyEffects(
                    item.effects, to: content, scale: transform.scale, commandBuffer: commandBuffer,
                    historyKey: item.id, hostTime: hostTime
                ),
                contentRect: bounds,
                matte: nil, matteRect: bounds,
                knockout: false
            )
        }
        return plan
    }

    private func drawMaskedComposite(
        _ prepared: PreparedComposite,
        item: RenderItem,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {

        var vertices = Self.quadVertices(pixelRect: prepared.contentRect, targetSize: targetSize)
        guard let matte = prepared.matte else {

            var opacity = Float(item.opacity)
            encoder.setRenderPipelineState(pipeline(.textured, item.blendMode))
            encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(prepared.content, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            return
        }
        var uvMap = SIMD4<Float>(
            Float(prepared.contentRect.width / prepared.matteRect.width),
            Float(prepared.contentRect.height / prepared.matteRect.height),
            Float((prepared.contentRect.minX - prepared.matteRect.minX) / prepared.matteRect.width),
            Float((prepared.contentRect.minY - prepared.matteRect.minY) / prepared.matteRect.height)
        )
        var params = SIMD4<Float>(prepared.knockout ? 1 : 0, Float(item.opacity), 0, 0)
        encoder.setRenderPipelineState(pipeline(.maskedComposite, item.blendMode))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&uvMap, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setFragmentTexture(prepared.content, index: 0)
        encoder.setFragmentTexture(matte, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private struct BuildUniformsData {
        var matteRect: SIMD4<Float>
        var params: SIMD4<Float>
        var wipe: SIMD4<Float>
        var wipeFeather: SIMD4<Float>
        var wipeFeatherMax: SIMD4<Float>
    }

    private static func tiltFocalDistance(targetSize: CGSize) -> CGFloat {
        max(targetSize.width, targetSize.height) * 1.5
    }

    public static func buildQuadCorners(
        contentRect: CGRect, motion: AnimationMotion, sceneScale: CGFloat, targetSize: CGSize
    ) -> [CGPoint] {
        let projector = BuildProjector(contentRect: contentRect, motion: motion, sceneScale: sceneScale, targetSize: targetSize)
        return [
            projector.project(u: 0, v: 0), projector.project(u: 1, v: 0),
            projector.project(u: 0, v: 1), projector.project(u: 1, v: 1),
        ]
    }

    struct BuildProjector {
        let center: CGPoint
        let dx: CGFloat, dy: CGFloat
        let halfW: CGFloat, halfH: CGFloat
        let cosT: CGFloat, sinT: CGFloat
        let cosS: CGFloat, sinS: CGFloat
        let pivotY: CGFloat
        let keyTop: CGFloat, keyBottom: CGFloat
        let shearX: CGFloat, shearY: CGFloat
        let focal: CGFloat

        init(contentRect: CGRect, motion: AnimationMotion, sceneScale: CGFloat, targetSize: CGSize) {
            center = CGPoint(x: contentRect.midX, y: contentRect.midY)
            dx = CGFloat(motion.translate.dx) * sceneScale
            dy = CGFloat(motion.translate.dy) * sceneScale
            let scale = CGFloat(motion.scale)
            let scaleY = CGFloat(motion.scaleY ?? motion.scale)
            halfW = contentRect.width / 2 * scale
            halfH = contentRect.height / 2 * scaleY
            let theta = CGFloat(motion.tilt) * .pi / 180
            cosT = cos(theta); sinT = sin(theta)
            let phi = CGFloat(motion.swing) * .pi / 180
            cosS = cos(phi); sinS = sin(phi)

            pivotY = switch motion.tiltPivot {
            case .top: -halfH
            case .center: 0
            case .bottom: halfH
            }
            keyTop = CGFloat(motion.keystoneTop)
            keyBottom = CGFloat(motion.keystoneBottom)

            shearX = tan(CGFloat(min(max(motion.skewX, -85), 85)) * .pi / 180)
            shearY = tan(CGFloat(min(max(motion.skewY, -85), 85)) * .pi / 180)
            focal = tiltFocalDistance(targetSize: targetSize)
        }

        func project(u: CGFloat, v: CGFloat) -> CGPoint {

            let edgeScale = keyTop + (keyBottom - keyTop) * v
            let kx = (u * 2 - 1) * halfW * edgeScale
            let ky = (v * 2 - 1) * halfH

            let rx = kx - ky * shearX
            let ry = ky + kx * shearY

            let ay = ry - pivotY
            var z = -ay * sinT
            let py = pivotY + ay * cosT

            let px = rx * cosS - z * sinS
            z = rx * sinS + z * cosS
            let depth = max(focal + z, 1)
            let k = focal / depth
            return CGPoint(x: center.x + dx + px * k, y: center.y + dy + py * k)
        }
    }

    static let stretchKeystoneStrips = 32

    static func stretchKeystoneVertices(
        contentRect: CGRect, motion: AnimationMotion, sceneScale: CGFloat, targetSize: CGSize
    ) -> [OutputWarpVertexData] {
        let projector = BuildProjector(contentRect: contentRect, motion: motion, sceneScale: sceneScale, targetSize: targetSize)
        func ndc(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2(Float(p.x / targetSize.width * 2 - 1), Float(1 - p.y / targetSize.height * 2))
        }
        func vertex(u: CGFloat, v: CGFloat) -> OutputWarpVertexData {
            let p = ndc(projector.project(u: u, v: v))
            return OutputWarpVertexData(posUV: SIMD4(p.x, p.y, Float(u), Float(v)), q: SIMD4(1, 0, 0, 0))
        }
        var vertices: [OutputWarpVertexData] = []
        vertices.reserveCapacity(stretchKeystoneStrips * 6)
        for i in 0..<stretchKeystoneStrips {
            let v0 = CGFloat(i) / CGFloat(stretchKeystoneStrips)
            let v1 = CGFloat(i + 1) / CGFloat(stretchKeystoneStrips)
            let tl = vertex(u: 0, v: v0), tr = vertex(u: 1, v: v0)
            let bl = vertex(u: 0, v: v1), br = vertex(u: 1, v: v1)
            vertices += [tl, bl, br, tl, br, tr]
        }
        return vertices
    }

    private func drawBuildComposite(
        _ prepared: PreparedComposite,
        item: RenderItem,
        motion: AnimationMotion,
        transform: SceneTransform,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let corners = Self.buildQuadCorners(
            contentRect: prepared.contentRect, motion: motion,
            sceneScale: transform.scale, targetSize: targetSize
        )
        func ndc(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x / targetSize.width * 2 - 1, y: 1 - p.y / targetSize.height * 2)
        }
        let destinations = corners.map(ndc)
        let sources = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        let uvq = OutputWarp.projectiveUVs(destinations: destinations, sources: sources)
            ?? zip(destinations, sources).map { _, s in SIMD3(Double(s.x), Double(s.y), 1) }
        func vertex(_ i: Int) -> OutputWarpVertexData {
            OutputWarpVertexData(
                posUV: SIMD4(Float(destinations[i].x), Float(destinations[i].y), Float(uvq[i].x), Float(uvq[i].y)),
                q: SIMD4(Float(uvq[i].z), 0, 0, 0)
            )
        }

        var vertices = motion.usesStretchKeystone
            ? Self.stretchKeystoneVertices(
                contentRect: prepared.contentRect, motion: motion,
                sceneScale: transform.scale, targetSize: targetSize)
            : [vertex(0), vertex(2), vertex(3), vertex(0), vertex(3), vertex(1)]

        var wipe = SIMD4<Float>(0, 1, 0, 1)
        var feather = SIMD4<Float>(0, 0, 0, 0)
        var featherMax = SIMD4<Float>(0, 0, 0, 0)
        if let w = motion.wipe {
            let p = Float(min(max(w.progress, 0), 1))
            switch w.edge {
            case .left: wipe = SIMD4(0, p, 0, 1)
            case .right: wipe = SIMD4(1 - p, 1, 0, 1)
            case .top: wipe = SIMD4(0, 1, 0, p)
            case .bottom: wipe = SIMD4(0, 1, 1 - p, 1)
            }
            let fpx = CGFloat(w.feather) * transform.scale
            feather = SIMD4(
                Float(fpx / max(prepared.contentRect.width, 1)),
                Float(fpx / max(prepared.contentRect.height, 1)),
                1, 0
            )
            featherMax = SIMD4(feather.x, feather.y, 0, 0)
        }

        if let c = motion.clip {

            let box = SIMD4<Float>(Float(c.minU), Float(c.maxU), Float(c.minV), Float(c.maxV))
            wipe = motion.wipe == nil ? box : SIMD4(max(wipe.x, box.x), min(wipe.y, box.y), max(wipe.z, box.z), min(wipe.w, box.w))
            feather = SIMD4(max(feather.x, Float(c.featherMinU)), max(feather.y, Float(c.featherMinV)), 1, 0)
            featherMax = SIMD4(max(featherMax.x, Float(c.featherMaxU)), max(featherMax.y, Float(c.featherMaxV)), 0, 0)
        }
        var uniforms = BuildUniformsData(
            matteRect: SIMD4(
                Float(prepared.matteRect.minX), Float(prepared.matteRect.minY),
                Float(max(prepared.matteRect.width, 1)), Float(max(prepared.matteRect.height, 1))
            ),
            params: SIMD4(prepared.knockout ? 1 : 0, Float(item.opacity), prepared.matte == nil ? 0 : 1, 0),
            wipe: wipe,
            wipeFeather: feather,
            wipeFeatherMax: featherMax
        )
        encoder.setRenderPipelineState(buildPipelines[item.blendMode]!)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BuildUniformsData>.stride, index: 0)
        encoder.setFragmentTexture(prepared.content, index: 0)
        encoder.setFragmentTexture(prepared.matte ?? prepared.content, index: 1)

        let stride = MemoryLayout<OutputWarpVertexData>.stride
        let perChunk = max((4096 / stride) / 6 * 6, 6)
        var start = 0
        while start < vertices.count {
            let count = min(perChunk, vertices.count - start)
            vertices.withUnsafeBufferPointer { buffer in
                encoder.setVertexBytes(buffer.baseAddress! + start, length: stride * count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            start += count
        }
    }

    private func sweepCachesIfDue() {
        guard cacheClock - lastSweep >= Self.sweepInterval else { return }
        lastSweep = cacheClock
        evictStaleEntries(asOf: cacheClock)
    }

    func sweepCaches(at now: CFTimeInterval) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        evictStaleEntries(asOf: now)
    }

    private func evictStaleEntries(asOf now: CFTimeInterval) {
        let deadline = now - Self.cacheTTL

        if textTextures.contains(where: { $0.value.lastUsed < deadline }) {
            textTextures = textTextures.filter { $0.value.lastUsed >= deadline }
        }
        if shapeTextures.contains(where: { $0.value.lastUsed < deadline }) {
            shapeTextures = shapeTextures.filter { $0.value.lastUsed >= deadline }
        }
        if stripTextures.contains(where: { $0.value.lastUsed < deadline }) {
            stripTextures = stripTextures.filter { $0.value.lastUsed >= deadline }
        }
        if flatPaths.contains(where: { $0.value.lastUsed < deadline }) {
            flatPaths = flatPaths.filter { $0.value.lastUsed >= deadline }
        }
        if scratchPool.contains(where: { $0.value.lastUsed < deadline }) {
            scratchPool = scratchPool.filter { $0.value.lastUsed >= deadline }
        }
        if effectHistories.contains(where: { $0.value.lastUsed < deadline }) {
            effectHistories = effectHistories.filter { $0.value.lastUsed >= deadline }
        }
    }

    var effectHistoryCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return effectHistories.count
    }

    var scratchTextureCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return scratchPool.values.reduce(0) { $0 + $1.free.count } + scratchBusy.count
    }

    var textTextureCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return textTextures.count
    }

    var shapeTextureCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return shapeTextures.count
    }

    var stripTextureCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return stripTextures.count
    }

    var flatPathCount: Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return flatPaths.count
    }

    private func drawSolid(
        _ color: SceneColor,
        item: RenderItem,
        pixelRect: CGRect,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        guard pixelRect.width > 0, pixelRect.height > 0 else { return }
        var vertices = Self.quadVertices(
            pixelRect: pixelRect, targetSize: targetSize, rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
        )

        var color = color.linearPremultiplied * Float(item.opacity)
        encoder.setRenderPipelineState(pipeline(.solid, item.blendMode))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawShape(
        _ style: ShapeStyle,
        item: RenderItem,
        transform: SceneTransform,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {

        let pad = ShapeRasterizer.padding(for: style)
        let paddedRect = transform.pixelRect(item.frame.insetBy(dx: -pad, dy: -pad))
        let snapped = CGRect(
            x: paddedRect.origin.x.rounded(),
            y: paddedRect.origin.y.rounded(),
            width: paddedRect.width.rounded(),
            height: paddedRect.height.rounded()
        )
        let width = Int(snapped.width)
        let height = Int(snapped.height)
        guard width > 0, height > 0 else { return }
        let padMilli = Int((pad * transform.scale * 1000).rounded())

        if case .media(let mediaID, let scaleMode, let sourceRect) = style.fill {
            drawMediaFilledShape(
                style, mediaID: mediaID, scaleMode: scaleMode, sourceRect: sourceRect, item: item,
                transform: transform, snapped: snapped,
                width: width, height: height, padMilli: padMilli,
                pixelPad: pad * transform.scale,
                targetSize: targetSize, encoder: encoder, hostTime: hostTime
            )
            return
        }

        let key = ShapeRasterizer.Key(
            style: style,
            pixelWidth: width,
            pixelHeight: height,
            scaleMilli: Int((transform.scale * 1000).rounded()),
            padMilli: padMilli
        )
        let texture: MTLTexture
        if let index = shapeTextures.index(forKey: key) {
            shapeTextures.values[index].lastUsed = cacheClock
            texture = shapeTextures.values[index].texture
        } else if let made = ShapeRasterizer.makeTexture(
            style: style,
            pixelWidth: width,
            pixelHeight: height,
            pixelPad: pad * transform.scale,
            scale: transform.scale,
            device: device
        ) {
            shapeTextures[key] = CachedTexture(texture: made, lastUsed: cacheClock)
            texture = made
        } else {
            return
        }

        var vertices = Self.quadVertices(
            pixelRect: snapped, targetSize: targetSize, rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
        )
        var opacity = Float(item.opacity)
        encoder.setRenderPipelineState(pipeline(.textured, item.blendMode))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawMediaFilledShape(
        _ style: ShapeStyle,
        mediaID: String,
        scaleMode: SceneMediaScaleMode,
        sourceRect: SceneSourceRect?,
        item: RenderItem,
        transform: SceneTransform,
        snapped: CGRect,
        width: Int,
        height: Int,
        padMilli: Int,
        pixelPad: CGFloat,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {
        let scaleMilli = Int((transform.scale * 1000).rounded())

        if let surface = mediaSource?.surface(for: mediaID, hostTime: hostTime) {

            let maskStyle = ShapeStyle(kind: style.kind, fill: .solid(.white))
            let maskKey = ShapeRasterizer.Key(
                style: maskStyle, pixelWidth: width, pixelHeight: height,
                scaleMilli: scaleMilli, padMilli: padMilli
            )
            let maskTexture: MTLTexture?
            if let index = shapeTextures.index(forKey: maskKey) {
                shapeTextures.values[index].lastUsed = cacheClock
                maskTexture = shapeTextures.values[index].texture
            } else if let made = ShapeRasterizer.makeTexture(
                style: maskStyle, pixelWidth: width, pixelHeight: height,
                pixelPad: pixelPad, scale: transform.scale, device: device
            ) {
                shapeTextures[maskKey] = CachedTexture(texture: made, lastUsed: cacheClock)
                maskTexture = made
            } else {
                maskTexture = nil
            }

            if let maskTexture {
                let contentSize: CGSize = switch surface {
                case .ycbcrBiplanar(let luma, _, _, _):
                    CGSize(width: luma.width, height: luma.height)
                case .bgra(let texture, _, _):
                    CGSize(width: texture.width, height: texture.height)
                }

                let frameRect = transform.pixelRect(item.frame)
                let (quadRect, uvRect) = Self.mediaGeometry(
                    contentSize: contentSize, frame: frameRect, mode: scaleMode,
                    sourceRect: sourceRect
                )
                var uvMap = SIMD4<Float>(0, 0, 0, 0)
                if quadRect.width > 0, quadRect.height > 0 {
                    let ax = snapped.width / quadRect.width * uvRect.width
                    let ay = snapped.height / quadRect.height * uvRect.height
                    let bx = uvRect.minX + (snapped.minX - quadRect.minX) / quadRect.width * uvRect.width
                    let by = uvRect.minY + (snapped.minY - quadRect.minY) / quadRect.height * uvRect.height
                    uvMap = SIMD4(Float(ax), Float(ay), Float(bx), Float(by))
                }

                var uvBounds = SIMD4<Float>(
                    Float(uvRect.minX), Float(uvRect.minY),
                    Float(uvRect.maxX), Float(uvRect.maxY)
                )

                var vertices = Self.quadVertices(
                    pixelRect: snapped, targetSize: targetSize,
                    rotationDegrees: item.rotationDegrees,
                    flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
                )
                encoder.setVertexBytes(
                    &vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0
                )
                switch surface {
                case .ycbcrBiplanar(let luma, let chroma, let colorTransform, _):

                    var uniforms = VideoUniformsGPU(colorTransform, opacity: item.opacity * style.fillOpacity)
                    encoder.setRenderPipelineState(pipeline(.videoYCbCrMasked, item.blendMode))
                    encoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<VideoUniformsGPU>.stride, index: 0
                    )
                    encoder.setFragmentBytes(&uvMap, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    encoder.setFragmentBytes(&uvBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                    encoder.setFragmentTexture(luma, index: 0)
                    encoder.setFragmentTexture(chroma, index: 1)
                    encoder.setFragmentTexture(maskTexture, index: 2)
                case .bgra(let texture, let colorTransform, _):
                    var uniforms = VideoUniformsGPU(colorTransform, opacity: item.opacity * style.fillOpacity)
                    encoder.setRenderPipelineState(pipeline(.videoRGBAMasked, item.blendMode))
                    encoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<VideoUniformsGPU>.stride, index: 0
                    )
                    encoder.setFragmentBytes(&uvMap, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    encoder.setFragmentBytes(&uvBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentTexture(maskTexture, index: 1)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        guard style.stroke != nil || style.shadow != nil else { return }
        var chromeStyle = style
        chromeStyle.fill = .media(id: "", scaleMode: .fill)
        let chromeKey = ShapeRasterizer.Key(
            style: chromeStyle, pixelWidth: width, pixelHeight: height,
            scaleMilli: scaleMilli, padMilli: padMilli
        )
        let chromeTexture: MTLTexture
        if let index = shapeTextures.index(forKey: chromeKey) {
            shapeTextures.values[index].lastUsed = cacheClock
            chromeTexture = shapeTextures.values[index].texture
        } else if let made = ShapeRasterizer.makeChromeTexture(
            style: style, pixelWidth: width, pixelHeight: height,
            pixelPad: pixelPad, scale: transform.scale, device: device
        ) {
            shapeTextures[chromeKey] = CachedTexture(texture: made, lastUsed: cacheClock)
            chromeTexture = made
        } else {
            return
        }

        var vertices = Self.quadVertices(
            pixelRect: snapped, targetSize: targetSize, rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
        )
        var opacity = Float(item.opacity)
        encoder.setRenderPipelineState(pipeline(.textured, item.blendMode))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(chromeTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawText(
        _ text: StyledText,
        item: RenderItem,
        pixelRect: CGRect,
        scale: CGFloat,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {

        if let pathData = text.pathData, !pathData.isEmpty {
            drawPathText(
                text, pathData: pathData, item: item, pixelRect: pixelRect,
                scale: scale, targetSize: targetSize, encoder: encoder, hostTime: hostTime
            )
            return
        }
        let sceneFrameSize = item.frame.size

        let snapped = CGRect(
            x: pixelRect.origin.x.rounded(),
            y: pixelRect.origin.y.rounded(),
            width: pixelRect.width.rounded(),
            height: pixelRect.height.rounded()
        )
        let width = Int(snapped.width)
        let height = Int(snapped.height)
        guard width > 0, height > 0 else { return }

        let fontScale = TextRasterizer.fittedFontScale(for: text, sceneFrame: sceneFrameSize)
        let key = TextRasterizer.Key(
            text: text,
            pixelWidth: width,
            pixelHeight: height,
            scaleMilli: Int((scale * 1000).rounded()),
            fontScaleMilli: Int((fontScale * 1000).rounded())
        )
        let texture: MTLTexture
        if let index = textTextures.index(forKey: key) {
            textTextures.values[index].lastUsed = cacheClock
            texture = textTextures.values[index].texture
        } else if let made = TextRasterizer.makeTexture(
            text: text, pixelWidth: width, pixelHeight: height, scale: scale,
            fontScale: fontScale, device: device
        ) {
            textTextures[key] = CachedTexture(texture: made, lastUsed: cacheClock)
            texture = made
        } else {
            return
        }

        var vertices = Self.quadVertices(
            pixelRect: snapped, targetSize: targetSize, rotationDegrees: item.rotationDegrees,
            flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
        )
        var opacity = Float(item.opacity)
        encoder.setRenderPipelineState(pipeline(.textured, item.blendMode))
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawPathText(
        _ text: StyledText,
        pathData: String,
        item: RenderItem,
        pixelRect: CGRect,
        scale: CGFloat,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {
        guard pixelRect.width > 0, pixelRect.height > 0 else { return }

        let normalized = PathTextStrip.normalizedText(text)
        let key = PathTextStrip.Key(
            text: normalized,
            scaleMilli: Int((scale * 1000).rounded())
        )
        let strip: PathTextStrip.Strip
        if let index = stripTextures.index(forKey: key) {
            stripTextures.values[index].lastUsed = cacheClock
            strip = stripTextures.values[index].strip
        } else if let made = PathTextStrip.make(text: normalized, scale: scale, device: device) {
            stripTextures[key] = CachedStrip(strip: made, lastUsed: cacheClock)
            strip = made
        } else {
            return
        }

        let pathKey = FlatPathKey(
            pathData: pathData, x: pixelRect.minX, y: pixelRect.minY,
            width: pixelRect.width, height: pixelRect.height
        )
        let flat: PathTextLayout.FlatPath
        if let index = flatPaths.index(forKey: pathKey) {
            flatPaths.values[index].lastUsed = cacheClock
            flat = flatPaths.values[index].path
        } else if let cgPath = SVGPathParser.path(from: pathData, in: pixelRect),
                  let made = PathTextLayout.flatten(cgPath) {
            flatPaths[pathKey] = CachedFlatPath(path: made, lastUsed: cacheClock)
            flat = made
        } else {
            return
        }

        let effectiveTime = item.tickerAnchorHostTime.map { hostTime - $0 } ?? hostTime

        let direction: Double = text.tickerLeftToRight ? 1 : -1
        var phasePx = CGFloat(effectiveTime * text.tickerSpeed * direction) * scale

        if text.tickerRepeat > 0, !text.tickerStream,
           item.tickerAnchorHostTime != nil, text.tickerSpeed != 0 {
            let periodPx: CGFloat = flat.isClosed
                ? flat.totalLength
                : flat.totalLength + strip.run.runLengthPx + 2 * strip.run.padXPx
            let limit = CGFloat(text.tickerRepeat) * periodPx
            if abs(phasePx) >= limit {
                if flat.isClosed {
                    phasePx = 0 
                } else {
                    return 
                }
            } else if text.tickerRamp != .none, periodPx > 0 {

                let travelled = abs(phasePx)
                let passIndex = (travelled / periodPx).rounded(.down)
                let inPass = Double((travelled - passIndex * periodPx) / periodPx)
                let eased = passIndex * periodPx + CGFloat(text.tickerRamp.apply(inPass)) * periodPx
                phasePx = phasePx < 0 ? -eased : eased
            }
        }
        let placed = PathTextLayout.place(
            run: strip.run,
            along: flat,
            phasePx: phasePx,
            alignment: text.alignment,
            isScrolling: text.tickerSpeed != 0,
            reversed: text.pathReversed,
            offsetPx: CGFloat(text.pathOffset) * scale,
            stream: text.tickerStream,
            gapPx: CGFloat(text.tickerGap) * scale
        )
        guard !placed.isEmpty else { return }

        var opacity = Float(item.opacity)
        encoder.setRenderPipelineState(pipeline(.textured, item.blendMode))
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.setFragmentTexture(strip.texture, index: 0)

        let chunkSize = 40
        var start = 0
        while start < placed.count {
            let chunk = Array(placed[start..<min(start + chunkSize, placed.count)])
            var vertices = Self.pathGlyphVertices(
                placed: chunk,
                stripHeightPx: CGFloat(strip.run.stripHeightPx),
                baselineFromBottomPx: strip.run.baselineFromBottomPx,
                targetSize: targetSize
            )
            encoder.setVertexBytes(
                &vertices, length: MemoryLayout<SIMD4<Float>>.stride * vertices.count, index: 0
            )
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            start += chunkSize
        }
    }

    private func drawMedia(
        id: String,
        scaleMode: SceneMediaScaleMode,
        sourceRect: SceneSourceRect?,
        item: RenderItem,
        pixelRect: CGRect,
        targetSize: CGSize,
        encoder: MTLRenderCommandEncoder,
        hostTime: CFTimeInterval
    ) {
        guard pixelRect.width > 0, pixelRect.height > 0,
              let surface = mediaSource?.surface(for: id, hostTime: hostTime)
        else { return }

        let contentSize: CGSize = switch surface {
        case .ycbcrBiplanar(let luma, _, _, _):
            CGSize(width: luma.width, height: luma.height)
        case .bgra(let texture, _, _):
            CGSize(width: texture.width, height: texture.height)
        }
        let (quadRect, uvRect) = Self.mediaGeometry(
            contentSize: contentSize, frame: pixelRect, mode: scaleMode,
            sourceRect: sourceRect
        )
        var vertices = Self.quadVertices(
            pixelRect: quadRect,
            targetSize: targetSize,
            rotationDegrees: item.rotationDegrees,
            rotationCenter: CGPoint(x: pixelRect.midX, y: pixelRect.midY),
            uvRect: uvRect,
            flipHorizontal: item.flipHorizontal, flipVertical: item.flipVertical
        )
        encoder.setVertexBytes(&vertices, length: MemoryLayout<SIMD4<Float>>.stride * 6, index: 0)

        switch surface {
        case .ycbcrBiplanar(let luma, let chroma, let transform, _):
            var uniforms = VideoUniformsGPU(transform, opacity: item.opacity)
            encoder.setRenderPipelineState(pipeline(.videoYCbCr, item.blendMode))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniformsGPU>.stride, index: 0)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
        case .bgra(let texture, let transform, _):
            var uniforms = VideoUniformsGPU(transform, opacity: item.opacity)
            encoder.setRenderPipelineState(pipeline(.videoRGBA, item.blendMode))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniformsGPU>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    static func mediaGeometry(
        contentSize: CGSize,
        frame: CGRect,
        mode: SceneMediaScaleMode,
        sourceRect: SceneSourceRect? = nil
    ) -> (quad: CGRect, uv: CGRect) {

        if let source = sourceRect?.cgRect,
           source.width > 0, source.height > 0,
           source != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let cropped = CGSize(
                width: contentSize.width * source.width,
                height: contentSize.height * source.height
            )
            let (quad, uv) = mediaGeometry(contentSize: cropped, frame: frame, mode: mode)
            let mapped = CGRect(
                x: source.minX + uv.minX * source.width,
                y: source.minY + uv.minY * source.height,
                width: uv.width * source.width,
                height: uv.height * source.height
            )
            return (quad, mapped)
        }
        let fullUV = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard contentSize.width > 0, contentSize.height > 0,
              frame.width > 0, frame.height > 0
        else { return (frame, fullUV) }
        let contentAspect = contentSize.width / contentSize.height
        let frameAspect = frame.width / frame.height

        switch mode {
        case .stretch:
            return (frame, fullUV)
        case .fill:
            if contentAspect > frameAspect {
                let visible = frameAspect / contentAspect
                return (frame, CGRect(x: (1 - visible) / 2, y: 0, width: visible, height: 1))
            } else {
                let visible = contentAspect / frameAspect
                return (frame, CGRect(x: 0, y: (1 - visible) / 2, width: 1, height: visible))
            }
        case .fit:
            var quad = frame
            if contentAspect > frameAspect {
                quad.size.height = frame.width / contentAspect
                quad.origin.y += (frame.height - quad.height) / 2
            } else {
                quad.size.width = frame.height * contentAspect
                quad.origin.x += (frame.width - quad.width) / 2
            }
            return (quad, fullUV)
        }
    }

    private static func quadVertices(
        pixelRect: CGRect,
        targetSize: CGSize,
        rotationDegrees: Double = 0,
        rotationCenter: CGPoint? = nil,
        uvRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) -> [SIMD4<Float>] {
        let center = rotationCenter ?? CGPoint(x: pixelRect.midX, y: pixelRect.midY)
        let radians = rotationDegrees * .pi / 180
        let cosR = CGFloat(cos(radians))
        let sinR = CGFloat(sin(radians))
        let uMin = flipHorizontal ? uvRect.maxX : uvRect.minX
        let uMax = flipHorizontal ? uvRect.minX : uvRect.maxX
        let vMin = flipVertical ? uvRect.maxY : uvRect.minY
        let vMax = flipVertical ? uvRect.minY : uvRect.maxY

        func corner(_ x: CGFloat, _ y: CGFloat, _ u: CGFloat, _ v: CGFloat) -> SIMD4<Float> {

            let dx = x - center.x
            let dy = y - center.y
            let rx = center.x + dx * cosR - dy * sinR
            let ry = center.y + dx * sinR + dy * cosR
            return SIMD4(
                Float(rx / targetSize.width) * 2 - 1,
                1 - Float(ry / targetSize.height) * 2,
                Float(u), Float(v)
            )
        }

        let topLeft = corner(pixelRect.minX, pixelRect.minY, uMin, vMin)
        let topRight = corner(pixelRect.maxX, pixelRect.minY, uMax, vMin)
        let bottomLeft = corner(pixelRect.minX, pixelRect.maxY, uMin, vMax)
        let bottomRight = corner(pixelRect.maxX, pixelRect.maxY, uMax, vMax)
        return [topLeft, bottomLeft, bottomRight, topLeft, bottomRight, topRight]
    }

    static func pathGlyphVertices(
        placed: [PathTextLayout.PlacedGlyph],
        stripHeightPx: CGFloat,
        baselineFromBottomPx: CGFloat,
        targetSize: CGSize
    ) -> [SIMD4<Float>] {
        var vertices: [SIMD4<Float>] = []
        vertices.reserveCapacity(placed.count * 6)
        let ascentSide = stripHeightPx - baselineFromBottomPx

        for glyph in placed {
            let tangent = CGVector(dx: cos(glyph.tangentRadians), dy: sin(glyph.tangentRadians))

            let up = CGVector(dx: tangent.dy, dy: -tangent.dx)
            let halfWidth = glyph.tileWidthPx / 2

            func corner(_ along: CGFloat, _ rise: CGFloat, _ u: CGFloat, _ v: CGFloat) -> SIMD4<Float> {
                let x = glyph.center.x + tangent.dx * along + up.dx * rise
                let y = glyph.center.y + tangent.dy * along + up.dy * rise
                return SIMD4(
                    Float(x / targetSize.width) * 2 - 1,
                    1 - Float(y / targetSize.height) * 2,
                    Float(u), Float(v)
                )
            }

            let topLeft = corner(-halfWidth, ascentSide, glyph.uv.minX, glyph.uv.minY)
            let topRight = corner(halfWidth, ascentSide, glyph.uv.maxX, glyph.uv.minY)
            let bottomLeft = corner(-halfWidth, -baselineFromBottomPx, glyph.uv.minX, glyph.uv.maxY)
            let bottomRight = corner(halfWidth, -baselineFromBottomPx, glyph.uv.maxX, glyph.uv.maxY)
            vertices.append(contentsOf: [topLeft, bottomLeft, bottomRight, topLeft, bottomRight, topRight])
        }
        return vertices
    }
}
