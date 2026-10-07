import enum AutomergeUniffi.ExpandMark
import struct AutomergeUniffi.Mark

typealias FfiMark = AutomergeUniffi.Mark
typealias FfiExpandMark = AutomergeUniffi.ExpandMark

public struct Mark: Equatable, Hashable, Sendable {

    public let start: UInt64

    public let end: UInt64

    public let name: String

    public let value: ScalarValue

    public init(start: UInt64, end: UInt64, name: String, value: ScalarValue) {
        self.start = start
        self.end = end
        self.name = name
        self.value = value
    }

    static func fromFfi(_ ffiMark: FfiMark) -> Self {
        Self(
            start: ffiMark.start,
            end: ffiMark.end,
            name: ffiMark.name,
            value: ScalarValue.fromFfi(value: ffiMark.value)
        )
    }
}

public enum ExpandMark: Equatable, Hashable, Sendable {

    case before

    case after

    case both

    case none

    static func fromFfi(_ ffiExp: FfiExpandMark) -> Self {
        switch ffiExp {
        case .before:
            return ExpandMark.before
        case .after:
            return ExpandMark.after
        case .both:
            return ExpandMark.both
        case .none:
            return ExpandMark.none
        }
    }

    func toFfi() -> FfiExpandMark {
        switch self {
        case .before:
            return FfiExpandMark.before
        case .after:
            return FfiExpandMark.after
        case .both:
            return FfiExpandMark.both
        case .none:
            return FfiExpandMark.none
        }
    }
}
