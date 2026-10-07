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
        window.onUserClose = { [displayUUID] in onUserClose(displayUUID) }
        window.title = "Output — \(display.name)"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [
            .fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle,
        ]
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.contentView = sceneView
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
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
