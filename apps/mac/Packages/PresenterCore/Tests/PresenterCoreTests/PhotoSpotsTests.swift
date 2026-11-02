import Foundation
import Testing
@testable import PresenterCore

private func spot(_ id: String, x: Double, y: Double) -> SlideObject {
    SlideObject(id: id, objectKind: .shape, name: "Shape", text: "", x: x, y: y, width: 400, height: 300, photoSpot: true)
}

private let theme = Theme(
    id: "t", name: "T", fontFamily: "Helvetica", fontSize: 72, textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
    slides: [
        Slide(id: "body", name: "Body", objects: [SlideObject(id: "b", objectKind: .text, name: "Text", text: "")]),
        { var s = Slide(id: "p1", name: "Photo + Text", objects: [spot("s", x: 0, y: 0), SlideObject(id: "t", objectKind: .text, name: "Words", text: "Sample")]); s.folder = "Full Slide"; return s }(),
        { var s = Slide(id: "p2", name: "2 Photos", objects: [spot("b", x: 900, y: 0), spot("a", x: 0, y: 10)]); s.folder = "Full Slide"; return s }(),
        { var s = Slide(id: "p3", name: "3 Photos", objects: [spot("a", x: 0, y: 0), spot("b", x: 500, y: 0), spot("c", x: 1000, y: 0)]); s.folder = "Full Slide"; return s }(),
    ])

@Test func spotsReadLeftToRightThenTopToBottom() {
    let slide = Slide(id: "x", name: "", objects: [spot("low", x: 0, y: 600), spot("right", x: 900, y: 20), spot("left", x: 0, y: 0)])
    #expect(slide.photoSpots.map(\.id) == ["left", "right", "low"])
    #expect(SlideObject.photo(mediaId: "m", scale: .fill).fill?.mediaScaleMode == nil)
    #expect(SlideObject.photo(mediaId: "m", scale: .fit).isPhotoSpot)
}

@Test func aPicturePassageTakesItsChosenDesignAndItsWords() throws {
    let group = MarkedGroup(id: "g", type: "picture", text: "Scan to give", media: ["k1", "k2"])
    let override = SlideRowOverride(themeSlideName: "Photo + Text")
    let row = try #require(DeterministicSlidePlanner().plan([group], theme: theme, overrides: ["g": override]).rows.first)
    #expect(row.themeSlideName == "Photo + Text" && row.photosPerSlide == 1)
    #expect(row.parts == [[SlideBox(name: "Words", text: "Scan to give")]] && row.notes == nil)
    let built = NoteSlideBuilder.build(SlidePlan(rows: [row]), blanks: [:], blank: .init(), media: { $0 == "k1" ? "m1" : nil })
    #expect(built.slides.count == 2, "one slide each by default")
    #expect(built.slides.allSatisfy { $0.themeSlideName == "Photo + Text" && $0.objects.count == 2 })
    #expect(built.slides[0].objects.first?.fill?.mediaId == "m1" && built.slides[0].objects.first?.isPhotoSpot == true)
    #expect(built.slides[1].objects.first?.fill?.mediaId == NoteMedia.pendingId(for: "k2"))

    #expect(built.slides[0].objects.first?.fill?.mediaScaleMode == nil)
}

