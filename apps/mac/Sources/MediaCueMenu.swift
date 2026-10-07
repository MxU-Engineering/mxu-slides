import AppKit
import PresenterCore
import SwiftUI

@MainActor @Observable
final class MediaCueMenuState {
    var settingsTargetID: String?
    var autoAdvanceTargetID: String?
    var actionsEditorTargetID: String?
    var actionPicker: ActionPicker?
    var actionPlacement: ActionPlacement?
    var renameTargetID: String?
    var renameText = ""

    struct ActionPicker: Identifiable {
        let id = UUID()
        var mediaItemID: String
        var actionID: String
        var kind: DocumentKind
    }

    struct ActionPlacement: Identifiable {
        var mediaItemID: String
        var draft: SlideAction
        var id: String { draft.id }
    }
}

struct MediaCueMenuItems: View {
    let model: AppModel
    let actionRouter: ActionRouter?
    let mediaID: String
    let state: MediaCueMenuState

    var fallbackName: String? = nil

    var includesCueGrammar = true

    var body: some View {
        if model.media(mediaID) == nil {

            Text("Deleted from the library")
            Button("Restore Media File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.image, .movie]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        if let carried = await model.restoreMediaReference(
                            id: mediaID, suggestedName: fallbackName, with: url
                        ) {
                            MediaRelinkAlerts.carriedSettingsWarning(
                                itemName: url.deletingPathExtension().lastPathComponent,
                                carried: carried
                            )
                        }
                    }
                }
            }
        }
        if let item = model.media(mediaID) {

            Button("Media Settings…") { state.settingsTargetID = mediaID }
            Button("Rename…") {
                state.renameText = item.name
                state.renameTargetID = mediaID
            }
            Divider()
            if includesCueGrammar {
                MediaCueGrammarItems(
                    model: model, actionRouter: actionRouter, mediaID: mediaID, state: state
                )
                Divider()
            }

            Picker("Classification", selection: Binding(
                get: { model.media(mediaID)?.classification ?? .foreground },
                set: { value in model.updateMedia(mediaID) { $0.classification = value } }
            )) {
                Text("Foreground").tag(MediaClassification.foreground)
                Text("Background").tag(MediaClassification.background)
            }
            if item.mediaKind == .video {

                Picker("Loop", selection: Binding(
                    get: { model.media(mediaID)?.loops ?? false },
                    set: { value in model.updateMedia(mediaID) { $0.loops = value } }
                )) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
            }
            Picker("Favorite", selection: Binding(
                get: { model.media(mediaID)?.favorite ?? false },
                set: { value in model.updateMedia(mediaID) { $0.favorite = value } }
            )) {
                Text("Yes").tag(true)
                Text("No").tag(false)
            }
            Divider()

            Button("Replace Media File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.image, .movie]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        if let carried = await model.replaceMediaFile(mediaID, with: url) {
                            MediaRelinkAlerts.carriedSettingsWarning(itemName: item.name, carried: carried)
                        }
                    }
                }
            }
        }
    }
}

struct MediaCueGrammarItems: View {
    let model: AppModel
    let actionRouter: ActionRouter?
    let mediaID: String
    let state: MediaCueMenuState

    var body: some View {
        if let item = model.media(mediaID) {
            Menu("Add Action") {
                AddActionMenuItems(
                    model: model,
                    timers: actionRouter?.timerChoices ?? []
                ) { action in
                    addAction(action, to: item)
                }
            }
            let actions = item.actions ?? []
            if !actions.isEmpty {

                let timers = actionRouter?.timerChoices ?? []
                Menu("Edit Action") {
                    ForEach(actions) { action in
                        Button(slideActionLabel(
                            action, model: model, timers: timers,
                            confidenceScreens: actionRouter?.confidenceScreenChoices ?? [])) {
                            state.actionsEditorTargetID = mediaID
                        }
                    }
                }
                Menu("Remove Action") {
                    ForEach(actions) { action in
                        Button(
                            slideActionLabel(
                                action, model: model, timers: timers,
                                confidenceScreens: actionRouter?.confidenceScreenChoices ?? []),
                            role: .destructive
                        ) {
                            model.updateMedia(mediaID) { media in
                                let kept = (media.actions ?? []).filter { $0.id != action.id }
                                media.actions = kept.isEmpty ? nil : kept
                            }
                        }
                    }
                }
            }
            Button(item.autoAdvance == nil ? "Auto Advance…" : "Auto Advance… ✓") {
                state.autoAdvanceTargetID = mediaID
            }
        }
    }

