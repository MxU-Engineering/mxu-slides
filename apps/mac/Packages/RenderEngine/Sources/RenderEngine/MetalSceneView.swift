import AppKit
import Metal
import QuartzCore

@MainActor
public final class MetalSceneView: NSView {

    public var sceneProvider: (@Sendable () -> RenderScene)? {
        get { providerBox.value }
        set { providerBox.value = newValue }
    }

    public var outputAdjustments: OutputAdjustments? {
        get { adjustmentsBox.value }
        set { adjustmentsBox.value = newValue }
    }

    public var outputMask: MTLTexture? {
        get { maskBox.value }
        set { maskBox.value = newValue }
    }

    public var outputSourceRect: CGRect? {
        get { sourceRectBox.value }
        set { sourceRectBox.value = newValue }
    }

    public var outputPlacement: CGRect? {
        get { placementBox.value }
        set { placementBox.value = newValue }
    }

    public struct CompositeSource: @unchecked Sendable {
        public let provider: @Sendable () -> RenderScene
        public let sourceRect: CGRect?
        public let placement: CGRect?
        public let adjustments: OutputAdjustments?
        public let mask: MTLTexture?

        public init(
            provider: @escaping @Sendable () -> RenderScene,
            sourceRect: CGRect?, placement: CGRect?,
            adjustments: OutputAdjustments?, mask: MTLTexture?
        ) {
            self.provider = provider
            self.sourceRect = sourceRect
            self.placement = placement
            self.adjustments = adjustments
            self.mask = mask
        }
    }

    public var compositeSources: [CompositeSource]? {
        get { compositeBox.value }
        set { compositeBox.value = newValue }
    }

    public var videoDelayFrames: Int {
        get { delayBox.value }
        set { delayBox.value = max(0, newValue) }
    }

    public var sceneInset: CGFloat = 0 {
        didSet {
            if sceneInset != oldValue { updateDrawableGeometry() }
        }
    }

    public var tickCount: Int { tickState.value.tickCount }
    public var missedTickCount: Int { tickState.value.missedTickCount }

    private struct TickState {
        var tickCount = 0
        var missedTickCount = 0
        var lastTargetTimestamp: CFTimeInterval?
        var shortestTickInterval: CFTimeInterval = .infinity

        mutating func record(targetTimestamp: CFTimeInterval) {
            tickCount += 1
            if let last = lastTargetTimestamp {
                let delta = targetTimestamp - last

                if delta > 0 { shortestTickInterval = min(shortestTickInterval, delta) }
                if delta > shortestTickInterval * 1.75 { missedTickCount += 1 }
            }
            lastTargetTimestamp = targetTimestamp
        }
    }

    private let providerBox = Locked<(@Sendable () -> RenderScene)?>(nil)
    private let tickState = Locked(TickState())
    private let adjustmentsBox = Locked<OutputAdjustments?>(nil)
    private let maskBox = Locked<MTLTexture?>(nil)
    private let sourceRectBox = Locked<CGRect?>(nil)
    private let placementBox = Locked<CGRect?>(nil)
    private let compositeBox = Locked<[CompositeSource]?>(nil)
    private let delayBox = Locked(0)

    private let insetPixelsBox = Locked<CGFloat>(0)

    private final class DelayRing {
        var textures: [MTLTexture] = []
        var writeIndex = 0
        var written = 0
    }
    private let delayRingBox = Locked<DelayRing?>(nil)

    private let compositor: Compositor

    private let transparentBackground: Bool
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?

    public init(compositor: Compositor, transparentBackground: Bool = false) {
        self.compositor = compositor
        self.transparentBackground = transparentBackground
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MetalSceneView does not support NSCoder")
    }

    public override func makeBackingLayer() -> CALayer {
        metalLayer.device = compositor.device
        metalLayer.pixelFormat = Compositor.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: Compositor.workingColorSpaceName)
        metalLayer.framebufferOnly = false 
        metalLayer.isOpaque = !transparentBackground
        metalLayer.backgroundColor = transparentBackground
            ? CGColor(gray: 0, alpha: 0)
            : CGColor(gray: 0, alpha: 1)
        return metalLayer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        updateDrawableGeometry()
        startDisplayLink()
    }

    public override func layout() {
        super.layout()
        updateDrawableGeometry()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableGeometry()
    }

    @objc private func windowDidChangeScreen(_ notification: Notification) {

        updateDrawableGeometry()
    }

    private func updateDrawableGeometry() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        insetPixelsBox.value = sceneInset * scale
        updateFrameRatePacing()
    }

    private func updateFrameRatePacing() {
        guard let displayLink else { return }
        let maxFPS = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(30, maxFPS),
            maximum: maxFPS,
            preferred: maxFPS
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        displayLink = link
        updateFrameRatePacing()

        nonisolated(unsafe) let movingLink = link
        RenderThread.shared.perform {
            movingLink.add(to: RunLoop.current, forMode: .common)
        }
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        displayLink = nil

        nonisolated(unsafe) let movingLink = link
        RenderThread.shared.perform {
            movingLink.invalidate()
        }
    }
}

extension MetalSceneView: CAMetalDisplayLinkDelegate {
    public nonisolated func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {

        let targetTimestamp = update.targetTimestamp
        tickState.withLock { $0.record(targetTimestamp: targetTimestamp) }
        if let sources = compositeBox.value, !sources.isEmpty {

            compositor.render(
                composite: sources.map { source in
                    Compositor.OutputCompositeLayer(
                        scene: source.provider(),
                        sourceRect: source.sourceRect,
                        placement: source.placement,
                        adjustments: source.adjustments,
                        mask: source.mask
                    )
                },
                into: update.drawable, at: targetTimestamp
            )
            return
        }
        guard let provider = providerBox.value else { return }
        let delay = delayBox.value
        guard delay > 0 else {
            delayRingBox.value = nil
            compositor.render(
                scene: provider(), into: update.drawable, at: targetTimestamp,
                transparentBackground: transparentBackground,
                adjustments: adjustmentsBox.value, sourceRect: sourceRectBox.value,
                placement: placementBox.value, mask: maskBox.value,
                inset: insetPixelsBox.value
            )
            return
        }

        let target = update.drawable.texture
        let ring: DelayRing? = delayRingBox.withLock { box in
            let wanted = delay + 1
            if let existing = box, existing.textures.count == wanted,
               existing.textures.first?.width == target.width,
               existing.textures.first?.height == target.height {
                return existing
            }
            let fresh = DelayRing()
            for index in 0 ..< wanted {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: Compositor.pixelFormat,
                    width: target.width, height: target.height, mipmapped: false
                )
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let texture = compositor.device.makeTexture(descriptor: descriptor)
                else { return nil }
                texture.label = "sceneView.delay\(index)"
                fresh.textures.append(texture)
            }
            box = fresh
            return fresh
        }
        guard let ring else {
            compositor.render(
                scene: provider(), into: update.drawable, at: targetTimestamp,
                transparentBackground: transparentBackground,
                adjustments: adjustmentsBox.value, sourceRect: sourceRectBox.value,
                placement: placementBox.value, mask: maskBox.value
            )
            return
        }
        let write = ring.writeIndex
        compositor.render(
            scene: provider(), into: ring.textures[write], at: targetTimestamp,
            adjustments: adjustmentsBox.value, sourceRect: sourceRectBox.value,
            placement: placementBox.value, mask: maskBox.value
        )
        ring.written += 1
        ring.writeIndex = (write + 1) % ring.textures.count
        let read = ring.written > delay ? ring.writeIndex : write
        compositor.present(texture: ring.textures[read], into: update.drawable)
    }
}
