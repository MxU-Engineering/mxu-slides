import Foundation
import Metal
import Testing
import PresenterCore
import RenderEngine
@testable import SlideScene

@MainActor
struct ThumbnailPeakLookTests {
    private func ink(_ frame: RenderedFrame) -> Int {
        var count = 0
        frame.data.withUnsafeBytes { raw in
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
                    if Float(base.assumingMemoryBound(to: Float16.self)[3]) > 0.05 { count += 1 }
                }
            }
        }
        return count
    }

    private let noteSlide = Slide(
        id: "note", name: "Scripture",
        objects: [SlideObject(id: "t", objectKind: .text, name: "Scripture", text: "Blessed is the one who does not walk in step with the wicked")],
        themeSlideName: "Scripture")
    private let sideThirds = StarterPack.digital.makeTheme().scoped(toSlideFolder: "Side Thirds")

    @Test func peakLookDropsEveryExitStepIncludingDecorAndDonated() {
        let settled = SlideSceneBuilder.scene(
            for: noteSlide, theme: sideThirds, canvasSize: CGSize(width: 1920, height: 1080), animationContext: .settled)
        let items = settled.layers.flatMap(\.items)

        #expect(items.contains { $0.id == "t" && $0.animationSteps.contains { $0.kind == .exit } })
        #expect(items.contains { $0.id.hasPrefix("theme-") && $0.animationSteps.contains { $0.kind == .exit } })
        let peak = SlideSceneBuilder.peakLook(settled).layers.flatMap(\.items)
        #expect(peak.allSatisfy { !$0.animationSteps.contains { $0.kind == .exit } })
        #expect(peak.flatMap(\.animationSteps).contains { $0.kind == .enter }, "Ins stay: the tile shows the arrived look")
    }

    @Test func noteSlideThroughSideThirdsRendersInkAtPeak() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let compositor = try Compositor()
        let canvas = CGSize(width: 1920, height: 1080)
        let settled = SlideSceneBuilder.scene(for: noteSlide, theme: sideThirds, canvasSize: canvas, animationContext: .settled)
        let blank = try compositor.renderFrame(scene: settled, width: 480, height: 270, transparentBackground: true)
        #expect(ink(blank) == 0, "the bug: settled plays the click Outs")
        let peak = try compositor.renderFrame(
            scene: SlideSceneBuilder.peakLook(settled), width: 480, height: 270, transparentBackground: true)
        #expect(ink(peak) > 200)
    }

    @Test func lookKeyTellsFolderScopesAndOverrideDesignsApart() {
        let theme = StarterPack.digital.makeTheme()
        let whole = SlideSceneBuilder.lookKey(for: noteSlide, theme: theme)
        let side = SlideSceneBuilder.lookKey(for: noteSlide, theme: theme.scoped(toSlideFolder: "Side Thirds"))
        let lower = SlideSceneBuilder.lookKey(for: noteSlide, theme: theme.scoped(toSlideFolder: "Lower Thirds"))
        #expect(Set([whole, side, lower]).count == 3)
        #expect(side.hasPrefix(theme.id + "|"))
        var chosen = noteSlide
        chosen.themeSlideName = "Verse + Reference (Side Third)"
        #expect(SlideSceneBuilder.lookKey(for: chosen, theme: theme.scoped(toSlideFolder: "Side Thirds")) != side)
        #expect(SlideSceneBuilder.lookKey(for: noteSlide, theme: nil) == "|")
    }
}
