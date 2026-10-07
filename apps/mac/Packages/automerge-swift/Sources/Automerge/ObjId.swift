import AutomergeUniffi

public struct ObjId: Equatable, Hashable, Sendable {
    var bytes: [UInt8]

    public static let ROOT = ObjId(bytes: AutomergeUniffi.root())
}

extension ObjId: CustomDebugStringConvertible {
    public var debugDescription: String {
        if bytes == AutomergeUniffi.root() {
            return "ObjId.ROOT"
        } else {
            return "ObjId(\(bytes.map { Swift.String(format: "%02hhx", $0) }.joined()))"
        }
    }
}
