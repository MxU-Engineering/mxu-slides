import Foundation

public enum TimelineZoom {
    public static let range: ClosedRange<Double> = 24...480

    public static let stepFactor = 1.3

    public static let fitReserve: Double = 116

    public static let fitMinimumViewport: Double = 140

    public static let songRange: ClosedRange<Double> = 2...120

    public static func clamped(_ pointsPerSecond: Double, in range: ClosedRange<Double> = range) -> Double {
        min(max(pointsPerSecond, range.lowerBound), range.upperBound)
    }

    public static func pinched(base: Double, magnification: Double, in range: ClosedRange<Double> = range) -> Double {
        clamped(base * magnification, in: range)
    }

    public static func zoomedIn(_ pointsPerSecond: Double, in range: ClosedRange<Double> = range) -> Double {
        min(pointsPerSecond * stepFactor, range.upperBound)
    }

    public static func zoomedOut(_ pointsPerSecond: Double, in range: ClosedRange<Double> = range) -> Double {
        max(pointsPerSecond / stepFactor, range.lowerBound)
    }

    public static func fit(
        seconds: Double, viewportWidth: Double, reserve: Double = fitReserve, in range: ClosedRange<Double> = range
    ) -> Double? {
        guard seconds > 0, viewportWidth > fitMinimumViewport else { return nil }
        return clamped((viewportWidth - reserve) / seconds, in: range)
    }
}

public struct TimelineSegment: Equatable, Sendable {
    public var start: Double
    public var displayDuration: Double
    public var width: CGFloat

    public init(start: Double, displayDuration: Double, width: CGFloat) {
        self.start = start
        self.displayDuration = displayDuration
        self.width = width
    }

    public static func width(
        displayDuration: Double, hasContent: Bool, pointsPerSecond: CGFloat, floor: CGFloat
    ) -> CGFloat {
        let natural = CGFloat(displayDuration) * pointsPerSecond
        return hasContent ? natural : max(natural, floor)
    }
}

public struct TimelineMap: Equatable, Sendable {
    public var segments: [TimelineSegment]
    public var pointsPerSecond: CGFloat

    public init(segments: [TimelineSegment], pointsPerSecond: CGFloat) {
        self.segments = segments
        self.pointsPerSecond = pointsPerSecond
    }

    public var width: CGFloat {
        segments.reduce(0) { $0 + $1.width }
    }

    public func x(ofSegment index: Int) -> CGFloat {
        segments.prefix(index).reduce(0) { $0 + $1.width }
    }

    public func x(ofTime t: Double) -> CGFloat {
        var x: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            let next = index + 1 < segments.count ? segments[index + 1].start : .infinity
            if t < next {
                let offset = max(t - segment.start, 0)
                return x + min(CGFloat(offset) * pointsPerSecond, segment.width)
            }
            x += segment.width
        }
        return x
    }

    public func locate(x: CGFloat) -> (time: Double, segment: Int)? {
        var cursor: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if x < cursor + segment.width || index == segments.count - 1 {
                let offset = Double(max(x - cursor, 0) / pointsPerSecond)
                return (segment.start + min(offset, segment.displayDuration), index)
            }
            cursor += segment.width
        }
        return nil
    }

    public func segmentIndex(atX x: CGFloat) -> Int? {
        var cursor: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            cursor += segment.width
            if x < cursor { return index }
        }
        return segments.indices.last
    }

    public func boundary(nearX x: CGFloat, tolerance: CGFloat) -> Int? {
        guard segments.count > 1 else { return nil }
        for boundary in 1..<segments.count where abs(x - self.x(ofSegment: boundary)) <= tolerance {
            return boundary
        }
        return nil
    }
}

public enum TimelineBlockEdit {
    public enum Mode: Equatable, Sendable {
        case move, stretch, trim
    }

    public static let engageDistance: CGFloat = 3

    public static let minimumWidth: CGFloat = 26

    public static let minimumTrimWidth: CGFloat = 34

    public static let minimumDuration = 0.05

    public static func mode(pressX: CGFloat, frameMinX: CGFloat, frameWidth: CGFloat) -> Mode {
        let baseWidth = max(frameWidth, minimumWidth)
        let edgeZone = min(12, max(baseWidth / 3, 6))
        let local = pressX - frameMinX
        if local > baseWidth - edgeZone { return .stretch }
        if local < edgeZone, baseWidth >= minimumTrimWidth { return .trim }
        return .move
    }

    public static func liveSpan(
        x: CGFloat, width: CGFloat, mode: Mode?, delta: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        switch mode {
        case .move: (x + delta, max(width, minimumWidth))
        case .stretch: (x, max(width + delta, minimumWidth))
        case .trim: (x + delta, max(width - delta, minimumWidth))
        case nil: (x, max(width, minimumWidth))
        }
    }

    public static func snapped(_ seconds: Double) -> Double {
        max((seconds * 20).rounded() / 20, minimumDuration)
    }

    public static func liveDuration(
        _ duration: Double, mode: Mode?, delta: CGFloat, pointsPerSecond: CGFloat
    ) -> Double {
        let seconds = Double(delta / pointsPerSecond)
        switch mode {
        case .stretch: return snapped(duration + seconds)
        case .trim: return snapped(duration - seconds)
        case .move, nil: return duration
        }
    }

    public static func durationLabel(_ seconds: Double) -> String {
        let tenths = (seconds * 10).rounded() / 10
        return abs(tenths - seconds) < 0.001
            ? String(format: "%.1fs", seconds)
            : String(format: "%.2fs", seconds)
    }
}
