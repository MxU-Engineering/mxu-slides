import Foundation
import Testing
@testable import PresenterCore

private let picture = NoteBlock(type: .image, url: "file:///Users/me/Notes/photo.png", width: 400)
private let video = NoteBlock(type: .attachment, attachmentKind: "video", hexId: "v1", filename: "baptism.mp4")
private let outline = NoteBlock(type: .attachment, attachmentKind: "file", hexId: "f1", filename: "outline.pdf")
private let clipAsFile = NoteBlock(type: .attachment, attachmentKind: "file", hexId: "f2", filename: "clip.mov")

private let body = NoteBody(blocks: [
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Grace")]),
    picture,
    NoteBlock(type: .quote, blocks: [video]),
    NoteBlock(type: .list, items: [NoteListItem(runs: [], checked: nil, blocks: [clipAsFile])]),
    outline,
    NoteBlock(type: .image, url: ""),
], plainText: "Grace")

@Test func mediaBlocksArePicturesAndVideosNestedToo() {
    #expect(NoteMedia.blocks(in: body) == [picture, video, clipAsFile], "a pdf and an empty picture are not media")
    #expect(NoteMedia.key(of: picture) == "file:///Users/me/Notes/photo.png")
    #expect(NoteMedia.key(of: video) == "hex:v1")
    #expect(NoteMedia.key(of: body.blocks[0]) == nil)
    #expect(NoteMedia.fileName(of: picture) == "photo.png")
    #expect(NoteMedia.fileName(of: video) == "baptism.mp4")
}

@Test func mailChromeAndCidPicturesAreNoMedia() {
    let icon = NoteBlock(type: .image, url: "https://ssl.gstatic.com/docs/doclist/images/icon_10_generic_list.png")
    let screenshot = NoteBlock(type: .image, url: "cid:ii_mvikieid0", alt: "Screenshot.png")
    let mailed = NoteBody(blocks: [icon, screenshot, picture], plainText: "")
    #expect(NoteMedia.blocks(in: mailed) == [picture])
    #expect(NoteMedia.isMailChrome("https://drive-thirdparty.googleusercontent.com/16/type/video/mp4"))
    #expect(NoteMedia.isMailChrome("https://mail.google.com/mail/u/0/images/cleardot.gif"))
    #expect(!NoteMedia.isMailChrome("https://lh3.googleusercontent.com/photo.jpg"), "a real Google Photos picture")
    #expect(!NoteMedia.isMailChrome(picture.url!))
    #expect(NoteMedia.resolve("cid:ii_mvikieid0") == nil, "only Mail can read it")
}

@Test func aSecondRunImportsOnlyWhatTheLibraryLacks() {
    let remembered = [NoteMediaImport(key: "hex:v1", mediaId: "m-video"), NoteMediaImport(key: "hex:f2", mediaId: "m-gone")]
    let pending = NoteMedia.pending(in: body, remembered: remembered) { $0 == "m-video" }
    #expect(pending == [picture, clipAsFile], "the video is in the library; the clip's item left it; the picture was never brought in")
    #expect(NoteMedia.pending(in: body, remembered: [
        NoteMediaImport(key: picture.url!, mediaId: "m1"), NoteMediaImport(key: "hex:v1", mediaId: "m2"), NoteMediaImport(key: "hex:f2", mediaId: "m3"),
    ]) { _ in true }.isEmpty)
}

@Test func theMemoryFollowsTheNoteAndTakesNewLandings() {
    let remembered = [NoteMediaImport(key: "hex:f2", mediaId: "m-gone"), NoteMediaImport(key: "hex:removed", mediaId: "m-old")]
    let landed = [NoteMediaImport(key: picture.url!, mediaId: "m-pic"), NoteMediaImport(key: "hex:f2", mediaId: "m-clip")]
    #expect(NoteMedia.remembering(remembered, adding: landed, in: body) == [
        NoteMediaImport(key: picture.url!, mediaId: "m-pic"),
        NoteMediaImport(key: "hex:f2", mediaId: "m-clip"),
    ], "note order; the clip's new item replaces the lost one; a block the note no longer has is forgotten")
}

@Test func picturesResolveOnlyFromWhatThisMacCanRead() {
    #expect(NoteMedia.resolve("https://cdn.example/a.png")?.absoluteString == "https://cdn.example/a.png")
    #expect(NoteMedia.resolve("file:///Users/me/a.png")?.isFileURL == true, "a note's own copy")
    #expect(NoteMedia.resolve("cid:ii_mvikieid0") == nil)
}

@Test func aPictureNeverRunsPastTheColumn() {
    #expect(NoteMedia.fitted(CGSize(width: 480, height: 270), toWidth: 240) == CGSize(width: 240, height: 135), "narrower column: scaled, same shape")
    #expect(NoteMedia.fitted(CGSize(width: 200, height: 100), toWidth: 240) == CGSize(width: 200, height: 100), "fits already: unchanged")
    #expect(NoteMedia.fitted(CGSize(width: 480, height: 270), toWidth: 0) == CGSize(width: 480, height: 270), "no layout width yet")
}

@Test func theFooterNamesWhatARunBringsIn() {
    let clip = NoteBlock(type: .attachment, url: "file:///Users/me/Notes/clip.mov", attachmentKind: "video", filename: "clip.mov")
    let local = NoteBody(blocks: body.blocks + [clip], plainText: "")
    let all = NoteMedia.importable(in: local, remembered: [], libraryHas: { _ in false })
    #expect(all == [picture, clip], "an attachment with no file here is never fetched")
    #expect(NoteMedia.footerLine(for: all) == "Also adds 1 picture and 1 video to Media\u{00A0}\u{203A}\u{00A0}Needs\u{00A0}Sorted.")
    #expect(NoteMedia.footerLine(for: []) == nil)
}

@Test func keptFilesAreFoundAndSavedOnce() throws {
    let video = NoteBlock(type: .attachment, url: "file:///tmp/Snoop.mp4", attachmentKind: "video", filename: "Snoop.mp4", slideGroup: "g1")
    let picture = NoteBlock(type: .image, url: "file:///tmp/a.png")
    let web = NoteBlock(type: .image, url: "https://cdn.example/b.png")
    let quoted = NoteBlock(type: .quote, blocks: [picture])
    let body = NoteBody(blocks: [video, quoted, web], plainText: "")

    #expect(NoteMedia.key(of: video) == "file:///tmp/Snoop.mp4")
    #expect(NoteMedia.importable(in: body, remembered: [], libraryHas: { _ in false }).count == 3)
    #expect(NoteMedia.localFiles(in: body).map(\.url) == ["file:///tmp/Snoop.mp4", "file:///tmp/a.png"])

    let folder = FileManager.default.temporaryDirectory.appending(path: "note-saver-\(UUID().uuidString)")
    let save = NoteMedia.saver(in: folder)
    let first = try #require(save(Data("png".utf8), "a.png"))
    #expect(save(Data("png".utf8), "a.png") == first)
    #expect(save(Data("other".utf8), "a.png") != first)
    #expect(URL(string: first)?.lastPathComponent == "a.png")
}

@Test func aVideosPosterIsASecondIn() {
    #expect(NoteMedia.posterTime(duration: 42) == 1)
    #expect(NoteMedia.posterTime(duration: 1.5) == 0.1)
}
