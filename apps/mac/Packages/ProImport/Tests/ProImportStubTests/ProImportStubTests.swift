import Foundation
import PresenterCore
import Testing
@testable import ProImport

@MainActor
struct ProImportStubTests {
    @Test func everyImportReportsUnavailable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = LibraryClient(rootURL: dir)
        try await client.start().value
        let workspace = try await ProWorkspaceImporter(client: client)
        #expect(workspace.scan(showDirectory: dir).presentations == 0)
        #expect(await workspace.importWorkspace(showDirectory: dir).warnings == [proImportUnavailable])

        let documents = try ProPresenterImporter(client: client)
        let summaries = await documents.importItems(at: [dir])
        #expect(summaries.map(\.presentationID) == [nil])
        #expect(await documents.importPlaylistBundle(at: dir).failureReason == proImportUnavailable)
    }
}
