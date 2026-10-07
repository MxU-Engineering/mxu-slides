import Foundation
import Testing

@testable import PresenterCore

@Suite struct ChangeAuthorTests {

    @LibraryActor private func lastMessage<Entity>(_ document: TypedDocument<Entity>) -> String? {
        document.document.heads().first.flatMap { document.document.change(hash: $0)?.message }
    }

    @Test func theMessageNamesUserStationAndKind() {
        #expect(ChangeAuthor(userHexId: "u1", stationHexId: "st1").message(for: .presentation) == "u1|st1|presentation")
        #expect(ChangeAuthor(userHexId: "u1", stationHexId: "st1").message(for: .actionCombo) == "u1|st1|actionCombo")
        #expect(ChangeAuthor.signedIn(userHexId: "u1", stationHexId: nil)?.message(for: .theme) == "u1||theme")
        #expect(ChangeAuthor.signedIn(userHexId: nil, stationHexId: "st1") == nil, "signed out: no author")
        #expect(ChangeAuthor.signedIn(userHexId: "u1", stationHexId: "st1") == ChangeAuthor(userHexId: "u1", stationHexId: "st1"))
    }

    @LibraryActor @Test func openStampsCommitsWithTheAuthorItFindsAndNoneWithout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        let created = try library.create(Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "", slides: []))
        #expect(created.commitMessage == nil)

        library.author = ChangeAuthor(userHexId: "u1", stationHexId: "st1")
        let opened = try library.open(Presentation.self, id: "d")
        try opened.update { $0.name = "D2" }
        #expect(lastMessage(opened) == "u1|st1|presentation")
        try library.save(opened)

        library.author = nil
        let anonymous = try library.open(Presentation.self, id: "d")
        #expect(anonymous.value.name == "D2")
        try anonymous.update { $0.name = "D3" }
        #expect(lastMessage(anonymous) == nil, "opened signed out: the commit carries no message")
    }
}
