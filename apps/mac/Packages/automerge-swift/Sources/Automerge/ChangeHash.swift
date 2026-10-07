import AutomergeUniffi
import Foundation

public struct ChangeHash: Equatable, Hashable, CustomDebugStringConvertible, Sendable {
    var bytes: [UInt8]

    public var debugDescription: String {
        bytes.map { String(format: "%02hhx", $0) }.joined()
    }
}

public extension Set<ChangeHash> {

    func raw() -> Data {
        let rawBytes = map(\.bytes).sorted { lhs, rhs in
            lhs.debugDescription > rhs.debugDescription
        }
        return Data(rawBytes.joined())
    }
}

public extension Data {

    func heads() -> Set<ChangeHash>? {
        let rawBytes: [UInt8] = Array(self)
        guard rawBytes.count % 32 == 0 else { return nil }
        let totalHashes = rawBytes.count / 32
        let heads = (0 ..< totalHashes).map { index in
            let lowerBound = index * 32
            let upperBound = (index + 1) * 32
            let bytes = rawBytes[lowerBound ..< upperBound]
            return ChangeHash(bytes: Array(bytes))
        }
        return Set(heads)
    }
}
