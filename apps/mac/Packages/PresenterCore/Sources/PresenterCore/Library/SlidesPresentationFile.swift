import Foundation

public enum SlidesPresentationFile {
    public static let fileExtension = "mxuslides"

    public static let typeIdentifier = "com.example.mxuslides.presentation"
    public static let formatVersion = 1
    static let manifestName = "manifest.json"
    static let payloadName = "presentation.json"
    static let blobsName = "blobs"
    static let fontsName = "fonts"

    public struct Manifest: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var createdAt: Date
        public var name: String
        public var slideCount: Int
    }

    public struct Payload: Codable, Equatable, Sendable {
        public var presentation: Presentation
        public var themes: [Theme]
        public var media: [MediaItem]
        public var audio: [AudioItem]
    }

    public enum FileError: Error, Equatable, LocalizedError {
        case notAPresentation(String)
        case unsupportedFormat(Int)
        case archive(String)

        public var errorDescription: String? {
            switch self {
            case .notAPresentation(let name):
                "“\(name)” isn't an MxU Slides presentation."
            case .unsupportedFormat(let version):
                "This presentation was made by a newer MxU Slides (format \(version)). Update the app to import it."
            case .archive(let detail):
                detail
            }
        }
    }

    public struct ExportSummary: Equatable, Sendable {
        public var missingFiles: [String]
        public var fontCount: Int
    }

    public static func write(
        _ bundle: DeckBundle, blobs: BlobStore, fonts: [URL], to destination: URL
    ) throws -> ExportSummary {
        let files = FileManager.default
        let holder = try files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: holder) }
        let staging = holder.appendingPathComponent("contents", isDirectory: true)
        let blobsDirectory = staging.appendingPathComponent(blobsName, isDirectory: true)
        let fontsDirectory = staging.appendingPathComponent(fontsName, isDirectory: true)
        try files.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        try files.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)

        let media = bundle.media.values.sorted { $0.id < $1.id }
        let audio = bundle.audio.values.sorted { $0.id < $1.id }
        var missing: [String] = []
        let wanted = media.map { ($0.fileHash, $0.name) } + audio.map { ($0.fileHash, $0.name) }
        var copied = Set<String>()
        for (hash, name) in wanted where !copied.contains(hash) {
            if let source = blobs.url(forHash: hash) {
                try files.copyItem(at: source, to: blobsDirectory.appendingPathComponent(source.lastPathComponent))
                copied.insert(hash)
            } else {
                missing.append(name)
            }
        }
        var fontCount = 0
        for url in fonts {
            if let font = FontSharing.document(forFileAt: url) {
                let target = fontsDirectory.appendingPathComponent("\(font.id).\(font.ext)")
                if !files.fileExists(atPath: target.path) {
                    try files.copyItem(at: url, to: target)
                    fontCount += 1
                }
            }
        }

        let payload = Payload(
            presentation: bundle.presentation,
            themes: bundle.themes.values.sorted { $0.id < $1.id },
            media: media, audio: audio)
        let manifest = Manifest(
            formatVersion: formatVersion, createdAt: Date(),
            name: bundle.presentation.name, slideCount: bundle.presentation.slides.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))
        try encoder.encode(payload).write(to: staging.appendingPathComponent(payloadName))

        let zip = holder.appendingPathComponent(destination.lastPathComponent)
        try ditto(["-c", "-k", "--norsrc", staging.path, zip.path])
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: zip)
        } else {
            try files.moveItem(at: zip, to: destination)
        }
        return ExportSummary(missingFiles: missing.sorted(), fontCount: fontCount)
    }

    @concurrent
    public static func bundle(id: String, reader: LibraryReader) async throws -> DeckBundle {
        var bundle = try await reader.deckBundle(id: id)
        let wanted = audioIDs(in: bundle.presentation).subtracting(bundle.audio.keys)
        let audio = await reader.loadValues(AudioItem.self, ids: wanted.sorted())
        bundle.audio.merge(audio.values) { held, _ in held }
        return bundle
    }

    static func audioIDs(in presentation: Presentation) -> Set<String> {
        Set(presentation.slides.flatMap { $0.actions ?? [] }
            .filter { $0.kind == .fireAudio }
            .compactMap(\.audioItemId)
            .filter { !$0.isEmpty })
    }

    public static func fontFiles(for bundle: DeckBundle) -> [URL] {
        var names = FontSharing.names(in: bundle.presentation)
        for theme in bundle.themes.values { names.formUnion(FontSharing.names(in: theme)) }
        return FontSharing.filesToShare(names: names, shared: [], resolve: FontSharing.resolve).keys
            .sorted { $0.path < $1.path }
    }

    public static func fileName(for presentation: Presentation) -> String {
        PresentationExport.baseName(for: presentation) + "." + fileExtension
    }

    public struct Contents: Sendable {
        public var manifest: Manifest
        public var payload: Payload
        public var directory: URL

        public var blobFiles: [String: URL] {
            let folder = directory.appendingPathComponent(SlidesPresentationFile.blobsName, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return Dictionary(urls.map { ($0.deletingPathExtension().lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        }

        public var fontFiles: [URL] {
            let folder = directory.appendingPathComponent(SlidesPresentationFile.fontsName, isDirectory: true)
            return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    public static func read(_ url: URL, into directory: URL) throws -> Contents {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try ditto(["-x", "-k", url.path, directory.path])
        } catch {
            throw FileError.notAPresentation(url.lastPathComponent)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
           let manifest = try? decoder.decode(Manifest.self, from: data) {
            if manifest.formatVersion > formatVersion {
                throw FileError.unsupportedFormat(manifest.formatVersion)
            } else if let data = try? Data(contentsOf: directory.appendingPathComponent(payloadName)),
                      let payload = try? decoder.decode(Payload.self, from: data) {
                return Contents(manifest: manifest, payload: payload, directory: directory)
            } else {
                throw FileError.notAPresentation(url.lastPathComponent)
            }
        } else {
            throw FileError.notAPresentation(url.lastPathComponent)
        }
    }

    public enum Conflict: Sendable {
        case replace
        case keepBoth
    }

    public struct Existing: Sendable {
        public var themes: Set<String>

        public var media: [String: String]
        public var audio: [String: String]

        public init(themes: Set<String> = [], media: [String: String] = [:], audio: [String: String] = [:]) {
            self.themes = themes
            self.media = media
            self.audio = audio
        }
    }

    public struct Plan: Equatable, Sendable {
        public var presentation: Presentation
        public var themes: [Theme]
        public var media: [MediaItem]
        public var audio: [AudioItem]

        public var hashes: Set<String>

        public var missing: [String]
    }

    public static func plan(
        _ payload: Payload, existing: Existing, files: Set<String>,
        placement: LibraryHome.Placement, presentationID: String? = nil
    ) -> Plan {
        var idMap: [String: String] = [:]
        var media: [MediaItem] = []
        var audio: [AudioItem] = []
        var hashes = Set<String>()
        var missing: [String] = []
        let mediaByHash = firstByHash(existing.media)
        let audioByHash = firstByHash(existing.audio)
        for var item in payload.media where existing.media[item.id] == nil {
            if let id = mediaByHash[item.fileHash] {
                idMap[item.id] = id
            } else if files.contains(item.fileHash) {
                item.folder = placement.folder(for: .media)
                item.folderId = nil
                media.append(item)
                hashes.insert(item.fileHash)
            } else {
                missing.append(item.name)
            }
        }
        for var item in payload.audio where existing.audio[item.id] == nil {
            if let id = audioByHash[item.fileHash] {
                idMap[item.id] = id
            } else if files.contains(item.fileHash) {
                item.folder = placement.folder(for: .audio)
                item.folderId = nil
                audio.append(item)
                hashes.insert(item.fileHash)
            } else {
                missing.append(item.name)
            }
        }
        let themes = payload.themes.filter { !existing.themes.contains($0.id) }
            .map { remapped($0, idMap) ?? $0 }
        var presentation = remapped(payload.presentation, idMap) ?? payload.presentation
        presentation.id = presentationID ?? presentation.id
        presentation.folder = placement.folder(for: .presentation)
        presentation.folderId = nil
        return Plan(
            presentation: presentation, themes: themes, media: media, audio: audio,
            hashes: hashes, missing: missing.sorted())
    }

    private static func firstByHash(_ hashes: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for (id, hash) in hashes.sorted(by: { $0.key < $1.key }) where map[hash] == nil {
            map[hash] = id
        }
        return map
    }

    public struct ImportResult: Equatable, Sendable {
        public var presentationID: String
        public var name: String
        public var themesAdded: Int
        public var mediaAdded: Int
        public var fontsAdded: Int
        public var missing: [String]
    }

    @MainActor
    public static func isInLibrary(_ contents: Contents, client: LibraryClient) async throws -> Bool {
        try await client.settledSnapshot().entry(id: contents.payload.presentation.id) != nil
    }

    @MainActor
    public static func importContents(
        _ contents: Contents, client: LibraryClient, blobs: BlobStore,
        placement: LibraryHome.Placement, conflict: Conflict
    ) async throws -> ImportResult {
        let index = try await client.settledSnapshot()
        let mediaIDs = index.entries(of: .media).map(\.id)
        let audioIDs = index.entries(of: .audio).map(\.id)
        let existing = Existing(
            themes: Set(index.entries(of: .theme).map(\.id)),
            media: try await client.loadValues(MediaItem.self, ids: mediaIDs).values.mapValues(\.fileHash),
            audio: try await client.loadValues(AudioItem.self, ids: audioIDs).values.mapValues(\.fileHash))
        let inLibrary = index.entry(id: contents.payload.presentation.id) != nil
        let blobFiles = contents.blobFiles
        let fontFiles = contents.fontFiles
        let root = client.rootURL
        let plan = plan(
            contents.payload, existing: existing, files: Set(blobFiles.keys), placement: placement,
            presentationID: inLibrary && conflict == .keepBoth ? UUID().uuidString : nil)

        let fontsAdded = try await Task.detached(priority: .userInitiated) {
            for hash in plan.hashes.sorted() {
                if let file = blobFiles[hash] { _ = try blobs.store(fileURL: file) }
            }
            return installFonts(fontFiles, libraryRoot: root)
        }.value

        var writes: [Task<LibraryBatch, any Error>] = []
        for theme in plan.themes { writes.append(client.create(theme, area: placement.area(for: .theme))) }
        for item in plan.media { writes.append(client.create(item, area: placement.area(for: .media))) }
        for item in plan.audio { writes.append(client.create(item, area: placement.area(for: .audio))) }
        if inLibrary && conflict == .replace {
            writes.append(client.replace(plan.presentation, area: placement.area(for: .presentation)))
        } else {
            writes.append(client.create(plan.presentation, area: placement.area(for: .presentation)))
        }
        for write in writes { _ = try await write.value }
        return ImportResult(
            presentationID: plan.presentation.id, name: plan.presentation.name,
            themesAdded: plan.themes.count, mediaAdded: plan.media.count + plan.audio.count,
            fontsAdded: fontsAdded, missing: plan.missing)
    }

    static func remapped<E: Codable>(_ value: E, _ map: [String: String]) -> E? {
        guard !map.isEmpty, let data = try? JSONEncoder().encode(value),
              let tree = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return nil }
        var changed = false
        func walk(_ node: Any) -> Any {
            if let string = node as? String {
                guard let target = map[string] else { return string }
                changed = true
                return target
            } else if let array = node as? [Any] {
                return array.map(walk)
            } else if let object = node as? [String: Any] {
                return Dictionary(object.map { key, value in
                    if let target = map[key] { changed = true; return (target, walk(value)) }
                    return (key, walk(value))
                }, uniquingKeysWith: { first, _ in first })
            } else {
                return node
            }
        }
        let out = walk(tree)
        guard changed, let back = try? JSONSerialization.data(withJSONObject: out, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(E.self, from: back)
    }

    nonisolated static func installFonts(_ files: [URL], libraryRoot: URL) -> Int {
        var installed = 0
        for file in files {
            if let faces = FontSharing.faces(inFileAt: file)?.faces,
               FontSharing.needsInstall(faces: faces, available: FontSharing.isAvailable),
               (try? FontActivator.install(
                   blobURL: file, hash: file.deletingPathExtension().lastPathComponent,
                   ext: file.pathExtension, libraryRoot: libraryRoot)) != nil {
                installed += 1
            }
        }
        return installed
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FileError.archive(detail.isEmpty ? "ditto could not write the file" : detail)
        }
    }
}
