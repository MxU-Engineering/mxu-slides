import AVFoundation
import AudioEngine
import MediaToolbox
import RenderEngine

final class VideoAudioTap {
    typealias Sink = @Sendable (AVAudioPCMBuffer) -> Void

    final class Context {
        let sink: Locked<Sink?>

        let delay: Locked<Double>

        private let line = AudioDelayLine()
        private(set) var tapFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2)!

        init(sink: Locked<Sink?>, delay: Locked<Double>) {
            self.sink = sink
            self.delay = delay
        }

        func prepare(format: AVAudioFormat) {
            tapFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }

        func unprepare() {
            converter = nil
            tapFormat = nil
        }

        var isIdle: Bool { sink.value == nil && delay.value == 0 }

        func handle(_ source: AVAudioPCMBuffer) {
            if let sink = sink.value, let converter {
                feed(sink, converting: source, with: converter)
            }
            let milliseconds = delay.value

            if milliseconds > 0, source.format.commonFormat == .pcmFormatFloat32,
               !source.format.isInterleaved {
                line.delayMilliseconds = milliseconds
                line.process(source)
            }
        }

        private func feed(
            _ sink: Sink, converting source: AVAudioPCMBuffer, with converter: AVAudioConverter
        ) {
            let ratio = outputFormat.sampleRate / source.format.sampleRate
            let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: capacity)
            else { return }
            nonisolated(unsafe) var fed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            if conversionError == nil, converted.frameLength > 0 {
                sink(converted)
            }
        }
    }

    @discardableResult
    static func attach(
        to item: AVPlayerItem, sink: Locked<Sink?>, delay: Locked<Double>
    ) -> Bool {
        guard let track = item.asset.tracks(withMediaType: .audio).first else {
            return false
        }
        let context = Context(sink: sink, delay: delay)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(
                Unmanaged.passRetained(context).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, processingFormat in
                let context = Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var asbd = processingFormat.pointee
                if let format = AVAudioFormat(streamDescription: &asbd) {
                    context.prepare(format: format)
                }
            },
            unprepare: { tap in
                Unmanaged<Context>.fromOpaque(
                    MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in

                RealtimeAudioCallback.scope {
                    let status = MTAudioProcessingTapGetSourceAudio(
                        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                    let context = Unmanaged<Context>.fromOpaque(
                        MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    if status == noErr, !context.isIdle, numberFramesOut.pointee > 0,
                       let tapFormat = context.tapFormat,
                       let source = AVAudioPCMBuffer(
                           pcmFormat: tapFormat, bufferListNoCopy: bufferListInOut) {
                        source.frameLength = AVAudioFrameCount(numberFramesOut.pointee)
                        context.handle(source)
                    }
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(context).release()  
            return false
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        return true
    }
}
