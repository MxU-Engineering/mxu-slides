import AppKit
import PresenterCore
import UniformTypeIdentifiers

extension AppModel {
    static var presentationFileTypes: [UTType] {
        [UTType(SlidesPresentationFile.typeIdentifier), UTType(filenameExtension: SlidesPresentationFile.fileExtension)]
            .compactMap { $0 }
    }

    static func isPresentationFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == SlidesPresentationFile.fileExtension
    }

    func presentPresentationFileImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.presentationFileTypes
        panel.message = "Choose MxU Slides presentations (.\(SlidesPresentationFile.fileExtension))"
        panel.begin { response in
            if response == .OK, !panel.urls.isEmpty {
                let urls = panel.urls
                Task { @MainActor in await self.importPresentationFiles(urls) }
            }
        }
    }

    func importPresentationFiles(_ urls: [URL]) async {
        let activity = ImportActivityModel(title: "Import Presentation")
        ImportActivityWindow.present(activity)
        activity.phase = "Presentations"
        activity.total = urls.count
        var lines: [String] = []
        var warnings: [String] = []
        var landed: [String] = []
        for (index, url) in urls.enumerated() {
            activity.completed = index
            activity.detail = url.deletingPathExtension().lastPathComponent
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("mxuslides-\(UUID().uuidString)", isDirectory: true)
            do {
                let contents = try await Task.detached(priority: .userInitiated) {
                    try SlidesPresentationFile.read(url, into: scratch)
                }.value
                let conflict = try await SlidesPresentationFile.isInLibrary(contents, client: client)
                    ? askPresentationConflict(name: contents.manifest.name)
                    : .keepBoth
                if let conflict, let blobs {
                    let result = try await SlidesPresentationFile.importContents(
                        contents, client: client, blobs: blobs, placement: newPlacement, conflict: conflict)
                    if conflict == .replace { noteImportReplacedDocuments() }
                    landed.append(result.presentationID)
                    var line = "“\(result.name)”"
                    let added = [
                        result.themesAdded > 0 ? "\(result.themesAdded) theme\(result.themesAdded == 1 ? "" : "s")" : nil,
                        result.mediaAdded > 0 ? "\(result.mediaAdded) media file\(result.mediaAdded == 1 ? "" : "s")" : nil,
                        result.fontsAdded > 0 ? "\(result.fontsAdded) font\(result.fontsAdded == 1 ? "" : "s")" : nil,
                    ].compactMap { $0 }
                    if !added.isEmpty { line += " with " + added.joined(separator: ", ") }
                    lines.append(line)
                    warnings += result.missing.map { "△ \(result.name): the file didn't include \($0)" }
                } else {
                    lines.append("“\(contents.manifest.name)” skipped")
                }
            } catch {
                warnings.append("✕ \(url.lastPathComponent): \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: scratch)
        }
        activity.completed = urls.count
        activity.finish(summaryLines: lines, warnings: warnings)
        if let last = landed.last {
            noteImportSummary("Imported \(landed.count) presentation\(landed.count == 1 ? "" : "s")")
            selectedSection = .presentations
            selectedEntryID = last
            libraryRevealID = last
        }
    }

    private func askPresentationConflict(name: String) -> SlidesPresentationFile.Conflict? {
        let alert = NSAlert()
        alert.messageText = "“\(name)” is already in your library"
        alert.informativeText = "Replace it with the imported copy, or keep both?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .keepBoth
        case .alertSecondButtonReturn: .replace
        default: nil
        }
    }
}

@MainActor
enum PresentationFileOpener {
    static var model: AppModel? {
        didSet { flush() }
    }
    private static var pending: [URL] = []

    static func open(_ urls: [URL]) {
        pending += urls.filter(AppModel.isPresentationFile)
        flush()
    }

    private static func flush() {
        if let model, !pending.isEmpty {
            let urls = pending
            pending = []
            model.whenLibraryReady {
                if UserDefaults.standard.bool(forKey: PresentLayoutController.lockedKey) {
                    let alert = NSAlert()
                    alert.messageText = "Unlock MxU Slides to import"
                    alert.informativeText = "Run-only mode is on. Unlock it, then open the presentation again."
                    alert.runModal()
                } else {
                    Task { @MainActor in await model.importPresentationFiles(urls) }
                }
            }
        }
    }
}
