import Foundation
import Metal
import simd
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

    @Test func withoutLayerMediaKeepsOnlySlideMediaAndPlaceholders() {
        var slide = Slide(id: "s", name: "", objects: [
            SlideObject(id: "m", objectKind: .media, name: "Logo", text: "", mediaId: "logo")
        ])
        slide.background = CueMedia(mediaId: "motion", mode: nil, layer: .loopingVideos, loops: true)
        var camera = noteSlide
        camera.background = CueMedia(mediaId: "input::cam", mode: nil, layer: .loopingVideos, loops: nil)
        let canvas = CGSize(width: 1920, height: 1080)
        let keep: (String) -> Bool = { $0.hasPrefix("input::") }
        func mediaIDs(_ scene: RenderScene) -> Set<String> {
            Set(scene.layers.flatMap(\.items).compactMap {
                switch $0.content {
                case .media(let id, _, _): id
                case .shape(let style): if case .media(let id, _, _) = style.fill { id } else { nil }
                default: nil
                }
            })
        }
        let built = SlideSceneBuilder.scene(for: slide, theme: nil, canvasSize: canvas)
        #expect(mediaIDs(built) == ["motion", "logo"])
        #expect(mediaIDs(SlideSceneBuilder.withoutLayerMedia(built, keep: keep)) == ["logo"])
        let input = SlideSceneBuilder.scene(for: camera, theme: nil, canvasSize: canvas)
        #expect(mediaIDs(SlideSceneBuilder.withoutLayerMedia(input, keep: keep)) == ["input::cam"])
    }

    @Test func posterLookSceneShowsTheStillWithTheItemChain() throws {
        let canvas = CGSize(width: 1440, height: 1080)
        let grain = SceneEffect(kind: .grain(amount: 0.3, size: 1, speed: 1))
        let scene = SlideSceneBuilder.posterLookScene(
            mediaID: "motion", stillID: "thumb::motion", canvas: canvas, effects: [grain])
        #expect(scene.canvasSize == canvas)
        let items = scene.layers.flatMap(\.items)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.content == .media(id: "thumb::motion", scaleMode: .fill, sourceRect: nil))
        #expect(item.frame == CGRect(origin: .zero, size: canvas))
        #expect(item.effects == [grain])
    }

    private final class RedStill: MediaTextureSource, @unchecked Sendable {
        let texture: MTLTexture

        init?(device: MTLDevice) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i + 2] = 255
                bytes[i + 3] = 255
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8 * 4)
            self.texture = texture
        }

        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
            mediaID == "thumb::motion"
                ? .bgra(
                    texture: texture,
                    transform: VideoColorTransform(
                        ycbcrMatrix: matrix_identity_float3x3, ycbcrOffset: .zero,
                        gamutToWorking: matrix_identity_float3x3, premultipliedAlpha: false),
                    retained: [])
                : nil
        }
    }

    @Test func posterLookSceneRendersTheChainOverTheStill() throws {
        if let device = MTLCreateSystemDefaultDevice(), let still = RedStill(device: device) {
            let compositor = try Compositor(device: device)
            compositor.mediaSource = still
            let canvas = CGSize(width: 1920, height: 1080)
            func center(_ effects: [SceneEffect]) throws -> SIMD4<Float> {
                let frame = try compositor.renderFrame(
                    scene: SlideSceneBuilder.posterLookScene(
                        mediaID: "motion", stillID: "thumb::motion", canvas: canvas, effects: effects),
                    width: 96, height: 54, transparentBackground: true)
                var out = SIMD4<Float>()
                frame.data.withUnsafeBytes { raw in
                    let halves = (raw.baseAddress! + 27 * frame.bytesPerRow + 48 * 8)
                        .assumingMemoryBound(to: Float16.self)
                    out = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
                }
                return out
            }
            let plain = try center([])
            let inverted = try center([SceneEffect(kind: .invert)])
            #expect(plain.x > 0.9 && plain.y < 0.1, "the plain still is red")
            #expect(inverted.x < 0.1 && inverted.y > 0.9 && inverted.z > 0.9, "the chain ran: red reads cyan")
        }
    }
}
