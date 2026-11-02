import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum NoteMedia {
    public static func blocks(in body: NoteBody) -> [NoteBlock] {
        body.blocks.flatMap(mediaBlocks)
    }

    private static func mediaBlocks(_ block: NoteBlock) -> [NoteBlock] {
        switch block.type {
        case .image: block.url.map(isPicture) == true ? [block] : []
        case .attachment: isMedia(block) ? [block] : []
        case .quote: (block.blocks ?? []).flatMap(mediaBlocks)
        case .list, .taskList: (block.items ?? []).flatMap { ($0.blocks ?? []).flatMap(mediaBlocks) }
        default: []
        }
    }

    private static func isPicture(_ url: String) -> Bool {
        guard !url.isEmpty, !isMailChrome(url) else { return false }
        return URL(string: url)?.scheme.map { fetchedSchemes.contains($0.lowercased()) } ?? true
    }

    private static let fetchedSchemes: Set = ["https", "http", "file", "data"]

    private static func isMedia(_ block: NoteBlock) -> Bool {
        guard block.hexId?.isEmpty == false || block.url?.isEmpty == false else { return false }
        let type = fileType(block)
        return isVideo(block) || type.conforms(to: .image)
    }

    public static func isVideo(_ block: NoteBlock) -> Bool {
        guard block.type == .attachment else { return false }
        let type = fileType(block)
        return block.attachmentKind == "video" || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private static func fileType(_ block: NoteBlock) -> UTType {
        UTType(filenameExtension: (block.filename ?? "").split(separator: ".").last.map(String.init) ?? "") ?? .data
    }

    public static func key(of block: NoteBlock) -> String? {
        switch block.type {
        case .image: block.url
        case .attachment: block.hexId.flatMap { $0.isEmpty ? nil : "hex:" + $0 } ?? block.url
        default: nil
        }
    }

    public static func fetchesByURL(_ block: NoteBlock) -> Bool {
        block.type == .image || block.hexId?.isEmpty != false
    }

    public static func fileName(of block: NoteBlock) -> String {
        switch block.type {
        case .attachment: block.filename?.isEmpty == false ? block.filename! : "attachment"
        default: block.url.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0 == "/" || $0.isEmpty ? nil : $0 } ?? "picture"
        }
    }

    public static func downloadURL(of block: NoteBlock, index: Int, in folder: URL) -> URL {
        folder.appending(path: "\(index)").appending(path: fileName(of: block))
    }

    public static func pending(
        in body: NoteBody, remembered: [NoteMediaImport], libraryHas: (String) -> Bool
    ) -> [NoteBlock] {
        let known = Dictionary(remembered.map { ($0.key, $0.mediaId) }, uniquingKeysWith: { _, last in last })
        return blocks(in: body).filter { block in
            guard let key = key(of: block) else { return false }
            return known[key].map { !libraryHas($0) } ?? true
        }
    }

    public static func importable(
        in body: NoteBody, remembered: [NoteMediaImport], libraryHas: (String) -> Bool
    ) -> [NoteBlock] {
        pending(in: body, remembered: remembered, libraryHas: libraryHas).filter { block in
            fetchesByURL(block) && resolve(block.url ?? "") != nil
        }
    }

    public static func footerLine(for blocks: [NoteBlock]) -> String? {
        let videos = blocks.filter(isVideo).count
        let parts = [(blocks.count - videos, "picture"), (videos, "video")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        guard !parts.isEmpty else { return nil }

        let folder = "Media \u{203A} \(LibraryHome.needsSorted)".replacingOccurrences(of: " ", with: "\u{00A0}")
        return "Also adds \(parts.joined(separator: " and ")) to \(folder)."
    }

    public static func remembering(
        _ remembered: [NoteMediaImport], adding landed: [NoteMediaImport], in body: NoteBody
    ) -> [NoteMediaImport] {
        var byKey = Dictionary(remembered.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        for entry in landed { byKey[entry.key] = entry }
        var seen = Set<String>()
        return blocks(in: body).compactMap(key(of:)).filter { seen.insert($0).inserted }.compactMap { byKey[$0] }
    }

    public static func resolve(_ url: String) -> URL? {
        guard let resolved = URL(string: url),
              let scheme = resolved.scheme?.lowercased(), fetchedSchemes.contains(scheme) else { return nil }
        return resolved
    }

    public static func isMailChrome(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "gstatic.com" || host.hasSuffix(".gstatic.com") || host == "mail.google.com"
            || host.hasPrefix("drive-thirdparty.") && host.hasSuffix(".googleusercontent.com")
    }

    public static func fitted(_ size: CGSize, toWidth width: CGFloat) -> CGSize {
        guard size.width > width, size.width > 0, width > 0 else { return size }
        return CGSize(width: width, height: (size.height * width / size.width).rounded())
    }

    public static func pendingId(for key: String) -> String { pendingPrefix + key }

    public static func key(ofPendingId id: String) -> String? {
        id.hasPrefix(pendingPrefix) ? String(id.dropFirst(pendingPrefix.count)) : nil
    }

    private static let pendingPrefix = "note-media:"

    public static func filling(_ slides: [Slide], remembered: [NoteMediaImport]) -> [Slide]? {
        let ids = Dictionary(remembered.map { ($0.key, $0.mediaId) }, uniquingKeysWith: { _, last in last })
        var changed = false
        func missing(_ key: String) -> String {
            "\(Slide.needsMediaNote) \(key.hasPrefix("hex:") ? "the note's video" : key) did not come in"
        }
        let filled = slides.map { slide -> Slide in
            var slide = slide
            if let key = slide.background.flatMap({ key(ofPendingId: $0.mediaId) }) {
                changed = true
                if let id = ids[key] {
                    slide.background?.mediaId = id
                } else {
                    slide.background = nil
                    slide.autoAdvance = nil
                    slide.notes = missing(key)
                }
            }

            slide.objects = slide.objects.compactMap { object in
                guard let key = object.fill?.mediaId.flatMap(key(ofPendingId:)) else { return object }
                changed = true
                guard let id = ids[key] else {
                    slide.notes = missing(key)
                    return nil
                }
                var object = object
                object.fill?.mediaId = id
                return object
            }
            return slide
        }
        return changed ? filled : nil
    }

    public static func saver(in folder: URL) -> NoteFileReader.SaveMedia {
        { data, name in
            let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let file = folder.appending(path: hash).appending(path: clean.isEmpty ? "picture" : clean)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard (try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                      (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            }
            return file.absoluteString
        }
    }

    public static func localFiles(in body: NoteBody) -> [NoteBlock] {
        blocks(in: body).filter { fetchesByURL($0) && $0.url.flatMap(URL.init(string:))?.isFileURL == true }
    }

    public static func posterTime(duration: Double) -> Double {
        duration >= 2 ? 1 : 0.1
    }
}
