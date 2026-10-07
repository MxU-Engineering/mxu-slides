import Foundation
import Testing

@testable import PresenterCore

@Suite struct ValueDecodeDoorTests {
    private func makeStore() throws -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try DocumentStore(rootURL: root), root)
    }

    @LibraryActor private func save(_ id: String, _ name: String, in store: DocumentStore) throws {
        try store.save(TypedDocument(ActionCombo(id: id, name: name, actions: [])))
    }

    private final class DecodeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private var peak = 0
        private var onMain = 0

        func decoding<T>(_ value: T) -> T {
            lock.withLock {
                running += 1
                peak = max(peak, running)
                onMain += Thread.isMainThread ? 1 : 0
            }
            Thread.sleep(forTimeInterval: 0.03)
            lock.withLock { running -= 1 }
            return value
        }

        var counts: (peak: Int, onMain: Int) { lock.withLock { (peak, onMain) } }
    }

    @LibraryActor @Test func loadValueDecodesWhatLoadDecodesAndThrowsItsError() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try save("a", "One", in: store)

        let value = try await store.loadValue(ActionCombo.self, id: "a")
        #expect(value == (try store.load(ActionCombo.self, id: "a").value))
        let parts = try await store.loadReplicaParts(ActionCombo.self, id: "a")
        #expect(parts.value == value)

        let missing = DocumentStore.StoreError.documentNotFound(kind: .actionCombo, id: "nope")
        #expect(throws: missing) { try store.load(ActionCombo.self, id: "nope") }
        await #expect(throws: missing) { try await store.loadValue(ActionCombo.self, id: "nope") }
        await #expect(throws: missing) { try await store.loadReplicaParts(ActionCombo.self, id: "nope") }
    }

    @Test func loadValuesKeepsReadableIdsAndNamesTheRest() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await save("a", "One", in: store)
        try await save("b", "Two", in: store)
        try Data("not an automerge document".utf8).write(to: store.url(kind: .actionCombo, id: "bad"))

        let loaded = await store.loadValues(ActionCombo.self, ids: ["a", "b", "bad", "gone"])
        #expect(loaded.values.mapValues(\.name) == ["a": "One", "b": "Two"])
        #expect(loaded.failed == ["bad", "gone"])

        let names = await store.loadValues(ActionCombo.self, ids: ["a", "gone"]) { $0.name }
        #expect(names.values == ["a": "One"])
        #expect(names.failed == ["gone"])

        let none = await store.loadValues(ActionCombo.self, ids: [])
        #expect(none.values.isEmpty && none.failed.isEmpty)
    }

    @Test func loadValuesDecodesABoundedFewAtOnce() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = (0..<12).map { "c\($0)" }
        for id in ids { try await save(id, id, in: store) }

        let narrow = DecodeProbe()
        let two = await store.loadValues(ActionCombo.self, ids: ids, width: 2) { narrow.decoding($0.name) }
        #expect(two.values.count == 12)
        #expect(narrow.counts.peak == 2, "two decode side by side, never more")

        let standard = DecodeProbe()
        let four = await store.loadValues(ActionCombo.self, ids: ids) { standard.decoding($0.name) }
        #expect(four.values.count == 12)
        #expect(standard.counts.peak > 1 && standard.counts.peak <= DocumentStore.decodeWidth)
    }

    @MainActor @Test func aMainActorCallerNeverDecodesOnMain() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await save("a", "One", in: store)
        try await save("b", "Two", in: store)

        let probe = DecodeProbe()
        let loaded = await store.loadValues(ActionCombo.self, ids: ["a", "b"], priority: .userInitiated) {
            probe.decoding($0.name)
        }
        #expect(loaded.values == ["a": "One", "b": "Two"])
        #expect(probe.counts.onMain == 0)
        #expect(try await store.loadValue(ActionCombo.self, id: "b").name == "Two")
    }
}
