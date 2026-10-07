import Foundation
import Testing
@testable import PresenterCore

private func customLegacy(name: String = "Resi", url: String = "rtmps://x/app", key: String? = "k") -> StreamPresetDestination {
    StreamPresetDestination(id: UUID().uuidString, name: name, transport: .rtmps, url: url, streamKey: key)
}

@Test func displayNameFallsBackToTheURL() {
    var custom = StreamDestinationLibrary.hoisted(customLegacy(name: ""))
    #expect(StreamDestinationLibrary.displayName(custom) == "rtmps://x/app")
    custom.name = "Resi"
    #expect(StreamDestinationLibrary.displayName(custom) == "Resi")
}

@Test func hoistingKeepsCustomIds() {
    let custom = customLegacy()
    let hoisted = StreamDestinationLibrary.hoisted(custom)
    #expect(hoisted.id == custom.id && hoisted.url == "rtmps://x/app" && hoisted.streamKey == "k")
}

@Test func planDropsUnfinishedDedupesCustomAndInfersKind() {
    let preset = StreamRecordPreset(
        id: "p", name: "Sunday",
        destinations: [
            customLegacy(name: "Resi"),
            customLegacy(name: "Resi again"),
            customLegacy(name: "Decoder", url: "", key: nil),
        ])
    let plan = StreamDestinationLibrary.plan(preset, existingCustomIDs: [:])
    #expect(plan.kind == .stream)
    #expect(plan.dropped == ["Sunday: removed a destination that could not stream — Decoder: no server URL"])
    #expect(plan.destinationIds.count == 1)
    #expect(plan.records.count == 1)
    #expect(plan.records[0].id == plan.destinationIds[0])

    let reuse = StreamDestinationLibrary.plan(
        StreamRecordPreset(id: "q", name: "Q", destinations: [customLegacy(name: "R")]),
        existingCustomIDs: [StreamDestinationLibrary.customKey(transport: .rtmps, url: "rtmps://x/app", streamKey: "k"): "existing"])
    #expect(reuse.records.isEmpty && reuse.destinationIds == ["existing"])

    let empty = StreamDestinationLibrary.plan(StreamRecordPreset(id: "r", name: "Rec", destinations: []), existingCustomIDs: [:])
    #expect(empty.kind == .recordOnly)
    let allDropped = StreamDestinationLibrary.plan(
        StreamRecordPreset(id: "s", name: "S", destinations: [customLegacy(name: "Decoder", url: "", key: nil)]), existingCustomIDs: [:])
    #expect(allDropped.kind == .stream, "meant to stream → readiness warning, never a silent recording")
}

@Test func sessionDestinationCarriesTheDisplayName() {
    let custom = StreamDestinationLibrary.sessionDestination(StreamDestinationLibrary.hoisted(customLegacy()), displayName: "Resi")
    #expect(custom.name == "Resi" && custom.privacy == nil && custom.url == "rtmps://x/app")
}

@LibraryActor @Test func libraryMigrationIsIdempotentAndWritesKinds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = try Library(rootURL: root)
    let legacyPreset = StreamRecordPreset(
        id: "sunday", name: "Sunday",
        destinations: [customLegacy(), customLegacy(name: "North", url: "rtmps://n/app", key: "n"), customLegacy(name: "Decoder", url: "", key: nil)])
    _ = try library.create(legacyPreset)
    _ = try library.create(StreamRecordPreset(id: "archive", name: "Archive", destinations: []))

    let first = try library.migrateStreamDestinations()
    #expect(first.presets == 2)
    #expect(first.dropped.count == 1)
    let sunday = try library.open(StreamRecordPreset.self, id: "sunday").value
    #expect(sunday.destinations.isEmpty)
    #expect(sunday.presetKind == .stream)
    #expect(sunday.destinationIds?.count == 2)
    let archive = try library.open(StreamRecordPreset.self, id: "archive").value
    #expect(archive.presetKind == .recordOnly)
    #expect(try library.store.ids(of: .streamDestination).count == 2)

    let second = try library.migrateStreamDestinations()
    #expect(second.presets == 0 && second.dropped.isEmpty)
    #expect(try library.store.ids(of: .streamDestination).count == 2)
}
