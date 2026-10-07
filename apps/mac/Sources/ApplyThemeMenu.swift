import PresenterCore
import SwiftUI

struct PendingDeckTheme: Equatable {
    let presentationID: String
    let themeID: String
}

struct DeckThemeMenuItems: View {
    let model: AppModel
    let presentationID: String
    let themes: [LibraryIndex.Entry]
    @Binding var pending: PendingDeckTheme?

    var body: some View {
        let currentThemeID = model.themeID(of: presentationID)
        let edited = model.presentationHasLocalEdits(presentationID)
        Toggle(
            "None",
            isOn: Binding(
                get: { currentThemeID.isEmpty },
                set: { _ in model.applyTheme(to: presentationID, themeID: "") }
            )
        )
        if !themes.isEmpty { Divider() }
        ForEach(themes, id: \.id) { theme in
            let isCurrent = theme.id == currentThemeID
            Toggle(
                theme.name + (isCurrent && edited ? " (edited)" : ""),
                isOn: Binding(
                    get: { isCurrent },
                    set: { _ in

                        if model.presentationHasSlideThemes(presentationID) {
                            pending = PendingDeckTheme(presentationID: presentationID, themeID: theme.id)
                        } else {
                            model.applyTheme(to: presentationID, themeID: theme.id)
                        }
                    }
                )
            )
        }
    }
}

extension View {

    func deckThemeConfirmation(model: AppModel, pending: Binding<PendingDeckTheme?>) -> some View {
        confirmationDialog(
            "Apply \(pending.wrappedValue.flatMap { model.entry($0.themeID)?.name } ?? "this theme") to every slide?",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply to Every Slide") {
                if let chosen = pending.wrappedValue { model.applyTheme(to: chosen.presentationID, themeID: chosen.themeID) }
                pending.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text("Slides that follow a theme of their own will follow this one instead.")
        }
    }
}

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
