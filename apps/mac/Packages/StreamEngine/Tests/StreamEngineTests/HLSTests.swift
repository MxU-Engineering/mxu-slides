import AVFoundation
import CoreMedia
import XCTest
@testable import StreamEngine

final class HLSPlaylistTests: XCTestCase {
    func testSequenceStartsAtZeroAndAdvancesWithTheWindow() {
        var playlist = HLSPlaylist()
        XCTAssertEqual(playlist.mediaSequence, 0)
        for index in 0..<7 {
            playlist.add(name: "seg-1-\(index).ts", duration: 2.0)
        }

        XCTAssertEqual(playlist.segments.count, 5)
        XCTAssertEqual(playlist.mediaSequence, 2)
        XCTAssertEqual(playlist.segments.first?.name, "seg-1-2.ts")
    }

    func testRenderMatchesTheIngestContract() {
        var playlist = HLSPlaylist(mediaSequence: 10)
        playlist.add(name: "seg-1-10.ts", duration: 1.966)
        playlist.add(name: "seg-1-11.ts", duration: 2.033)
        let rendered = playlist.render()
        XCTAssertTrue(rendered.hasPrefix("#EXTM3U\n#EXT-X-VERSION:3\n"))
        XCTAssertTrue(rendered.contains("#EXT-X-TARGETDURATION:3\n"))
        XCTAssertTrue(rendered.contains("#EXT-X-MEDIA-SEQUENCE:10\n"))
        XCTAssertTrue(rendered.contains("#EXTINF:1.966,\nseg-1-10.ts\n"))
        XCTAssertTrue(rendered.contains("#EXTINF:2.033,\nseg-1-11.ts\n"))
        XCTAssertFalse(rendered.contains("EXT-X-KEY"))
    }

    func testContinuityKeepsNamesUniqueAndSequenceMonotonic() {
        let continuity = HLSContinuity(epochMillis: 42)
        XCTAssertEqual(continuity.claimSegmentName(), "seg-42-0.ts")
        XCTAssertEqual(continuity.claimSegmentName(), "seg-42-1.ts")
        continuity.recordSequence(7)
        continuity.recordSequence(3)  
        XCTAssertEqual(continuity.resumeSequence, 7)

        XCTAssertEqual(HLSPlaylist(mediaSequence: continuity.resumeSequence).mediaSequence, 7)
    }

    func testUploadURLCompletesTheTemplate() {
        XCTAssertEqual(
            HLSUploader.uploadURL(
                template: "https://a.upload.youtube.com/http_upload_hls?cid=key&copy=0&file=",
                filename: "seg-1-0.ts")?.absoluteString,
            "https://a.upload.youtube.com/http_upload_hls?cid=key&copy=0&file=seg-1-0.ts")
        XCTAssertEqual(
            HLSUploader.uploadURL(template: "https://example.com/ingest?cid=key", filename: "p.m3u8")?.absoluteString,
            "https://example.com/ingest?cid=key&file=p.m3u8")
    }
}

final class HLSMuxTests: XCTestCase {

    func testWriterCutsSegmentsOnKeyframes() throws {
        let writer = TSWriter(segmentDuration: 2.0)
        writer.expectedMedias = [.video]

        var segments: [(data: Data, duration: Double)] = []
        var current = Data()
        writer.sink = { current.append($0) }
        writer.onSegmentCut = { duration in
            segments.append((current, duration))
            current = Data()
        }

        let format = try Self.h264FormatDescription()
        writer.videoFormat = format
        for frame in 0..<181 {  
            let seconds = Double(frame) / 30.0
            let keyframe = frame % 60 == 0
            writer.append(try Self.h264Sample(format: format, seconds: seconds, keyframe: keyframe))
        }

        XCTAssertEqual(segments.count, 3)
        for segment in segments {
            XCTAssertEqual(segment.duration, 2.0, accuracy: 0.05)
            XCTAssertEqual(segment.data.count % 188, 0, "TS packets must stay 188-byte aligned")
            XCTAssertEqual(segment.data.first, 0x47, "segment must open on a sync byte")
        }

        let second = segments[1].data
        XCTAssertEqual(second[0], 0x47)
        let firstPID = (UInt16(second[1] & 0x1F) << 8) | UInt16(second[2])
        XCTAssertEqual(firstPID, 0, "segment must start with the PAT")

        XCTAssertTrue(segments.allSatisfy { $0.duration >= 2.0 })
    }

