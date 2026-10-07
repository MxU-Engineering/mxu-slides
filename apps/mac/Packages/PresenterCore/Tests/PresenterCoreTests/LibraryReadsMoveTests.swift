import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("library-reads-\(UUID().uuidString)")
}

private func look(_ id: String, _ name: String) -> OutputPreset {
    OutputPreset(id: id, name: name, assignments: [])
}

private func deck(_ id: String, name: String) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "",
        slides: [Slide(id: "s1", name: "Verse", objects: [SlideObject(id: "t1", objectKind: .text, name: "Lyrics", text: "Line")])])
}

@MainActor private final class ResidentReadSide: LibraryReadSide {
    let epochs = DocumentKindVersions()
    let fills = DocumentKindVersions()
    let resident: ResidentLibrary

    init(source: any ResidentFillSource) {
        resident = ResidentLibrary(source: source, epochs: epochs, fills: fills)
    }

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        resident.value(kind: kind, id: id)
    }

    func applyOptimistic(_ change: DocumentChange) {
        land(change)
    }

    func optimisticWriteFailed(_ change: DocumentChange, error: any Error) {
        epochs.bump(change.kind)
    }

    func apply(_ batch: LibraryBatch) {
        batch.changes.forEach(land)
    }

    private func land(_ change: DocumentChange) {
        epochs.bump(change.kind)
        resident.reseed(kind: change.kind, id: change.id, value: change.value)
    }
}

@MainActor private func startedClient(_ root: URL, readSide: ResidentReadSide? = nil) async throws -> LibraryClient {
    let client = LibraryClient(rootURL: root)
    client.readSide = readSide
    try await client.start().value
    return client
}

@Suite struct LibraryReadsMoveTests {

    @MainActor @Test func theLaunchPathOpensNothingOnTheMainThread() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try DocumentStore(rootURL: root)
        try await files.save(TypedDocument(look("look", "Broadcast")))
        try await files.save(TypedDocument(MIDIDevice(id: "pad", name: "Pad")))
        try await files.save(TypedDocument(deck("welcome", name: "Welcome")))

        let trapped = try await MainThreadOpenTrap.recordingOpens {
            let client = LibraryClient(rootURL: root)
            let side = ResidentReadSide(source: client.residentFillSource)
            client.readSide = side
            #expect(side.resident.outputPresets.value("look") == nil, "before the open: a miss, the fill waits for the reader")
            #expect(side.resident.midiDevices.values.isEmpty)
            try await client.start().value
            await side.resident.ready([.outputPreset, .midiDevice])
            #expect(side.resident.outputPresets.value("look")?.name == "Broadcast")
            #expect(side.resident.midiDevices.values.map(\.id) == ["pad"])
            #expect(client.snapshot.entries(of: .outputPreset).map(\.id) == ["look"])
            #expect(!Library.needsOnboarding(rootURL: root, snapshot: client.snapshot), "a library with a deck is not new")
        }
        #expect(trapped.isEmpty, "decoded on the main thread at launch: \(trapped)")
    }

    @MainActor @Test func aMainThreadDecodeIsNamedAndCountedAndTheValueDoorIsNot() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        let files = try DocumentStore(rootURL: root)
        try await files.save(TypedDocument(look("bare", "Bare")))
        try await files.save(TypedDocument(look("fire", "Fire")))

        let trapped = try await MainThreadOpenTrap.recordingOpens {
            _ = Library.takeMainPassOpens()
            Library.measuringOpen(kind: .outputPreset, id: "bare") {
                MainThreadOpenTrap.check(kind: .outputPreset, id: "bare")
            }
            let bare = try await Library.open(OutputPreset.self, id: "bare", from: files, author: nil).value
            let fire = try await client.loadValue(OutputPreset.self, id: "fire")
            let counted = Library.takeMainPassOpens().count
            #expect(bare.name == "Bare" && fire.name == "Fire")
            #expect(counted == 1, "the main-thread decode is counted; the reader's is off main")
        }
        #expect(trapped == ["\(DocumentKind.outputPreset.directoryName)/bare"])
    }

    @MainActor @Test func outputPresetsAndMIDIDevicesFollowBatches() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = ResidentReadSide(source: client.residentFillSource)
        client.readSide = side
        try await client.start().value
        await side.resident.ready([.outputPreset, .midiDevice])
        let filled = (side.fills[.outputPreset], side.fills[.midiDevice])

        let created = client.create(look("look", "Broadcast"))
        #expect(side.resident.outputPresets.currentValue("look")?.name == "Broadcast", "optimistic: at once")
        _ = try await created.value
        _ = try await client.create(MIDIDevice(id: "pad", name: "Pad")).value
        #expect(side.resident.midiDevices.currentValue("pad")?.name == "Pad")

        let renamed = client.modify(OutputPreset.self, id: "look") { $0.name = "Stage" }
        #expect(side.resident.outputPresets.currentValue("look")?.name == "Stage", "the edit applies to the table's value")
        _ = try await renamed.value
        #expect(side.resident.outputPresets.currentValue("look")?.name == "Stage")
        #expect(try await DocumentStore(rootURL: root).load(OutputPreset.self, id: "look").value.name == "Stage")

        _ = try await client.delete(kind: .midiDevice, id: "pad").value
        #expect(side.resident.midiDevices.value("pad") == nil)
        #expect(side.resident.outputPresets.isCovered && side.resident.midiDevices.isCovered, "a batch keeps the kind covered")
        #expect((side.fills[.outputPreset], side.fills[.midiDevice]) == filled, "batches retag; nothing refilled")
    }

    @MainActor @Test func searchAnswersAfterTheWritesBeforeIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        client.create(deck("d", name: "Amazing Grace"))
        client.modify(Presentation.self, id: "d") { $0.name = "Great Is Thy Faithfulness" }
        #expect(try await client.search("Faithfulness").map(\.entry.id) == ["d"])
        #expect(try await client.search("Amazing").isEmpty)
    }

    @MainActor @Test func theEditorsReplicaIsAForkWithTheAuthor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        let author = ChangeAuthor.signedIn(userHexId: "u1", stationHexId: "s1")
        client.setAuthor(author)
        client.create(deck("d", name: "Deck"))
        client.modify(Presentation.self, id: "d") { $0.name = "Renamed" }
        let checkout = try await client.checkout(Presentation.self, id: "d")
        #expect(await client.author() == author)

        let replica = checkout.replica
        #expect(replica.value.name == "Renamed")
        #expect(replica.commitMessage != nil && replica.commitMessage == author?.message(for: .presentation))
        try replica.update { $0.name = "Editing" }
        await client.settled()
        #expect(try await DocumentStore(rootURL: root).load(Presentation.self, id: "d").value.name == "Renamed")
        let reader = try await client.reader()
        #expect(try await reader.loadValue(Presentation.self, id: "d").name == "Renamed")
        #expect(client.readerNow != nil)
        _ = try await client.release(token: checkout.token).value
    }
}
