import AppKit
import SwiftUI

extension View {

    func onClickOutside(active: Bool, perform action: @escaping () -> Void) -> some View {
        background(ClickOutsideMonitor(active: active, action: action))
    }
}

private struct ClickOutsideMonitor: NSViewRepresentable {
    let active: Bool
    let action: () -> Void

    final class Coordinator {
        var monitor: Any?
        var action: () -> Void = {}
        weak var view: NSView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return event }
                if !isInside(event) { action() }
                return event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isInside(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        sync(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        sync(context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    private func sync(_ coordinator: Coordinator) {
        coordinator.action = action
        if active { coordinator.install() } else { coordinator.remove() }
    }
}
