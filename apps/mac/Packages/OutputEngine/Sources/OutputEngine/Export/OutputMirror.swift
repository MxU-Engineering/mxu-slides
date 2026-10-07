import Accelerate
import CoreVideo
import Foundation
import Metal
import QuartzCore
import RenderEngine

public final class OutputMirror: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int

    public var framesDelivered: Int { counters.withLock { $0.delivered } }
    public var framesDropped: Int { counters.withLock { $0.dropped } }

    private struct Counters {
        var delivered = 0
        var dropped = 0
    }

    private final class RingSlot: @unchecked Sendable {
        let texture: MTLTexture
        let busy = Locked(false)
        init(texture: MTLTexture) { self.texture = texture }
    }

    private let compositor: Compositor
    private let provider: @Sendable () -> RenderScene
    private let sink: @Sendable (CVPixelBuffer, Double) -> Void

    private let delayFrames: (@Sendable () -> Int)?

    private let adjustments: (@Sendable () -> OutputAdjustments?)?

    private let sourceRect: CGRect?

    private let placement: CGRect?

    private let mask: (@Sendable () -> MTLTexture?)?

    public struct CompositeLayer: @unchecked Sendable {
        public let provider: @Sendable () -> RenderScene
        public let sourceRect: CGRect?
        public let placement: CGRect?
        public let adjustments: (@Sendable () -> OutputAdjustments?)?
        public let mask: (@Sendable () -> MTLTexture?)?

        public init(
            provider: @escaping @Sendable () -> RenderScene,
            sourceRect: CGRect?, placement: CGRect?,
            adjustments: (@Sendable () -> OutputAdjustments?)? = nil,
            mask: (@Sendable () -> MTLTexture?)? = nil
        ) {
            self.provider = provider
            self.sourceRect = sourceRect
            self.placement = placement
            self.adjustments = adjustments
            self.mask = mask
        }
    }

    private let composite: [CompositeLayer]

    private let held = Locked<[CVPixelBuffer]>([])
    private let slots: [RingSlot]
    private let nextSlot = Locked(0)
    private let counters = Locked(Counters())
    private let running = Locked(false)
    private let converter: PixelBufferConverter

    public static let maxDelayFrames = 15
    private let convertQueue = DispatchQueue(
        label: "outputEngine.mirror.convert", qos: .userInitiated)
    private let tickSource = Locked<DispatchSourceTimer?>(nil)

    let liveCadence = Locked<LiveCadence?>(nil)

    private let steeredDeadline = Locked<DispatchTime?>(nil)

    private let lastConverted = Locked<
        (
            scene: RenderScene, adjustments: OutputAdjustments?,
            maskID: ObjectIdentifier?, buffer: CVPixelBuffer
        )?>(nil)

    private let transparentBackground: Bool

    public static let debugNote = Locked<(@Sendable (String) -> Void)?>(nil)
    private let firstTickSeen = Locked(false)
    private var identity: String {
        let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10000)
        return "\(width)×\(height)@\(framesPerSecond)#\(tag)"
    }

    public init?(
        compositor: Compositor,
        width: Int,
        height: Int,
        framesPerSecond: Int = 30,
        color: PixelBufferConverter.Color = .sdr,
        transparentBackground: Bool = false,
        provider: @escaping @Sendable () -> RenderScene,
        delayFrames: (@Sendable () -> Int)? = nil,
        adjustments: (@Sendable () -> OutputAdjustments?)? = nil,
        sourceRect: CGRect? = nil,
        placement: CGRect? = nil,
        mask: (@Sendable () -> MTLTexture?)? = nil,
        composite: [CompositeLayer] = [],
        consumerHeldFrames: Int = 0,
        sink: @escaping @Sendable (CVPixelBuffer, Double) -> Void
    ) {
        guard width > 0, height > 0, framesPerSecond > 0,
              let converter = PixelBufferConverter(
                  width: width, height: height,

                  poolCeiling: (delayFrames == nil ? 8 : 8 + Self.maxDelayFrames)
                      + max(0, consumerHeldFrames),
                  color: color)
        else { return nil }
        self.compositor = compositor
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.transparentBackground = transparentBackground
        self.provider = provider
        self.delayFrames = delayFrames
        self.adjustments = adjustments
        self.sourceRect = sourceRect
        self.placement = placement
        self.mask = mask
        self.composite = composite
        self.sink = sink
        self.converter = converter

        var slots: [RingSlot] = []
        for index in 0..<3 {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Compositor.pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let texture = compositor.device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            texture.label = "outputMirror.slot\(index)"
            slots.append(RingSlot(texture: texture))
        }
        self.slots = slots
    }

    public func start() {
        let alreadyRunning = running.withLock { wasRunning -> Bool in
            defer { wasRunning = true }
            return wasRunning
        }
        guard !alreadyRunning else { return }
        Self.debugNote.value?("mirror \(identity): timer arming")

        let interval = 1.0 / Double(framesPerSecond)
        let source = DispatchSource.makeTimerSource(queue: convertQueue)
        source.schedule(
            deadline: .now() + interval, repeating: interval,
            leeway: .milliseconds(2))
        let identity = identity
        source.setEventHandler { [weak self] in
            guard let self else {
                Self.debugNote.value?("mirror \(identity): fired but DEALLOCATED")
                return
            }
            let fired = DispatchTime.now()
            let now = CACurrentMediaTime()
            self.tick(at: now)

            let step = MirrorCadence.next(
                nominal: interval, now: now, reference: self.liveCadence.value)
            if let step {
                let steered = step.interval
                RenderPulse.shared.mirrorSteered(
                    edgeDistanceMS: step.edgeDistance * 1000, periodMS: step.period * 1000)

                let armed = self.steeredDeadline.value ?? fired
                let next = max(armed + steered, fired + steered / 2)
                self.steeredDeadline.value = next

                self.tickSource.value?.schedule(
                    deadline: next, repeating: interval, leeway: .milliseconds(1))
            } else {
                self.steeredDeadline.value = nil
            }
        }
        source.resume()
        tickSource.value = source
        Self.debugNote.value?("mirror \(identity): timer resumed")
    }

    func startWithoutTimerForTesting() {
        running.value = true
    }

    public func stop() {
        Self.debugNote.value?("mirror \(identity): stopped")
        running.value = false

        lastConverted.value = nil
        held.value = []
        tickSource.withLock { source in
            source?.cancel()
            source = nil
        }
    }

    public func tick(at hostTime: CFTimeInterval) {
        let sawFirst = firstTickSeen.withLock { seen -> Bool in
            defer { seen = true }
            return !seen
        }
        if sawFirst {
            Self.debugNote.value?(
                "mirror \(identity): first tick (running: \(running.value))")
        }
        guard running.value else { return }
        if !composite.isEmpty {
            tickComposite(at: hostTime)
            return
        }
        let scene = provider()
        noteLiveCadence(in: [scene])
        let currentAdjustments = adjustments?()
        let currentMask = mask?()
        let currentMaskID = currentMask.map(ObjectIdentifier.init)

        if !scene.isTimeVarying,
           let last = lastConverted.value, last.scene == scene,
           last.adjustments == currentAdjustments,
           last.maskID == currentMaskID {
            convertQueue.async { [weak self] in
                guard let self, self.running.value else { return }
                self.counters.withLock { $0.delivered += 1 }
                RenderPulse.shared.mirrorResend()
                self.deliver(last.buffer, at: hostTime)
            }
            return
        }

        let claimed: RingSlot? = {
            let start = nextSlot.value
            for offset in 0..<slots.count {
                let slot = slots[(start + offset) % slots.count]
                let wasBusy = slot.busy.withLock { busy -> Bool in
                    defer { busy = true }
                    return busy
                }
                if !wasBusy {
                    nextSlot.value = (start + offset + 1) % slots.count
                    return slot
                }
            }
            return nil
        }()
        guard let slot = claimed else {
            counters.withLock { $0.dropped += 1 }
            RenderPulse.shared.mirrorDrop()
            return
        }

        compositor.render(
            scene: scene, into: slot.texture, at: hostTime,
            transparentBackground: transparentBackground,
            adjustments: currentAdjustments,
            sourceRect: sourceRect,
            placement: placement,
            mask: currentMask
        ) {
            [weak self] in
            guard let self else {
                slot.busy.value = false
                return
            }
            self.convertQueue.async {
                defer { slot.busy.value = false }
                guard self.running.value,
                      let pixelBuffer = self.converter.convert(texture: slot.texture)
                else {
                    self.counters.withLock { $0.dropped += 1 }
                    RenderPulse.shared.mirrorDrop()
                    return
                }
                self.lastConverted.value = (
                    scene, currentAdjustments, currentMaskID, pixelBuffer
                )
                self.counters.withLock { $0.delivered += 1 }
                self.deliver(pixelBuffer, at: hostTime)
            }
        }
    }

    private func tickComposite(at hostTime: CFTimeInterval) {
        let claimed: RingSlot? = {
            let start = nextSlot.value
            for offset in 0..<slots.count {
                let slot = slots[(start + offset) % slots.count]
                let wasBusy = slot.busy.withLock { busy -> Bool in
                    defer { busy = true }
                    return busy
                }
                if !wasBusy {
                    nextSlot.value = (start + offset + 1) % slots.count
                    return slot
                }
            }
            return nil
        }()
        guard let slot = claimed else {
            counters.withLock { $0.dropped += 1 }
            RenderPulse.shared.mirrorDrop()
            return
        }
        noteLiveCadence(in: composite.map { $0.provider() })
        let layers = composite.map { layer in
            Compositor.OutputCompositeLayer(
                scene: layer.provider(),
                sourceRect: layer.sourceRect,
                placement: layer.placement,
                adjustments: layer.adjustments?(),
                mask: layer.mask?()
            )
        }
        compositor.render(composite: layers, into: slot.texture, at: hostTime) {
            [weak self] in
            guard let self else {
                slot.busy.value = false
                return
            }
            self.convertQueue.async {
                defer { slot.busy.value = false }
                guard self.running.value,
                      let pixelBuffer = self.converter.convert(texture: slot.texture)
                else {
                    self.counters.withLock { $0.dropped += 1 }
                    RenderPulse.shared.mirrorDrop()
                    return
                }
                self.counters.withLock { $0.delivered += 1 }
                self.deliver(pixelBuffer, at: hostTime)
            }
        }
    }

    private func noteLiveCadence(in scenes: [RenderScene]) {
        let source = compositor.mediaSource
        liveCadence.value = scenes.lazy
            .flatMap(\.visibleMediaIDs)
            .compactMap { source?.liveCadence(for: $0) }
            .first
    }

    private func deliver(_ buffer: CVPixelBuffer, at hostTime: Double) {
        let delay = max(0, min(delayFrames?() ?? 0, Self.maxDelayFrames))
        let outgoing: CVPixelBuffer? = held.withLock { queue in
            if delay == 0, queue.isEmpty { return buffer }
            queue.append(buffer)

            if queue.count > delay + 1 {
                queue.removeFirst(queue.count - (delay + 1))
            }
            return queue.count > delay ? queue.removeFirst() : nil
        }
        if let outgoing { sink(outgoing, hostTime) }
    }
}

