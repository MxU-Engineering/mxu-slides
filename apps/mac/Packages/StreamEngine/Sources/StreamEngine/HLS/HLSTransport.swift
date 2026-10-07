import AVFoundation
import CoreMedia
import Foundation
import os

private let log = Logger(subsystem: "com.example.mxuslides", category: "hls")

final class HLSTransport: @unchecked Sendable {
    static let segmentDuration = 2.0

    private let destination: StreamEndpoint
    private let video: StreamVideoConfiguration
    private let continuity: HLSContinuity
    private let uploader: HLSUploader

    private enum MuxEvent: @unchecked Sendable {
        case video(CMSampleBuffer)
        case audio(AVAudioCompressedBuffer, AVAudioTime)
    }

    init(destination: StreamEndpoint, video: StreamVideoConfiguration, continuity: HLSContinuity, uploader: HLSUploader? = nil) {
        self.destination = destination
        self.video = video
        self.continuity = continuity
        self.uploader = uploader ?? HLSUploader(
            primary: destination.url,
            backup: destination.backupUrl,
            continuity: continuity)
    }

    func run(
        frames: AsyncStream<CMSampleBuffer>,
        audio: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>
    ) async throws {
        let encoder = try HLSVideoEncoder(video: video, segmentDuration: Self.segmentDuration)
        let (muxEvents, muxContinuation) = AsyncStream<MuxEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(240))

        log.info("hls publishing: \(self.destination.name, privacy: .public) codec=\(self.video.codec.rawValue, privacy: .public) \(self.video.width)x\(self.video.height)")

        try await withThrowingTaskGroup(of: Void.self) { group in

            group.addTask {
                for await sample in frames {
                    encoder.encode(sample)
                }

                encoder.finish()
            }
            group.addTask {
                for await compressed in encoder.output {
                    muxContinuation.yield(.video(compressed))
                }
                muxContinuation.finish()
            }

            group.addTask {
                let converterBox = UnsafeSendableBox<HLSAudioEncoder?>(nil)
                for await (buffer, when) in audio {
                    if converterBox.value == nil {
                        converterBox.value = HLSAudioEncoder(inputFormat: buffer.format)
                        if converterBox.value == nil {
                            log.error("hls audio converter init failed for \(buffer.format, privacy: .public) — streaming without audio")
                        }
                    }
                    guard let converter = converterBox.value else { continue }
                    for (packet, time) in converter.encode(buffer, when: when) {
                        muxContinuation.yield(.audio(packet, time))
                    }
                }
            }

            group.addTask { [self] in
                try await mux(events: muxEvents)
            }

            group.addTask { [uploader] in
                try await uploader.run()
            }

            do {
                while try await group.next() != nil {}
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func mux(events: AsyncStream<MuxEvent>) async throws {
        let writer = TSWriter(segmentDuration: Self.segmentDuration)

        var segmentData = Data()
        var currentName = continuity.claimSegmentName()
        var finished: [HLSUploader.Item] = []
        writer.sink = { bytes in
            segmentData.append(bytes)
        }
        writer.onSegmentCut = { duration in
            finished.append(HLSUploader.Item(name: currentName, data: segmentData, duration: duration))
            segmentData = Data()
            currentName = self.continuity.claimSegmentName()
        }

        func apply(_ event: MuxEvent) {
            switch event {
            case .video(let sample):
                if let format = sample.formatDescription {
                    writer.videoFormat = format
                }
                writer.append(sample)
            case .audio(let packet, let when):
                writer.audioFormat = packet.format
                writer.append(packet, when: when)
            }
        }

        var buffered: [MuxEvent] = []
        var writerStarted = false
        var bufferedVideo = 0
        var sawAudio = false

        func declareFormats(_ events: [MuxEvent]) {
            for event in events {
                switch event {
                case .video(let sample):
                    if let format = sample.formatDescription {
                        writer.videoFormat = format
                    }
                case .audio(let packet, _):
                    writer.audioFormat = packet.format
                }
            }
        }

        for await event in events {
            if !writerStarted {
                buffered.append(event)
                if case .video = event { bufferedVideo += 1 }
                if case .audio = event { sawAudio = true }
                guard sawAudio || bufferedVideo >= 15 else { continue }
                writer.expectedMedias = sawAudio ? [.video, .audio] : [.video]
                declareFormats(buffered)
                writerStarted = true
                buffered.forEach(apply)
                buffered.removeAll()
            } else {
                apply(event)
            }
            while !finished.isEmpty {
                uploader.enqueue(finished.removeFirst())
            }
        }
        if !writerStarted, !buffered.isEmpty {

            writer.expectedMedias = sawAudio ? [.video, .audio] : [.video]
            declareFormats(buffered)
            buffered.forEach(apply)
            while !finished.isEmpty {
                uploader.enqueue(finished.removeFirst())
            }
        }

        if !segmentData.isEmpty {
            uploader.enqueue(HLSUploader.Item(
                name: currentName, data: segmentData,
                duration: max(writer.openSegmentSeconds, 1.0 / 30.0)))
        }
        uploader.finishEnqueuing()
    }
}

final class UnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
