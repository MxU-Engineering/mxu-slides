import Foundation
import Testing
@testable import PresenterCore

private func item(_ id: String, _ kind: ServiceItemKind = .presentation, synced: Bool = false) -> ServiceItem {
    ServiceItem(id: id, itemKind: kind, name: id, refId: kind == .header ? "" : "ref-\(id)",
                mxuItemHexId: synced ? "hex-\(id)" : nil)
}

private let rows = [item("h1", .header), item("a"), item("b", .media), item("h2", .header), item("c")]

@Test func surfaceItemKeepsTheCurrentWhileItStaysSelected() {
    #expect(RunOrderSelection.surfaceItem(selection: ["a", "c"], current: "c", rows: rows) == "c",
            "⌘/⇧ growing the selection never moves the center")
    #expect(RunOrderSelection.surfaceItem(selection: ["c"], current: "a", rows: rows) == "c",
            "a plain click elsewhere does")
}

@Test func surfaceItemFallsToFirstNonHeaderInSidebarOrder() {
    #expect(RunOrderSelection.surfaceItem(selection: ["c", "h1", "b"], current: nil, rows: rows) == "b")
}

@Test func surfaceItemIgnoresHeadersAndClearsOnEmpty() {
    #expect(RunOrderSelection.surfaceItem(selection: ["h1"], current: "a", rows: rows) == "a",
            "a header has no surface — the center keeps what it had")
    #expect(RunOrderSelection.surfaceItem(selection: ["h1"], current: nil, rows: rows) == nil)
    #expect(RunOrderSelection.surfaceItem(selection: [], current: "a", rows: rows) == nil)
}

@Test func sweptSelectsCrossedRowsOnTopOfShiftHold() {
    let frames: [String: CGRect] = [
        "a": CGRect(x: 0, y: 0, width: 200, height: 20),
        "b": CGRect(x: 0, y: 20, width: 200, height: 20),
        "c": CGRect(x: 0, y: 40, width: 200, height: 20),
    ]
    let band = CGRect(x: 150, y: 25, width: 30, height: 30)
    #expect(RunOrderSelection.swept(frames: frames, band: band) == ["b", "c"])
    #expect(RunOrderSelection.swept(frames: frames, band: band, keeping: ["a"]) == ["a", "b", "c"])
    #expect(RunOrderSelection.swept(frames: frames, band: CGRect(x: 0, y: 100, width: 10, height: 10)).isEmpty)
}

@Test func removalSplitsSyncedRowsFromLocalOnesInDocumentOrder() {
    let items = [item("h1", .header, synced: true), item("a", synced: true), item("b"), item("c", synced: true)]
    let removal = RunOrderSelection.removal(of: ["c", "b", "h1", "zzz"], in: items)
    #expect(removal.local.map(\.id) == ["h1", "b"], "headers remove locally even when synced (the header menu's rule)")
    #expect(removal.synced.map(\.id) == ["c"])
    #expect(removal.ids == ["h1", "b", "c"])
    #expect(removal.count == 3)
    #expect(RunOrderSelection.removal(of: ["b"], in: items).synced.isEmpty)
}

@Test func libraryKindsThatAddToTheRunOrder() {
    #expect(ServiceRunOrder.itemKind(adding: .presentation) == .presentation)
    #expect(ServiceRunOrder.itemKind(adding: .media) == .media)
    #expect(ServiceRunOrder.itemKind(adding: .audio) == .audio)
    #expect(ServiceRunOrder.itemKind(adding: .playlist) == .playlist)
    #expect(ServiceRunOrder.itemKind(adding: .theme) == nil)
    #expect(ServiceRunOrder.itemKind(adding: .service) == nil)
}
