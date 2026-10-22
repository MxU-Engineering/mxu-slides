import PresenterCore
import SwiftUI

struct ApplyThemeTarget: Identifiable {
    let id = UUID()
    let presentationID: String
    let slideIDs: [String]?
}

struct ApplyThemeSheet: View {
    let appModel: AppModel
    let render: RenderContext?

    let deckThemeId: String

    let scope: String

    var onNone: (() -> Void)? = nil
    let onApply: (_ themeId: String, _ design: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var looks: [ThemeLook]?

    var body: some View {
        VStack(spacing: 0) {
            ThemeExplorerView(
                appModel: appModel, render: render, deckThemeId: deckThemeId, looks: looks,
                onPickTheme: { apply($0.id, design: nil) }
            ) { themeId, design in
                apply(themeId, design: design.name)
            }
            Divider()
            HStack {
                Text(scope).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let onNone {
                    Button("No Theme") {
                        onNone()
                        dismiss()
                    }
                    .help("Keep the current look as each slide's own and stop following a theme")
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 600)
        .task { looks = await ThemeLook.load(appModel, firstThemeId: deckThemeId) }
    }

    private func apply(_ themeId: String, design: String?) {
        onApply(themeId, design)
        dismiss()
    }
}

struct SlideThemeSheet: View {
    let appModel: AppModel
    let render: RenderContext?
    let model: SlideEditorModel

    @Environment(\.dismiss) private var dismiss

    @State private var looks: [ThemeLook]?

    var body: some View {
        let slide = model.currentSlide
        VStack(spacing: 0) {
            ThemeExplorerView(
                appModel: appModel, render: render, deckThemeId: model.presentation.themeId, looks: looks,
                currentDesign: slide?.themeId?.isEmpty != false ? slide?.themeSlideName : nil
            ) { themeId, design in
                pick(design.name, themeId: themeId)
            }
            Divider()
            HStack {
                Text("Applies to this slide.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Automatic") { pick(nil, themeId: model.presentation.themeId) }
                    .help("Follow the deck's theme with this slide's own kind of design")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 820, height: 600)
        .task { looks = await ThemeLook.load(appModel, firstThemeId: model.presentation.themeId) }
    }

    private func pick(_ name: String?, themeId: String) {
        if let slideID = model.currentSlide?.id {
            model.pickThemeSlide(name, themeId: themeId, for: slideID)
        }
        dismiss()
    }
}
