import Foundation

public struct ChangeAuthor: Equatable, Sendable {
    public var userHexId: String

    public var stationHexId: String

    public init(userHexId: String, stationHexId: String) {
        self.userHexId = userHexId
        self.stationHexId = stationHexId
    }

    public static func signedIn(userHexId: String?, stationHexId: String?) -> ChangeAuthor? {
        userHexId.map { ChangeAuthor(userHexId: $0, stationHexId: stationHexId ?? "") }
    }

    public func message(for kind: DocumentKind) -> String {
        "\(userHexId)|\(stationHexId)|\(kind.rawValue)"
    }
}
