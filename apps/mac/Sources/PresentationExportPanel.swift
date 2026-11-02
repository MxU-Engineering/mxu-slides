import AppKit
import PresenterCore
import UniformTypeIdentifiers

extension AppModel {

    func exportPresentation(presentationID: String, render: RenderContext?) {
        Task { @MainActor in
            if let deck = await presentationsFilled([presentationID])[presentationID] {
                exportPresentation(deck, render: render)
            }
        }
    }

    func exportPresentation(
        _ presentation: Presentation, render: RenderContext?, preferred: PresentationExport.Format? = nil
    ) {

        let formats = PresentationExport.formats(for: presentation).filter { render != nil || !$0.rendersSlides }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let options = ExportOptionsAccessory(panel: panel, presentation: presentation, formats: formats)
        panel.accessoryView = options.view
        options.apply(preferred.flatMap { formats.contains($0) ? $0 : nil } ?? options.remembered)
        panel.begin { response in
            withExtendedLifetime(options) {
                if response == .OK, let url = panel.url {
                    let choice = options.choice
                    options.remember()
                    Task { @MainActor in
                        await self.export(presentation, as: choice, to: url, render: render)
                    }
                }
            }
        }
    }

    private func export(
        _ presentation: Presentation, as choice: ExportOptionsAccessory.Choice, to url: URL, render: RenderContext?
    ) async {
        if choice.format.chordProFormat != nil {
            do { try ChordProExport.text(for: presentation).write(to: url, atomically: true, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        } else {
            let activity = ImportActivityModel(title: "Export “\(presentation.name)”")
            activity.finishedHeadline = "Export finished"
            activity.emptyHeadline = "Nothing was exported."
            ImportActivityWindow.present(activity)
            activity.phase = "Reading the presentation…"
            do {
                await client.settled()
                let bundle = try await SlidesPresentationFile.bundle(id: presentation.id, reader: client.reader())
                if choice.format == .slidesFile, let blobs {
                    activity.phase = "Saving media and fonts…"
                    let summary = try await Task.detached(priority: .userInitiated) {
                        try SlidesPresentationFile.write(
                            bundle, blobs: blobs, fonts: SlidesPresentationFile.fontFiles(for: bundle), to: url)
                    }.value
                    activity.finish(
                        summaryLines: ["Saved “\(url.lastPathComponent)”: \(bundle.presentation.slides.count) slides"
                            + (summary.fontCount > 0 ? ", \(summary.fontCount) font files" : "")],
                        warnings: summary.missingFiles.map { "△ Not downloaded to this Mac, left out: \($0)" })
                } else if let render {
                    let pictures = SlideImageExport(
                        model: self, render: render, bundle: bundle, includeMedia: choice.includeMedia)
                    defer { pictures.finish() }
                    activity.phase = "Rendering slides…"
                    let progress = { (done: Int, total: Int) in
                        activity.completed = done
                        activity.total = total
                        activity.detail = "Slide \(done + 1) of \(total)"
                    }
                    if choice.format == .pdf {
                        try await pictures.writePDF(
                            to: url, columns: choice.columns,
                            roundedCorners: UserDefaults.standard.object(forKey: "slideGrid.roundedCorners") as? Bool ?? true,
                            progress: progress)
                        activity.finish(summaryLines: ["Saved “\(url.lastPathComponent)”: \(pictures.items.count) slides"], warnings: [])
                    } else {
                        let written = try await pictures.writeImages(to: url, progress: progress)
                        activity.finish(
                            summaryLines: ["Saved \(written) slide images in “\(url.lastPathComponent)”"],
                            warnings: written < pictures.items.count ? ["△ \(pictures.items.count - written) slides could not be rendered"] : [])
                    }
                } else {
                    activity.finish(summaryLines: [], warnings: ["✕ The library isn't open yet. Try again in a moment."])
                }
            } catch {
                activity.finish(summaryLines: [], warnings: ["✕ \(error.localizedDescription)"])
            }
        }
    }
}

@MainActor
final class ExportOptionsAccessory: NSObject {
    struct Choice {
        var format: PresentationExport.Format
        var columns: Int
        var includeMedia: Bool
    }

    private static let formatKey = "export.format"
    private static let columnsKey = "export.pdfColumns"
    private static let mediaKey = "export.includeMedia"

    let view: NSView
    private let formats: [PresentationExport.Format]
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let columnsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let columnsRow: NSStackView
    private let mediaCheckbox = NSButton(
        checkboxWithTitle: "Include background and foreground media", target: nil, action: nil)
    private weak var panel: NSSavePanel?
    private let presentation: Presentation

    private var named = false

    init(panel: NSSavePanel, presentation: Presentation, formats: [PresentationExport.Format]) {
        self.panel = panel
        self.presentation = presentation
        self.formats = formats
        formatPopup.addItems(withTitles: formats.map(\.label))
        columnsPopup.addItems(withTitles: PresentationExport.Sheet.columnRange.map(String.init))
        let defaults = UserDefaults.standard
        let columns = defaults.object(forKey: Self.columnsKey) as? Int ?? 3
        columnsPopup.selectItem(withTitle: String(columns))
        mediaCheckbox.state = defaults.object(forKey: Self.mediaKey) as? Bool ?? true ? .on : .off
        mediaCheckbox.toolTip = "Show the backgrounds, still graphics and foreground videos each slide plays with, as a still frame. Off: only the slide's own layer."
        let formatRow = NSStackView(views: [NSTextField(labelWithString: "Format:"), formatPopup])
        columnsRow = NSStackView(views: [NSTextField(labelWithString: "Columns:"), columnsPopup])
        let stack = NSStackView(views: [formatRow, columnsRow, mediaCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
    }

    var remembered: PresentationExport.Format {
        let saved = UserDefaults.standard.string(forKey: Self.formatKey).flatMap(PresentationExport.Format.init(rawValue:))
        return saved.flatMap { formats.contains($0) ? $0 : nil } ?? formats.first ?? .slidesFile
    }

    var choice: Choice {
        let format = formats.indices.contains(formatPopup.indexOfSelectedItem) ? formats[formatPopup.indexOfSelectedItem] : remembered
        return Choice(
            format: format,
            columns: Int(columnsPopup.titleOfSelectedItem ?? "") ?? 3,
            includeMedia: mediaCheckbox.state == .on)
    }

    func remember() {
        let choice = choice
        let defaults = UserDefaults.standard
        defaults.set(choice.format.rawValue, forKey: Self.formatKey)
        defaults.set(choice.columns, forKey: Self.columnsKey)
        defaults.set(choice.includeMedia, forKey: Self.mediaKey)
    }

    func apply(_ format: PresentationExport.Format) {
        if let index = formats.firstIndex(of: format) { formatPopup.selectItem(at: index) }
        columnsRow.isHidden = format != .pdf
        mediaCheckbox.isHidden = !format.rendersSlides
        panel?.allowedContentTypes = format.fileExtension.flatMap { UTType(filenameExtension: $0) }.map { [$0] } ?? []

        panel?.nameFieldStringValue = PresentationExport.fileName(
            for: presentation, format: format, typed: named ? panel?.nameFieldStringValue : nil)
        named = true
    }

    @objc private func formatChanged() {
        if formats.indices.contains(formatPopup.indexOfSelectedItem) { apply(formats[formatPopup.indexOfSelectedItem]) }
    }
}
