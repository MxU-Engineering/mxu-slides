import CoreGraphics
import XCTest
@testable import RenderEngine

final class OutputScalingTests: XCTestCase {
    private let fourThree = CGSize(width: 1024, height: 768)
    private let wide = CGSize(width: 1920, height: 1080)

    private func scene() -> RenderScene {
        var scene = RenderScene(canvasSize: fourThree)
        let full = CGRect(origin: .zero, size: fourThree)
        scene.addItem(RenderItem(id: "bg", frame: full, content: .media(id: "loop", scaleMode: .fill)), to: .loopingVideos)
        scene.addItem(RenderItem(id: "s-backdrop", frame: full, content: .solid(.white)), to: .slide)
        scene.addItem(RenderItem(id: "lyric", frame: CGRect(x: 100, y: 600, width: 824, height: 100), content: .solid(.white)), to: .slide)
        scene.addItem(RenderItem(id: "still", frame: full, content: .media(id: "png", scaleMode: .fit)), to: .stillGraphics)
        return scene
    }

    private func frame(_ id: String, in scene: RenderScene) -> CGRect? {
        scene.layers.flatMap(\.items).first { $0.id == id }?.frame
    }

    func testFitGrowsTheCanvasAndBackgroundsCoverIt() {
        let fitted = scene().scaled(toScreen: wide, mode: .fit)
        XCTAssertEqual(fitted.canvasSize.height, 768)
        XCTAssertEqual(fitted.canvasSize.width, 768 * 16 / 9, accuracy: 0.001)
        let grown = CGRect(origin: .zero, size: fitted.canvasSize)

        XCTAssertEqual(frame("bg", in: fitted), grown)
        XCTAssertEqual(frame("s-backdrop", in: fitted), grown)

        let dx = (fitted.canvasSize.width - 1024) / 2
        XCTAssertEqual(frame("lyric", in: fitted), CGRect(x: 100 + dx, y: 600, width: 824, height: 100))
        XCTAssertEqual(frame("still", in: fitted), CGRect(x: dx, y: 0, width: 1024, height: 768))
    }

    func testFillCropsTheMiddle() {
        let filled = scene().scaled(toScreen: wide, mode: .fill)
        XCTAssertEqual(filled.canvasSize.width, 1024)
        XCTAssertEqual(filled.canvasSize.height, 576, accuracy: 0.001)

        XCTAssertEqual(frame("lyric", in: filled), CGRect(x: 100, y: 504, width: 824, height: 100))
        XCTAssertEqual(frame("bg", in: filled), CGRect(x: 0, y: -96, width: 1024, height: 768))
    }

    func testTallScreenGrowsTheCanvasDown() {
        let fitted = scene().scaled(toScreen: CGSize(width: 1080, height: 1920), mode: .fit)
        XCTAssertEqual(fitted.canvasSize.width, 1024)
        XCTAssertEqual(fitted.canvasSize.height, 1024 * 16 / 9, accuracy: 0.001)
        XCTAssertEqual(frame("lyric", in: fitted)?.minX, 100)
    }

    func testSameShapeIsUnchanged() {
        let original = scene()
        XCTAssertEqual(original.scaled(toScreen: CGSize(width: 2048, height: 1536), mode: .fill), original)
        XCTAssertEqual(original.scaled(toScreen: .zero, mode: .fit), original)
    }
}
