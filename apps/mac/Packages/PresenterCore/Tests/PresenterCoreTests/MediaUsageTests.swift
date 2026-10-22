import Foundation
import Testing
@testable import PresenterCore

private func media(hash: String, inPoint: Double? = nil) -> MediaItem {
    var item = MediaItem(
        id: "m1", name: "Background", mediaKind: .image, classification: .background,
        fileHash: hash, fileName: "bg.png", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: false)
    item.inPoint = inPoint
    return item
}

@Test func theWhereUsedListGroupsThemesFirstNamesAtoZ() {
    let groups = MediaUsage.groups([
        .init(kind: .presentation, id: "p2", name: "Sermon"),
        .init(kind: .service, id: "s1", name: "Sunday"),
        .init(kind: .theme, id: "t1", name: "The Blessed Life"),
        .init(kind: .presentation, id: "p1", name: "Announcements"),
    ])
    #expect(groups.map(\.title) == ["Themes", "Presentations", "Services"])
    #expect(groups[1].uses.map(\.name) == ["Announcements", "Sermon"])
    #expect(MediaUsage.groups([]).isEmpty, "unused: no confirm, straight to the open panel")
}

@Test func aNewFileOrFirstFrameIsAFileChange() {
    #expect(MediaUsage.fileChanged(from: media(hash: "a"), to: media(hash: "b")))
    #expect(MediaUsage.fileChanged(from: media(hash: "a"), to: media(hash: "a", inPoint: 2)))
    var renamed = media(hash: "a")
    renamed.name = "Renamed"
    #expect(!MediaUsage.fileChanged(from: media(hash: "a"), to: renamed), "a rename keeps every decoded picture")
    #expect(!MediaUsage.fileChanged(from: nil, to: media(hash: "a")))
    #expect(!MediaUsage.fileChanged(from: media(hash: "a"), to: nil))
}

@Test func theMediaCardSaysWhatThePickIs() {
    #expect(MediaPickCardLogic.detail(kind: .image, width: 1920, height: 1080, duration: nil, missing: false)
        == "Image · 1920 × 1080")
    #expect(MediaPickCardLogic.detail(kind: .video, width: 1280, height: 720, duration: 92.4, missing: false)
        == "Video · 1:32 · 1280 × 720")
    #expect(MediaPickCardLogic.detail(kind: .video, width: nil, height: nil, duration: 3725, missing: false)
        == "Video · 1:02:05")
    #expect(MediaPickCardLogic.detail(kind: .image, width: 10, height: 10, duration: nil, missing: true)
        == "Missing — the file isn't on this Mac")
}

@Test func presentationsOnAThemeThatUsesTheItemAreListedViaTheTheme() {
    let documents: [MediaUsage.Document] = [
        .init(use: .init(kind: .theme, id: "t1", name: "Clean Geometric"), mediaIDs: ["m1"]),
        .init(use: .init(kind: .theme, id: "t2", name: "Other"), mediaIDs: ["m9"]),
        .init(use: .init(kind: .presentation, id: "p1", name: "QA Song"), mediaIDs: [], themeIDs: ["t1"]),
        .init(use: .init(kind: .presentation, id: "p2", name: "Own Use"), mediaIDs: ["m1"], themeIDs: ["t1"]),
        .init(use: .init(kind: .presentation, id: "p3", name: "Elsewhere"), mediaIDs: [], themeIDs: ["t2"]),
    ]
    let uses = MediaUsage.uses(of: "m1", in: documents)
    #expect(Set(uses.map(\.id)) == ["t1", "p1", "p2"])
    #expect(uses.first { $0.id == "p1" }?.via == "Clean Geometric")
    #expect(uses.first { $0.id == "p2" }?.via == nil, "a direct use is listed once, as itself")
}
