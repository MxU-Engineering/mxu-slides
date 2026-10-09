import AppKit
import PresenterCore
import UniformTypeIdentifiers

extension AppModel {

    func exportChordPro(presentationID: String) {
        Task { @MainActor in
            if let deck = await presentationsFilled([presentationID])[presentationID] {
                exportChordPro(deck)
            }
        }
    }

    func exportChordPro(_ presentation: Presentation) {
        let text = ChordProExport.text(for: presentation)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ChordProExport.fileName(for: presentation)
        panel.allowedContentTypes = [UTType(filenameExtension: "cho") ?? .plainText]
        panel.begin { response in
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