@Test func aPictureFarFromItsSpotsShapeTakesScaleAndBlur() throws {
    #expect(PictureShape(picture: 0.5, spot: 4.0 / 3) == .tall && PictureShape(picture: 3, spot: 4.0 / 3) == .wide)
    #expect(PictureShape(picture: 1.5, spot: 4.0 / 3) == nil && PictureShape(picture: nil, spot: 1) == nil)
    #expect(PictureShape.tall.caption == "Scale and Blur (tall picture)")
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["tall", "wide", "unknown"])
    let override = ["g": SlideRowOverride(themeSlideName: "Photo + Text")]
    let planner = DeterministicSlidePlanner(pictureAspects: ["tall": 0.5, "wide": 1.5])
    let row = try #require(planner.plan([group], theme: theme, overrides: override).rows.first)
    #expect(row.pictureShapes == ["tall": .tall])
    let built = NoteSlideBuilder.build(SlidePlan(rows: [row]))
    #expect(built.slides.map { $0.objects.first?.fill?.mediaScaleMode } == [.scaleAndBlur, nil, nil])
    #expect(built.pictureShapes == [built.slides[0].id: .tall])

    let kept = NoteSlideUpdate.updating(built.slides, to: row).updated
    #expect(kept[0].objects.first?.fill?.mediaScaleMode == .scaleAndBlur)
    var fit = SlideOptions()
    fit.pictureScale = .fit
    let fitRow = try #require(DeterministicSlidePlanner(options: fit, pictureAspects: ["tall": 0.5]).plan([group], theme: theme, overrides: override).rows.first)
    #expect(fitRow.pictureShapes.isEmpty)
    #expect(NoteSlideUpdate.updating(built.slides, to: fitRow).updated.allSatisfy { $0.objects.first?.fill?.mediaScaleMode == .fit })
}

@Test func aScalePickedForThePassageWinsInPhotoSpots() throws {
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["tall", "wide"])
    let override = ["g": SlideRowOverride(themeSlideName: "Photo + Text")]
    let auto = try #require(DeterministicSlidePlanner(pictureAspects: ["tall": 0.5]).plan([group], theme: theme, overrides: override).rows.first)
    #expect(!auto.scaleChosen && auto.shownScale == .scaleAndBlur, "the first picture took Scale and Blur for its shape")

    var fill = SlideOptions()
    fill.pictureScale = .fill
    let picked = try #require(DeterministicSlidePlanner(options: fill, pictureAspects: ["tall": 0.5], pictureScaleChosen: true)
        .plan([group], theme: theme, overrides: override).rows.first)
    #expect(picked.scaleChosen && picked.pictureShapes.isEmpty && picked.shownScale == .fill)
    #expect(NoteSlideBuilder.build(SlidePlan(rows: [picked])).slides.allSatisfy { $0.objects.first?.fill?.mediaScaleMode == nil })

    let blurred = NoteSlideBuilder.build(SlidePlan(rows: [auto])).slides
    #expect(NoteSlideUpdate.updating(blurred, to: picked).updated.allSatisfy { $0.objects.first?.fill?.mediaScaleMode == nil })

    var blur = SlideOptions()
    blur.pictureScale = .scaleAndBlur
    let blurPick = try #require(DeterministicSlidePlanner(options: blur, pictureScaleChosen: true).plan([group], theme: theme, overrides: override).rows.first)
    #expect(blurPick.shownScale == .scaleAndBlur)
    #expect(NoteSlideBuilder.build(SlidePlan(rows: [blurPick])).slides.allSatisfy { $0.objects.first?.fill?.mediaScaleMode == .scaleAndBlur })

    #expect(try #require(DeterministicSlidePlanner(options: fill).plan([group], theme: nil, overrides: [:]).rows.first).shownScale == .fill)
}

@Test func picturesTogetherFindTheDesignWithThatManySpots() throws {
    var options = SlideOptions()
    options.picturesTogether = true
    let planner = DeterministicSlidePlanner(options: options)
    let three = MarkedGroup(id: "g", type: "picture", text: "", media: ["a", "b", "c", "d"])
    let row = try #require(planner.plan([three], theme: theme, overrides: [:]).rows.first)
    #expect(row.themeSlideName == "3 Photos" && row.photosPerSlide == 3)
    let built = NoteSlideBuilder.build(SlidePlan(rows: [row]))
    #expect(built.slides.map(\.objects.count) == [3, 1], "four pictures: three together, then one")

    let two = MarkedGroup(id: "g", type: "picture", text: "", media: ["a", "b"])
    #expect(planner.plan([two], theme: theme, overrides: [:]).rows.first?.themeSlideName == "2 Photos")
    let one = MarkedGroup(id: "g", type: "picture", text: "", media: ["a"])
    #expect(planner.plan([one], theme: theme, overrides: [:]).rows.first?.themeSlideName == nil)

    #expect(planner.plan([three], theme: nil, overrides: [:]).rows.first?.themeSlideName == nil)

    #expect(DeterministicSlidePlanner().plan([one], theme: theme, overrides: ["g": SlideRowOverride(themeSlideName: "Body")]).rows.first?.themeSlideName == nil)
}

