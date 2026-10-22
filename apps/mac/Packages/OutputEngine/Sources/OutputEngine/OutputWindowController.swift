import AppKit
import RenderEngine

@MainActor
public final class OutputWindowController {
    public let displayUUID: DisplayUUID
    public let sceneView: MetalSceneView
    private let window: OutputWindow

    public var frame: CGRect { window.frame }

    public init(
        display: DisplaySnapshot,
        screen: NSScreen,
        compositor: Compositor,
        sceneProvider: @escaping @Sendable () -> RenderScene,
        onUserClose: @escaping @MainActor (DisplayUUID) -> Void
    ) {
        displayUUID = display.uuid
        sceneView = MetalSceneView(compositor: compositor)
        sceneView.sceneProvider = sceneProvider

        window = OutputWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        let userClose: @MainActor () -> Void = { [displayUUID] in onUserClose(displayUUID) }
        window.onUserClose = userClose
        window.title = "Output — \(display.name)"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [
            .fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle,
        ]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = OutputContentView(sceneView: sceneView, onClose: userClose)
        window.setFrame(screen.frame, display: true)
        if Self.takesKeyFocus(screenCount: NSScreen.screens.count) {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    static func takesKeyFocus(screenCount: Int) -> Bool {
        screenCount <= 1
    }

    public func reframe(to frame: CGRect) {
        window.setFrame(frame, display: true)
    }

    public func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

private final class OutputWindow: NSWindow {
    var onUserClose: (@MainActor () -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { 
            onUserClose?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onUserClose?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

final class OutputContentView: NSView {
    static let hideDelay: TimeInterval = 2

    let closeButton: NSButton
    private let hideDelay: TimeInterval
    private var hideTimer: Timer?

    init(
        sceneView: NSView,
        hideDelay: TimeInterval = OutputContentView.hideDelay,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.hideDelay = hideDelay
        closeButton = OutputCloseButton(onClose: onClose)
        super.init(frame: .zero)
        wantsLayer = true
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.width, .height]
        addSubview(sceneView)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        closeButton.alphaValue = 0
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OutputContentView does not support NSCoder")
    }

    var isCloseButtonShown: Bool { !closeButton.isHidden }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showCloseButton()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideCloseButton()
    }

    func showCloseButton() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideCloseButton() }
        }
        if closeButton.isHidden {
            closeButton.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                closeButton.animator().alphaValue = 1
            }
        }
    }

    func hideCloseButton() {
        hideTimer?.invalidate()
        hideTimer = nil
        if !closeButton.isHidden {
            closeButton.isHidden = true
            closeButton.alphaValue = 0
        }
    }
}

private final class OutputCloseButton: NSButton {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close output")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        contentTintColor = .white
        imagePosition = .imageOnly
        toolTip = "Close output (Esc)"
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 18
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        target = self
        action = #selector(close)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OutputCloseButton does not support NSCoder")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func close() {
        onClose()
    }
}
