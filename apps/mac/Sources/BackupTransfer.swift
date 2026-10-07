import AppKit
import Foundation
import PresenterCore

@MainActor
struct BackupTransferRunner {
    let model: AppModel

    private static let optionsDefaultsKey = "import.backup.options"

    static func loadOptions() -> BackupImportOptions {
        var options = BackupImportOptions()
        if let data = UserDefaults.standard.data(forKey: optionsDefaultsKey),
           let stored = try? JSONDecoder().decode(BackupImportOptions.self, from: data) {
            options = stored
        }
        return options
    }

    static func saveOptions(_ options: BackupImportOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: optionsDefaultsKey)
        }
    }

    func presentExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Library \(Date.now.formatted(.iso8601.year().month().day())).mxubackup"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in await export(to: url) }
            }
        }
    }

    func export(to url: URL) async {
        let activity = ImportActivityModel(title: "Export Library Backup")
        activity.finishedHeadline = "Backup saved"
        activity.emptyHeadline = "The backup could not be saved."
        ImportActivityWindow.present(activity)
        do {
            let manifest = try await BackupBundle.export(client: model.client, to: url) {
                activity.apply($0)
            }
            let documents = manifest.documentCounts.values.reduce(0, +)
            var lines = ["\(documents) documents, \(manifest.blobCount) media files"]
            if let fonts = manifest.fontCount, fonts > 0 { lines.append("\(fonts) imported fonts") }
            if let settings = manifest.settingsCount, settings > 0 { lines.append("\(settings) app settings") }
            lines.append("Saved to \(url.path)")
            lines.append("Left out by design: sign-ins, stream keys, the Run-Only PIN, and this Mac's screens and device routing.")
            activity.finish(summaryLines: lines, warnings: [])
        } catch {
            activity.finish(summaryLines: [], warnings: [error.localizedDescription])
        }
    }

    func presentImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an MxU Slides library backup (.mxubackup)"
        panel.prompt = "Import Backup"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in preflight(bundleURL: url) }
            }
        }
    }

    func preflight(bundleURL: URL) {
        let activity = ImportActivityModel(title: "Import Library Backup")
        ImportActivityWindow.present(activity)
        do {
            let scan = try BackupBundle.scan(bundleURL)
            activity.requestBackupOptions(scan: scan, options: Self.loadOptions()) { confirmed in
                if let confirmed {
                    Self.saveOptions(confirmed)
                    Task { @MainActor in
                        await run(bundleURL: bundleURL, options: confirmed, activity: activity)
                    }
                } else {
                    ImportActivityWindow.dismiss()
                }
            }
        } catch {
            activity.emptyHeadline = "That backup can't be imported."
            activity.finish(summaryLines: [], warnings: [error.localizedDescription])
        }
    }

    func run(bundleURL: URL, options: BackupImportOptions, activity: ImportActivityModel) async {
        do {
            let result = try await BackupBundle.restore(
                from: bundleURL, into: model.client, options: options
            ) { activity.apply($0) }
            if result.fontsCopied > 0 {
                FontActivator.activateStored(libraryRoot: model.client.rootURL)
            }
            model.noteExternalMutation()
            if result.merged + result.replaced > 0 {
                model.noteImportReplacedDocuments()
            }
            model.adoptFallbackServiceIfNeeded()
            let lines = Self.summaryLines(result)
            activity.finish(summaryLines: lines, warnings: result.warnings)
            model.noteImportSummary("Backup import: \(lines.joined(separator: "; "))")
        } catch {
            activity.emptyHeadline = "The backup could not be imported."
            activity.finish(summaryLines: [], warnings: [error.localizedDescription])
        }
    }

    static func summaryLines(_ result: BackupRestoreResult) -> [String] {
        var lines = BackupSection.allCases.compactMap { section in
            result.added[section].map { "\($0) new — \(section.title)" }
        }
        if result.merged > 0 { lines.append("\(result.merged) already here — merged with the backup") }
        if result.replaced > 0 { lines.append("\(result.replaced) already here — replaced with the backup's copy") }
        if result.kept > 0 { lines.append("\(result.kept) already here — kept yours") }
        if result.mediaFilesCopied > 0 { lines.append("\(result.mediaFilesCopied) media files") }
        if result.fontsCopied > 0 { lines.append("\(result.fontsCopied) imported fonts") }
        if result.settingsStaged > 0 {
            lines.append("\(result.settingsStaged) app settings — quit and reopen MxU Slides to apply them")
        }
        return lines
    }
}
