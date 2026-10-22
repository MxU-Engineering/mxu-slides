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

    func testACardTargetHoldsItsPlaceInTheCardsFrame() throws {
        let reference = LiveCadence(lastArrival: 10, period: ntsc)
        let next = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + ntsc * MirrorCadence.cardTarget, reference: reference,
            target: MirrorCadence.cardTarget))
        XCTAssertEqual(next.interval, ntsc, accuracy: 1e-9)
    }

    func testATickPastTheTargetComesRoundTheShortWay() throws {
        let next = try XCTUnwrap(MirrorCadence.next(
            nominal: nominal, now: 10 + ntsc * 0.9,
            reference: LiveCadence(lastArrival: 10, period: ntsc),
            target: MirrorCadence.cardTarget))
        XCTAssertGreaterThan(next.interval, ntsc)
    }

    func testCardPacingLandsEveryFrameClearOfTheCardsCopy() {
        var generator = SystemRandomNumberGenerator()
        let card = ntsc * (1 + 40e-6)
        var clock = CardClock()
        var deadline = 100.0
        var closest = Double.infinity
        for index in 0..<3600 {
            let fired = deadline + Double.random(in: 0...0.002, using: &generator)
            let landing = fired + Double.random(in: 0.006...0.020, using: &generator)
            let phase = landing.truncatingRemainder(dividingBy: card)
            if index > 300 { closest = min(closest, phase, card - phase) }
            let completions = Int((fired / card).rounded(.down))
            let observed = Double(completions) * card + Double.random(in: 0...0.002, using: &generator)
            _ = clock.record(
                completions: completions, lastCompletion: min(observed, fired),
                counters: .init())
            let next = MirrorCadence.next(
                nominal: nominal, now: fired, reference: clock.cadence,
                target: MirrorCadence.cardTarget)
            deadline += next?.interval ?? nominal
        }
        XCTAssertGreaterThan(closest, 0.004)
    }

    func testTheLiveSourceOnScreenOutranksACardClock() throws {
        let compositor: Compositor
        do {
            compositor = try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let source = CadenceSource()
        compositor.mediaSource = source
        let canvas = CGSize(width: 320, height: 180)
        var live = RenderScene(canvasSize: canvas)
        live.addItem(
            RenderItem(
                id: "cam", frame: CGRect(origin: .zero, size: canvas),
                content: .media(id: "camera", scaleMode: .fill, sourceRect: nil)),
            to: .stillGraphics)
        let shown = live
        let empty = RenderScene(canvasSize: canvas)
        let card = LiveCadence(lastArrival: 50, period: 1.0 / 30)
        let cardOnly = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180,
            provider: { empty }, pacing: { card }, sink: { _, _ in }))
        let cardAndCamera = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180,
            provider: { shown }, pacing: { card }, sink: { _, _ in }))
        for mirror in [cardOnly, cardAndCamera] {
            mirror.startWithoutTimerForTesting()
            mirror.tick(at: 42)
        }

        let liveStep = try XCTUnwrap(cardAndCamera.steeringStep(nominal: nominal, at: 42.01))
        XCTAssertEqual(liveStep.period, CadenceSource.cadence.period)
        let cardStep = try XCTUnwrap(cardOnly.steeringStep(nominal: nominal, at: 50.01))
        XCTAssertEqual(cardStep.period, card.period)
        cardOnly.stop()
        cardAndCamera.stop()
        withExtendedLifetime(source) {}
    }
}
