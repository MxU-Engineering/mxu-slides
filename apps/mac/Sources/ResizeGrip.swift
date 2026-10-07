import AppKit
import SwiftUI

struct ResizeGripArea: NSViewRepresentable {
    let hovering: (Bool) -> Void
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> ResizeGripView {
        let view = ResizeGripView()
        sync(view)
        return view
    }

    func updateNSView(_ nsView: ResizeGripView, context: Context) {
        sync(nsView)
    }

    private func sync(_ view: ResizeGripView) {
        view.hovering = hovering
        view.changed = changed
        view.ended = ended
    }
}

final class ResizeGripView: NSView {

    private static let live = NSHashTable<ResizeGripView>.weakObjects()

    static func covers(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        live.allObjects.contains { grip in
            grip.window === window && !grip.isHiddenOrHasHiddenAncestor
                && grip.bounds.contains(grip.convert(windowPoint, from: nil))
        }
    }

    var hovering: (Bool) -> Void = { _ in }
    var changed: (CGFloat) -> Void = { _ in }
    var ended: () -> Void = {}

    private var pressX: CGFloat?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.live.add(self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        if pressX == nil { hovering(false) }
    }

    override func mouseDown(with event: NSEvent) {
        pressX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        if let pressX {

            NSCursor.resizeLeftRight.set()
            changed(event.locationInWindow.x - pressX)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let pressX {

            changed(event.locationInWindow.x - pressX)
            self.pressX = nil
            ended()
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { hovering(false) }
        }
    }
}
