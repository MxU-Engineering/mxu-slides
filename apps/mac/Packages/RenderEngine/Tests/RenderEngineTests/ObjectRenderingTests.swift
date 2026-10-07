import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class ObjectRenderingTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> SIMD4<Float> {
        var out = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
            let halves = base.assumingMemoryBound(to: Float16.self)
            out = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        return out
    }

    private func renderItem(
        _ item: RenderItem,
        background: SceneColor = .black,
        to layer: LayerKind = .slide
    ) throws -> RenderedFrame {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = background
        scene.addItem(item, to: layer)
        return try compositor.renderFrame(scene: scene, width: 192, height: 108)
    }

    func testInsetDrawsOffCanvasContentInTheBand() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))

        scene.addItem(
            RenderItem(id: "off", frame: CGRect(x: 150, y: 40, width: 100, height: 28), content: .solid(.white)),
            to: .slide
        )

        let frame = try compositor.renderFrame(
            scene: scene, width: 292, height: 208, transparentBackground: true, inset: 50)
        XCTAssertEqual(pixel(frame, x: 50 + 170, y: 50 + 54).w, 1, accuracy: 0.01, "on the canvas")
        XCTAssertEqual(pixel(frame, x: 50 + 220, y: 50 + 54).w, 1, accuracy: 0.01, "past the canvas edge, in the band")
        XCTAssertEqual(pixel(frame, x: 50 + 100, y: 50 + 54).w, 0, accuracy: 0.01, "empty canvas stays clear")
        XCTAssertEqual(pixel(frame, x: 20, y: 20).w, 0, accuracy: 0.01, "the band stays clear where nothing hangs")
    }

    func testOpacityScalesContribution() throws {
        let item = RenderItem(
            id: "o",
            frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(.white),
            opacity: 0.5
        )
        let frame = try renderItem(item)
        let center = pixel(frame, x: 96, y: 54)

        XCTAssertEqual(center.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(center.z, 0.5, accuracy: 0.01)
    }

    func testAddBlendSumsChannels() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        let full = CGRect(x: 0, y: 0, width: 192, height: 108)
        scene.addItem(
            RenderItem(id: "g", frame: full, content: .solid(SceneColor(red: 0, green: 1, blue: 0))),
            to: .stillGraphics
        )
        scene.addItem(
            RenderItem(
                id: "r", frame: full,
                content: .solid(SceneColor(red: 1, green: 0, blue: 0)),
                blendMode: .add
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 1, accuracy: 0.01, "red adds")
        XCTAssertEqual(center.y, 1, accuracy: 0.01, "green survives")
    }

    func testMultiplyBlendWithTransparentSourceLeavesDestination() throws {

        let gray = SceneColor(red: 0.5, green: 0.5, blue: 0.5)
        let clearMultiply = RenderItem(
            id: "m",
            frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(.clear),
            blendMode: .multiply
        )
        let with = try renderItem(clearMultiply, background: gray)
        let compositor = try makeCompositor()
        var plain = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        plain.background = gray
        let without = try compositor.renderFrame(scene: plain, width: 192, height: 108)
        XCTAssertEqual(with.data, without.data)
    }

    func testMultiplyAndScreenBlendMath() throws {
        let half = SceneColor(red: 0.5, green: 0.5, blue: 0.5)
        let linear = Float(half.linear.x)
        for (mode, expected): (SceneBlendMode, Float) in [
            (.multiply, linear * linear),
            (.screen, linear + linear * (1 - linear)),
        ] {
            let item = RenderItem(
                id: "b",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(half),
                blendMode: mode
            )
            let frame = try renderItem(item, background: half)
            let center = pixel(frame, x: 96, y: 54)
            XCTAssertEqual(center.x, expected, accuracy: 0.01, "\(mode) math")
        }
    }

    func testRotationSwapsInkAspect() throws {
        let wide = RenderItem(
            id: "r",
            frame: CGRect(x: 46, y: 44, width: 100, height: 20),
            content: .solid(.white),
            rotationDegrees: 90
        )
        let frame = try renderItem(wide)

        XCTAssertEqual(pixel(frame, x: 50, y: 54).x, 0, accuracy: 0.02, "left of frame now empty")
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 10).x, 0.9, "above frame now filled")
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "center stays filled")
    }

    private func shapeItem(_ style: ShapeStyle, frame: CGRect) -> RenderItem {
        RenderItem(id: "s", frame: frame, content: .shape(style))
    }

    func testRectangleFillsFrameAndNotOutside() throws {
        let style = ShapeStyle(kind: .rectangle, fill: .solid(SceneColor(red: 1, green: 0, blue: 0)))
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 27, width: 96, height: 54)))
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "inside is filled")
        XCTAssertEqual(pixel(frame, x: 24, y: 54).x, 0, accuracy: 0.02, "outside stays background")
    }

    func testEllipseAndRoundedCornersLeaveCornersEmpty() throws {
        for kind: SceneShapeKind in [.ellipse, .roundedRectangle(cornerRadius: 20)] {
            let style = ShapeStyle(kind: kind, fill: .solid(.white))
            let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 27, width: 96, height: 54)))
            XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "center filled for \(kind)")
            XCTAssertEqual(pixel(frame, x: 49, y: 28).x, 0, accuracy: 0.05,
                           "frame corner empty for \(kind)")
        }
    }

    func testLinearGradientRunsAlongItsAngle() throws {
        let style = ShapeStyle(
            kind: .rectangle,
            fill: .linearGradient(angleDegrees: 0, stops: [
                SceneGradientStop(color: .black, position: 0),
                SceneGradientStop(color: .white, position: 1),
            ])
        )
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 0, y: 0, width: 192, height: 108)))
        let left = pixel(frame, x: 10, y: 54).x
        let right = pixel(frame, x: 182, y: 54).x
        XCTAssertLessThan(left, 0.1)
        XCTAssertGreaterThan(right, 0.85)
        XCTAssertGreaterThan(pixel(frame, x: 140, y: 54).x, pixel(frame, x: 50, y: 54).x)
    }

    func testStrokeOnlyShapeDrawsBorderNotInterior() throws {
        let style = ShapeStyle(
            kind: .rectangle,
            fill: .none,
            stroke: SceneStroke(color: .white, width: 4)
        )
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 27, width: 96, height: 54)))
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 27).x, 0.5, "top border inked")
        XCTAssertEqual(pixel(frame, x: 96, y: 54).x, 0, accuracy: 0.02, "interior empty")
    }

    func testDottedStrokeDrawsGaps() throws {
        func borderInk(_ dash: SceneStroke.Dash) throws -> Int {
            let style = ShapeStyle(
                kind: .rectangle,
                fill: .none,
                stroke: SceneStroke(color: .white, width: 4, dash: dash)
            )
            let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 27, width: 96, height: 54)))
            var count = 0
            for y in 0..<frame.height {
                for x in 0..<frame.width where pixel(frame, x: x, y: y).x > 0.2 {
                    count += 1
                }
            }
            return count
        }
        let solid = try borderInk(.solid)
        let dotted = try borderInk(.dotted)
        XCTAssertGreaterThan(dotted, 20, "dots must draw")
        XCTAssertLessThan(dotted, solid * 6 / 10, "dots must leave real gaps")
    }

    func testShadowEscapesTheFrame() throws {
        let style = ShapeStyle(
            kind: .rectangle,
            fill: .solid(.white),
            shadow: TextShadow(color: .white, blurRadius: 0, offsetX: 20, offsetY: 0)
        )
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 27, width: 60, height: 54)))

        XCTAssertGreaterThan(pixel(frame, x: 118, y: 54).x, 0.5,
                             "shadow must draw outside the item frame")
    }

    func testBezierPathTriangle() throws {
        let style = ShapeStyle(
            kind: .path("M 0.5 0 L 1 1 L 0 1 Z"),
            fill: .solid(.white)
        )
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 48, y: 4, width: 96, height: 100)))
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 90).x, 0.9, "base of triangle filled")
        XCTAssertEqual(pixel(frame, x: 55, y: 10).x, 0, accuracy: 0.02, "apex corners empty")
        XCTAssertEqual(pixel(frame, x: 137, y: 10).x, 0, accuracy: 0.02, "apex corners empty")
    }

    func testMalformedPathRendersNothing() throws {
        let style = ShapeStyle(kind: .path("M 0 0 W nonsense"), fill: .solid(.white))
        let frame = try renderItem(shapeItem(style, frame: CGRect(x: 0, y: 0, width: 192, height: 108)))
        XCTAssertEqual(pixel(frame, x: 96, y: 54).x, 0, accuracy: 0.001,
                       "unsupported path commands must draw nothing, not guess")
    }

    func testMediaGeometryModes() {
        let content = CGSize(width: 200, height: 100)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let stretch = Compositor.mediaGeometry(contentSize: content, frame: frame, mode: .stretch)
        XCTAssertEqual(stretch.quad, frame)
        XCTAssertEqual(stretch.uv, CGRect(x: 0, y: 0, width: 1, height: 1))

        let fill = Compositor.mediaGeometry(contentSize: content, frame: frame, mode: .fill)
        XCTAssertEqual(fill.quad, frame)
        XCTAssertEqual(fill.uv, CGRect(x: 0.25, y: 0, width: 0.5, height: 1), "crop the wide sides")

        let fit = Compositor.mediaGeometry(contentSize: content, frame: frame, mode: .fit)
        XCTAssertEqual(fit.quad, CGRect(x: 0, y: 25, width: 100, height: 50), "letterbox vertically")
        XCTAssertEqual(fit.uv, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testMediaGeometryCropsToSourceRect() {

        let content = CGSize(width: 400, height: 400)
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let source = SceneSourceRect(x: 0.25, y: 0.375, width: 0.5, height: 0.25)

        let stretch = Compositor.mediaGeometry(
            contentSize: content, frame: frame, mode: .stretch, sourceRect: source
        )
        XCTAssertEqual(stretch.quad, frame)
        XCTAssertEqual(stretch.uv, CGRect(x: 0.25, y: 0.375, width: 0.5, height: 0.25))

        let fill = Compositor.mediaGeometry(
            contentSize: content, frame: frame, mode: .fill, sourceRect: source
        )
        XCTAssertEqual(fill.quad, frame)
        XCTAssertEqual(fill.uv, CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25))

        let fit = Compositor.mediaGeometry(
            contentSize: content, frame: frame, mode: .fit, sourceRect: source
        )
        XCTAssertEqual(fit.quad, CGRect(x: 0, y: 25, width: 100, height: 50))
        XCTAssertEqual(fit.uv, CGRect(x: 0.25, y: 0.375, width: 0.5, height: 0.25))

        let whole = Compositor.mediaGeometry(
            contentSize: content, frame: frame, mode: .fill,
            sourceRect: SceneSourceRect(x: 0, y: 0, width: 1, height: 1)
        )
        XCTAssertEqual(whole.uv, CGRect(x: 0, y: 0, width: 1, height: 1))
        let degenerate = Compositor.mediaGeometry(
            contentSize: content, frame: frame, mode: .fill,
            sourceRect: SceneSourceRect(x: 0.5, y: 0.5, width: 0, height: 0)
        )
        XCTAssertEqual(degenerate.uv, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testObjectRenderingIsDeterministicAcrossEngineInstances() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        var scene = RenderScene()
        scene.addItem(
            RenderItem(
                id: "shape",
                frame: CGRect(x: 200, y: 200, width: 800, height: 400),
                content: .shape(ShapeStyle(
                    kind: .roundedRectangle(cornerRadius: 40),
                    fill: .linearGradient(angleDegrees: 90, stops: [
                        SceneGradientStop(color: SceneColor(red: 0.1, green: 0.2, blue: 0.4), position: 0),
                        SceneGradientStop(color: SceneColor(red: 0.4, green: 0.1, blue: 0.3), position: 1),
                    ]),
                    stroke: SceneStroke(color: .white, width: 3),
                    shadow: TextShadow(color: .black, blurRadius: 24, offsetX: 0, offsetY: 12)
                )),
                rotationDegrees: -4,
                opacity: 0.9,
                blendMode: .screen
            ),
            to: .slide
        )
        let first = try Compositor().renderFrame(scene: scene, width: 960, height: 540)
        let second = try Compositor().renderFrame(scene: scene, width: 960, height: 540)
        XCTAssertEqual(first.data, second.data)
    }
}
