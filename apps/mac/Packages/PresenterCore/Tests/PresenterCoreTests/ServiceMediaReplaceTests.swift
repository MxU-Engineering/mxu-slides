import Foundation
import Testing
@testable import PresenterCore

@Test func replaceMediaRepointsOnlyThatRow() {
    var items = [
        ServiceItem(id: "a", itemKind: .media, name: "Old", refId: "m1"),
        ServiceItem(id: "b", itemKind: .media, name: "Old", refId: "m1"),
    ]
    ServiceRunOrder.replaceMedia(in: &items, itemID: "a", mediaID: "m2", name: "New")
    #expect(items[0].refId == "m2")
    #expect(items[0].name == "New", "a local row takes the new item's name")
    #expect(items[1].refId == "m1", "another row using the same media is untouched")
}

@Test func replaceMediaKeepsASyncedRowsPlanName() {
    var items = [ServiceItem(id: "a", itemKind: .media, name: "Walk-in", refId: "m1", mxuItemHexId: "hex")]
    ServiceRunOrder.replaceMedia(in: &items, itemID: "a", mediaID: "m2", name: "New")
    #expect(items[0].refId == "m2")
    #expect(items[0].name == "Walk-in")
}

@Test func replaceMediaLeavesOtherKindsAlone() {
    var items = [ServiceItem(id: "a", itemKind: .presentation, name: "Deck", refId: "p1")]
    ServiceRunOrder.replaceMedia(in: &items, itemID: "a", mediaID: "m2", name: "New")
    #expect(items[0].refId == "p1")
}
