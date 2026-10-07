import AppKit
import Metal
import QuartzCore
import RenderEngine
import SwiftUI

@MainActor
public final class TexturePreviewNSView: NSView {

    public var textureProvider: (@MainActor () -> MTLTexture?)?

    public var sourceRect: CGRect?

    private let compositor: Compositor
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?

    public init(compositor: Compositor) {
        self.compositor = compositor
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TexturePreviewNSView does not support NSCoder")
    }

    public override func makeBackingLayer() -> CALayer {
        metalLayer.device = compositor.device
        metalLayer.pixelFormat = Compositor.pixelFormat
        metalLayer.colorspace = CGColorSpace(name: Compositor.workingColorSpaceName)
        metalLayer.framebufferOnly = false 
        metalLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return metalLayer
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        guard window != nil else { return }
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
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self

        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

extension TexturePreviewNSView: CAMetalDisplayLinkDelegate {
    public nonisolated func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        nonisolated(unsafe) let drawable = update.drawable
        MainActor.assumeIsolated {
            guard let texture = textureProvider?() else { return }
            compositor.present(texture: texture, into: drawable, sourceRect: sourceRect)
        }
    }
}

public struct PlaceholderScreenPreview: NSViewRepresentable {
    private let screen: PlaceholderScreen
    private let compositor: Compositor

    private let sourceRect: CGRect?

    public init(
        screen: PlaceholderScreen, compositor: Compositor, sourceRect: CGRect? = nil
    ) {
        self.screen = screen
        self.compositor = compositor
        self.sourceRect = sourceRect
    }

    public func makeNSView(context: Context) -> TexturePreviewNSView {
        let view = TexturePreviewNSView(compositor: compositor)
        view.textureProvider = { [weak screen] in screen?.texture }
        view.sourceRect = sourceRect
        return view
    }

    public func updateNSView(_ nsView: TexturePreviewNSView, context: Context) {
        nsView.sourceRect = sourceRect
    }
}
