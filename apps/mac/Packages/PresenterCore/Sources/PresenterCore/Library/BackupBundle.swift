import Foundation

public enum BackupBundle {
    public struct Manifest: Codable, Equatable, Sendable {
        public let formatVersion: Int
        public let createdAt: Date
        public let documentCounts: [String: Int]
        public let blobCount: Int

        public var fontCount: Int?
        public var settingsCount: Int?

        public var modernVocabulary: Bool?
    }

    public enum BackupError: Error, Equatable, LocalizedError {
        case notABackup(String)
        case unsupportedFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup(let name):
                "“\(name)” isn't an MxU Slides library backup."
            case .unsupportedFormat(let version):
                "This backup was made by a newer MxU Slides (format \(version)). Update the app to import it."
            }
        }
    }

    public static let formatVersion = 1
    static let manifestName = "manifest.json"
    static let usageName = "usage.json"
    static let blobsName = "blobs"
    static let fontsName = "fonts"
    static let postersName = "thumbnails"

    private static let batchSize = 20

    @MainActor
    @discardableResult
    public static func export(
        client: LibraryClient, to destination: URL,
        defaults: UserDefaults = .standard,
        progress: BackupProgressHandler? = nil
    ) async throws -> Manifest {
        let root = client.rootURL
        let settings = BackupSettings.snapshot(defaults: defaults)
        let settingsData = try PropertyListSerialization.data(
            fromPropertyList: settings, format: .binary, options: 0)
        let usage = try await client.allUsage().mapValues(\.timeIntervalSince1970)
        let usageData = try JSONEncoder().encode(usage)
        let settingsCount = settings.count

        return try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let holder = try files.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: destination, create: true)
            defer { try? files.removeItem(at: holder) }
            let staging = holder.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: true)

            await progress?(BackupProgress(phase: "Copying documents…"))
            var counts: [String: Int] = [:]
            for kind in DocumentKind.allCases {
                let target = staging.appendingPathComponent(kind.directoryName, isDirectory: true)
                try files.copyItem(
                    at: root.appendingPathComponent(kind.directoryName, isDirectory: true),
                    to: target)
                counts[kind.rawValue] = documentFiles(in: target).count
            }

            let blobs = try await copyMissing(
                from: root.appendingPathComponent(blobsName, isDirectory: true),
                to: staging.appendingPathComponent(blobsName, isDirectory: true),
                phase: "Copying media files…", strict: true, progress: progress)
            let fonts = try await copyMissing(
                from: root.appendingPathComponent(fontsName, isDirectory: true),
                to: staging.appendingPathComponent(fontsName, isDirectory: true),
                phase: "Copying fonts…", strict: true, progress: progress)
            _ = try await copyMissing(
                from: root.appendingPathComponent(postersName, isDirectory: true),
                to: staging.appendingPathComponent(postersName, isDirectory: true),
                phase: "Copying media posters…", strict: true, progress: progress)

            await progress?(BackupProgress(phase: "Finishing…"))
            try usageData.write(to: staging.appendingPathComponent(usageName))
            try settingsData.write(to: staging.appendingPathComponent(BackupSettings.fileName))

            let manifest = Manifest(
                formatVersion: formatVersion,
                createdAt: Date(),
                documentCounts: counts,
                blobCount: blobs.copied,
                fontCount: fonts.copied,
                settingsCount: settingsCount,
                modernVocabulary: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))

            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: destination)
            }
            return manifest
        }.value
    }

    public static func manifest(at bundleURL: URL) throws -> Manifest {
        let manifestURL = bundleURL.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw BackupError.notABackup(bundleURL.lastPathComponent)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.formatVersion <= formatVersion else {
            throw BackupError.unsupportedFormat(manifest.formatVersion)
        }
        return manifest
    }

    public static func scan(_ bundleURL: URL) throws -> BackupScan {
        let manifest = try manifest(at: bundleURL)
        var counts: [BackupSection: Int] = [:]
        for kind in DocumentKind.allCases {
            counts[BackupSection.section(for: kind), default: 0] += documentFiles(
                in: bundleURL.appendingPathComponent(kind.directoryName, isDirectory: true)).count
        }
        counts[.mediaFiles] = plainFiles(
            in: bundleURL.appendingPathComponent(blobsName, isDirectory: true)).count
        counts[.fonts] = plainFiles(
            in: bundleURL.appendingPathComponent(fontsName, isDirectory: true)).count
        counts[.settings] = BackupSettings.read(fromBundle: bundleURL).count
        return BackupScan(manifest: manifest, counts: counts)
    }

    @MainActor
    @discardableResult
    public static func restore(
        from bundleURL: URL, into client: LibraryClient,
        options: BackupImportOptions = BackupImportOptions(),
        defaults: UserDefaults = .standard,
        progress: BackupProgressHandler? = nil
    ) async throws -> BackupRestoreResult {
        var result = BackupRestoreResult(manifest: try manifest(at: bundleURL))
        result.warnings = integrityWarnings(bundleURL: bundleURL, manifest: result.manifest)
        let root = client.rootURL

        let work = DocumentKind.allCases
            .filter { options.includes(BackupSection.section(for: $0)) }
            .flatMap { kind in
                documentFiles(in: bundleURL.appendingPathComponent(kind.directoryName, isDirectory: true))
                    .map { RestoreItem(kind: kind, id: $0.deletingPathExtension().lastPathComponent, file: $0) }
            }

        let size = LibraryClient.bulkChunkSize
        for start in stride(from: 0, to: work.count, by: size) {
            let chunk = Array(work[start..<min(start + size, work.count)])
            progress?(BackupProgress(
                phase: "Importing documents…", detail: chunk[0].kind.directoryName,
                completed: start, total: work.count))
            let landings = try await client.engine.restore(chunk, policy: options.policy)
            for (item, landing) in zip(chunk, landings) {
                switch landing {
                case .success(.added): result.added[BackupSection.section(for: item.kind), default: 0] += 1
                case .success(.merged): result.merged += 1
                case .success(.replaced): result.replaced += 1
                case .success(.kept): result.kept += 1
                case .failure(let error):
                    result.warnings.append(
                        "\(item.kind.directoryName)/\(item.id) could not be imported: \(error.localizedDescription)")
                }
            }
        }

        if options.includes(.mediaFiles) {
            let blobs = try await copyMissing(
                from: bundleURL.appendingPathComponent(blobsName, isDirectory: true),
                to: root.appendingPathComponent(blobsName, isDirectory: true),
                phase: "Copying media files…", strict: false, progress: progress)
            result.mediaFilesCopied = blobs.copied
            result.warnings += blobs.failures
        }
        if options.includes(.media) {

            let posters = try await copyMissing(
                from: bundleURL.appendingPathComponent(postersName, isDirectory: true),
                to: root.appendingPathComponent(postersName, isDirectory: true),
                phase: "Copying media posters…", strict: false, progress: progress)
            result.warnings += posters.failures
        }
        if options.includes(.fonts) {
            let fonts = try await copyMissing(
                from: bundleURL.appendingPathComponent(fontsName, isDirectory: true),
                to: root.appendingPathComponent(fontsName, isDirectory: true),
                phase: "Copying fonts…", strict: false, progress: progress)
            result.fontsCopied = fonts.copied
            result.warnings += fonts.failures
        }
        if options.includes(.settings) {
            result.settingsStaged = BackupSettings.stage(
                BackupSettings.read(fromBundle: bundleURL),
                policy: options.policy, defaults: defaults)
        }

        progress?(BackupProgress(phase: "Finishing…"))
        await mergeUsage(from: bundleURL, into: client, warnings: &result.warnings)
        if result.documentsLanded > 0, result.manifest.modernVocabulary != true {
            progress?(BackupProgress(phase: "Updating documents from an older backup…"))
            try await normalize(bundleURL: bundleURL, options: options, client: client)
        }
        return result
    }

    struct RestoreItem: Sendable {
        var kind: DocumentKind
        var id: String
        var file: URL
    }

    enum Landing: Sendable { case added, merged, replaced, kept }

    private static func integrityWarnings(bundleURL: URL, manifest: Manifest) -> [String] {
        var warnings: [String] = []
        for kind in DocumentKind.allCases {
            let expected = manifest.documentCounts[kind.rawValue] ?? 0
            let found = documentFiles(
                in: bundleURL.appendingPathComponent(kind.directoryName, isDirectory: true)).count
            if found < expected {
                warnings.append(
                    "This backup is incomplete: \(kind.directoryName) lists \(expected) documents but holds \(found).")
            }
        }
        let blobsFound = plainFiles(
            in: bundleURL.appendingPathComponent(blobsName, isDirectory: true)).count
        if blobsFound < manifest.blobCount {
            warnings.append(
                "This backup is incomplete: it lists \(manifest.blobCount) media files but holds \(blobsFound).")
        }
        return warnings
    }

    @MainActor
    private static func mergeUsage(from bundleURL: URL, into client: LibraryClient, warnings: inout [String]) async {
        if let data = try? Data(contentsOf: bundleURL.appendingPathComponent(usageName)),
           let stamps = try? JSONDecoder().decode([String: Double].self, from: data) {
            do {
                _ = try await client.mergeUsage(stamps.mapValues(Date.init(timeIntervalSince1970:))).value
            } catch {
                warnings.append("Last-used history could not be imported: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private static func normalize(
        bundleURL: URL, options: BackupImportOptions, client: LibraryClient
    ) async throws {

        let legacyBoard = bundleURL
            .appendingPathComponent("build-presets", isDirectory: true)
            .appendingPathComponent("build-preset-board")
            .appendingPathExtension("automerge")
        if options.includes(.presetBoards), FileManager.default.fileExists(atPath: legacyBoard.path) {
            let stagedDir = client.rootURL
                .appendingPathComponent("build-presets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: stagedDir, withIntermediateDirectories: true
            )
            let staged = stagedDir
                .appendingPathComponent("build-preset-board")
                .appendingPathExtension("automerge")
            if !FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.copyItem(at: legacyBoard, to: staged)
            }
        }

        _ = try await client.maintain { library in
            try library.normalizeMediaObjects()
            try library.normalizeAnimationVocabulary()
        }.value
    }

    private static func documentFiles(in directory: URL) -> [URL] {
        plainFiles(in: directory).filter { $0.pathExtension == "automerge" }
    }

    private static func plainFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func copyMissing(
        from source: URL, to destination: URL, phase: String, strict: Bool,
        progress: BackupProgressHandler?
    ) async throws -> (copied: Int, failures: [String]) {
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            let sources = plainFiles(in: source)
            var copied = 0
            var failures: [String] = []
            if !sources.isEmpty {
                try files.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            for (offset, file) in sources.enumerated() {
                if offset % batchSize == 0 {
                    await progress?(BackupProgress(
                        phase: phase, detail: file.lastPathComponent,
                        completed: offset, total: sources.count))
                }
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if !files.fileExists(atPath: target.path) {
                    do {
                        try files.copyItem(at: file, to: target)
                        copied += 1
                    } catch {
                        if strict { throw error }
                        failures.append(
                            "\(file.lastPathComponent) could not be copied: \(error.localizedDescription)")
                    }
                }
            }
            return (copied, failures)
        }.value
    }
}

extension LibraryEngine {

    func restore(
        _ items: [BackupBundle.RestoreItem], policy: BackupConflictPolicy
    ) throws -> [Result<BackupBundle.Landing, any Error>] {
        var landings: [Result<BackupBundle.Landing, any Error>] = []
        _ = try publishing {
            for item in items {
                landings.append(Result { try restoreOne(SyncScope.entityType(for: item.kind), item: item, policy: policy) })
            }
        }
        return landings
    }

    private func restoreOne<E: DocumentEntity>(
        _ type: E.Type, item: BackupBundle.RestoreItem, policy: BackupConflictPolicy
    ) throws -> BackupBundle.Landing {
        let bundled = try TypedDocument<E>(data: Data(contentsOf: item.file))
        let exists = try opened().store.exists(kind: item.kind, id: item.id)
        let listed = Library.listedKinds.contains(item.kind)
        var landing = BackupBundle.Landing.added
        if exists, policy == .keepMine {
            landing = .kept
        } else if exists, policy == .merge {

            let document = try replica(type, id: item.id)
            try document.merge(bundled)
            try persist(document, origin: .local, listed: listed)
            landing = .merged
        } else {
            if exists {

                try dropFile(kind: item.kind, id: item.id)
                landing = .replaced
            }
            try persist(bundled, origin: .local, listed: listed)
        }
        return landing
    }
}
