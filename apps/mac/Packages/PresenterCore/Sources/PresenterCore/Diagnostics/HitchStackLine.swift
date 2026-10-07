import Foundation

public enum HitchStackLine {
    public static let leafFrames = 8
    public static let appFrames = 8
    public static let maxFrames = 24

    public static func chosen(
        _ frames: [StackFrame], isApp: (StackFrame) -> Bool,
        leaf: Int = leafFrames, app: Int = appFrames, cap: Int = maxFrames
    ) -> [String] {
        var picked = Array(frames.indices.prefix(leaf))
        let appIndices = frames.indices.dropFirst(leaf).filter { isApp(frames[$0]) }
        picked.append(contentsOf: appIndices.prefix(app))
        var printed: [String] = []
        var previous: Int?
        for index in picked.prefix(cap) {
            if let previous, index > previous + 1 { printed.append("…") }
            printed.append(frames[index].description)
            previous = index
        }
        if let last = previous, last < frames.count - 1 { printed.append("…") }
        return printed
    }

    public static func movement(from previous: RawStack, to current: RawStack) -> String {
        if previous.addresses == current.addresses {
            return "unchanged"
        } else {
            let shared = zip(previous.addresses.reversed(), current.addresses.reversed())
                .prefix { $0 == $1 }.count
            return "moved, \(shared) of \(current.addresses.count) frames shared from the root"
        }
    }

    public static func detail(
        mode: String, blockedMS: Double, loadAddress: UInt, movement: String?, frames: [String]
    ) -> String {
        let head = String(format: "%@ %.0f ms", mode, blockedMS)
        let moved = movement.map { ", stack \($0)" } ?? ""
        let stack = frames.isEmpty ? "(no frames)" : frames.joined(separator: " ← ")
        return "\(head)\(moved), load 0x\(String(loadAddress, radix: 16)) | \(stack)"
    }
}

public struct HitchCaptureGate: Sendable {
    public static let minimumGap = 2.0
    public static let linesPerMinute = 30

    private var lastCaptureAt = -Double.infinity
    private var lines = PerfLineLimiter(perMinute: HitchCaptureGate.linesPerMinute)

    public init() {}

    public mutating func admitFirst(now: Double) -> Int? {
        var admitted: Int?
        if now - lastCaptureAt >= Self.minimumGap, let dropped = lines.admit("stack", now: now) {
            lastCaptureAt = now
            admitted = dropped
        }
        return admitted
    }

    public mutating func admitFollowUp(now: Double) -> Int? {
        let admitted = lines.admit("stack", now: now)
        if admitted != nil { lastCaptureAt = now }
        return admitted
    }
}