@Test func theImportFillsPicturesInSpots() throws {
    let slide = Slide(id: "s", name: "", objects: [
        SlideObject.photo(mediaId: NoteMedia.pendingId(for: "k1"), scale: nil),
        SlideObject.photo(mediaId: NoteMedia.pendingId(for: "k2"), scale: nil),
    ])
    let filled = try #require(NoteMedia.filling([slide], remembered: [NoteMediaImport(key: "k1", mediaId: "m1")]))
    #expect(filled[0].objects.map { $0.fill?.mediaId } == ["m1"])
    #expect(filled[0].notes?.hasPrefix(Slide.needsMediaNote) == true)
}

@Test func updatingAPictureInASpotTakesTheScale() {
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["k"])
    var options = SlideOptions()
    options.pictureScale = .stretch
    let row = DeterministicSlidePlanner(options: options).plan([group], theme: theme, overrides: ["g": SlideRowOverride(themeSlideName: "Photo + Text")]).rows[0]
    let made = Slide(id: "s", name: "", objects: [SlideObject.photo(mediaId: "m", scale: .fit)])
    #expect(NoteSlideUpdate.updating([made], to: row).updated.first?.objects.first?.fill?.mediaScaleMode == .stretch)
}

@Test func picturesTogetherDecodesOffByDefault() throws {
    #expect(try JSONDecoder().decode(SlideOptions.self, from: Data("{}".utf8)).picturesTogether == false)
    #expect(try JSONDecoder().decode(SlideOptions.self, from: Data(#"{"picturesTogether":true}"#.utf8)).picturesTogether)
}

@Test(arguments: StarterPack.allCases)
func everyPackShipsPhotoDesignsInEachFolder(_ pack: StarterPack) {
    let slides = pack.makeTheme().slides ?? []
    let expected: [(String, String, Int, Bool)] = [
        ("Photo", "Full Slide", 1, false), ("Photo + Text", "Full Slide", 1, true),
        ("2 Photos", "Full Slide", 2, false), ("3 Photos", "Full Slide", 3, false),
        ("Photo + Text (Lower Third)", "Lower Thirds", 1, true), ("Photo (Lower Third)", "Lower Thirds", 1, false),
        ("Photo (Side Third)", "Side Thirds", 1, false), ("Photo + Text (Side Third)", "Side Thirds", 1, true),
    ]
    for (name, folder, spots, text) in expected {
        let design = slides.first { $0.name == name }
        #expect(design?.folder == folder, "\(pack.title)/\(name) folder")
        #expect(design?.photoSpots.count == spots, "\(pack.title)/\(name) spots")
        #expect(design?.objects.contains { $0.objectKind == .text } == text, "\(pack.title)/\(name) words")
        #expect(design?.objects.allSatisfy { !$0.isPhotoSpot || !($0.animationSteps ?? []).isEmpty } == true, "\(pack.title)/\(name) spots arrive")
        #expect(design?.objects.allSatisfy { ($0.animationSteps ?? []).allSatisfy { $0.kind != .out } } == true, "\(pack.title)/\(name) never leaves on a click")
    }
}

