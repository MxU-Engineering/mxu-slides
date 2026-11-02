import Foundation
import Testing
@testable import PresenterCore

private func paragraph(_ text: String, href: String? = nil) -> NoteBlock {
    NoteBlock(type: .paragraph, runs: [NoteRun(text: text, href: href)])
}

private let picture = NoteBlock(type: .image, url: "/rails/active_storage/blobs/x/lake.jpg", width: 640)
private let videoFile = NoteBlock(type: .attachment, attachmentKind: "video", hexId: "abc", filename: "recap.mp4")

private func body(_ blocks: [NoteBlock]) -> NoteBody { NoteBody(blocks: blocks, plainText: "") }

@Test func aMarkedPictureIsAPassageHoldingItsKey() {
    var block = picture
    block.markRun = NoteRun(text: "", slideGroup: "g1", slideType: "picture")
    var declined = videoFile
    declined.markRun = NoteRun(text: "", slideGroup: "g2", slideType: "video", slideState: NoteSlideMarks.declined)
    let groups = NoteSlideMarks.groups(in: body([block, declined]))
    #expect(groups.map(\.id) == ["g1"])
    #expect(groups.first?.media == [picture.url!])
    #expect(groups.first?.text == "")
    #expect(groups.first?.type == "picture")
}

@Test func runRulesApplyToAPictureBlocksMark() {
    let marked = NoteSlideMarks.marking(picture, group: "g1", type: "picture", state: NoteSlideMarks.suggested)
    #expect(marked.slideGroup == "g1" && marked.slideState == NoteSlideMarks.suggested)
    let accepted = NoteSlideMarks.acceptingSuggestions(in: body([marked]))
    #expect(accepted.blocks[0].slideState == nil && accepted.blocks[0].slideGroup == "g1")
    let stamped = NoteSlideMarks.stamping(slideId: "s1", onGroup: "g1", in: accepted)
    #expect(stamped.blocks[0].slideId == "s1")
    let unmarked = NoteSlideMarks.unmarking(group: "g1", in: stamped)
    #expect(unmarked.blocks[0] == picture)

    #expect(paragraph("words").markRun == nil)
}

@Test func linksOnAPassagesWordsAreKept() {
    let line = NoteBlock(type: .paragraph, runs: [
        NoteRun(text: "Video: ", slideGroup: "g1"),
        NoteRun(text: "Testimony", href: "https://vimeo.com/1", slideGroup: "g1"),
    ])
    #expect(NoteSlideMarks.groups(in: body([line])).first?.links == ["https://vimeo.com/1"])
}

@Test func picturesAndVideosAreSuggestedAsTheirOwnSlides() {
    let note = body([
        paragraph("Big idea: What lasts."),
        picture,
        paragraph("Video: Sarah's story (2:40)"),
        paragraph("Video: Testimony", href: "https://vimeo.com/1"),
        paragraph("Picture: the lake at dawn"),
        videoFile,
    ])
    let groups = NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(note))
    #expect(groups.map(\.type) == ["points", "picture", "video", "video"])
    #expect(groups[1].media == [picture.url!])
    #expect(groups[2].text == "Video: Testimony")
    #expect(groups[3].media == ["hex:abc"])
}

@Test func boldLinesOnlyKeepsPicturesAndVideos() {
    let bold = { (text: String) in NoteBlock(type: .paragraph, runs: [NoteRun(text: text, bold: true)]) }
    let note = body([bold("One bold line"), bold("Another bold line"), paragraph("Plain words here"), picture, videoFile])
    let types = NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(note, mode: .boldLines)).map(\.type)
    #expect(types.filter { $0 == "picture" || $0 == "video" } == ["picture", "video"])
}

@Test func aPictureRowTakesTheTeamsScale() {
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["k"])
    let row = DeterministicSlidePlanner().plan([group], theme: nil, overrides: [:]).rows[0]
    #expect(row.kind == .picture && row.media == ["k"] && row.scale == .scaleAndBlur && row.warning == nil)
    var options = SlideOptions()
    options.pictureScale = .fit
    #expect(DeterministicSlidePlanner(options: options).plan([group], theme: nil, overrides: [:]).rows[0].scale == .fit)
}

@Test func aVideoWithOnlyALinkIsAPlaceholderHoldingIt() {
    let planner = DeterministicSlidePlanner()
    let inWords = planner.plan([MarkedGroup(id: "g", text: "Video: Testimony – https://vimeo.com/1")], theme: nil, overrides: [:]).rows[0]
    #expect(inWords.kind == .video && inWords.notes == "https://vimeo.com/1" && inWords.warning != nil)
    let onWords = planner.plan([MarkedGroup(id: "g", text: "Video: Testimony", links: ["https://vimeo.com/2"])], theme: nil, overrides: [:]).rows[0]
    #expect(onWords.notes == "https://vimeo.com/2")
    let built = NoteSlideBuilder.build(SlidePlan(rows: [inWords]))
    #expect(built.slides.count == 1 && built.slides[0].background == nil && built.slides[0].notes == "https://vimeo.com/1")
}

