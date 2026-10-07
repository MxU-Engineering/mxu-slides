import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

private final class CadenceSource: MediaTextureSource, @unchecked Sendable {
    static let cadence = LiveCadence(lastArrival: 42, period: 1001.0 / 30000)

    func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { nil }

    func liveCadence(for mediaID: String) -> LiveCadence? {
        mediaID == "camera" ? Self.cadence : nil
    }
}

final class MirrorCadenceTests: XCTestCase {
    private let nominal = 1.0 / 30
    private let ntsc = 1001.0 / 30000

    func testNoLiveSourceLeavesTheTimerFreeRunning() {
        XCTAssertNil(MirrorCadence.next(nominal: nominal, now: 5, reference: nil))
    }

    func testMidFrameFollowsTheSourcePeriodExactly() throws {
        let reference = LiveCadence(lastArrival: 10, period: ntsc)
        let next = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + ntsc / 2, reference: reference))
        XCTAssertEqual(next.interval, ntsc, accuracy: 1e-9)
        XCTAssertEqual(next.edgeDistance, ntsc / 2, accuracy: 1e-9)
    }

    func testATickNearTheNextArrivalComesEarlierAndNeverLurches() throws {
        let reference = LiveCadence(lastArrival: 10, period: ntsc)
        let late = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + ntsc * 0.95, reference: reference))
        let early = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + ntsc * 0.05, reference: reference))
        XCTAssertLessThan(late.interval, ntsc)
        XCTAssertGreaterThan(early.interval, ntsc)
        XCTAssertGreaterThanOrEqual(late.interval, nominal - MirrorCadence.maxSteer)
        XCTAssertLessThanOrEqual(early.interval, nominal + MirrorCadence.maxSteer)
    }

    func testADoubleRateSourceIsFollowedEveryOtherFrame() throws {
        let period = ntsc / 2
        let next = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + period / 2,
            reference: LiveCadence(lastArrival: 10, period: period)))
        XCTAssertEqual(next.interval, ntsc, accuracy: 1e-9)
    }

    func testAnUnfollowableRateOrALostSignalFreeRuns() {
        XCTAssertNil(MirrorCadence.next(
            nominal: nominal, now: 10.01, reference: LiveCadence(lastArrival: 10, period: 1.0 / 25)))
        XCTAssertNil(MirrorCadence.next(
            nominal: nominal, now: 10.5, reference: LiveCadence(lastArrival: 10, period: ntsc)))
    }

    func testSteeringHoldsAJitteryTickOffTheSourceEdgesForMinutes() {
        var generator = SystemRandomNumberGenerator()
        var deadline = 100.0
        var closest = Double.infinity
        for index in 0..<3600 {
            let fired = deadline + Double.random(in: 0...0.002, using: &generator)
            let arrival = (fired / ntsc).rounded(.down) * ntsc
            let phase = fired - arrival
            if index > 150 { closest = min(closest, phase, ntsc - phase) }
            let observed = arrival + Double.random(in: -0.003...0.003, using: &generator)
            let next = MirrorCadence.next(
                nominal: nominal, now: fired,
                reference: LiveCadence(lastArrival: min(observed, fired), period: ntsc))
            deadline += next?.interval ?? nominal
        }
        XCTAssertGreaterThan(closest, 0.008)
    }

    func testATickNotesTheLiveSourceItsSceneShows() throws {
        let compositor: Compositor
        do {
            compositor = try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let source = CadenceSource()
        compositor.mediaSource = source
        let canvas = CGSize(width: 320, height: 180)
        let scene = Locked(RenderScene(canvasSize: canvas))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180,
            provider: { scene.value }, sink: { _, _ in }))
        mirror.startWithoutTimerForTesting()

        mirror.tick(at: 1)
        XCTAssertNil(mirror.liveCadence.value)

        scene.withLock {
            $0.addItem(
                RenderItem(
                    id: "cam", frame: CGRect(origin: .zero, size: canvas),
                    content: .media(id: "camera", scaleMode: .fill, sourceRect: nil)),
                to: .stillGraphics)
        }
        mirror.tick(at: 2)
        XCTAssertEqual(mirror.liveCadence.value, CadenceSource.cadence)

        scene.value = RenderScene(canvasSize: canvas)
        mirror.tick(at: 3)
        XCTAssertNil(mirror.liveCadence.value)
        mirror.stop()
    }
}
