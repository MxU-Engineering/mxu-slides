import Foundation

public enum VideoMarks {

    public struct Point: Sendable, Equatable {
        public var id: String
        public var name: String

        public var at: Double

        public var colorHex: String?

        public init(id: String, name: String, at: Double, colorHex: String? = nil) {
            self.id = id
            self.name = name
            self.at = at
            self.colorHex = colorHex
        }
    }

    public static let startGrace: Double = 1.0

    public static let tolerance: Double = 0.15

    public static func points(_ marks: [VideoMark]?, inPoint: Double?, length: Double) -> [Point] {
        let offset = inPoint ?? 0
        return (marks ?? [])
            .map { Point(id: $0.id, name: $0.name, at: $0.at - offset, colorHex: $0.colorHex) }
            .filter { $0.at >= 0 && $0.at <= length }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    public static func crossed(
        _ points: [Point], from: Double?, to: Double, elapsed: Double, rate: Double,
        length: Double, looping: Bool
    ) -> [Point] {
        guard length > 0 else { return [] }
        guard let from else {
            return to < startGrace ? points.filter { $0.at <= to } : []
        }
        let allowed = max(0, elapsed) * max(rate, 0) + tolerance
        var forward = to - from
        if looping, forward < -tolerance { forward += length }
        guard forward >= -tolerance, forward <= allowed else {

            return to < from && to < startGrace ? points.filter { $0.at <= to } : []
        }
        if to >= from {
            return points.filter { $0.at > from && $0.at <= to }
        }
        guard looping, forward > 0 else { return [] }
        return points.filter { $0.at > from } + points.filter { $0.at <= to }
    }

    public static func target(
        _ points: [Point], after position: Double, target: VideoCountdownTarget, name: String?
    ) -> Point? {
        let ahead = points.filter { $0.at > position }
        switch target {
        case .end: return nil
        case .nextMark: return ahead.first
        case .namedMark:
            guard let name, !name.isEmpty else { return nil }
            return ahead.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    public static func countUpStart(
        _ points: [Point], before position: Double, target: VideoCountdownTarget, name: String?
    ) -> Double {
        let behind = points.filter { $0.at <= position }
        switch target {
        case .end: return 0
        case .nextMark: return behind.last?.at ?? 0
        case .namedMark:
            guard let name, !name.isEmpty else { return behind.last?.at ?? 0 }
            return behind.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.at ?? 0
        }
    }

    public static func untilNext(_ points: [Point], after position: Double, length: Double, looping: Bool) -> Double? {
        if let next = points.first(where: { $0.at > position }) { return next.at - position }
        guard looping, let first = points.first, length > 0 else { return nil }
        return length - position + first.at
    }

    public static func defaultName(forActionLabel label: String) -> String {
        guard let colon = label.range(of: ": ") else { return label }
        let target = label[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? label : target
    }

    public static func defaultName(_ marks: [VideoMark]?) -> String {
        let names = Set((marks ?? []).map { $0.name.lowercased() })
        var n = (marks ?? []).count + 1
        while names.contains("mark \(n)") { n += 1 }
        return "Mark \(n)"
    }

    public static func adding(
        _ marks: [VideoMark]?, id: String, name: String, at: Double, actions: [SlideAction], fileLength: Double
    ) -> [VideoMark] {
        let mark = VideoMark(id: id, name: name, at: clampedTime(at, fileLength: fileLength), actions: actions)
        return sorted((marks ?? []) + [mark])
    }

    public static func moving(_ marks: [VideoMark]?, id: String, to at: Double, fileLength: Double) -> [VideoMark] {
        sorted((marks ?? []).map { mark in
            guard mark.id == id else { return mark }
            var moved = mark
            moved.at = clampedTime(at, fileLength: fileLength)
            return moved
        })
    }

    private static func clampedTime(_ at: Double, fileLength: Double) -> Double {
        let upper = fileLength > 0 ? fileLength : at
        return (min(max(at, 0), upper) * 1000).rounded() / 1000
    }

    private static func sorted(_ marks: [VideoMark]) -> [VideoMark] {
        marks.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }
}
