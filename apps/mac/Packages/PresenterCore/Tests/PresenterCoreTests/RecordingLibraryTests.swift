import AVFoundation
import Foundation
import Testing
@testable import PresenterCore

@Suite(.serialized)
struct RecordingLibraryTests {

    private func item(
        folder: String?, recordedAt: Double?, status: MediaFileStatus = .ready,
        name: String = "clip"
    ) -> MediaItem {
        MediaItem(
            id: UUID().uuidString, name: name, mediaKind: .video,
            classification: .foreground, fileHash: "hash", fileName: "\(name).mov",
            fileStatus: status, statusDetail: "", tags: [], favorite: false,
            collections: [], loops: false, folder: folder, recordedAt: recordedAt)
    }

    @Test func newestReadyRecordingInFolderWins() {
        let items = [
            item(folder: "Recordings", recordedAt: 100, name: "early"),
            item(folder: "Recordings", recordedAt: 300, name: "latest"),
            item(folder: "Recordings", recordedAt: 200, name: "middle"),
        ]
        #expect(RecordingLibrary.latestRecording(in: items, folder: "Recordings")?.name == "latest")
    }

    @Test func importedMediaNeverWins() {

        let items = [
            item(folder: "Recordings", recordedAt: nil, name: "imported"),
            item(folder: "Recordings", recordedAt: 100, name: "recorded"),
        ]
        #expect(RecordingLibrary.latestRecording(in: items, folder: "Recordings")?.name == "recorded")
    }

    @Test func unreadyAndForeignFoldersAreExcluded() {
        let items = [
            item(folder: "Recordings", recordedAt: 900, status: .needsTranscode, name: "flagged"),
            item(folder: "Backgrounds", recordedAt: 800, name: "elsewhere"),

            item(folder: "Recordings Archive", recordedAt: 700, name: "sibling"),
            item(folder: "Recordings/2026", recordedAt: 100, name: "nested"),
        ]
        let winner = RecordingLibrary.latestRecording(in: items, folder: "Recordings")
        #expect(winner?.name == "nested")  
    }

    @Test func freshnessGuardExcludesStaleRecordings() {

        let lastWeek = item(folder: "Recordings", recordedAt: 1_000, name: "last-week")
        let cutoff = Date(timeIntervalSince1970: 2_000)
        #expect(RecordingLibrary.latestRecording(
            in: [lastWeek], folder: "Recordings", notBefore: cutoff) == nil)

        let today = item(folder: "Recordings", recordedAt: 3_000, name: "today")
        #expect(RecordingLibrary.latestRecording(
            in: [lastWeek, today], folder: "Recordings", notBefore: cutoff)?.name == "today")

        #expect(RecordingLibrary.latestRecording(
            in: [lastWeek], folder: "Recordings")?.name == "last-week")
    }

    @Test func emptyFolderResolvesNil() {
        let items = [item(folder: "Backgrounds", recordedAt: 100)]
        #expect(RecordingLibrary.latestRecording(in: items, folder: "Recordings") == nil)
    }

    private func writeVideo(to url: URL, frames: Int = 8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
        #expect(writer.status == .completed)
    }

    @MainActor @Test func adoptionMovesSpoolFileAndCreatesRecordingItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        let spool = RecordingLibrary.spoolDirectory(libraryRoot: root)
        let file = spool.appendingPathComponent("Sunday 2026-08-10 at 9.00.00 AM.mov")
        try await writeVideo(to: file)
        let startedAt = Date(timeIntervalSince1970: 1_754_000_000)
        let exportDir = root.appendingPathComponent("dropbox-sync", isDirectory: true)

        let item = try await RecordingLibrary.adopt(
            fileURL: file, client: client, folder: "Recordings",
            recordedAt: startedAt, presetId: "preset-1",
            alsoCopyTo: exportDir)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        let blobs = try BlobStore(libraryRoot: root)
        #expect(blobs.url(forHash: item.fileHash) != nil)

        #expect(FileManager.default.fileExists(
            atPath: exportDir.appendingPathComponent(item.fileName).path))

        #expect(item.fileStatus == .ready)
        #expect(item.folder == "Recordings")
        #expect(item.recordedAt == startedAt.timeIntervalSince1970)
        #expect(item.recordedByPresetId == "preset-1")
        #expect(item.mediaKind == .video)
        #expect(item.durationSeconds ?? 0 > 0)

        let loaded = try await Library(rootURL: root).open(MediaItem.self, id: item.id).value
        #expect(loaded.recordedAt == item.recordedAt)

        #expect(RecordingLibrary.latestRecording(in: [loaded], folder: "Recordings")?.id == item.id)
    }
}
