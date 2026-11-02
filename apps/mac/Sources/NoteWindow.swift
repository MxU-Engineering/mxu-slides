import AppKit
import PresenterCore
import SwiftUI

struct NoteWindowView: View {
    let model: AppModel
    let noteID: String
    let layout: PresentLayoutController?
    var render: RenderContext? = nil
    var controls: ServiceControls? = nil

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @Environment(\.openWindow) private var openWindow

    static func autosaveName(for noteID: String) -> String { "note.\(noteID)" }

    var body: some View {
        NoteReaderView(model: model, noteID: noteID, host: .window, layout: layout, render: render, controls: controls)
            .background(Color.basePlane)
            .environment(\.runOnly, layout?.runOnly ?? false)
            .background(
                ModuleWindowConfigurator(autosaveName: Self.autosaveName(for: noteID)) {
                    layout?.noteWindowClosed(noteID)
                }
            )
            .navigationTitle(model.indexEntry(noteID)?.name ?? "Note")
            .frame(minWidth: 360, minHeight: 400)
            .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
            .onAppear {
                layout?.noteWindowOpened(noteID)
                WindowBridge.openMain = { openWindow(id: "main") }
            }
    }
}
