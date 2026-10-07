import AppKit
import PresenterCore
import SwiftUI

extension View {

    func consoleScrolling() -> some View {
        background(ConsoleScrollingHost())
    }
}

enum ConsoleScrolling {

    static var scrollerHeight: CGFloat {
        GrabbableScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
    }
}

final class GrabbableScroller: NSScroller {
    static let reach = CGFloat(MixerStripLayout.grabBarReach)

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle) + 2 * reach
    }

    private var barRect: NSRect {
        bounds.insetBy(dx: 0, dy: Self.reach)
    }

    override func rect(for partCode: NSScroller.Part) -> NSRect {
        let rect = super.rect(for: partCode)
        guard partCode == .knob || partCode == .knobSlot else { return rect }
        return NSRect(x: rect.minX, y: barRect.minY, width: rect.width, height: barRect.height)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        super.drawKnobSlot(in: rect(for: .knobSlot), highlight: flag)
    }

    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        var local = convert(point, from: nil)
        local.y = MixerStripLayout.grabBarY(
            local.y, barMinY: barRect.minY, barMaxY: barRect.maxY)
        return super.testPart(convert(local, to: nil))
    }
}

private struct ConsoleScrollingHost: NSViewRepresentable {
    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func showScroller() {
            guard let scrollView = view?.enclosingScrollView else { return }
            if !(scrollView.horizontalScroller is GrabbableScroller) {
                let scroller = GrabbableScroller()
                scroller.controlSize = .small
                scrollView.horizontalScroller = scroller
            }
            scrollView.hasHorizontalScroller = true
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return steer(event) ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func steer(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window,
                  let scrollView = view.enclosingScrollView,
                  let document = scrollView.documentView
            else { return false }
            let clip = scrollView.contentView
            let location = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(location) else { return false }
            guard let travel = SidewaysWheelLogic.sidewaysTravel(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                contentWidth: document.frame.width,
                visibleWidth: clip.bounds.width)
            else { return false }
            var origin = clip.bounds.origin
            origin.x = SidewaysWheelLogic.clampedOrigin(
                current: origin.x,
                travel: travel,
                contentWidth: document.frame.width,
                visibleWidth: clip.bounds.width)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        DispatchQueue.main.async { context.coordinator.showScroller() }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        DispatchQueue.main.async { context.coordinator.showScroller() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }
}
