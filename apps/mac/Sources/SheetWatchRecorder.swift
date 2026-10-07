import AppKit
import Foundation
import PresenterCore

@MainActor
final class SheetWatchRecorder {
    static let shared = SheetWatchRecorder()

    private static let blockedNoteInterval: TimeInterval = 2

    private var watch = SheetWatch()

    private var windows: [String: (blocker: NSWindow, host: NSWindow?)] = [:]
    private var timer: Timer?
    private var clickMonitor: Any?
    private var lastBlockedNote: TimeInterval = -.infinity

    private var revealed: Set<String> = []

    private init() {}

    func activate() {
        if timer == nil {

            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { SheetWatchRecorder.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer

            for name in [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { SheetWatchRecorder.shared.tickSoon() }
                }
            }

            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                MainActor.assumeIsolated { SheetWatchRecorder.shared.clicked(event) }
                return event
            }
            scheduleSyntheticGhostSheet()
        }
    }

    private func scheduleSyntheticGhostSheet() {
        if let raw = ProcessInfo.processInfo.environment["MXU_SYNTHETIC_GHOST_SHEET_S"],
           let seconds = Double(raw), seconds > 0
        {
            DiagnosticsStore.shared.note("sheet.syntheticGhost", detail: String(format: "in %.0f s", seconds))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    let host = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true } ?? NSApp.mainWindow
                    if let host {

                        if let sheet = host.attachedSheet {
                            sheet.alphaValue = 0
                        } else {
                            let ghost = NSWindow(
                                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
                            ghost.title = "Synthetic Ghost Sheet"
                            host.beginSheet(ghost)
                            ghost.orderOut(nil)
                        }
                        for delay in [1.0, 3.5] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                MainActor.assumeIsolated { Self.postClick(on: host) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func postClick(on window: NSWindow) {
        let center = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private func tickSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { SheetWatchRecorder.shared.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var found: [SheetWatch.Blocker] = []
        var seen: [String: (blocker: NSWindow, host: NSWindow?)] = [:]
        for host in NSApp.windows {
            if let sheet = host.attachedSheet {
                let id = "sheet-\(sheet.windowNumber)"
                found.append(SheetWatch.Blocker(
                    id: id, name: "sheet \(Self.name(of: sheet)) on \(Self.hostName(of: host))", look: Self.look(of: sheet, host: host)))
                seen[id] = (sheet, host)
            }
        }
        if let modal = NSApp.modalWindow {
            let id = "modal-\(modal.windowNumber)"
            found.append(SheetWatch.Blocker(id: id, name: "modal \(Self.name(of: modal))", look: Self.look(of: modal)))
            seen[id] = (modal, nil)
        }
        windows = seen
        let changes = watch.observe(found, at: now)
        for blocker in changes.began {
            DiagnosticsStore.shared.note(
                "sheet.begin", detail: "\(blocker.name): \(blocker.look.summary); \(InputTrailRecorder.shared.cause())")
        }
        for blocker in changes.hid {
            DiagnosticsStore.shared.note("sheet.hidden", detail: "\(blocker.name): \(blocker.look.summary)")
        }
        for blocker in changes.shown {
            DiagnosticsStore.shared.note("sheet.shown", detail: "\(blocker.name): \(blocker.look.summary)")
        }
        for name in changes.ended {
            DiagnosticsStore.shared.note("sheet.end", detail: name)
        }
        revealed = revealed.intersection(seen.keys)
    }

    private func clicked(_ event: NSEvent) {
        tick()
        let target = event.window
        let modalID = NSApp.modalWindow.map { "modal-\($0.windowNumber)" }
        let blockerID: String? = if let modalID, let target, target !== NSApp.modalWindow {
            modalID
        } else if let sheet = target?.attachedSheet {
            "sheet-\(sheet.windowNumber)"
        } else {
            nil
        }
        if let blockerID, let target, let blocker = watch.current[blockerID] {
            let now = ProcessInfo.processInfo.systemUptime
            let hiddenFor = watch.hiddenSince[blockerID].map { now - $0 }
            if now - lastBlockedNote >= Self.blockedNoteInterval {
                lastBlockedNote = now
                DiagnosticsStore.shared.note(
                    "input.blocked",
                    detail: SheetWatch.blockedClickSummary(target: Self.hostName(of: target), blocker: blocker, hiddenFor: hiddenFor))
            }
            if watch.shouldUnstick(blockerID, at: now) {
                unstick(blockerID, blocker: blocker, hiddenFor: hiddenFor ?? 0)
            }
        }
    }

    private func unstick(_ id: String, blocker: SheetWatch.Blocker, hiddenFor: TimeInterval) {
        if let pair = windows[id] {
            if revealed.contains(id) {
                DiagnosticsStore.shared.note(
                    "sheet.unstuck",
                    detail: String(format: "ended %@ after %.1f s hidden", blocker.name, hiddenFor))
                if let host = pair.host {
                    host.endSheet(pair.blocker, returnCode: .abort)
                } else {
                    NSApp.abortModal()
                }
                pair.blocker.orderOut(nil)
            } else {
                revealed.insert(id)
                DiagnosticsStore.shared.note(
                    "sheet.unstuck",
                    detail: String(format: "showed %@ after %.1f s hidden", blocker.name, hiddenFor))
                Self.reveal(pair.blocker, over: pair.host)
            }
            tickSoon()
        }
    }

    private static func reveal(_ window: NSWindow, over host: NSWindow?) {
        window.alphaValue = 1
        let frame = window.frame
        if !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) || frame.width <= 2 || frame.height <= 2 {
            let size = NSSize(width: max(frame.width, 320), height: max(frame.height, 200))
            let area = host?.frame ?? NSScreen.main?.visibleFrame ?? .zero
            window.setFrame(
                NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 28, width: size.width, height: size.height),
                display: true)
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    private static func look(of window: NSWindow, host: NSWindow? = nil) -> SheetWatch.Look {
        let frame = window.frame
        let covered = host.map { $0.occlusionState.contains(.visible) && !window.occlusionState.contains(.visible) } ?? false
        return SheetWatch.Look(
            isVisible: window.isVisible,
            alpha: Double(window.alphaValue),
            onScreen: NSScreen.screens.contains { $0.frame.intersects(frame) },
            hasArea: frame.width > 2 && frame.height > 2,
            covered: covered)
    }

    private static func name(of window: NSWindow) -> String {
        let descriptions = [
            window.contentViewController.map { String(reflecting: type(of: $0)) },
            window.contentView.map { String(reflecting: type(of: $0)) },
        ].compactMap { $0 }
        let fallback = window.title.isEmpty ? String(describing: type(of: window)) : window.title
        let size = String(format: " %.0f×%.0f", window.frame.width, window.frame.height)
        return SheetWatch.shortName(typeDescriptions: descriptions, fallback: fallback) + size
    }

    private static func hostName(of window: NSWindow) -> String {
        if let identifier = window.identifier?.rawValue, !identifier.isEmpty {
            identifier
        } else if !window.title.isEmpty {
            window.title
        } else {
            String(describing: type(of: window))
        }
    }
}
