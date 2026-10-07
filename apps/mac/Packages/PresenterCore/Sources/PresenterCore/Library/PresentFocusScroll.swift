import Foundation

public struct PresentFocusScroll: Equatable, Sendable {

    public private(set) var honoredItemID: String?

    public init() {}

    public mutating func request(_ itemID: String?) -> String? {
        if let itemID, itemID != honoredItemID {
            honoredItemID = itemID
            return itemID
        } else {
            return nil
        }
    }

    public mutating func reset() {
        honoredItemID = nil
    }

    public private(set) var reselects = 0

    public mutating func reselect() {
        honoredItemID = nil
        reselects += 1
    }
}
