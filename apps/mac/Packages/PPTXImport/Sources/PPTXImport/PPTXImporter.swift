import CryptoKit
import Foundation
import PresenterCore

@MainActor
public struct PPTXImporter {

    public struct DocumentSummary: Sendable {
        public let sourceURL: URL

        public let presentationID: String?
        public let name: String
        public let warnings: [String]
        public let mediaImported: Int

        public var missingFonts: [String]
    }

    private let client: LibraryClient

    private let placement: LibraryHome.Placement

    public init(client: LibraryClient, placement: LibraryHome.Placement = .unplaced) throws {
        self.client = client
        self.placement = placement
        _ = try MediaImporter(client: client)  
    }

    public func importItems(
        at urls: [URL], folder: String? = "PowerPoint Import",
        onDocument: ((URL) -> Void)? = nil
    ) async -> [DocumentSummary] {
        guard let resolver = try? await ImportMediaResolver(client: client, placement: placement) else { return [] }
        var summaries: [DocumentSummary] = []
        for url in expand(urls) {
            onDocument?(url)
            summaries.append(await importOne(url, folder: folder, resolver: resolver))
        }
        return summaries
    }

    private func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [url] }
            guard isDirectory.boolValue else { return [url] }
            return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { ["pptx", "ppt"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        }
    }

    private func importOne(_ url: URL, folder: String?, resolver: ImportMediaResolver) async -> DocumentSummary {
        let fallbackName = url.deletingPathExtension().lastPathComponent

        func skipped(_ reason: String) -> DocumentSummary {
            DocumentSummary(sourceURL: url, presentationID: nil, name: fallbackName,
                            warnings: [reason], mediaImported: 0, missingFonts: [])
        }

        if url.pathExtension.lowercased() == "ppt" {
            return skipped("legacy .ppt is not supported — open it in PowerPoint and save as .pptx")
        }

        let sourceID = Self.presentationID(forSourcePath: url.standardizedFileURL.path)

        var extractedDir: URL?

        defer { extractedDir.map { try? FileManager.default.removeItem(at: $0) } }

        let mapped: PPTXMappedDocument
        var fontWarnings: [String] = []
        do {
            let name = fallbackName
            let id = sourceID
            let staged = try await Task.detached(priority: .userInitiated) { () -> (URL, [PPTXEmbeddedFont]) in
                let root = try PPTXArchive.extract(url)
                return (root, PPTXPresentationParser.embeddedFonts(in: PPTXPackage(root: root)))
            }.value
            extractedDir = staged.0
            for font in staged.1 {
                if let stored = FontActivator.store(
                    dataURL: URL(fileURLWithPath: font.filePath),
                    libraryRoot: client.rootURL
                ) {
                    FontActivator.register(url: stored)
                } else {
                    let variant = font.variant == "regular" ? "" : " (\(font.variant))"
                    fontWarnings.append("embedded font \"\(font.typeface)\"\(variant) could not be activated — restricted or unreadable")
                }
            }

            let extractedRoot = staged.0
            mapped = try await Task.detached(priority: .userInitiated) { () -> PPTXMappedDocument in
                let package = PPTXPackage(root: extractedRoot)
                var warnings: [String] = []
                let parsed = try PPTXPresentationParser.parse(in: package, warnings: &warnings)
                var slides: [PPTXSlide] = []
                for part in parsed.slidePartPaths {
                    slides.append(try PPTXSlideParser.parse(
                        partPath: part, presentationPart: parsed.partPath,
                        in: package, warnings: &warnings))
                }
                let deck = PPTXDeck(
                    slideWidthEMU: parsed.slideWidthEMU, slideHeightEMU: parsed.slideHeightEMU,
                    slides: slides, sections: parsed.sections, warnings: warnings)
                return PPTXDocumentMapper.map(deck, fallbackName: name, sourceID: id)
            }.value
        } catch {
            return skipped("not a readable PowerPoint document: \(error.localizedDescription)")
        }
        var warnings = mapped.warnings + fontWarnings

        var wants = mapped.mediaWants
        if !mapped.bakes.isEmpty, let extractedDir {
            let canvasWidth = mapped.presentation.canvasWidth ?? 1920
            let canvasHeight = mapped.presentation.canvasHeight ?? 1080
            let bakes = mapped.bakes
            wants += await Task.detached(priority: .userInitiated) { () -> [MediaWant] in
                var baked: [MediaWant] = []
                for (index, bake) in bakes.enumerated() {
                    let output = extractedDir.appendingPathComponent("baked-background-\(index).png")
                    if TextureBaker.bake(bake, canvasWidth: canvasWidth, canvasHeight: canvasHeight, to: output) {
                        baked.append(MediaWant(
                            placeholderID: bake.placeholderID,
                            absolutePath: output.path, relativePath: nil))
                    }
                }
                return baked
            }.value
        }

        let resolution = await resolver.resolve(wants, sourceFileURL: url, bundleRoot: extractedDir)
        warnings.append(contentsOf: resolution.warnings)

        var presentation = PPTXDocumentMapper.replacingMediaIDs(mapped.presentation, with: resolution.idMap)
        presentation.folder = folder

        do {

            _ = try await client.replace(presentation, area: placement.area(for: .presentation)).value
        } catch {
            return skipped("could not save: \(error.localizedDescription)")
        }
        return DocumentSummary(
            sourceURL: url,
            presentationID: presentation.id,
            name: presentation.name,
            warnings: warnings,
            mediaImported: resolution.imported,
            missingFonts: mapped.missingFonts
        )
    }

    nonisolated static func presentationID(forSourcePath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        var rest = hex[...]
        var groups: [String] = []
        for length in [8, 4, 4, 4, 12] {
            groups.append(String(rest.prefix(length)))
            rest = rest.dropFirst(length)
        }
        return groups.joined(separator: "-")
    }
}
