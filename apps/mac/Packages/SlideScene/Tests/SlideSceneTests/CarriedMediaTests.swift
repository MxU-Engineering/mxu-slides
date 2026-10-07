import Foundation
import PresenterCore
import RenderEngine
import Testing
@testable import SlideScene

private let facts: [String: SlideSceneBuilder.MediaFacts] = [
    "bg-video": (.video, .background),
    "bg-still": (.image, .background),
    "fg-video": (.video, .foreground),
    "fg-still": (.image, .foreground),
]

private func slide(
    _ id: String, background: CueMedia? = nil, actions: [SlideAction] = [], sectionId: String? = nil
) -> Slide {
    var s = Slide(id: id, name: id, objects: [])
    s.background = background
    s.actions = actions.isEmpty ? nil : actions
    s.sectionId = sectionId
    return s
}

private func fire(_ mediaId: String, delay: Double? = nil) -> SlideAction {
    SlideAction(id: UUID().uuidString, kind: .fireMedia, mediaId: mediaId, delaySeconds: delay)
}

private func clear(_ layer: LayerKind, delay: Double? = nil) -> SlideAction {
    SlideAction(id: UUID().uuidString, kind: .clearLayer, layer: layer.rawValue, delaySeconds: delay)
}

private func deck(_ slides: [Slide]) -> Presentation {
    Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: slides)
}

private func carried(_ presentation: Presentation, _ index: Int) -> [LayerKind: String] {
    SlideSceneBuilder.carriedMedia(for: presentation.slides[index], presentation: presentation) { facts[$0] }
}

