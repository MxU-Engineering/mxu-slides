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

    public private(set) var returning = false

    public mutating func leave() {
        honoredItemID = nil
        returning = true
    }

    public mutating func comeBack(
        to left: PresentPlace?, serviceID: String, focusItemID: String?
    ) -> PresentLanding.Anchor? {
        let anchor = returning ? left?.anchor(serviceID: serviceID, focusItemID: focusItemID) : nil
        returning = false
        if anchor != nil { honoredItemID = focusItemID }
        return anchor
    }

    public mutating func reselect() {
        honoredItemID = nil
        returning = false
        reselects += 1
    }
}

public struct PresentPlace: Equatable, Sendable {
    public let serviceID: String
    public let focusItemID: String?
    public let anchor: PresentLanding.Anchor

    public init(serviceID: String, focusItemID: String?, anchor: PresentLanding.Anchor) {
        self.serviceID = serviceID
        self.focusItemID = focusItemID
        self.anchor = anchor
    }

    public func anchor(serviceID: String, focusItemID: String?) -> PresentLanding.Anchor? {
        serviceID == self.serviceID && focusItemID == self.focusItemID ? anchor : nil
    }
}
