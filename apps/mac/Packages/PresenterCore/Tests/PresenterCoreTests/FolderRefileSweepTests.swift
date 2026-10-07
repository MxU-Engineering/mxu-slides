import Foundation
import Testing

@Suite struct FolderRefileSweepTests {
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

    private func block(after marker: String, in source: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) expected")
        let tail = source[start.upperBound...]
        return String(tail[..<(try #require(tail.range(of: "\n    }\n"), "\(marker) closes")).lowerBound])
    }

    private func expectInOrder(_ markers: [String], in text: String, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var from = text.startIndex
        for marker in markers {
            if let found = text.range(of: marker, range: from..<text.endIndex) {
                from = found.upperBound
            } else {
                Issue.record("\(what): \"\(marker)\" missing or out of order", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func mainAppliesAChunkWithOneListBump() throws {
        let model = try source("AppModel.swift")
        let chunk = try block(after: "func file(_ refiles: [LibraryRefile]) -> Task<LibraryEngine.Refiled, any Error> {", in: model)
        #expect(chunk.contains("return coalescingListBumps { client.refile(refiles) }"))
        let single = try block(after: "func file(_ entry: LibraryIndex.Entry, folder: String?, area: LibraryArea) {", in: model)
        #expect(single.contains("file([refile])"))
        #expect(!single.contains("modify("), "no whole-value refile")

        let mutation = try block(after: "private func noteMutation(_ kind: DocumentKind) {", in: model)
        expectInOrder(["kindVersions.bump(kind)", "if listBumpsHeld > 0 {", "listBumpOwed = true", "} else {", "listVersion += 1"], in: mutation, "noteMutation")
        let coalescing = try block(after: "private func coalescingListBumps<T>(", in: model)
        expectInOrder(["listBumpsHeld += 1", "let result = body()", "listBumpsHeld -= 1", "if listBumpsHeld == 0, listBumpOwed {", "listVersion += 1"], in: coalescing, "coalescingListBumps")
    }

    @Test func theViewMenuSortsAndNarrowsOffMain() throws {
        let model = try source("AppModel.swift")
        let browse = try block(after: "func browserEntries(in section: LibrarySection) -> [LibraryIndex.Entry] {", in: model)
        expectInOrder(["(librarySorts[section] ?? .name).ordered(", "showFiltersAdmit(id: $0.id, kind: $0.kind)"], in: browse, "browserEntries")
        let admit = try block(after: "func showFiltersAdmit(id: String, kind: DocumentKind) -> Bool {", in: model)
        #expect(admit.contains("!(upcomingOnly && UpcomingUse.kinds.contains(kind)) || upcomingIds.contains(id)"))

        let library = try source("LibraryView.swift")
        #expect(library.contains("rows: (model.librarySorts[section] ?? .name).merged(items, cloud: cloud),"))
        let refresh = try block(after: "private func refreshUpcoming() {", in: model)
        expectInOrder(["upcomingTask?.cancel()", "guard upcomingOnly else { return }", "UpcomingUse.services(", "try? await client.reader()",
                       "reader.loadValues(Service.self", "reader.loadValues(Presentation.self", "reader.loadValues(Playlist.self",
                       "if !Task.isCancelled, let self, self.upcomingIds != all {"], in: refresh, "refreshUpcoming")
        #expect(!refresh.contains("store.load"))
        let land = try block(after: "private func land(_ change: DocumentChange) {", in: model)
        #expect(land.contains("if upcomingOnly, [.service, .presentation, .playlist].contains(change.kind) {"))
        let sort = try block(after: "func setSort(_ sort: LibrarySort, for section: LibrarySection) {", in: model)
        expectInOrder(["if librarySorts[section] != sort {", "UserDefaults.standard.set(sort.rawValue, forKey: LibrarySort.defaultsKey("], in: sort, "setSort")
    }
}