    static func h264FormatDescription() throws -> CMFormatDescription {

        let sps: [UInt8] = [
            0x67, 0x64, 0x00, 0x1E, 0xAC, 0xD9, 0x40, 0xA0,
            0x2F, 0xF9, 0x70, 0x11, 0x00, 0x00, 0x03, 0x00,
            0x01, 0x00, 0x00, 0x03, 0x00, 0x32, 0x0F, 0x16,
            0x2D, 0x96
        ]
        let pps: [UInt8] = [0x68, 0xEB, 0xEC, 0xB2, 0x2C]
        var format: CMFormatDescription?
        try sps.withUnsafeBufferPointer { spsPointer in
            try pps.withUnsafeBufferPointer { ppsPointer in
                let parameterSets = [spsPointer.baseAddress!, ppsPointer.baseAddress!]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSets,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
                guard status == noErr else { throw XCTSkip("H264 format description unavailable (\(status))") }
            }
        }
        return format!
    }

    static func h264Sample(format: CMFormatDescription, seconds: Double, keyframe: Bool) throws -> CMSampleBuffer {

        var payload: [UInt8] = [0, 0, 0, 9, keyframe ? 0x65 : 0x41]
        payload.append(contentsOf: [UInt8](repeating: 0xAB, count: 8))
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: payload.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer)
        CMBlockBufferReplaceDataBytes(
            with: payload, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: payload.count)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000),
            decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        let buffer = sample!
        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }
}

final class HLSStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [Int] = []
    nonisolated(unsafe) static var requests: [(url: String, body: Data)] = []
    nonisolated(unsafe) static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.requests.append((request.url!.absoluteString, body))
        let status = Self.responses.isEmpty ? 200 : Self.responses.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HLSUploaderTests: XCTestCase {
    static let primary = "https://a.upload.example/http_upload_hls?cid=key&copy=0&file="
    static let backup = "https://b.upload.example/http_upload_hls?cid=key&copy=1&file="

    override func setUp() {
        super.setUp()
        HLSStubProtocol.responses = []
        HLSStubProtocol.requests = []
    }

    private func makeUploader(backup: String? = HLSUploaderTests.backup) -> HLSUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HLSStubProtocol.self]
        return HLSUploader(
            primary: Self.primary, backup: backup,
            continuity: HLSContinuity(epochMillis: 42),
            session: URLSession(configuration: config))
    }

    func testDeliversSegmentThenPlaylistAndDrainsOnFinish() async throws {
        let uploader = makeUploader()
        uploader.enqueue(HLSUploader.Item(name: "seg-42-0.ts", data: Data([0x47, 1, 2]), duration: 2.0))
        uploader.finishEnqueuing()
        try await uploader.run()

        XCTAssertEqual(HLSStubProtocol.requests.count, 2)
        XCTAssertTrue(HLSStubProtocol.requests[0].url.hasSuffix("file=seg-42-0.ts"))
        XCTAssertTrue(HLSStubProtocol.requests[1].url.hasSuffix("file=playlist.m3u8"))
        let playlist = String(decoding: HLSStubProtocol.requests[1].body, as: UTF8.self)
        XCTAssertTrue(playlist.contains("#EXT-X-MEDIA-SEQUENCE:0"))
        XCTAssertTrue(playlist.contains("seg-42-0.ts"))
    }

    func testRetriesServerErrorsThenFailsOverToBackup() async throws {

        HLSStubProtocol.responses = [500, 500, 200, 200]
        let uploader = makeUploader()
        uploader.enqueue(HLSUploader.Item(name: "seg-42-0.ts", data: Data([0x47]), duration: 2.0))
        uploader.finishEnqueuing()
        try await uploader.run()

        let urls = HLSStubProtocol.requests.map(\.url)
        XCTAssertEqual(urls.count, 4)
        XCTAssertTrue(urls[0].hasPrefix("https://a.upload.example"))
        XCTAssertTrue(urls[1].hasPrefix("https://a.upload.example"))
        XCTAssertTrue(urls[2].hasPrefix("https://b.upload.example"), "third try lands on the backup ingest")
        XCTAssertTrue(urls[3].hasPrefix("https://b.upload.example"), "failover is sticky for the playlist too")
    }

    func testUnauthorizedIsFatalNotRetried() async {
        HLSStubProtocol.responses = [401]
        let uploader = makeUploader()
        uploader.enqueue(HLSUploader.Item(name: "seg-42-0.ts", data: Data([0x47]), duration: 2.0))
        uploader.finishEnqueuing()

        do {
            try await uploader.run()
            XCTFail("expected fatal error")
        } catch let error as StreamSessionError {
            XCTAssertTrue(error.isFatal)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        XCTAssertEqual(HLSStubProtocol.requests.count, 1, "401 must not retry")
    }

    func testExhaustedRetriesWithoutBackupThrowTransportClosed() async {
        HLSStubProtocol.responses = [500, 500, 500, 500]
        let uploader = makeUploader(backup: nil)
        uploader.enqueue(HLSUploader.Item(name: "seg-42-0.ts", data: Data([0x47]), duration: 2.0))
        uploader.finishEnqueuing()

        do {
            try await uploader.run()
            XCTFail("expected transportClosed")
        } catch let error as StreamSessionError {
            XCTAssertFalse(error.isFatal)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
