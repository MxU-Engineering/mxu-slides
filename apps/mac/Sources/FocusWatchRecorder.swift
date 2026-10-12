import AppKit
import Foundation
import PresenterCore

@MainActor
final class FocusWatchRecorder {
    static let shared = FocusWatchRecorder()

    private static let noteInterval: TimeInterval = 2

    private var clickMonitor: Any?
    private var lastNote: TimeInterval = -.infinity

    private init() {}

    func activate() {
        if clickMonitor == nil {
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { notification in
                let window = notification.object as? NSWindow
                MainActor.assumeIsolated {
                    let name = window.map(SheetWatchRecorder.hostName(of:)) ?? "-"
                    FocusWatchRecorder.shared.resigned(name)
                }
            }
            for (name, state) in [
                (NSApplication.didBecomeActiveNotification, "active"),
                (NSApplication.didResignActiveNotification, "inactive"),
            ] {
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        DiagnosticsStore.shared.note("focus.app", detail: "\(state); \(InputTrailRecorder.shared.cause())")
                    }
                }
            }

            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                MainActor.assumeIsolated { FocusWatchRecorder.shared.clicked(event) }
                return event
            }
        }
    }

    private func resigned(_ name: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if NSApp.isActive && NSApp.keyWindow == nil {
                    DiagnosticsStore.shared.note(
                        "focus.lost",
                        detail: "\(name) gave up key and no window took it; windows: \(Self.windowsSummary()); "
                            + InputTrailRecorder.shared.cause())
                }
            }
        }
    }

    private func clicked(_ event: NSEvent) {
        if let target = event.window {
            let name = SheetWatchRecorder.hostName(of: target)
            let click = FocusWatch.Click(
                appActive: NSApp.isActive, hasKeyWindow: NSApp.keyWindow != nil,
                targetIsMain: target.identifier?.rawValue.hasPrefix("main") == true,
                targetCanBecomeKey: target.canBecomeKey,
                targetBlocked: target.attachedSheet != nil || NSApp.modalWindow.map { $0 !== target } == true,
                command: event.modifierFlags.contains(.command))
            if click.rescuesBeforeClick {
                noteLimited("focus.rescued", "made \(name) key before the click; \(click.summary); windows: \(Self.windowsSummary())")
                target.makeKey()
            }

            let number = target.windowNumber
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    if click.isStuck(hasKeyWindowAfter: NSApp.keyWindow != nil),
                       let window = NSApp.window(withWindowNumber: number), window.isVisible {
                        FocusWatchRecorder.shared.unstick(window, name: name, click: click)
                    }
                }
            }
        }
    }

    private func unstick(_ window: NSWindow, name: String, click: FocusWatch.Click) {
        noteLimited(
            "focus.stuck",
            "a click on \(name) left no key window (before it: \(click.summary)); activating; windows: \(Self.windowsSummary())")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DiagnosticsStore.shared.note(
                    "focus.unstuck",
                    detail: NSApp.keyWindow === window
                        ? "\(name) is key again"
                        : "still not key (\(NSApp.isActive ? "app active" : "app inactive"), key: \(NSApp.keyWindow.map(SheetWatchRecorder.hostName(of:)) ?? "none"))")
            }
        }
    }

    private func noteLimited(_ name: String, _ detail: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastNote >= Self.noteInterval {
            lastNote = now
            DiagnosticsStore.shared.note(name, detail: "\(detail); \(InputTrailRecorder.shared.cause())")
        }
    }

    private static func windowsSummary() -> String {
        NSApp.windows.filter(\.isVisible).prefix(8).map { window in
            SheetWatchRecorder.hostName(of: window)
                + (window.canBecomeKey ? "" : " (can't take key)")
                + (window.isMainWindow ? " (main)" : "")
                + (window.alphaValue < 1 ? String(format: " (alpha %.2f)", window.alphaValue) : "")
        }.joined(separator: ", ")
    }
}