@Test func aPictureSlideIsFullScreenOnStillGraphics() throws {
    var row = SlideRow(groupId: "g", kind: .picture, themeSlideName: nil, linesPerSlide: 1, parts: [], lyrics: nil, notes: nil, warning: nil)
    row.media = ["k1", "k2"]
    row.scale = .scaleAndBlur
    let built = NoteSlideBuilder.build(SlidePlan(rows: [row]), blanks: [:], blank: .init(), media: { $0 == "k1" ? "m1" : nil })
    #expect(built.slides.count == 2)
    let cue = try #require(built.slides[0].background)
    #expect(cue == CueMedia(mediaId: "m1", layer: .stillGraphics, classification: .foreground, scaleMode: .scaleAndBlur))

    #expect(built.slides[1].background?.mediaId == NoteMedia.pendingId(for: "k2"))
    #expect(built.slides.allSatisfy { built.groupBySlideId[$0.id] == "g" })
    row.scale = .fill
    #expect(NoteSlideBuilder.build(SlidePlan(rows: [row])).slides[0].background?.scaleMode == nil)
}

@Test(arguments: SlideOptions.VideoEnd.allCases)
func aVideoSlideEndsAsChosen(_ end: SlideOptions.VideoEnd) throws {
    var row = SlideRow(groupId: "g", kind: .video, themeSlideName: nil, linesPerSlide: 1, parts: [], lyrics: nil, notes: nil, warning: nil)
    row.media = ["hex:abc"]
    row.videoEnd = end
    let slide = NoteSlideBuilder.build(SlidePlan(rows: [row]), blanks: [:], blank: .init(), media: { _ in "v1" }).slides[0]
    let cue = try #require(slide.background)
    #expect(cue.layer == .videos && cue.classification == .foreground)
    #expect(slide.autoAdvance == (end == .next ? AutoAdvance(delaySeconds: 0, afterPlayback: true) : nil))
    #expect(cue.loops == (end == .loop))
    #expect(cue.endFade == [.fadeToBlack: MediaEndFade.black, .fadeToClear: .clear][end])
}

@Test func theImportFillsPendingSlides() throws {
    let pending = Slide(id: "a", name: "", objects: [], background: CueMedia(mediaId: NoteMedia.pendingId(for: "k1")))
    var lost = Slide(id: "b", name: "", objects: [], background: CueMedia(mediaId: NoteMedia.pendingId(for: "hex:z")))
    lost.autoAdvance = AutoAdvance(delaySeconds: 0, afterPlayback: true)
    let plain = Slide(id: "c", name: "", objects: [], background: CueMedia(mediaId: "m9"))
    let filled = try #require(NoteMedia.filling([pending, lost, plain], remembered: [NoteMediaImport(key: "k1", mediaId: "m1")]))
    #expect(filled[0].background?.mediaId == "m1")
    #expect(filled[1].background == nil && filled[1].autoAdvance == nil && filled[1].notes?.hasPrefix("Needs media") == true)
    #expect(filled[2] == plain)
    #expect(NoteMedia.filling([plain], remembered: []) == nil)
    #expect(NoteMedia.key(ofPendingId: "m9") == nil)
}

@Test func pictureAndVideoOptionsDecodeWithDefaults() throws {
    let old = try JSONDecoder().decode(SlideOptions.self, from: Data("{}".utf8))
    #expect(old.pictureScale == .scaleAndBlur && old.videoEnd == .next)
    let set = try JSONDecoder().decode(SlideOptions.self, from: Data(#"{"pictureScale":"fit","videoEnd":"fadeToClear"}"#.utf8))
    #expect(set.pictureScale == .fit && set.videoEnd == .fadeToClear)
    #expect(try JSONDecoder().decode(SlideOptions.self, from: JSONEncoder().encode(set)) == set)
}

@Test func updatingAPictureKeepsItsSlideAndTakesTheScale() {
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["k"])
    var options = SlideOptions()
    options.pictureScale = .fit
    let row = DeterministicSlidePlanner(options: options).plan([group], theme: nil, overrides: [:]).rows[0]
    let made = Slide(id: "s", name: "", objects: [], background: CueMedia(mediaId: "m", scaleMode: .scaleAndBlur))
    let result = NoteSlideUpdate.updating([made], to: row)
    #expect(result.removedIds.isEmpty && result.appended.isEmpty)
    #expect(result.updated.first?.background?.scaleMode == .fit)
    #expect(!NoteSlideUpdate.isBehind(group, slides: [made], theme: nil))
}

@Test func aDropFillsAPlaceholderFullScreen() {
    var placeholder = Slide(id: "s", name: "", objects: [])
    placeholder.notes = "https://vimeo.com/1"
    #expect(placeholder.waitsForMedia)
    var options = SlideOptions()
    options.videoEnd = .fadeToBlack
    var video = MediaItem(
        id: "v", name: "Clip", mediaKind: .video, classification: .background, fileHash: "h", fileName: "clip.mov",
        fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: true)
    placeholder.fillPlaceholder(with: video, options: options)
    #expect(placeholder.background?.layer == .videos && placeholder.background?.endFade == .black)
    #expect(placeholder.notes == "https://vimeo.com/1" && !placeholder.waitsForMedia)

    var lost = Slide(id: "l", name: "", objects: [])
    lost.notes = Slide.needsMediaNote + " the note's video did not come in"
    video.mediaKind = .image
    lost.fillPlaceholder(with: video, options: SlideOptions())
    #expect(lost.background?.scaleMode == .scaleAndBlur && lost.background?.layer == .stillGraphics && lost.notes == nil)

    var blank = Slide(id: "b", name: "", objects: [])
    #expect(!blank.waitsForMedia)
    blank.notes = "Pastor: hold here"
    #expect(!blank.waitsForMedia)
}