@Suite struct CarriedMediaTests {
    @Test func backgroundFiresPersistUnderFollowingSlidesAndForegroundsLeave() {
        let deck = deck([
            slide("a", actions: [fire("bg-video")]),
            slide("b", actions: [fire("fg-video"), fire("fg-still")]),
            slide("c"),
            slide("d", actions: [fire("bg-still")]),
        ])
        #expect(carried(deck, 0) == [.loopingVideos: "bg-video"])
        #expect(carried(deck, 1) == [.loopingVideos: "bg-video", .videos: "fg-video", .stillGraphics: "fg-still"],
                "the slide's own fires show on it, over and under the slide layer")
        #expect(carried(deck, 2) == [.loopingVideos: "bg-video"], "foregrounds sweep on the next fire; the background stays")
        #expect(carried(deck, 3) == [.loopingVideos: "bg-still"], "a background still replaces on Background Media")
    }

    @Test func clearsEndCoverageButNeverStripTheSlidesOwnFire() {
        let deck = deck([
            slide("a", actions: [fire("bg-video"), clear(.loopingVideos)]),
            slide("b", actions: [clear(.loopingVideos)]),
            slide("c", actions: [fire("bg-video"), clear(.loopingVideos, delay: 5)]),
            slide("d", actions: [SlideAction(id: "all", kind: .clearAll), fire("fg-still")]),
            slide("e"),
        ])
        #expect(carried(deck, 0) == [.loopingVideos: "bg-video"], "a clear of the layer its own fire lands on is filtered, the 2026-08-20 rule")
        #expect(carried(deck, 1) == [:], "the next slide's clear takes it down")
        #expect(carried(deck, 2) == [.loopingVideos: "bg-video"], "a delayed clear runs past the fire instant")
        #expect(carried(deck, 3) == [.stillGraphics: "fg-still"], "Clear All sweeps what it may and the protected fire lands")
        #expect(carried(deck, 4) == [:])
    }

    @Test func effectiveBackgroundRidesItsLayerAndReFiredStillsSurviveTheSweep() {
        let deck = deck([
            slide("a", background: CueMedia(mediaId: "bg-video", mode: .untilReplaced, layer: .loopingVideos)),
            slide("b", actions: [fire("fg-still")]),
            slide("c", actions: [fire("fg-still")]),
            slide("d", background: CueMedia(mediaId: "own", mode: .slideOnly, layer: .stillGraphics)),
            slide("e"),
        ])
        #expect(carried(deck, 1) == [.loopingVideos: "bg-video", .stillGraphics: "fg-still"])
        #expect(carried(deck, 2) == [.loopingVideos: "bg-video", .stillGraphics: "fg-still"], "a still the incoming slide re-fires is not swept")
        #expect(carried(deck, 3) == [.loopingVideos: "bg-video", .stillGraphics: "own"], "the declared background lands where it says; the range still covers")
        #expect(carried(deck, 4) == [.loopingVideos: "bg-video", .stillGraphics: "own"],
                "a slideOnly declaration ends the DECLARED range, but the glass keeps playing both — the persistence the canvas exists to show")

        let loose = slide("z", actions: [fire("gone"), fire("bg-video")])
        #expect(SlideSceneBuilder.carriedMedia(for: loose, presentation: deck) { facts[$0] } == [.loopingVideos: "bg-video"])
    }

    @Test func batchMapMatchesThePerSlideWalk() {
        var deck = deck([
            slide("a", actions: [fire("bg-video")], sectionId: "s1"),
            slide("b", actions: [fire("fg-video"), clear(.loopingVideos, delay: 2)], sectionId: "s1"),
            slide("c", background: CueMedia(mediaId: "bg-still", mode: .untilReplaced, layer: .loopingVideos), sectionId: "s2"),
            slide("d", actions: [SlideAction(id: "all", kind: .clearAll), fire("fg-still")], sectionId: "s2"),
            slide("e", actions: [fire("gone")], sectionId: "s2"),
            slide("loose", actions: [fire("bg-still")]),
        ])
        deck.sections = [PresentationSection(id: "s1", name: "One"), PresentationSection(id: "s2", name: "Two")]
        deck.arrangements = [Arrangement(id: "arr", name: "Arr", sectionIds: ["s1", "s2", "s1"])]
        for arrangementId in [nil, "arr"] {
            let map = SlideSceneBuilder.carriedMediaMap(for: deck, arrangementId: arrangementId) { facts[$0] }
            for slide in deck.slides {
                let single = SlideSceneBuilder.carriedMedia(
                    for: slide, presentation: deck, arrangementId: arrangementId) { facts[$0] }
                #expect(map[slide.id] == single, "slide \(slide.id), arrangement \(arrangementId ?? "base")")
            }
        }
        #expect(SlideSceneBuilder.carriedMediaMap(for: deck, arrangementId: "arr") { facts[$0] }["loose"] == [.loopingVideos: "bg-still"],
                "a slide the arrangement omits previews its own fire alone")
    }

    @Test func sceneCompositesCarriedMediaOnItsLayersOnce() {
        let deck = deck([slide("a", background: CueMedia(mediaId: "bg-video", layer: .loopingVideos))])
        let scene = SlideSceneBuilder.scene(
            for: deck.slides[0], theme: nil, presentation: deck,
            carriedMedia: [.loopingVideos: "bg-video", .stillGraphics: "fg-still", .videos: "fg-video"]
        )
        func ids(_ kind: LayerKind) -> [String] {
            scene.layers.first { $0.kind == kind }?.items.map(\.id) ?? []
        }
        #expect(ids(.loopingVideos) == ["a-cue-background"], "the cue background already fills its layer with that id")
        #expect(ids(.stillGraphics) == ["a-carried-stillGraphics"])
        #expect(ids(.videos) == ["a-carried-videos"])
        let replaced = SlideSceneBuilder.scene(
            for: deck.slides[0], theme: nil, presentation: deck, carriedMedia: [.loopingVideos: "bg-still"]
        )
        #expect(ids(.loopingVideos).count == 1 && replaced.layers.first { $0.kind == .loopingVideos }?.items.count == 2,
                "a different id on the background's layer stacks over the cue background")
    }
}
