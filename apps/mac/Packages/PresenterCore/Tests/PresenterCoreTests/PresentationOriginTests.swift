import Foundation
import Testing
@testable import PresenterCore

@Suite struct PresentationOriginTests {
    private func deck(_ origin: PresentationOrigin? = nil) -> Presentation {
        Presentation(id: "p1", name: "Give Me Jesus", presentationKind: .deck, themeId: "", slides: [], origin: origin)
    }

    @Test func aStampedOriginReadsAsWords() {
        #expect(PresentationOrigin(.chartFile, detail: "Chord Chart.pdf").label
            == "Chord chart file · Chord Chart.pdf")
        #expect(PresentationOrigin(.madeHere, detail: " ").label == "Made in MxU Slides")
        #expect(deck(PresentationOrigin(.songSelect, detail: "Way Maker")).originLabel == "SongSelect · Way Maker")
    }

    @Test func olderDecksSayWhatTheyStillShow() {
        var chart = deck()
        chart.chordProSource = "{title: Center}"
        #expect(chart.originLabel == "Chord chart import")
        var lyrics = deck()
        lyrics.ccli = CCLIInfo(songNumber: 1)
        lyrics.reflowSource = "Verse 1"
        #expect(lyrics.originLabel == "Lyrics import")
        #expect(deck().originLabel == nil)
        #expect(deck().indexOrigin == "")
    }

    @LibraryActor @Test func theIndexKeepsTheOriginWhereverEntriesAreRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
        let value = deck(PresentationOrigin(.proPresenter, at: nil))
        try index.upsert(
            id: value.id, kind: .presentation, subkind: "Lyrics", name: value.name,
            updatedAt: Date(timeIntervalSince1970: 10), origin: value.indexOrigin)

        #expect(try index.entry(id: "p1")?.origin == "ProPresenter import")
        #expect(try index.search("Give").first?.origin == "ProPresenter import")
        var mirror = try LibraryIndexMirror.read(index)
        #expect(mirror.snapshot(generation: 0).entry(id: "p1")?.origin == "ProPresenter import")
        mirror.upsert(id: "p1", kind: .presentation, subkind: "Lyrics", name: value.name,
                      updatedAt: Date(timeIntervalSince1970: 10), origin: "Copy · of Give Me Jesus")
        #expect(mirror.snapshot(generation: 0).entry(id: "p1")?.origin == "Copy · of Give Me Jesus")
        #expect(LibraryIndex.Entry(pending: value).origin == "ProPresenter import")
    }
}
