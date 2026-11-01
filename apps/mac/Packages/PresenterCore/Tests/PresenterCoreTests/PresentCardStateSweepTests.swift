import Foundation
import Testing

@Suite struct PresentCardStateSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    @Test func cardStateLivesInTheObservedStore() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("@MainActor @Observable\nfinal class PresentCards {"))
        for state in ["settingsItemID", "headerHeights"] {
            #expect(!surface.contains("@State private var \(state)"), "\(state) as @State never redrew the cards")
        }
        #expect(!surface.contains("@State private var settingsPopoverItemID"))
        #expect(surface.contains("set: { cards.settingsItemID = $0 ? item.id : nil }"))
    }

    @Test func theHeaderReserveReadsTheMeasuredHeight() throws {
        let surface = try source("ServiceContinuousView.swift")
        #expect(surface.contains("HeaderReserve(itemID: item.id)"))
        #expect(surface.contains("Color.clear.frame(height: PresentCards.shared.headerHeight(itemID))"))
        #expect(surface.contains("cards.headerHeights[item.id] = height"))
    }
}
