import CoreGraphics
import Testing
@testable import RenderEngine

private let canvas = CGSize(width: 1920, height: 1080)

private func scene(_ item: RenderItem) -> RenderScene {
    var scene = RenderScene(canvasSize: canvas)
    scene.addItem(item, to: .stillGraphics)
    return scene
}

private func items(_ scene: RenderScene) -> [RenderItem] {
    scene.layers.flatMap(\.items)
}

@Test func scaleAndBlurIsABlurredFillUnderTheFitPicture() throws {
    let item = RenderItem(id: "p", frame: CGRect(origin: .zero, size: canvas), content: .media(id: "m", scaleMode: .scaleAndBlur))
    let out = items(MediaLooks.expanding(scene(item)) { _ in nil })
    #expect(out.map(\.id) == ["p#scalebg", "p"])
    #expect(out[0].content == .media(id: "m", scaleMode: .fill, sourceRect: MediaLooks.zoomed(nil)))
    #expect(out[0].effects == [.blur(radius: 48)])

    #expect(out[0].frame == item.frame)
    let zoom = MediaLooks.zoomed(SceneSourceRect(x: 0.5, y: 0, width: 0.5, height: 1))
    #expect(abs(zoom.width - 0.5 / MediaLooks.backdropZoom) < 1e-9 && abs((zoom.x + zoom.width / 2) - 0.75) < 1e-9)
    #expect(out[1].content == .media(id: "m", scaleMode: .fit))

    let content = CGSize(width: 1000, height: 1000), frame = CGRect(origin: .zero, size: canvas)
    #expect(Compositor.mediaGeometry(contentSize: content, frame: frame, mode: .scaleAndBlur)
        == Compositor.mediaGeometry(contentSize: content, frame: frame, mode: .fit))
}

@Test func aSceneWithNothingToExpandIsUntouched() {
    let plain = scene(RenderItem(id: "p", frame: .zero, content: .media(id: "m")))
    #expect(MediaLooks.expanding(plain) { _ in 0 } == plain)
}

@Test func theEndFadeRunsOverTheLastSecond() {
    #expect(MediaLooks.endFadeAmount(remaining: nil) == 0)
    #expect(MediaLooks.endFadeAmount(remaining: 5) == 0)
    #expect(MediaLooks.endFadeAmount(remaining: 0.25) == 0.75)
    #expect(MediaLooks.endFadeAmount(remaining: 0) == 1)
}

@Test func fadeToClearFadesTheVideoOut() {
    var item = RenderItem(id: "v", frame: CGRect(origin: .zero, size: canvas), content: .media(id: "m"))
    item.endFade = .clear
    #expect(items(MediaLooks.expanding(scene(item)) { _ in 9 }).map(\.opacity) == [1])
    let fading = items(MediaLooks.expanding(scene(item)) { _ in 0.5 })
    #expect(fading.count == 1 && fading[0].opacity == 0.5)
}

@Test func fadeToBlackCoversTheVideoAndHolds() {
    var item = RenderItem(id: "v", frame: CGRect(origin: .zero, size: canvas), content: .media(id: "m", scaleMode: .scaleAndBlur))
    item.endFade = .black
    let ended = items(MediaLooks.expanding(scene(item)) { $0 == "m" ? 0 : nil })
    #expect(ended.map(\.id) == ["v#scalebg", "v", "v#endfade"])
    #expect(ended[2].content == .solid(.black) && ended[2].opacity == 1)
}

private final class EndingSource: MediaTextureSource, @unchecked Sendable {
    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { nil }
    func liveCadence(for mediaID: String) -> LiveCadence? { nil }
    func playbackRemaining(for mediaID: String, hostTime: CFTimeInterval) -> Double? { 0.5 }
}

@Test func theCompositorReadsTimeLeftFromTheSource() {
    let source: any MediaTextureSource = EndingSource()
    #expect(source.playbackRemaining(for: "m", hostTime: 0) == 0.5)
}

@Test func scaleAndBlurInAShapeIsClippedToItsOutline() throws {
    let style = ShapeStyle(
        kind: .roundedRectangle(cornerRadius: 20), fill: .media(id: "m", scaleMode: .scaleAndBlur),
        stroke: SceneStroke(color: .white, width: 4))
    let item = RenderItem(id: "spot", frame: CGRect(x: 100, y: 100, width: 400, height: 300), content: .shape(style))
    let out = items(MediaLooks.expanding(scene(item)) { _ in nil })
    #expect(out.map(\.id) == ["spot#spotmatte", "spot#scalebg", "spot"])
    #expect(out[0].matteGroup == "spot#spotmatte" && out[1].maskedBy == "spot#spotmatte")
    guard case .shape(let matte) = out[0].content, case .shape(let blurred) = out[1].content, case .shape(let picture) = out[2].content else {
        Issue.record("shapes expected")
        return
    }
    #expect(matte.fill == .solid(.white) && matte.stroke == nil)
    #expect(blurred.fill == .media(id: "m", scaleMode: .fill, sourceRect: MediaLooks.zoomed(nil)) && blurred.stroke == nil)
    #expect(out[1].effects == [.blur(radius: 48)])
    #expect(picture.fill == .media(id: "m", scaleMode: .fit) && picture.stroke != nil, "the picture keeps the border")
}
