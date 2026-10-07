import AVFoundation
import CoreMedia
import RenderEngine
import XCTest
@testable import OutputEngine

final class SyncMonitorSamplesTests: XCTestCase {

    func testVideoAndAudioOfOneMomentShareAStampTheClockReachesLagLater() throws {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let video = try XCTUnwrap(SyncMonitorSamples.video(try XCTUnwrap(pixelBuffer), hostSeconds: 1234.5))

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        let audio = try XCTUnwrap(Recorder.sampleBuffer(
            from: pcm,
            presentationTime: CMTime(seconds: 1234.5, preferredTimescale: SyncMonitorSamples.timescale)))

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(video).seconds, 1234.5, accuracy: 1e-4)
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(video), CMSampleBufferGetPresentationTimeStamp(audio))
        XCTAssertEqual(CMSampleBufferGetNumSamples(audio), 480)
        XCTAssertEqual(
            SyncMonitorSamples.clockTime(atHostSeconds: 1234.5 + SyncMonitorSamples.lag).seconds,
            1234.5, accuracy: 1e-4)
    }

    func testRoutingToNoDeviceLeavesTheRendererAloneInsteadOfRaising() {
        let renderer = AVSampleBufferAudioRenderer()
        SyncMonitorSamples.route(renderer, toDeviceUID: nil)
        SyncMonitorSamples.route(renderer, toDeviceUID: "")
        XCTAssertNil(renderer.audioOutputDeviceUniqueID)
        SyncMonitorSamples.route(renderer, toDeviceUID: "BuiltInSpeakerDevice")
        XCTAssertEqual(renderer.audioOutputDeviceUniqueID, "BuiltInSpeakerDevice")
    }

    func testTheMeterCountsWhatArrivesAndHearsTheMonitorsOwnSound() throws {
        let meter = SyncMonitorMeter()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        try XCTUnwrap(pcm.floatChannelData)[1][100] = -0.5
        meter.videoFrame()
        meter.videoFrame()
        meter.audio(pcm)

        let reading = meter.drain()
        XCTAssertEqual(reading.videoFrames, 2)
        XCTAssertEqual(reading.audioBuffers, 1)
        XCTAssertEqual(reading.peak, 0.5)
        XCTAssertEqual(reading.peakDecibels, -6.02, accuracy: 0.01)
        XCTAssertEqual(reading.channels, 2)
        XCTAssertEqual(meter.drain(), SyncMonitorMeter.Reading())
        XCTAssertEqual(SyncMonitorMeter.Reading().peakDecibels, -90)
    }

    func testPlanarAudioReachesThePlayerInterleavedSampleForSample() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        pcm.frameLength = 3
        let planes = try XCTUnwrap(pcm.floatChannelData)
        for frame in 0..<3 {
            planes[0][frame] = Float(frame) + 0.1
            planes[1][frame] = -(Float(frame) + 0.1)
        }
        let interleaved = try XCTUnwrap(SyncMonitorSamples.interleaved(pcm))
        XCTAssertTrue(interleaved.format.isInterleaved)
        XCTAssertEqual(interleaved.frameLength, 3)
        let samples = try XCTUnwrap(interleaved.floatChannelData)[0]
        XCTAssertEqual((0..<6).map { samples[$0] }, [0.1, -0.1, 1.1, -1.1, 2.1, -2.1])
        let sample = try XCTUnwrap(Recorder.sampleBuffer(
            from: interleaved, presentationTime: CMTime(value: 48_000, timescale: 48_000)))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 3)
    }

    func testListeningGainScalesEverySampleAndLimitsAtFullScale() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        pcm.frameLength = 2
        let samples = try XCTUnwrap(pcm.floatChannelData)[0]
        for (index, value) in [Float(0.03), -0.03, 0.5, -0.5].enumerated() { samples[index] = value }
        SyncMonitorSamples.applyGain(pcm, decibels: 20)
        XCTAssertEqual(samples[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(samples[1], -0.3, accuracy: 1e-6)
        XCTAssertEqual(samples[2], 1)
        XCTAssertEqual(samples[3], -1)
    }

    func testTheMonitorRendersSmallAndSparesItsLagInFrames() {
        XCTAssertEqual(SyncMonitorSamples.renderSize(width: 1920, height: 1080).width, 960)
        XCTAssertEqual(SyncMonitorSamples.renderSize(width: 1920, height: 1080).height, 540)
        XCTAssertEqual(SyncMonitorSamples.renderSize(width: 1280, height: 480).height, 480)
        XCTAssertEqual(SyncMonitorSamples.heldFrames(framesPerSecond: 30), Int((SyncMonitorSamples.lag * 30).rounded(.up)) + 8)
    }

    func testAMirrorWhoseConsumerHoldsFramesKeepsDelivering() throws {
        let compositor: Compositor
        do {
            compositor = try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let canvas = CGSize(width: 160, height: 90)
        let tickCount = Locked(0)
        let held = Locked<[CVPixelBuffer]>([])
        let frames = 30
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90,

            provider: {
                var scene = RenderScene(canvasSize: canvas)
                let shade = Double(tickCount.value % 2)
                scene.addItem(
                    RenderItem(
                        id: "fill-\(tickCount.value)", frame: CGRect(origin: .zero, size: canvas),
                        content: .solid(shade == 0 ? .white : .black)),
                    to: .stillGraphics)
                return scene
            },
            consumerHeldFrames: frames,
            sink: { buffer, _ in held.withLock { $0.append(buffer) } }))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        for tick in 0..<frames {
            tickCount.value = tick
            mirror.tick(at: Double(tick) / 30)
            let landed = expectation(description: "frame \(tick)")
            DispatchQueue.global().async {
                while held.value.count <= tick, mirror.framesDropped == 0 { usleep(1000) }
                landed.fulfill()
            }
            wait(for: [landed], timeout: 5)
        }
        XCTAssertEqual(mirror.framesDropped, 0)
        XCTAssertEqual(held.value.count, frames)
        XCTAssertEqual(Set(held.value.map { ObjectIdentifier($0) }).count, frames)
    }
}
