import Foundation

public struct PerfLineLimiter: Sendable {
    public let perMinute: Int
    private var windows: [String: Window] = [:]

    private struct Window: Sendable {
        var start: Double
        var admitted = 0
        var dropped = 0
    }

    public init(perMinute: Int) {
        self.perMinute = perMinute
    }

    public mutating func admit(_ kind: String, now: Double) -> Int? {
        var window = windows[kind] ?? Window(start: now)
        if now - window.start >= 60 {
            window = Window(start: now, admitted: 0, dropped: window.dropped)
        }
        var result: Int?
        if window.admitted < perMinute {
            window.admitted += 1
            result = window.dropped
            window.dropped = 0
        } else {
            window.dropped += 1
        }
        windows[kind] = window
        return result
    }

    public static func annotate(_ detail: String, dropped: Int) -> String {
        dropped > 0 ? "\(detail) (+\(dropped) dropped)" : detail
    }
}

public enum RunLoopModeName {
    public static func short(_ mode: String?) -> String {
        switch mode {
        case nil: "none"
        case "kCFRunLoopDefaultMode": "default"
        case "NSEventTrackingRunLoopMode": "tracking"
        case "NSModalPanelRunLoopMode": "modal"
        case "kCFRunLoopCommonModes": "common"
        case let other?: other
        }
    }
}
