import AppKit
import Foundation
import PresenterCore

@MainActor
final class MenuTrackingRecorder {
    static let shared = MenuTrackingRecorder()

    private var tracking: MenuTrackingTimeline?

    private weak var trackingMenu: NSMenu?

    private var lastClick: TimeInterval?
    private var sampler: Timer?
    private var hitchObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    private init() {}

    func activate() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] notification in

            let now = ProcessInfo.processInfo.systemUptime
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            Task { @MainActor in self?.began(menu: menu, at: now) }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in self?.ended(at: now) }
        }
        hitchObserver = center.addObserver(forName: DiagnosticsStore.hitchNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.tracking?.noteHitch() }
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let clicked = event.timestamp
            MainActor.assumeIsolated { self?.lastClick = clicked }
            return event
        }
    }

    private func began(menu: NSMenu?, at time: TimeInterval) {

        if tracking == nil {
            tracking = MenuTrackingTimeline(
                title: menu?.title ?? "", itemCount: menu?.items.count ?? 0,
                began: time, lastClick: lastClick, windows: Self.menuWindowCount())
            trackingMenu = menu
            lastClick = nil
            let timer = Timer(timeInterval: MenuTrackingTimeline.tickInterval, repeats: true) { [weak self] _ in
                let now = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.sample(at: now) }
            }

            RunLoop.main.add(timer, forMode: .common)
            sampler = timer
        }
    }

    private func sample(at time: TimeInterval) {
        tracking?.sample(
            at: time, windows: Self.menuWindowCount(),
            hoveringSubmenuItem: trackingMenu?.highlightedItem?.hasSubmenu == true)
    }

    private func ended(at time: TimeInterval) {
        sampler?.invalidate()
        sampler = nil
        if let tracking {
            DiagnosticsStore.shared.note("menu.track", detail: tracking.summary(endedAt: time))
        }
        tracking = nil
        trackingMenu = nil
    }

    private static func menuWindowCount() -> Int {
        let pid = Int(getpid())
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { window in
            (window[kCGWindowOwnerPID as String] as? Int) == pid
                && (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
        }.count
    }
}
