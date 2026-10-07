import Foundation
import Testing

@Suite struct LibraryListingSweepTests {
    private func body(_ file: SourceSweep.File, _ signature: String) throws -> String {
        let start = try #require(file.lines.firstIndex { $0.contains(signature) }, "\(signature)")
        return file.block(from: start).map { file.code($0) }.joined(separator: "\n")
    }

    @Test func listingsReadTheListingVersion() throws {
        let model = try #require(try SourceSweep.app().file("AppModel.swift"))
        #expect(try body(model, "private var listedSnapshot: IndexSnapshot {").contains("_ = listingVersion"))
        #expect(try body(model, "func area(_ kind: DocumentKind, _ id: String) -> LibraryArea {").contains("_ = listingVersion"))

        #expect(try body(model, "func entry(_ id: String) -> LibraryIndex.Entry? {").contains("_ = listVersion"))
    }

    @Test func onlyAListingChangeMovesIt() throws {
        let model = try #require(try SourceSweep.app().file("AppModel.swift"))
        #expect(!(try body(model, "private func noteMutation(_ kind: DocumentKind) {")).contains("listingVersion"),
                "a document change reaches the listing through its batch")
        let apply = try body(model, "func apply(_ batch: LibraryBatch) {")
        #expect(apply.contains("appliedListing.map(batch.snapshot.listsLike) != true"))
        #expect(apply.contains("listingVersion += 1"))
    }

    @Test func theSidebarReadsListVersionOnlyForSearch() throws {
        let library = try #require(try SourceSweep.app().file("LibraryView.swift"))
        let reads = library.codeLines.enumerated().filter { $0.element.contains("listVersion") }
        #expect(reads.count == 1 && library.lines[reads[0].offset].contains(".task(id: \"\\(model.listVersion)|\\(model.teamCloudItems.count)|\\(searchText)\")"),
                "\(reads.map { "LibraryView.swift:\($0.offset + 1)" })")
    }
}
