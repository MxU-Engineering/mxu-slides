import Foundation
import PresenterCore
import RenderEngine
import XCTest
@testable import SlideScene

final class MediaTransportTargetTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 10_000)

    private func candidate(
        _ id: String, layer: LayerKind = .videos,
        origin: TransportOrigin = .foregroundServiceItem,
        looping: Bool = false, firedAt offset: TimeInterval = 0
    ) -> TransportCandidate {
        TransportCandidate(
            mediaID: id, layer: layer, origin: origin,
            isLooping: looping, firedAt: t0.addingTimeInterval(offset)
        )
    }

    func testDefaultViewportIsTheForegroundLayer() {
        let background = candidate("bg", layer: .loopingVideos, origin: .backgroundCue, looping: true)
        let foreground = candidate("fg")
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [background, foreground])?.mediaID, "fg",
            "nothing off the viewed layer ever auto-shows"
        )
        XCTAssertNil(
            TransportTarget.resolve(candidates: [background]),
            "a background loop must not leak into the default foreground viewport"
        )
    }

    func testCountdownTargetResolvesPerLayerWithoutThePin() {
        let background = candidate("bg", layer: .loopingVideos, origin: .backgroundCue, looping: true)
        let foreground = candidate("fg")
        XCTAssertEqual(
            TransportTarget.countdownTarget(candidates: [background, foreground])?.mediaID, "fg"
        )
        XCTAssertEqual(
            TransportTarget.countdownTarget(
                candidates: [background, foreground], layer: .loopingVideos
            )?.mediaID, "bg",
            "a layer-targeted box reads ITS layer's video"
        )
        let loopingForeground = candidate("loop", looping: true)
        XCTAssertEqual(
            TransportTarget.countdownTarget(candidates: [background, loopingForeground])?.mediaID,
            "loop",
            "a lone looping foreground counts one pass"
        )
        XCTAssertNil(
            TransportTarget.countdownTarget(candidates: [background]),
            "the default read is the foreground — an idle foreground is silent"
        )
        XCTAssertNil(
            TransportTarget.countdownTarget(candidates: [background, foreground], layer: .slide),
            "an idle layer renders nothing"
        )
    }

    func testEarliestStartWinsAndLaterFiresNeverSteal() {
        let first = candidate("first", firedAt: 0)
        let second = candidate("second", firedAt: 30)
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [second, first])?.mediaID, "first",
            "the target must not retarget when a newer video fires"
        )
    }

    func testSimultaneousStartsBreakByOriginRank() {

        let cueVideo = candidate("cue", layer: .slide, origin: .foregroundCue, firedAt: 0)
        let slideVideo = candidate("slide", layer: .slide, origin: .slides, firedAt: 0.5)
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [cueVideo, slideVideo], viewedLayer: .slide)?.mediaID,
            "slide"
        )

        let lateSlide = candidate("late", layer: .slide, origin: .slides, firedAt: 2)
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [cueVideo, lateSlide], viewedLayer: .slide)?.mediaID,
            "cue"
        )
    }

    func testFullTieFallsToCandidateOrder() {

        let a = candidate("a", layer: .slide, origin: .slides, firedAt: 0)
        let b = candidate("b", layer: .slide, origin: .slides, firedAt: 0)
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [a, b], viewedLayer: .slide)?.mediaID, "a"
        )
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [b, a], viewedLayer: .slide)?.mediaID, "b"
        )
    }

    func testLoopsNeverAutoSelectButExplicitSelectionGetsThem() {
        let loop = candidate("loop", looping: true, firedAt: 0)
        let video = candidate("video", firedAt: 5)

        XCTAssertEqual(
            TransportTarget.resolve(candidates: [loop, video])?.mediaID, "video"
        )

        XCTAssertEqual(
            TransportTarget.resolve(candidates: [loop])?.mediaID, "loop"
        )

        XCTAssertEqual(
            TransportTarget.resolve(
                candidates: [loop, video], preferNonLooping: false
            )?.mediaID, "loop",
            "explicit selection takes the layer's earliest video, loops included"
        )
    }

    func testPinnedVideoWinsWhileLiveAndFallsBackWhenGone() {
        let fg = candidate("fg", firedAt: 0)
        let pinnedLoop = candidate("bg", layer: .loopingVideos, origin: .backgroundCue, looping: true)
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [fg, pinnedLoop], pinnedID: "bg")?.mediaID, "bg",
            "a pin follows the video regardless of viewport"
        )
        XCTAssertEqual(
            TransportTarget.resolve(candidates: [fg], pinnedID: "bg")?.mediaID, "fg",
            "a stale pin falls back to the auto rules"
        )
    }

    func testTransportSeedsCarryLayerAndDirectness() {
        var state = ShowState()
        state.fire(media: CueMedia(mediaId: "direct-fg", mode: nil, layer: .videos, loops: nil), on: .videos)
        state.fire(media: CueMedia(mediaId: "cue-bg", mode: nil, layer: .loopingVideos, loops: nil), on: .loopingVideos)

        var seeds = state.transportSeeds()
        XCTAssertEqual(
            seeds.first { $0.mediaID == "direct-fg" }?.origin, .foregroundServiceItem
        )

        state.clear(layer: .videos)
        seeds = state.transportSeeds()
        XCTAssertNil(seeds.first { $0.mediaID == "direct-fg" }, "cleared layer must drop its seed")
        XCTAssertEqual(seeds.first { $0.mediaID == "cue-bg" }?.layer, .loopingVideos)
    }

    func testSlideObjectSeedsCoverFillsAndLegacyMediaObjects() {

        var shape = SlideObject(id: "s", objectKind: .shape, name: "Panel", text: "")
        shape.fill = ObjectFill(fillKind: .media, mediaId: "fill-video")
        var legacy = SlideObject(id: "m", objectKind: .media, name: "Pic", text: "")
        legacy.mediaId = "object-video"
        let slide = Slide(id: "slide", name: "One", objects: [shape, legacy])

        var state = ShowState()
        state.fire(slide: slide)
        let ids = state.transportSeeds().map(\.mediaID)
        XCTAssertTrue(ids.contains("fill-video"))
        XCTAssertTrue(ids.contains("object-video"))
    }

    func testVideoCountdownFreezesWhilePausedAndClampsAtZero() {
        let playing = VideoCountdown(
            name: "Bumper", duration: 90, position: 30, anchoredAt: t0, isPlaying: true
        )
        XCTAssertEqual(playing.remaining(at: t0), 60, accuracy: 0.0001)
        XCTAssertEqual(playing.remaining(at: t0 + 20), 40, accuracy: 0.0001)
        XCTAssertEqual(playing.remaining(at: t0 + 500), 0, "countdown clamps at zero, never overruns")

        let paused = VideoCountdown(
            name: "Bumper", duration: 90, position: 30, anchoredAt: t0, isPlaying: false
        )
        XCTAssertEqual(paused.remaining(at: t0 + 500), 60, accuracy: 0.0001, "paused countdown freezes")
    }

    func testConfidenceSceneRendersTheCountdownLine() {
        var info = ConfidenceInfo()
        info.videoCountdown = VideoCountdown(
            name: "Bumper", duration: 90, position: 70, anchoredAt: t0, isPlaying: true
        )
        let scene = ConfidenceSceneBuilder.scene(info: info, at: t0)
        func countdownLine(in scene: RenderScene) -> StyledText? {
            scene.layers.flatMap(\.items).compactMap { item -> StyledText? in
                guard case .text(let styled) = item.content,
                      styled.string.contains("Bumper") else { return nil }
                return styled
            }.first
        }
        guard let styled = countdownLine(in: scene) else {
            return XCTFail("countdown line missing from the confidence scene")
        }
        XCTAssertTrue(styled.string.contains("0:20"), "line carries the remaining time: \(styled.string)")
        XCTAssertEqual(
            styled.color, ColorHex.color(TimerWarning.amberHex),
            "inside the warning window the line reads amber"
        )

        let bare = ConfidenceSceneBuilder.scene(info: ConfidenceInfo(), at: t0)
        XCTAssertNil(countdownLine(in: bare))
    }
}
