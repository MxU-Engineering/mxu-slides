import Foundation
import Testing
@testable import PresenterCore

private func media(_ id: String, name: String, hash: String) -> MediaItem {
    MediaItem(
        id: id, name: name, mediaKind: .image, classification: .background,
        fileHash: hash, fileName: "\(name).png", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: false)
}

private func audio(_ id: String, name: String, hash: String) -> AudioItem {
    AudioItem(id: id, name: name, fileHash: hash, fileName: "\(name).mp3", tags: [], favorite: false)
}

@Test func theSameFileReusesTheLibrarysItem() {
    let dedupe = MediaImportDedupe(media: [media("m1", name: "Announce", hash: "h1")], audio: [])
    #expect(dedupe.match(hash: "h1", name: "Renamed on disk", kind: .media) == .sameFile(id: "m1"))
}

@Test func aDifferentFileUnderAnExistingNameAsks() {
    let dedupe = MediaImportDedupe(media: [media("m1", name: "Announce", hash: "h1")], audio: [])
    #expect(dedupe.match(hash: "h2", name: " announce ", kind: .media) == .sameName(id: "m1", name: "Announce"))
    #expect(dedupe.match(hash: "h2", name: "Other", kind: .media) == .new)
}

@Test func mediaAndAudioNeverMatchEachOther() {
    let dedupe = MediaImportDedupe(media: [media("m1", name: "Song", hash: "h1")], audio: [audio("a1", name: "Song", hash: "h2")])
    #expect(dedupe.match(hash: "h1", name: "Song", kind: .audio) == .sameName(id: "a1", name: "Song"))
    #expect(dedupe.match(hash: "h2", name: "x", kind: .audio) == .sameFile(id: "a1"))
    #expect(dedupe.match(hash: "h2", name: "x", kind: .media) == .new)
}

@Test func aFileMadeThisRunIsReusedByItsTwin() {
    var dedupe = MediaImportDedupe(media: [], audio: [])
    dedupe.note(id: "new1", hash: "h9", name: "Flyer", kind: .media)
    #expect(dedupe.match(hash: "h9", name: "Flyer copy", kind: .media) == .sameFile(id: "new1"))
}