@Test func theRepairTakesThePhotoLeavesOut() {
    let pack = StarterPack.digital
    let fresh = pack.makeTheme().slides ?? []
    let leave = AnimationStep(id: "leave", kind: .out, animation: .fade, trigger: .onClick, durationSeconds: 0.4)
    func leaving(_ slide: Slide) -> Slide {
        var s = slide
        s.objects[0].animationSteps = (s.objects[0].animationSteps ?? []) + [leave]
        s.animationOrder = (s.animationOrder ?? []) + [leave.id]
        return s
    }
    let stale = fresh.map { $0.id.hasPrefix("\(pack.themeID).photo") ? leaving($0) : $0 }
    #expect(stale != fresh)
    #expect(pack.stayingPhotos(stale) == fresh)
    let mine = leaving(Slide(id: "mine", name: "My Photo", objects: [SlideObject(id: "p", objectKind: .shape, name: "Photo", text: "")]))
    #expect(pack.stayingPhotos(fresh + [mine]) == fresh + [mine])
}

@Test func theRepairAddsPhotoDesignsAndKeepsTheUsersOwn() {
    let pack = StarterPack.cleanGeometric
    var mine = Slide(id: "mine", name: "Photo", objects: [])
    mine.folder = "Full Slide"
    let seeded = (pack.makeTheme().slides ?? []).filter { !$0.id.hasPrefix("\(pack.themeID).photo") }
    let repaired = pack.addingPhotoDesigns(to: seeded + [mine])
    #expect(repaired.filter { $0.name == "Photo" }.map(\.id) == ["mine"], "a design the user calls Photo keeps its place")
    #expect(repaired.contains { $0.name == "3 Photos" } && repaired.contains { $0.name == "Photo (Side Third)" })
    let lower = repaired.firstIndex { $0.name == "Photo + Text (Lower Third)" } ?? -1
    #expect(repaired[lower - 1].folder == "Lower Thirds", "joins the end of its folder")
    #expect(pack.addingPhotoDesigns(to: repaired) == repaired)
}

@Test func twoPicturesWithOneFileNameDownloadApart() {
    let picture = NoteBlock(type: .image, url: "/rails/active_storage/blobs/a/image.png")
    let twin = NoteBlock(type: .image, url: "/rails/active_storage/blobs/b/image.png")
    let folder = URL(fileURLWithPath: "/tmp/run")
    let first = NoteMedia.downloadURL(of: picture, index: 0, in: folder)
    let second = NoteMedia.downloadURL(of: twin, index: 1, in: folder)
    #expect(first != second && first.lastPathComponent == "image.png" && second.lastPathComponent == "image.png")
}

@Test func wordsNeverLandOnAPhotoDesignByName() {
    for pack in StarterPack.allCases {
        let theme = pack.makeTheme()
        for kind in SlideKind.allCases where kind != .picture {
            let name = NoteSlideBuilder.designName(for: kind, in: theme)
            #expect(theme.slides?.first { $0.name == name }?.photoSpots.isEmpty ?? true, "\(pack.title) \(kind) landed on \(name ?? "")")
        }
    }
}

@Test func aSpotFillsUnlessTheScaleSaysOtherwise() {
    #expect(MediaScaleMode.scaleAndBlur.inPhotoSpot == .fill)
    #expect(MediaScaleMode.fit.inPhotoSpot == .fit && MediaScaleMode.stretch.inPhotoSpot == .stretch)
    let group = MarkedGroup(id: "g", type: "picture", text: "", media: ["k"])
    var options = SlideOptions()
    options.pictureScale = .fit
    let row = DeterministicSlidePlanner(options: options).plan([group], theme: theme, overrides: ["g": SlideRowOverride(themeSlideName: "Photo + Text")]).rows[0]
    #expect(NoteSlideBuilder.build(SlidePlan(rows: [row])).slides[0].objects.first?.fill?.mediaScaleMode == .fit)
    let made = Slide(id: "s", name: "", objects: [SlideObject.photo(mediaId: "m", scale: .fit)])
    let blurRow = DeterministicSlidePlanner().plan([group], theme: theme, overrides: ["g": SlideRowOverride(themeSlideName: "Photo + Text")]).rows[0]
    #expect(NoteSlideUpdate.updating([made], to: blurRow).updated.first?.objects.first?.fill?.mediaScaleMode == nil)
}