public final class PixelBufferConverter: @unchecked Sendable {
    public enum Color: Sendable, Equatable {

        case sdr

        case hlg2020
    }

    enum HLG {
        static let a: Float = 0.17883277
        static let b: Float = 0.28466892
        static let c: Float = 0.55991073

        static let sdrWhiteScale: Float = 0.264945
    }

    private let width: Int
    private let height: Int
    private let color: Color
    private let pool: CVPixelBufferPool
    private let poolCeiling: Int
    private let converter: vImageConverter
    private let sourceBytesPerRow: Int
    private var scratch: Data

    private var hlgFloatScratch: Data
    private var hlgWideScratch: Data

    init?(width: Int, height: Int, poolCeiling: Int = 8, color: Color = .sdr) {
        self.width = width
        self.height = height
        self.color = color
        self.poolCeiling = poolCeiling
        self.sourceBytesPerRow = width * 4 * MemoryLayout<UInt16>.size
        self.scratch = Data(count: sourceBytesPerRow * height)
        self.hlgFloatScratch = color == .hlg2020
            ? Data(count: width * height * 4 * MemoryLayout<Float>.size) : Data()
        self.hlgWideScratch = color == .hlg2020
            ? Data(count: width * height * 4 * MemoryLayout<UInt16>.size) : Data()

        let pixelFormat: OSType = switch color {
        case .sdr: kCVPixelFormatType_32BGRA
        case .hlg2020: kCVPixelFormatType_ARGB2101010LEPacked
        }
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, poolAttributes as CFDictionary, &pool) == kCVReturnSuccess,
            let pool
        else { return nil }
        self.pool = pool

