import Foundation
import PresenterCore

@MainActor
public struct ProPresenterImporter {


    let client: LibraryClient

    let placement: LibraryHome.Placement

    public init(client: LibraryClient, placement: LibraryHome.Placement = .unplaced) throws {
        self.client = client
        self.placement = placement
        _ = try MediaImporter(client: client)  
    }

    public func importItems(
        at urls: [URL], folder: String? = "ProPresenter Import",
        policy: ImportConflictPolicy = .updateUnedited,
        onDocument: ((URL) -> Void)? = nil
    ) async -> [DocumentSummary] {
        guard let resolver = try? await ImportMediaResolver(client: client, placement: placement) else { return [] }

        let writer = await ImportWriter(client: client, policy: policy, placement: placement)
        let summaries = await importItems(
            at: urls, folder: folder, resolver: resolver, writer: writer,
            onDocument: onDocument)
        writer.saveLedger()
        return summaries
    }

    func importItems(
        at urls: [URL], folder: String?, resolver: ImportMediaResolver,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:],
        bundleRoot: URL? = nil,
        writer: ImportWriter,
        importMedia: Bool = true,
        onDocument: ((URL) -> Void)? = nil
    ) async -> [DocumentSummary] {
        var summaries: [DocumentSummary] = []
        for url in expand(urls) {
            onDocument?(url)
            summaries.append(await importOne(
                url, folder: folder, resolver: resolver,
                timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, bundleRoot: bundleRoot,
                writer: writer, importMedia: importMedia))
        }
        return summaries
    }

    func countDocuments(at urls: [URL]) -> Int {
        expand(urls).count
    }

    private func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [url] }
            guard isDirectory.boolValue else { return [url] }
            let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { ["pro", "probundle"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            return contents
        }
    }

    private func importOne(
        _ url: URL, folder: String?, resolver: ImportMediaResolver,
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String] = [:],
        bundleRoot outerBundleRoot: URL? = nil,
        writer: ImportWriter,
        importMedia: Bool = true
    ) async -> DocumentSummary {
        let fallbackName = url.deletingPathExtension().lastPathComponent

        func skipped(_ reason: String) -> DocumentSummary {
            DocumentSummary(sourceURL: url, presentationID: nil, name: fallbackName,
                            warnings: [reason], mediaImported: 0)
        }

        var proFileURL = url

        var bundleRoot: URL? = outerBundleRoot
        var extractedDir: URL?
        defer { extractedDir.map { try? FileManager.default.removeItem(at: $0) } }

        if url.pathExtension.lowercased() == "probundle" {
            do {

                let extracted = try await Task.detached(priority: .userInitiated) {
                    try Self.extractBundle(url)
                }.value
                extractedDir = extracted
                bundleRoot = extracted
                guard let pro = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension.lowercased() == "pro" })
                else { return skipped("no .pro document inside the bundle") }
                proFileURL = pro
            } catch {
                return skipped("could not extract bundle: \(error.localizedDescription)")
            }
        }

        let mapped: ProMappedDocument
        do {
            let fileURL = proFileURL
            let timerIDs = timerIDsByProUUID
            let timerNames = timerIDsByName
            let name = fallbackName
            mapped = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: fileURL)
                let document = try RVData_Presentation(serializedBytes: data)
                return ProDocumentMapper.map(
                    document, fallbackName: name,
                    timerIDsByProUUID: timerIDs, timerIDsByName: timerNames)
            }.value
        } catch {
            return skipped("not a readable ProPresenter 7 document: \(error.localizedDescription)")
        }
        var warnings = mapped.warnings

        if let reason = await writer.check(
            Presentation.self, id: mapped.presentation.id, label: mapped.presentation.name
        ) {
            return DocumentSummary(
                sourceURL: url, presentationID: mapped.presentation.id,
                name: mapped.presentation.name, warnings: [], mediaImported: 0,
                groupHotKeys: mapped.groupHotKeys, skipped: reason
            )
        }

        let resolution = await resolver.resolve(
            mapped.mediaWants, sourceFileURL: proFileURL, bundleRoot: bundleRoot,
            importNew: importMedia)
        warnings.append(contentsOf: resolution.warnings)
        let importedCount = resolution.imported
        await applyMediaSettings(from: mapped.mediaWants, resolution: resolution)

        var presentation = ProDocumentMapper.replacingMediaIDs(mapped.presentation, with: resolution.idMap)
        presentation.folder = folder

        guard await writer.write(presentation, label: presentation.name, warnings: &warnings) else {
            return skipped("could not save: \(warnings.last ?? "unknown error")")
        }
        return DocumentSummary(
            sourceURL: url,
            presentationID: presentation.id,
            name: presentation.name,
            warnings: warnings,
            mediaImported: importedCount,
            groupHotKeys: mapped.groupHotKeys,
            mediaWithheld: resolution.withheld
        )
    }

    private func applyMediaSettings(from wants: [ProMediaWant], resolution: ImportMediaResolver.Resolution) async {
        for want in wants {
            let hasSettings = want.inPoint != nil || want.outPoint != nil
                || want.playRate != nil || want.fadeSeconds != nil
                || want.classification != nil || want.loops != nil
            guard hasSettings,
                  let id = resolution.idMap[want.placeholderID],
                  resolution.importedIDs.contains(id),
                  !resolution.audioIDs.contains(id)
            else { continue }

            _ = await client.modify(MediaItem.self, id: id) { item in
                if let classification = want.classification { item.classification = classification }
                if let loops = want.loops { item.loops = loops }
                if let inPoint = want.inPoint { item.inPoint = inPoint }
                if let outPoint = want.outPoint { item.outPoint = outPoint }
                if let rate = want.playRate { item.playRate = rate }
                if let fade = want.fadeSeconds {

                    item.transition = Transition(transitionKind: .dissolve, durationSeconds: fade)
                }
            }.result
        }
    }

    public func importPlaylistBundle(at url: URL, folder: String? = "ProPresenter Import") async -> PlaylistBundleSummary {
        var summary = PlaylistBundleSummary()
        guard let resolver = try? await ImportMediaResolver(client: client, placement: placement) else {
            summary.failureReason = "the media store could not open"
            return summary
        }
        let extracted: URL
        do {
            extracted = try await Task.detached(priority: .userInitiated) {
                try Self.extractBundle(url)
            }.value
        } catch {
            summary.failureReason = "could not extract the bundle: \(error.localizedDescription)"
            return summary
        }
        defer { try? FileManager.default.removeItem(at: extracted) }

        let playlistDocs: [(doc: RVData_PlaylistDocument, url: URL)] = await Task.detached(priority: .userInitiated) {
            var found: [(doc: RVData_PlaylistDocument, url: URL)] = []
            var seenRoots = Set<String>()
            let files = (FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            for file in files where file.pathExtension.lowercased() != "pro" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
                guard size < 32 * 1024 * 1024, let data = try? Data(contentsOf: file) else { continue }
                guard let doc = try? RVData_PlaylistDocument(serializedBytes: data) else { continue }
                let leaves = ProPlaylistMapper.leafPlaylists(under: doc.rootNode)
                guard leaves.contains(where: { !$0.uuid.string.isEmpty }) else { continue }
                let rootID = doc.rootNode.uuid.string.lowercased()
                guard seenRoots.insert(rootID.isEmpty ? file.path : rootID).inserted else { continue }
                found.append((doc, file))
            }
            return found
        }.value
        guard !playlistDocs.isEmpty else {
            summary.failureReason = "no playlist was found in the bundle"
            return summary
        }

        let writer = await ImportWriter(client: client, policy: .updateUnedited, placement: placement)
        summary.documents = await importItems(
            at: [extracted], folder: folder, resolver: resolver, bundleRoot: extracted,
            writer: writer)
        summary.mediaImported += summary.documents.reduce(0) { $0 + $1.mediaImported }

        let rootPath = extracted.standardizedFileURL.path
        var byOriginalPath: [String: String] = [:]
        var byFileName: [String: String?] = [:]  
        for document in summary.documents {
            guard let id = document.presentationID else { continue }
            let standardized = document.sourceURL.standardizedFileURL.path
            if standardized.hasPrefix(rootPath) {
                byOriginalPath[String(standardized.dropFirst(rootPath.count))] = id
            }
            let fileName = document.sourceURL.lastPathComponent.lowercased()
            byFileName[fileName] = byFileName.keys.contains(fileName) ? Optional<String>.none : id
        }
        func resolvePresentation(_ ref: ProPlaylistPresentationRef) -> String? {
            if let absolute = ref.absolutePath {
                let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
                if let id = byOriginalPath[standardized] { return id }
                if let id = byFileName[URL(fileURLWithPath: standardized).lastPathComponent.lowercased()] ?? nil { return id }
            }
            if let relative = ref.relativePath,
               let id = byFileName[URL(fileURLWithPath: relative).lastPathComponent.lowercased()] ?? nil {
                return id
            }
            return nil
        }

        for (doc, docURL) in playlistDocs {
            let mapped = ProPlaylistMapper.mapPresentationPlaylists(doc, resolvePresentation: resolvePresentation)
            let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: docURL, bundleRoot: extracted)
            summary.mediaImported += resolution.imported
            summary.warnings.append(contentsOf: resolution.warnings)
            for mappedService in mapped.services {
                let (service, dropped) = ProPlaylistMapper.replacingMediaIDs(
                    mappedService.service, with: resolution.idMap, audioIDs: resolution.audioIDs)
                if await writer.check(
                    Service.self, id: service.id, label: "playlist \"\(service.name)\""
                ) == nil,
                    await writer.write(
                        service, label: "playlist \"\(service.name)\"",
                        warnings: &summary.warnings) {
                    summary.services.append(service.name)
                }
                summary.warnings.append(contentsOf: (mappedService.warnings + dropped).map { "playlist \"\(service.name)\": \($0)" })
            }
        }
        writer.saveLedger()
        appendSkipSummary(from: writer, into: &summary.warnings)
        if summary.services.isEmpty, summary.documents.isEmpty {
            summary.failureReason = "the bundle contained nothing importable"
        }
        return summary
    }

    func appendSkipSummary(from writer: ImportWriter, into warnings: inout [String]) {
        if writer.skippedExisting > 0 {
            warnings.append(
                "\(writer.skippedExisting) already here — kept yours (policy: only add new)")
        }
        if !writer.skippedEdited.isEmpty {
            warnings.append(
                "\(writer.skippedEdited.count) skipped — edited here since import: \(writer.skippedEdited.joined(separator: ", "))")
        }
    }

    nonisolated static func extractBundle(_ url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("probundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", url.path, destination.path]
        let stderr = Pipe()
        ditto.standardError = stderr
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ImportError.extractFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+rwX", destination.path]
        try chmod.run()
        chmod.waitUntilExit()

        return destination
    }

    enum ImportError: LocalizedError {
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .extractFailed(let detail):
                return detail.isEmpty ? "ditto could not extract the bundle" : detail
            }
        }
    }
}
