import AppKit
import PresenterCore
import UniformTypeIdentifiers

extension AppModel {

    func exportChordPro(presentationID: String) {
        Task { @MainActor in
            if let deck = await presentationsFilled([presentationID])[presentationID] {
                if ChordProExport.isSong(deck) {
                    exportChordPro(deck)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "“\(deck.name)” isn't a song"
                    alert.informativeText = "ChordPro export is for songs: presentations with lyrics or chords."
                    alert.runModal()
                }
            }
        }
    }

    func exportChordPro(_ presentation: Presentation) {
        let text = ChordProExport.text(for: presentation)
        let panel = NSSavePanel()
        let format = ChordProFormatAccessory(panel: panel, presentation: presentation)
        panel.accessoryView = format.view
        format.apply(.plainText)
        panel.begin { response in

            withExtendedLifetime(format) {
                if response == .OK, let url = panel.url {
                    do {
                        try text.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }
}

@MainActor
private final class ChordProFormatAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private let presentation: Presentation

    init(panel: NSSavePanel, presentation: Presentation) {
        self.panel = panel
        self.presentation = presentation
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: ChordProExport.FileFormat.allCases.map(\.label))
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(formatChanged)
    }

    func apply(_ format: ChordProExport.FileFormat) {
        if let index = ChordProExport.FileFormat.allCases.firstIndex(of: format) {
            popup.selectItem(at: index)
        }
        panel?.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]

        let current = panel?.nameFieldStringValue ?? ""
        let base = ChordProExport.FileFormat.allCases
            .map { "." + $0.rawValue }
            .first { current.lowercased().hasSuffix($0) }
            .map { String(current.dropLast($0.count)) }
        panel?.nameFieldStringValue = base.map { $0 + "." + format.rawValue }
            ?? ChordProExport.fileName(for: presentation, format: format)
    }

    @objc private func formatChanged() {
        let formats = ChordProExport.FileFormat.allCases
        if formats.indices.contains(popup.indexOfSelectedItem) {
            apply(formats[popup.indexOfSelectedItem])
        }
    }
}
