import AppKit
import SwiftUI

extension View {

    func listMarquee(
        active: Bool, rowFrames: [CGRect],
        began: @escaping (NSEvent.ModifierFlags) -> Void,
        changed: @escaping (CGRect) -> Void,
        ended: @escaping () -> Void,
        pressedRow: @escaping (CGPoint, NSEvent.ModifierFlags) -> (() -> Void)? = { _, _ in nil }
    ) -> some View {
        background {
            GeometryReader { proxy in
                ListMarqueeMonitor(
                    active: active, origin: proxy.frame(in: .global).origin,
                    rowFrames: rowFrames,
                    began: began, changed: changed, ended: ended, pressedRow: pressedRow)
            }
        }
    }

    func reportingGlobalFrame(id: String, into frames: Binding<[String: CGRect]>) -> some View {
        background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { if frames.wrappedValue[id] != frame { frames.wrappedValue[id] = frame } }
                    .onChange(of: frame) { _, frame in
                        if frames.wrappedValue[id] != frame { frames.wrappedValue[id] = frame }
                    }
                    .onDisappear { frames.wrappedValue.removeValue(forKey: id) }
            }
        }
    }
}

struct ListMarqueeBand: View {
    let rect: CGRect?

    var body: some View {
        if let rect {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1)
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct ListMarqueeMonitor: NSViewRepresentable {
    let active: Bool

    let origin: CGPoint
    let rowFrames: [CGRect]
    let began: (NSEvent.ModifierFlags) -> Void
    let changed: (CGRect) -> Void
    let ended: () -> Void

    let pressedRow: (CGPoint, NSEvent.ModifierFlags) -> (() -> Void)?

    static let clickSlop: CGFloat = 4

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        var monitor: Any?
        var active = false
        var origin = CGPoint.zero
        var rowFrames: [CGRect] = []
        var began: (NSEvent.ModifierFlags) -> Void = { _ in }
        var changed: (CGRect) -> Void = { _ in }
        var ended: () -> Void = {}
        var pressedRow: (CGPoint, NSEvent.ModifierFlags) -> (() -> Void)? = { _, _ in nil }
        weak var view: FlippedView?

        private var start: CGPoint?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handle(event)
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            start = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:

                guard let view, let window = view.window, event.window === window,
                      !ResizeGripView.covers(event.locationInWindow, in: window)
                else { return event }
                let local = view.convert(event.locationInWindow, from: nil)
                let point = local.applying(.init(translationX: origin.x, y: origin.y))
                guard view.bounds.contains(local) else { return event }
                if rowFrames.contains(where: { $0.contains(point) }) {
                    if let click = pressedRow(point, event.modifierFlags) {
                        runIfClick(click, pressedAt: NSEvent.mouseLocation)
                    }
                    return event
                } else if active {
                    start = point
                    focusList(under: event, in: window)
                    began(event.modifierFlags)
                    return nil
                } else {
                    return event
                }
            case .leftMouseDragged:
                guard let start, let view else { return event }
                let raw = view.convert(event.locationInWindow, from: nil)

                let point = CGPoint(
                    x: min(max(raw.x, 0), view.bounds.width) + origin.x,
                    y: min(max(raw.y, 0), view.bounds.height) + origin.y)
                changed(CGRect(
                    x: min(start.x, point.x), y: min(start.y, point.y),
                    width: abs(point.x - start.x), height: abs(point.y - start.y)))
                return nil
            case .leftMouseUp:
                guard start != nil else { return event }
                start = nil
                ended()
                return nil
            default:
                return event
            }
        }

        private func runIfClick(_ click: @escaping () -> Void, pressedAt: NSPoint) {
            nonisolated(unsafe) let click = click
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    let now = NSEvent.mouseLocation
                    if hypot(now.x - pressedAt.x, now.y - pressedAt.y) <= ListMarqueeMonitor.clickSlop {
                        click()
                    }
                }
            }
        }

        private func focusList(under event: NSEvent, in window: NSWindow) {
            var target = window.contentView?.hitTest(event.locationInWindow)
            while let candidate = target, !candidate.acceptsFirstResponder {
                target = candidate.superview
            }
            if let target, window.firstResponder !== target {
                window.makeFirstResponder(target)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: FlippedView, context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func makeNSView(context: Context) -> FlippedView {
        let view = FlippedView()
        context.coordinator.view = view
        sync(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: FlippedView, context: Context) {
        context.coordinator.view = nsView
        sync(context.coordinator)
    }

    static func dismantleNSView(_ nsView: FlippedView, coordinator: Coordinator) {
        coordinator.remove()
    }

    private func sync(_ coordinator: Coordinator) {
        coordinator.active = active
        coordinator.origin = origin
        coordinator.rowFrames = rowFrames
        coordinator.began = began
        coordinator.changed = changed
        coordinator.ended = ended
        coordinator.pressedRow = pressedRow

        coordinator.install()
    }
}
