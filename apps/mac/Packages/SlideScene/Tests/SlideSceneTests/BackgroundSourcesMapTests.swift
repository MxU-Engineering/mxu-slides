import Foundation
import PresenterCore
import Testing
@testable import SlideScene

private func slide(
    _ id: String, background: CueMedia? = nil, sectionId: String? = nil
) -> Slide {
    Slide(
        id: id, name: id,
        objects: [SlideObject(id: "\(id)-text", objectKind: .text, name: "Text", text: "hi")],
        background: background, sectionId: sectionId
    )
}

private func cue(
    _ mediaId: String, mode: CueMediaMode? = nil, layer: CueMediaLayer? = nil
) -> CueMedia {
    CueMedia(mediaId: mediaId, mode: mode, layer: layer)
}

private func expectEquivalent(
    _ presentation: Presentation, arrangementId: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let map = SlideSceneBuilder.backgroundSources(
        for: presentation, arrangementId: arrangementId
    )
    for slide in presentation.slides {
        let single = SlideSceneBuilder.backgroundSource(
            slide: slide, presentation: presentation, arrangementId: arrangementId
        )
        let batched = map[slide.id]
        #expect(
            single?.media == batched?.media && single?.source == batched?.source,
            "slide \(slide.id): per-slide \(String(describing: single)) vs map \(String(describing: batched))",
            sourceLocation: sourceLocation
        )
    }
}

@Suite struct BackgroundSourcesMapTests {
    @Test func coverageChainWithSlideOnlyAndForegroundDeclarations() {
        let deck = Presentation(
            id: "p", name: "Song", presentationKind: .deck, themeId: "",
            slides: [
                slide("a", background: cue("ocean", mode: .untilReplaced)),
                slide("b"),                                             
                slide("c", background: cue("bumper", layer: .videos)),  
                slide("d"),                                             
                slide("e", background: cue("logo", mode: .slideOnly)),  
                slide("f"),                                             
                slide("g", background: cue("fire", mode: .untilReplaced)),
                slide("h"),                                             
            ],
            background: cue("song-wide")
        )
        expectEquivalent(deck)
    }

    @Test func arrangementRepeatsAndExcludedSlidesFallBackToScopes() {
        let deck = Presentation(
            id: "p", name: "Song", presentationKind: .deck, themeId: "",
            slides: [
                slide("v1", background: cue("ocean", mode: .untilReplaced), sectionId: "verse"),
                slide("v2", sectionId: "verse"),
                slide("c1", sectionId: "chorus"),                        
                slide("br", sectionId: "bridge"),                        
                slide("out"),                                            
            ],
            background: cue("song-wide"),
            sections: [
                PresentationSection(id: "verse", name: "Verse"),
                PresentationSection(id: "chorus", name: "Chorus"),
                PresentationSection(id: "bridge", name: "Bridge", background: cue("bridge-bg")),
            ],
            arrangements: [

                Arrangement(id: "arr", name: "Live", sectionIds: ["verse", "chorus", "verse", "chorus"]),
            ]
        )
        expectEquivalent(deck, arrangementId: "arr")
        expectEquivalent(deck)  
    }

    @Test func noBackgroundsAnywhereYieldsEmptyMap() {
        let deck = Presentation(
            id: "p", name: "Song", presentationKind: .deck, themeId: "",
            slides: [slide("a"), slide("b")]
        )
        #expect(SlideSceneBuilder.backgroundSources(for: deck).isEmpty)
        expectEquivalent(deck)
    }
}

@Suite struct FireActionsTests {
    private func clear(_ layer: String) -> SlideAction {
        SlideAction(id: UUID().uuidString, kind: .clearLayer, layer: layer)
    }

    @Test func ownBackgroundLayerClearIsDropped() {

        var deck = slide("s", background: cue("give", layer: .stillGraphics))
        deck.actions = [
            clear("loopingVideos"), clear("stillGraphics"), clear("videos"),
            SlideAction(id: "combo", kind: .fireCombo, comboId: "c"),
        ]
        let fired = SlideSceneBuilder.fireActions(for: deck)
        #expect(fired.map { $0.layer ?? $0.kind.rawValue }
            == ["loopingVideos", "videos", "fireCombo"])
    }

    @Test func slideLayerClearNeverRunsOnOwnFire() {
        var deck = slide("s")
        deck.actions = [clear("slide"), clear("stillGraphics")]

        #expect(SlideSceneBuilder.fireActions(for: deck).map(\.layer) == ["stillGraphics"])
    }

    @Test func absentBackgroundLayerProtectsTheDefaultLayer() {
        var deck = slide("s", background: cue("bg"))  
        deck.actions = [clear("loopingVideos"), clear("videos")]
        #expect(SlideSceneBuilder.fireActions(for: deck).map(\.layer) == ["videos"])
    }

    @Test func fireMediaTargetsJoinTheProtectedSet() {

        var deck = slide("s", background: cue("bg"))
        var fire = SlideAction(id: "f", kind: .fireMedia)
        fire.mediaId = "logo"
        deck.actions = [fire, clear("stillGraphics"), clear("videos")]
        let protected = SlideSceneBuilder.protectedLayers(for: deck) { id in
            id == "logo" ? .stillGraphics : nil
        }
        #expect(protected == [.slide, .loopingVideos, .stillGraphics])
        let fired = SlideSceneBuilder.fireActions(for: deck, protected: protected)
        #expect(fired.map { $0.layer ?? $0.kind.rawValue } == ["fireMedia", "videos"])
    }

    @Test func unresolvedFireMediaProtectsNothingExtra() {

        var deck = slide("s")
        var fire = SlideAction(id: "f", kind: .fireMedia)
        fire.mediaId = "ghost"
        deck.actions = [fire]
        #expect(SlideSceneBuilder.protectedLayers(for: deck) { _ in nil } == [.slide])
    }
}
