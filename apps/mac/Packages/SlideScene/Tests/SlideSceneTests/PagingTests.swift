import CoreGraphics
import Foundation
import Testing
import PresenterCore
import RenderEngine
@testable import SlideScene

@MainActor
struct PagingTests {
    private let verse = (0..<120).map { ["grace", "how", "sweet", "the", "sound", "that", "saved", "a", "wretch"][$0 % 9] }.joined(separator: " ")
    private var slide: Slide {
        Slide(id: "s", name: "Scripture", objects: [
            SlideObject(id: "ref", objectKind: .text, name: "Reference", text: "Psalm 1:1-6"),
            SlideObject(id: "verse", objectKind: .text, name: "Verse", text: verse),
        ], themeSlideName: "Scripture")
    }
    private let digital = StarterPack.digital.makeTheme()
    private var sideThirds: Theme { digital.scoped(toSlideFolder: "Side Thirds") }

    @Test func aPagingLookTurnsOverflowIntoClickPagesBeforeTheLeave() {
        var s = slide
        s.setOverrideDesign("Verse + Reference (Side Third)", forTheme: digital.id)
        let r = s.rendered(throughOverride: sideThirds)
        let pages = Paging.pages(of: r, theme: sideThirds)
        #expect(pages.count > 1)
        #expect(pages[0].objects[1].text.count < verse.count, "page 1 is the first cut")
        #expect(pages.allSatisfy { $0.objects[0].text == "Psalm 1:1-6" }, "the reference fits, so it never pages")
        let composition = PlaceholderAnimations.stackComposition(slide: r, theme: sideThirds)
        let groups = AnimationSequence.groups(objects: composition.objects, order: composition.order)
        #expect(groups.click.count == pages.count, "pages minus one, plus the design's click-off Out")
        for turn in groups.click.dropLast() {
            #expect(turn.first?.step.kind == .morph && turn.first?.step.id.contains(Paging.stepMarker) == true)
        }
        #expect(groups.click.last?.contains { $0.step.kind == .out } == true, "the Out is the last click")
        let composed = composition.objects.first { $0.id == "verse" }
        #expect(composed?.text == pages[0].objects[1].text, "the composed object shows page 1")
        #expect(composed?.animationSteps?.last?.toObject?.text == pages.last?.objects[1].text)
    }

    @Test func theProjectorsDesignHoldsTheWholeTextAndCountsNoPages() {
        let projector = PlaceholderAnimations.stackComposition(slide: slide, theme: digital)
        #expect(projector.objects.first { $0.id == "verse" }?.text == verse)
        #expect(Paging.pageCount(of: slide, theme: digital) == 1)
        var show = ShowState()
        show.slideThemeOverrides = [sideThirds]
        var s = slide
        s.setOverrideDesign("Verse + Reference (Side Third)", forTheme: digital.id)

        show.fire(slide: s, theme: nil, atHostTime: 1)
        let pages = Paging.pageCount(of: s.rendered(throughOverride: sideThirds), theme: sideThirds)
        #expect(show.slideClickCount == pages, "pages minus one, plus the Out")
    }

    @Test func ownFramedSlidesPageThroughTheLookNotTheirOwnBox() {
        var own = slide
        own.objects[1].x = 172; own.objects[1].y = 150; own.objects[1].width = 1575; own.objects[1].height = 810
        own.objects[1].textStyle = TextStyle(fontName: "HelveticaNeue", fontSize: 42)
        #expect(Paging.pages(of: own, theme: sideThirds).count == 1, "raw: its own box holds it")
        let pages = Paging.pages(of: own, through: sideThirds, from: digital)
        #expect(pages.count > 1, "through the look: the column pages it")
        #expect(pages.allSatisfy { $0.objects[1].x == nil && $0.objects[1].textStyle == nil }, "page slides render as the output does")
        #expect(Paging.pages(of: own, through: sideThirds, from: nil).count == pages.count, "a deck whose theme is missing still pages through the look")

        var short = own
        short.objects[1].text = "Blessed is the one"
        let leave = PlaceholderAnimations.clickCount(slide: short, themes: [nil, sideThirds])
        #expect(PlaceholderAnimations.clickCount(slide: own, themes: [nil, sideThirds]) == leave + pages.count - 1,
                "the page turns, then the design's own leave, through the look")
        #expect(PlaceholderAnimations.clickCount(slide: own, themes: [nil, sideThirds], paging: false) == leave,
                "the body's cheap count skips the page measuring")
        var show = ShowState()
        show.slideThemeOverrides = [sideThirds]
        show.fire(slide: own, theme: nil, atHostTime: 1)
        #expect(show.slideClickCount == leave + pages.count - 1, "the advance bookkeeping sees the pages the output turns")
    }

    @Test func thumbnailsShowPageOneAndAFittingTextNeverPages() {
        var s = slide
        s.setOverrideDesign("Verse + Reference (Side Third)", forTheme: digital.id)
        let r = s.rendered(throughOverride: sideThirds)
        let scene = SlideSceneBuilder.scene(for: r, theme: sideThirds, animationContext: .settled)
        #expect(scene.layers.flatMap(\.items).contains { $0.animationSteps.contains { $0.id.contains(Paging.stepMarker) } })
        let peak = SlideSceneBuilder.peakLook(scene)
        #expect(peak.layers.flatMap(\.items).allSatisfy { !$0.animationSteps.contains { $0.id.contains(Paging.stepMarker) } })
        var short = r
        short.objects[1].text = "Blessed is the one"
        #expect(Paging.pages(of: short, theme: sideThirds).count == 1)
        #expect(AnimationSequence.clickCount(objects: PlaceholderAnimations.stackComposition(slide: short, theme: sideThirds).objects,
                                             order: PlaceholderAnimations.stackComposition(slide: short, theme: sideThirds).order) == 1,
                "just the click-off Out")
    }
}
