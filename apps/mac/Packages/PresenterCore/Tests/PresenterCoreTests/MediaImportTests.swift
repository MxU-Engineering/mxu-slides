import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PresenterCore

@Suite(.serialized)
struct MediaImportTests {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePNG(to url: URL, size: Int = 64) throws {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeWAV(to url: URL) throws {
        let sampleCount = 8000
        var data = Data("RIFF".utf8)
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append32(UInt32(36 + sampleCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16); append16(1); append16(1)
        append32(8000); append32(16000); append16(2); append16(16)
        data.append(contentsOf: "data".utf8)
        append32(UInt32(sampleCount * 2))
        data.append(Data(count: sampleCount * 2))
        try data.write(to: url)
    }

    private func writeVideo(to url: URL, codec: AVVideoCodecType, frames: Int = 8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    @MainActor @Test func fiftyMixedFilesImportOrganizedAndFlagged() async throws {
        let dir = try makeDir()
        let libraryRoot = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: libraryRoot)
        }

        for i in 0..<20 { try writePNG(to: dir.appendingPathComponent("image-\(i).png")) }
        for i in 0..<10 { try writeWAV(to: dir.appendingPathComponent("track-\(i).wav")) }
        for i in 0..<15 {
            try await writeVideo(to: dir.appendingPathComponent("clip-\(i).mov"), codec: .h264)
        }
        for i in 0..<3 {

            try await writeVideo(to: dir.appendingPathComponent("legacy-\(i).mov"), codec: .jpeg)
        }
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
            .write(to: dir.appendingPathComponent("corrupt.mov"))
        try Data("not media".utf8).write(to: dir.appendingPathComponent("notes.xyz"))

        let client = LibraryClient(rootURL: libraryRoot)
        try await client.start().value
        let importer = try MediaImporter(client: client)
        let results = await importer.importFiles(at: [dir])  
        #expect(results.count == 50)

        let (media, audio) = try await onLibraryActor(reading: libraryRoot) { library in
            (try library.index.entries(of: .media), try library.index.entries(of: .audio))
        }
        #expect(media.count == 39)  
        #expect(audio.count == 10)
        #expect(results.filter {
            if case .skipped = $0.outcome { return true } else { return false }
        }.count == 1)  

        let flagged = try await onLibraryActor(reading: libraryRoot) { library in
            try media.map { try library.open(MediaItem.self, id: $0.id).value }
                .filter { $0.fileStatus == .needsTranscode }
        }
        #expect(flagged.count == 4)  
        #expect(flagged.allSatisfy { !$0.statusDetail.isEmpty })

        let clips = try await onLibraryActor(reading: libraryRoot) { library in
            try media.map { try library.open(MediaItem.self, id: $0.id).value }
                .filter { $0.mediaKind == .video && $0.fileStatus == .ready }
        }
        #expect(clips.count == 15)
        #expect(clips.allSatisfy { $0.pixelWidth == 64 && $0.durationSeconds ?? 0 > 0 })

        let blobs = try BlobStore(libraryRoot: libraryRoot)
        #expect(blobs.allHashes().count < 49)  

        let queue = try TranscodeQueue(client: client)
        let outcomes = await queue.drain()
        #expect(outcomes.values.filter { $0 == .ready }.count == 3)
        #expect(outcomes.values.filter { $0 == .transcodeFailed }.count == 1)

        if let fixed = outcomes.first(where: { $0.value == .ready })?.key {
            let item = try await onLibraryActor(reading: libraryRoot) { try $0.open(MediaItem.self, id: fixed).value }
            let url = try #require(blobs.url(forHash: item.fileHash))
            let probe = await MediaImporter.probeVideo(AVURLAsset(url: url))
            #expect(probe.status == .ready)
        }
    }

    @MainActor @Test func duplicateImportSharesOneBlob() async throws {
        let dir = try makeDir()
        let libraryRoot = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        try writePNG(to: dir.appendingPathComponent("a.png"))
        try writePNG(to: dir.appendingPathComponent("b.png"))

        let client = LibraryClient(rootURL: libraryRoot)
        try await client.start().value
        let importer = try MediaImporter(client: client)
        _ = await importer.importFiles(at: [dir])

        let blobs = try BlobStore(libraryRoot: libraryRoot)
        #expect(blobs.allHashes().count == 1)
        #expect(try await onLibraryActor(reading: libraryRoot) { try $0.index.entries(of: .media).count } == 2)  
    }

    @MainActor @Test func importsLandInTheDriveInTheirLibrarysFolder() async throws {
        let dir = try makeDir()
        let libraryRoot = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: libraryRoot)
        }
        try writePNG(to: dir.appendingPathComponent("loop.png"))
        try writeWAV(to: dir.appendingPathComponent("bed.wav"))

        let client = LibraryClient(rootURL: libraryRoot)
        try await client.start().value
        let importer = try MediaImporter(client: client)
        let viewing = LibraryHome.Viewed(kind: .media, area: .team, path: "Backgrounds/Loops")
        _ = await importer.importFiles(at: [dir], placement: .drive(viewing: viewing))

        let snapshot = try await client.settledSnapshot()
        let image = try #require(snapshot.entries(of: .media).first)
        let audio = try #require(snapshot.entries(of: .audio).first)
        #expect(try await client.loadValue(MediaItem.self, id: image.id).folder == "Backgrounds/Loops")
        #expect(try await client.loadValue(AudioItem.self, id: audio.id).folder == LibraryHome.needsSorted)
        #expect(snapshot.area(kind: .media, id: image.id) == .team && snapshot.area(kind: .audio, id: audio.id) == .team)
    }
}
