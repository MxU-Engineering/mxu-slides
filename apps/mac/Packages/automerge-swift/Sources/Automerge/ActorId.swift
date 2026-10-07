import AutomergeUniffi
import Foundation

public struct ActorId: Equatable, Hashable, Sendable {
    var data: Data

    init(ffi: AutomergeUniffi.ActorId) {
        data = Data(ffi)
    }

    public init() {
        self.init(uuid: UUID())
    }

    public init(uuid: UUID) {
        data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    public init?(data: Data) {
        guard data.count <= 128 else {
            return nil
        }
        self.data = data
    }
}

extension ActorId: CustomStringConvertible {

    public var description: String {
        data.map { String(format: "%02hhX", $0) }.joined()
    }
}
