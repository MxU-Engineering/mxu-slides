import enum AutomergeUniffi.Position

typealias FfiPosition = AutomergeUniffi.Position

public struct Cursor: Equatable, Hashable, Sendable {
    var bytes: [UInt8]
}

extension Cursor: CustomStringConvertible {

    public var description: String {
        bytes.map { Swift.String(format: "%02hhx", $0) }.joined().uppercased()
    }
}

public enum Position {

    case cursor(Cursor)

    case index(UInt64)
}

extension Position {
    func toFfi() -> FfiPosition {
        switch self {
        case let .cursor(cursor):
            return .cursor(position: cursor.bytes)
        case let .index(index):
            return .index(position: index)
        }
    }
}