    private func addAction(_ action: SlideAction, to item: MediaItem) {

        state.actionPlacement = .init(mediaItemID: item.id, draft: action)
    }
}

extension View {

    func mediaCueSheets(model: AppModel, state: MediaCueMenuState) -> some View {
        modifier(MediaCueSheets(model: model, state: state))
    }
}

private struct MediaCueSheets: ViewModifier {
    let model: AppModel
    @Bindable var state: MediaCueMenuState

    func body(content: Content) -> some View {
        content
            .sheet(item: target(\.settingsTargetID)) { target in
                MediaSettingsSheet(model: model, mediaID: target.id)
            }
            .sheet(item: target(\.autoAdvanceTargetID)) { target in
                AutoAdvanceSheet(
                    slideName: name(of: target.id),
                    advance: Binding(
                        get: { model.media(target.id)?.autoAdvance },
                        set: { advance in
                            model.updateMedia(target.id) { $0.autoAdvance = advance }
                        }
                    ),
                    mediaScope: true,

                    showsCountFrom: model.media(target.id)?.mediaKind == .video
                )
            }
            .sheet(item: target(\.actionsEditorTargetID)) { target in

                SlideActionsSheet(
                    model: model,
                    slideName: name(of: target.id),
                    actions: Binding(
                        get: { model.media(target.id)?.actions ?? [] },
                        set: { actions in
                            model.updateMedia(target.id) {
                                $0.actions = actions.isEmpty ? nil : actions
                            }
                        }
                    )
                )
            }
            .sheet(item: $state.actionPlacement) { placement in
                ActionPlacementSheet(model: model, draft: placement.draft) { action in
                    model.updateMedia(placement.mediaItemID) { media in
                        media.actions = (media.actions ?? []) + [action]
                    }
                }
            }
            .sheet(item: $state.actionPicker) { picker in
                LibraryPickerSheet(appModel: model, kind: picker.kind) { entry in
                    model.updateMedia(picker.mediaItemID) { media in
                        guard var actions = media.actions,
                              let index = actions.firstIndex(where: { $0.id == picker.actionID })
                        else { return }
                        if picker.kind == .audio {
                            actions[index].audioItemId = entry.id
                        } else {
                            actions[index].mediaId = entry.id
                        }
                        media.actions = actions
                    }
                    state.actionPicker = nil
                }
            }
            .alert(
                "Rename Media",
                isPresented: Binding(
                    get: { state.renameTargetID != nil },
                    set: { if !$0 { state.renameTargetID = nil } }
                )
            ) {
                TextField("Name", text: $state.renameText)
                Button("Rename") {
                    if let id = state.renameTargetID,
                       let entry = model.indexEntry(id) {
                        model.rename(entry, to: state.renameText)
                    }
                    state.renameTargetID = nil
                }
                Button("Cancel", role: .cancel) { state.renameTargetID = nil }
            }
    }

    private func target(
        _ keyPath: ReferenceWritableKeyPath<MediaCueMenuState, String?>
    ) -> Binding<MediaSettingsTarget?> {
        Binding(
            get: { state[keyPath: keyPath].map { MediaSettingsTarget(id: $0) } },
            set: { state[keyPath: keyPath] = $0?.id }
        )
    }

    private func name(of mediaID: String) -> String {
        model.indexEntry(mediaID)?.name ?? "Media"
    }
}
