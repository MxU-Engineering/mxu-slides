import PresenterCore
import Testing
@testable import SlideScene

private func slide(_ id: String, section: String? = nil) -> Slide {
    var s = Slide(id: id, name: id, objects: [])
    s.sectionId = section
    return s
}

private func song() -> Presentation {
    var song = Presentation(
        id: "p", name: "Song", presentationKind: .deck, themeId: "",
        slides: [
            slide("v1a", section: "v1"), slide("v1b", section: "v1"),
            slide("c1", section: "c"),
            slide("v2a", section: "v2"),
        ]
    )
    song.sections = [
        PresentationSection(id: "v1", name: "Verse 1"),
        PresentationSection(id: "c", name: "Chorus"),
        PresentationSection(id: "v2", name: "Verse 2"),
    ]
    song.arrangements = [
        Arrangement(id: "sunday", name: "Sunday", sectionIds: ["v1", "c", "v2", "c"]),
    ]
    return song
}

@Test func blockSectionNamesAlignWithPillStarts() {
    let names = SlideSceneBuilder.blockSectionNames(for: song(), arrangementId: "sunday")
    #expect(names.map(\.start) == [0, 2, 3, 4])
    #expect(names.map(\.normalizedName) == ["verse1", "chorus", "verse2", "chorus"])

    let base = SlideSceneBuilder.blockSectionNames(for: song())
    #expect(base.map(\.start) == [0, 2, 3])
    #expect(base.map(\.normalizedName) == ["verse1", "chorus", "verse2"])
}

@Test func hotKeyJumpsToFirstMatchFromOutside() {

    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), arrangementId: "sunday", matching: ["chorus"], liveIndex: 0) == 2)
    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), arrangementId: "sunday", matching: ["chorus"], liveIndex: nil) == 2)

    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), matching: ["chorus", "chorus1"], liveIndex: nil) == 2)
}

@Test func hotKeyCyclesThroughRepeatedBlocks() {

    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), arrangementId: "sunday", matching: ["chorus"], liveIndex: 2) == 4)

    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), arrangementId: "sunday", matching: ["chorus"], liveIndex: 4) == 2)
}

@Test func hotKeyMissesQuietly() {
    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), arrangementId: "sunday", matching: ["bridge"], liveIndex: 0) == nil)
    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: song(), matching: [], liveIndex: 0) == nil)
}

@Test func hotKeySkipsZeroWidthBlocks() {

    var withEmpty = song()
    withEmpty.sections?.append(PresentationSection(id: "b", name: "Bridge"))
    withEmpty.arrangements = [
        Arrangement(id: "a", name: "A", sectionIds: ["v1", "b", "c"]),
    ]
    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: withEmpty, arrangementId: "a", matching: ["bridge"], liveIndex: 0) == nil)

    #expect(SlideSceneBuilder.hotKeyJumpStart(
        for: withEmpty, arrangementId: "a", matching: ["chorus"], liveIndex: 0) == 2)
}