        let destinationFormat: vImage_CGImageFormat?
        switch color {
        case .sdr:
            destinationFormat = CGColorSpace(name: CGColorSpace.displayP3).flatMap {
                vImage_CGImageFormat(
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    colorSpace: $0,
                    bitmapInfo: CGBitmapInfo(rawValue:
                        CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue))
            }
        case .hlg2020:

            destinationFormat = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020).flatMap {
                vImage_CGImageFormat(
                    bitsPerComponent: 32,
                    bitsPerPixel: 128,
                    colorSpace: $0,
                    bitmapInfo: CGBitmapInfo(rawValue:
                        CGBitmapInfo.floatComponents.rawValue
                            | CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue))
            }
        }

        guard
            let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
            let sourceFormat = vImage_CGImageFormat(
                bitsPerComponent: 16,
                bitsPerPixel: 64,
                colorSpace: workingSpace,
                bitmapInfo: CGBitmapInfo(rawValue:
                    CGBitmapInfo.floatComponents.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue)
            ),
            let destinationFormat,
            let converter = try? vImageConverter.make(
                sourceFormat: sourceFormat, destinationFormat: destinationFormat)
        else { return nil }
        self.converter = converter
    }

    func convert(texture: MTLTexture) -> CVPixelBuffer? {
        guard texture.width == width, texture.height == height else { return nil }
        var pixelBuffer: CVPixelBuffer?

        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: poolCeiling
        ]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxiliary as CFDictionary,
            &pixelBuffer) == kCVReturnSuccess,
            let pixelBuffer
        else { return nil }

        var readbackMS = 0.0
        var convertMS = 0.0
        let converted: Bool = scratch.withUnsafeMutableBytes { source in
            guard let sourceBase = source.baseAddress else { return false }
            let readbackStart = CACurrentMediaTime()
            texture.getBytes(
                sourceBase,
                bytesPerRow: sourceBytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
            readbackMS = (CACurrentMediaTime() - readbackStart) * 1000
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let destinationBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                return false
            }
            let sourceBuffer = vImage_Buffer(
                data: sourceBase,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: sourceBytesPerRow
            )
            var destinationBuffer = vImage_Buffer(
                data: destinationBase,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
            )
            let convertStart = CACurrentMediaTime()
            let ok: Bool
            switch color {
            case .sdr:
                ok = (try? converter.convert(
                    source: sourceBuffer, destination: &destinationBuffer)) != nil
            case .hlg2020:
                ok = self.convertHLG(
                    source: sourceBuffer, destination: &destinationBuffer)
            }
            convertMS = (CACurrentMediaTime() - convertStart) * 1000
            return ok
        }
        guard converted else { return nil }
        RenderPulse.shared.mirrorFrame(readbackMS: readbackMS, convertMS: convertMS)

        switch color {
        case .sdr:
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        case .hlg2020:
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(
                pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        }
        return pixelBuffer
    }

    private func convertHLG(
        source: vImage_Buffer, destination: inout vImage_Buffer
    ) -> Bool {
        let count = width * height * 4
        return hlgFloatScratch.withUnsafeMutableBytes { floats in
            hlgWideScratch.withUnsafeMutableBytes { wide in
                guard let floatBase = floats.baseAddress,
                      let wideBase = wide.baseAddress else { return false }
                var floatBuffer = vImage_Buffer(
                    data: floatBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4 * MemoryLayout<Float>.size)
                guard (try? converter.convert(
                    source: source, destination: &floatBuffer)) != nil else { return false }

                let values = floatBase.assumingMemoryBound(to: Float.self)
                var n = Int32(count)

                var scale = HLG.sdrWhiteScale
                vDSP_vsmul(values, 1, &scale, values, 1, vDSP_Length(count))
                var floor: Float = 0
                var ceil: Float = 1
                vDSP_vclip(values, 1, &floor, &ceil, values, 1, vDSP_Length(count))

                var low = [Float](repeating: 0, count: count)
                var high = [Float](repeating: 0, count: count)
                var three: Float = 3
                vDSP_vsmul(values, 1, &three, &low, 1, vDSP_Length(count))
                low.withUnsafeMutableBufferPointer { pointer in
                    vvsqrtf(pointer.baseAddress!, pointer.baseAddress!, &n)
                }
                var twelve: Float = 12
                var minusB = -HLG.b
                vDSP_vsmsa(values, 1, &twelve, &minusB, &high, 1, vDSP_Length(count))
                var logFloor: Float = 1e-6
                var logCeil = Float.greatestFiniteMagnitude
                vDSP_vclip(high, 1, &logFloor, &logCeil, &high, 1, vDSP_Length(count))
                high.withUnsafeMutableBufferPointer { pointer in
                    vvlogf(pointer.baseAddress!, pointer.baseAddress!, &n)
                }
                var a = HLG.a
                var c = HLG.c
                vDSP_vsmsa(high, 1, &a, &c, &high, 1, vDSP_Length(count))

                var kneeScale: Float = 1e6
                var minusKnee: Float = -1.0 / 12.0 * 1e6
                vDSP_vsmsa(values, 1, &kneeScale, &minusKnee, values, 1, vDSP_Length(count))
                vDSP_vclip(values, 1, &floor, &ceil, values, 1, vDSP_Length(count))
                vDSP_vsub(low, 1, high, 1, &high, 1, vDSP_Length(count))  
                vDSP_vma(values, 1, high, 1, low, 1, values, 1, vDSP_Length(count))

                var wideBuffer = vImage_Buffer(
                    data: wideBase,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width * 4 * MemoryLayout<UInt16>.size)
                var flatFloat = vImage_Buffer(
                    data: floatBase,
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<Float>.size)
                var flatWide = vImage_Buffer(
                    data: wideBase,
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * MemoryLayout<UInt16>.size)
                guard vImageConvert_FTo16U(
                    &flatFloat, &flatWide, 0, 1.0 / 65535.0,
                    vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
                let permuteRGBAtoARGB: [UInt8] = [3, 0, 1, 2]
                return vImageConvert_ARGB16UToARGB2101010(
                    &wideBuffer, &destination, 0, 1023,
                    permuteRGBAtoARGB, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
    }
}
