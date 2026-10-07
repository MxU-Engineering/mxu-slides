import Foundation
import PresenterCore

public struct ProThemeImportSummary: Sendable {
    public var sourceURL: URL
    public var themeID: String?
    public var name: String
    public var warnings: [String]
    public var mediaImported: Int

    public var skipped: ImportSkipReason?
}

extension ProPresenterImporter {

    public func importTheme(at url: URL, policy: ImportConflictPolicy = .updateUnedited) async -> ProThemeImportSummary {
        let fallbackName = url.deletingPathExtension().lastPathComponent
        func failed(_ reason: String) -> ProThemeImportSummary {
            ProThemeImportSummary(sourceURL: url, themeID: nil, name: fallbackName, warnings: [reason], mediaImported: 0)
        }
        guard let resolver = try? await ImportMediaResolver(client: client, placement: placement) else { return failed("could not open the media library") }
        let writer = await ImportWriter(client: client, policy: policy, placement: placement)
        defer { writer.saveLedger() }

        var root = url
        var extractedDir: URL?
        defer { extractedDir.map { try? FileManager.default.removeItem(at: $0) } }
        if url.pathExtension.lowercased() == "protheme" {
            do {
                let extracted = try await Task.detached(priority: .userInitiated) { try Self.extractBundle(url) }.value
                extractedDir = extracted
                root = extracted
            } catch {
                return failed("could not extract the theme: \(error.localizedDescription)")
            }
        }
        guard let themeFile = Self.themeFile(under: root) else { return failed("no Theme document inside") }

        let name = themeFile.lastPathComponent == "Theme" ? themeFile.deletingLastPathComponent().lastPathComponent : fallbackName

        let mapped: ProMappedTheme
        do {
            let fileURL = themeFile
            mapped = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: fileURL)
                let document = try RVData_Template.Document(serializedBytes: data)
                return ProWorkspaceMapper.mapTheme(document, name: name)
            }.value
        } catch {
            return failed("not a readable ProPresenter theme: \(error.localizedDescription)")
        }
        var warnings = mapped.warnings
        if let reason = await writer.check(Theme.self, id: mapped.theme.id, label: "theme \"\(name)\"") {
            return ProThemeImportSummary(sourceURL: url, themeID: mapped.theme.id, name: name, warnings: [], mediaImported: 0, skipped: reason)
        }

        let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: themeFile, bundleRoot: extractedDir)
        warnings.append(contentsOf: resolution.warnings)
        var theme = mapped.theme
        theme.slides = theme.slides.map { slides in
            slides.map { slide in
                var slide = slide
                let carrier = Presentation(id: "carrier", name: "", presentationKind: .deck, themeId: "", slides: [Slide(id: "carrier", name: "", objects: slide.objects)])
                slide.objects = ProDocumentMapper.replacingMediaIDs(carrier, with: resolution.idMap).slides[0].objects
                return slide
            }
        }
        guard await writer.write(theme, label: "theme \"\(name)\"", warnings: &warnings) else {
            return failed("could not save: \(warnings.last ?? "unknown error")")
        }
        return ProThemeImportSummary(sourceURL: url, themeID: theme.id, name: name, warnings: warnings, mediaImported: resolution.imported)
    }

    nonisolated static func themeFile(under root: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return root.lastPathComponent == "Theme" ? root : nil }
        let direct = root.appendingPathComponent("Theme")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let nested = child.appendingPathComponent("Theme")
            if FileManager.default.fileExists(atPath: nested.path) { return nested }
        }
        return nil
    }
}
