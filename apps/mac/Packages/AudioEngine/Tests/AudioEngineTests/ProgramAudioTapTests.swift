import AVFoundation
import Foundation
import Testing

@testable import AudioEngine

private final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(frames: AVAudioFrameCount, seconds: Double)] = []
    var count: Int { lock.withLock { received.count } }
    var first: (frames: AVAudioFrameCount, seconds: Double)? {
        lock.withLock { received.first }
    }
    func add(frames: AVAudioFrameCount, seconds: Double) {
        lock.withLock { received.append((frames, seconds)) }
    }
}

@Test(.disabled(if: isVirtualMachine(), "a virtual machine has no host audio clock: the tap delivered nothing in 186 s on GitHub's runner"))
func programTapDeliversCopiedBuffersOnTheHostClock() async throws {
    guard #available(macOS 14.2, *) else { return }
    let box = BufferBox()
    let tap: ProgramAudioTap
    do {
        tap = try ProgramAudioTap { buffer, _, hostSeconds in
            box.add(frames: buffer.frameLength, seconds: hostSeconds)
        }
    } catch {

        return
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    engine.mainMixerNode.outputVolume = 0
    let format = engine.mainMixerNode.outputFormat(forBus: 0)
    guard let tone = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate) / 10)
    else { return }
    tone.frameLength = tone.frameCapacity
    for channel in 0 ..< Int(format.channelCount) {
        guard let data = tone.floatChannelData?[channel] else { continue }
        for frame in 0 ..< Int(tone.frameLength) {
            data[frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate)) * 0.1
        }
    }
    do {
        try engine.start()
    } catch {
        return  
    }
    player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
    player.play()
    defer { engine.stop() }

    for _ in 0 ..< 30 where box.count < 3 {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    withExtendedLifetime(tap) {}
    #expect(box.count >= 3, "IO proc never ticked")
    if let first = box.first {
        #expect(first.frames > 0)

        #expect(abs(first.seconds - CACurrentMediaTime()) < 3_600)
    }
}

private func isVirtualMachine() -> Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let read = sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0)
    return read == 0 && present != 0
}
