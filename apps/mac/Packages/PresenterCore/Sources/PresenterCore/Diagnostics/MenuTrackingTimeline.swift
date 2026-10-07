import Foundation

public struct MenuTrackingTimeline: Equatable, Sendable {

    public static let clickWindow: TimeInterval = 3

    public static let tickInterval: TimeInterval = 0.1

    public static let lateTickThreshold: TimeInterval = 0.1

    public let title: String
    public let itemCount: Int
    public let began: TimeInterval

    public let openLatency: TimeInterval?
    public private(set) var peakWindows: Int

    public private(set) var submenuAfter: TimeInterval?

    public private(set) var hoveredSubmenuAfter: TimeInterval?
    public private(set) var hitches = 0

    public private(set) var longestTickGap: TimeInterval = 0

    public private(set) var lateTicks = 0
    private var lastTick: TimeInterval

    public init(title: String, itemCount: Int, began: TimeInterval, lastClick: TimeInterval?, windows: Int) {
        self.title = title
        self.itemCount = itemCount
        self.began = began
        let sinceClick = lastClick.map { began - $0 }
        if let sinceClick, sinceClick >= 0, sinceClick <= Self.clickWindow {
            openLatency = sinceClick
        } else {
            openLatency = nil
        }
        peakWindows = windows
        lastTick = began
        if windows >= 2 { submenuAfter = 0 }
    }

    public mutating func sample(at time: TimeInterval, windows: Int, hoveringSubmenuItem: Bool) {
        tick(at: time)
        peakWindows = max(peakWindows, windows)
        if windows >= 2, submenuAfter == nil { submenuAfter = time - began }
        if hoveringSubmenuItem, hoveredSubmenuAfter == nil { hoveredSubmenuAfter = time - began }
    }

    public mutating func noteHitch() {
        hitches += 1
    }

    public func summary(endedAt end: TimeInterval) -> String {
        var closing = self
        closing.tick(at: end)
        let opened = openLatency.map { "opened after \(Self.ms($0)) ms" } ?? "opened after ? ms (no click)"
        let submenu = submenuAfter.map { "submenu after \(Self.ms($0)) ms" } ?? "submenu never"
        let hovered = hoveredSubmenuAfter.map { "hovered submenu item: yes after \(Self.ms($0)) ms" } ?? "hovered submenu item: no"
        return String(
            format: "%@ %d items, %.2f s, menu windows peak %d (%@), hitches %d",
            title.isEmpty ? "(context)" : title, itemCount, end - began, peakWindows,
            peakWindows >= 2 ? "submenu opened" : "no submenu", hitches)
            + ", \(opened), \(submenu), \(hovered)"
            + ", longest tick gap \(Self.ms(closing.longestTickGap)) ms, late ticks \(closing.lateTicks)"
    }

    private mutating func tick(at time: TimeInterval) {
        let gap = time - lastTick
        longestTickGap = max(longestTickGap, gap)
        if gap >= Self.tickInterval + Self.lateTickThreshold { lateTicks += 1 }
        lastTick = time
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}
