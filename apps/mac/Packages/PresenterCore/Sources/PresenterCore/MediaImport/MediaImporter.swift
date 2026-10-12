import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
public struct MediaImporter {
    public struct Result: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            case media(id: String, status: MediaFileStatus)
            case audio(id: String)
            case skipped(reason: String)
        }
        public let fileURL: URL
        public let outcome: Outcome
    }

    static let playableCodecs: Set<CMVideoCodecType> = [
        kCMVideoCodecType_H264,
        kCMVideoCodecType_HEVC,
        kCMVideoCodecType_HEVCWithAlpha,
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
        kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ,
    ]

    private let client: LibraryClient
    private let blobs: BlobStore

    public init(client: LibraryClient) throws {
        self.client = client
        blobs = try BlobStore(libraryRoot: client.rootURL)
    }

    public func importFiles(at urls: [URL], placement: LibraryHome.Placement = .unplaced) async -> [Result] {
        var results: [Result] = []
        for url in Self.files(in: urls) {
            results.append(await importOne(url, placement: placement))
        }
        return results
    }

    public static func files(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return [url]  
            }
            guard isDirectory.boolValue else { return [url] }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            return files(in: children.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
    }

    public static func libraryKind(of url: URL) -> DocumentKind? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video) {
            .media
        } else if type.conforms(to: .audio) {
            .audio
        } else {
            nil
        }
    }

    private func importOne(_ url: URL, placement: LibraryHome.Placement) async -> Result {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return Result(fileURL: url, outcome: .skipped(reason: "unreadable file"))
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        do {
            if type.conforms(to: .image) {
                return Result(fileURL: url, outcome: try await importImage(url, placement: placement))
            }
            if type.conforms(to: .audio) {
                return Result(fileURL: url, outcome: try await importAudio(url, placement: placement))
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return Result(fileURL: url, outcome: try await importVideo(url, placement: placement))
            }
            return Result(fileURL: url, outcome: .skipped(reason: "not a media file (\(type.identifier))"))
        } catch {
            return Result(fileURL: url, outcome: .skipped(reason: String(describing: error)))
        }
    }

    private func importImage(_ url: URL, placement: LibraryHome.Placement) async throws -> Result.Outcome {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return .skipped(reason: "unreadable image")
        }
        let hash = try await storeBlob(url)
        var item = MediaItem(
            id: UUID().uuidString,
            name: url.deletingPathExtension().lastPathComponent,
            mediaKind: .image,
            classification: .background,
            fileHash: hash,
            fileName: url.lastPathComponent,
            fileStatus: .ready,
            statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false,
            inPoint: nil, outPoint: nil, durationSeconds: nil,
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int
        )
        item.folder = placement.folder(for: .media)
        _ = try await client.create(item, area: placement.area(for: .media)).value
        return .media(id: item.id, status: .ready)
    }

    private func importAudio(_ url: URL, placement: LibraryHome.Placement) async throws -> Result.Outcome {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        let hash = try await storeBlob(url)
        var item = AudioItem(
            id: UUID().uuidString,
            name: url.deletingPathExtension().lastPathComponent,
            fileHash: hash,
            fileName: url.lastPathComponent,
            tags: [], favorite: false,
            durationSeconds: duration
        )
        item.folder = placement.folder(for: .audio)
        _ = try await client.create(item, area: placement.area(for: .audio)).value
        return .audio(id: item.id)
    }

    private func importVideo(_ url: URL, placement: LibraryHome.Placement) async throws -> Result.Outcome {
        let asset = AVURLAsset(url: url)
        let probe = await Self.probeVideo(asset)
        let hash = try await storeBlob(url)
        var item = MediaItem(
            id: UUID().uuidString,
            name: url.deletingPathExtension().lastPathComponent,
            mediaKind: .video,
            classification: .background,
            fileHash: hash,
            fileName: url.lastPathComponent,
            fileStatus: probe.status,
            statusDetail: probe.detail,
            tags: [], favorite: false, collections: [], loops: false,
            inPoint: nil, outPoint: nil,
            durationSeconds: probe.duration,
            pixelWidth: probe.width,
            pixelHeight: probe.height
        )
        item.folder = placement.folder(for: .media)
        _ = try await client.create(item, area: placement.area(for: .media)).value
        return .media(id: item.id, status: probe.status)
    }

    private func storeBlob(_ url: URL) async throws -> String {
        let blobs = self.blobs
        return try await Task.detached(priority: .userInitiated) {
            try blobs.store(fileURL: url)
        }.value
    }

    struct VideoProbe {
        var status: MediaFileStatus
        var detail: String
        var duration: Double?
        var width: Int?
        var height: Int?
    }

    static func probeVideo(_ asset: AVURLAsset) async -> VideoProbe {
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return VideoProbe(status: .needsTranscode, detail: "no video track", duration: nil, width: nil, height: nil)
            }
            let (size, descriptions) = try await track.load(.naturalSize, .formatDescriptions)
            let duration = try await asset.load(.duration).seconds
            let codecs = descriptions.map(CMFormatDescriptionGetMediaSubType)
            let unplayable = codecs.filter { !playableCodecs.contains($0) }
            let status: MediaFileStatus = unplayable.isEmpty ? .ready : .needsTranscode
            let detail = unplayable.isEmpty
                ? ""
                : "unsupported codec: \(unplayable.map(Self.fourCC).joined(separator: ", "))"
            return VideoProbe(
                status: status, detail: detail, duration: duration,
                width: Int(size.width), height: Int(size.height)
            )
        } catch {
            return VideoProbe(
                status: .needsTranscode,
                detail: "unreadable by AVFoundation: \(error.localizedDescription)",
                duration: nil, width: nil, height: nil
            )
        }
    }

    static func fourCC(_ code: CMVideoCodecType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}
