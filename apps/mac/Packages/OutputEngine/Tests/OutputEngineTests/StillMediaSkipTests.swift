import CoreVideo
import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class StillMediaSkipTests: XCTestCase {

    private final class FakeMedia: MediaTextureSource, @unchecked Sendable {
        let stills = Locked<[String: UInt64]>([:])
        let mirrors = Locked<[String: LiveFrameSlot]>([:])
        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { nil }
        func stillGeneration(for mediaID: String) -> UInt64? {
            stills.value[mediaID] ?? mirrors.value[mediaID]?.generation
        }
    }

    private func makeMirror(
        _ compositor: Compositor, into slot: LiveFrameSlot,
        showing scene: @escaping @Sendable () -> RenderScene
    ) throws -> (mirror: OutputMirror, tick: (CFTimeInterval) -> Void) {
        let delivered = Locked(0)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: scene,
            sink: { buffer, _ in
                slot.set(buffer)
                delivered.withLock { $0 += 1 }
            }
        ))
        mirror.startWithoutTimerForTesting()
        return (mirror, { time in
            let before = delivered.value
            mirror.tick(at: time)
            let deadline = Date().addingTimeInterval(5)
            while delivered.value == before, Date() < deadline { usleep(10_000) }
        })
    }

    private func makeCompositor() throws -> Compositor {
        do {
            return try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func mediaScene(_ id: String) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 160, height: 90))
        scene.addItem(
            RenderItem(
                id: "media", frame: CGRect(x: 0, y: 0, width: 160, height: 90),
                content: .media(id: id, scaleMode: .fill, sourceRect: nil)
            ),
            to: .slide
        )
        return scene
    }

    func testPlaceholderScreenSkipsStillsAndRendersVideoEveryTick() throws {
        let compositor = try makeCompositor()
        let media = FakeMedia()
        media.stills.value = ["slide.jpg": 1]
        compositor.mediaSource = media
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Still", width: 160, height: 90
        ))
        let scene = Locked(mediaScene("slide.jpg"))
        screen.sceneProvider = { scene.value }

        screen.renderNow(at: 0)
        screen.renderNow(at: 1)
        XCTAssertEqual(screen.framesRendered, 1, "a still-only scene skips its second tick")

        media.stills.value = ["slide.jpg": 2]
        screen.renderNow(at: 2)
        screen.renderNow(at: 3)
        XCTAssertEqual(screen.framesRendered, 2, "a still swapped under the same id renders once")

        scene.value = mediaScene("clip.mov")
        screen.renderNow(at: 4)
        screen.renderNow(at: 5)
        XCTAssertEqual(screen.framesRendered, 4, "video renders every tick")

        scene.value = mediaScene("input::item::cam")
        screen.renderNow(at: 6)
        screen.renderNow(at: 7)
        XCTAssertEqual(screen.framesRendered, 6, "a live input renders every tick")
    }

    func testMirrorResendsStillsAndConvertsVideoEveryTick() throws {
        let compositor = try makeCompositor()
        let media = FakeMedia()
        media.stills.value = ["slide.jpg": 1]
        compositor.mediaSource = media
        let scene = Locked(mediaScene("slide.jpg"))
        let delivered = Locked<[CVPixelBuffer]>([])
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene.value },
            sink: { buffer, _ in delivered.withLock { $0.append(buffer) } }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        func tick(at time: CFTimeInterval) {
            let before = delivered.value.count
            mirror.tick(at: time)
            let deadline = Date().addingTimeInterval(5)
            while delivered.value.count == before, Date() < deadline { usleep(10_000) }
        }

        tick(at: 0)
        tick(at: 1)
        media.stills.value = ["slide.jpg": 2]
        tick(at: 2)
        scene.value = mediaScene("clip.mov")
        tick(at: 3)
        tick(at: 4)

        let buffers = delivered.value
        XCTAssertEqual(buffers.count, 5)
        XCTAssertTrue(buffers[1] === buffers[0], "a still resends the converted buffer")
        XCTAssertFalse(buffers[2] === buffers[1], "a swapped still converts once")
        XCTAssertFalse(buffers[3] === buffers[2], "video converts")
        XCTAssertFalse(buffers[4] === buffers[3], "and keeps converting every tick")
    }

    func testScreenMirrorOfAStaticScreenSkipsDownstream() throws {
        let compositor = try makeCompositor()
        let media = FakeMedia()
        let slot = LiveFrameSlot()
        media.stills.value = ["slide.jpg": 1]
        media.mirrors.value = ["screen::main": slot]
        compositor.mediaSource = media
        let upstream = Locked(mediaScene("slide.jpg"))
        let (mirror, tick) = try makeMirror(compositor, into: slot) { upstream.value }
        defer { mirror.stop() }
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Confidence", width: 160, height: 90
        ))
        let downstream = mediaScene("screen::main")
        screen.sceneProvider = { downstream }
        func both(at time: CFTimeInterval) {
            tick(time)
            screen.renderNow(at: time)
        }

        both(at: 0)
        both(at: 1)
        XCTAssertEqual(screen.framesRendered, 1, "a mirror of a static screen holds still")

        media.stills.value = ["slide.jpg": 2]
        both(at: 2)
        both(at: 3)
        XCTAssertEqual(screen.framesRendered, 2, "a change upstream renders once downstream")

        upstream.value = mediaScene("clip.mov")
        both(at: 4)
        both(at: 5)
        XCTAssertEqual(screen.framesRendered, 4, "a mirrored moving screen renders every tick")
    }

    func testMirrorOfItselfKeepsConvertingWithoutHanging() throws {
        let compositor = try makeCompositor()
        let media = FakeMedia()
        let slot = LiveFrameSlot()
        media.mirrors.value = ["screen::loop": slot]
        compositor.mediaSource = media
        let scene = mediaScene("screen::loop")
        let (mirror, tick) = try makeMirror(compositor, into: slot) { scene }
        defer { mirror.stop() }

        var generations: [UInt64] = []
        for time in 0..<3 {
            tick(CFTimeInterval(time))
            generations.append(slot.generation)
        }
        XCTAssertEqual(Set(generations).count, 3, "a cycle is video feedback: every tick converts")
    }
}
