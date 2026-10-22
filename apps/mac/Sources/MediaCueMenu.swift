import AppKit
import PresenterCore
import SlideScene
import SwiftUI

@MainActor @Observable
final class MediaCueMenuState {

    var replacing: Replacing?
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

    struct Replacing: Identifiable {
        let id: String
        let swap: (_ newID: String) -> Void
    }

    struct ActionPlacement: Identifiable {
        var mediaItemID: String
        var draft: SlideAction
        var editing = false
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

    var replace: SpotReplace? = nil

    var inheritedTransition: MediaTransition? = nil

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
            if includesCueGrammar {

                MediaEditorDoors(model: model, mediaID: mediaID, item: item)
                Button("Rename…") {
                    state.renameText = item.name
                    state.renameTargetID = mediaID
                }
                Divider()
                MediaCueGrammarItems(
                    model: model, actionRouter: actionRouter, mediaID: mediaID, state: state
                )
                Divider()
                playbackRows(item)
            } else {

                playbackRows(item)
                Divider()
                Button("Edit Media…") {
                    model.openInEditor(entryID: mediaID)
                    UserDefaults.standard.set(AppMode.edit.rawValue, forKey: "appMode")
                }
            }

            if let replace {
                Divider()
                Button(replace.label) {
                    state.replacing = .init(id: mediaID) { newID in replace.swap(mediaID, newID) }
                }
            }
        }
    }

    @ViewBuilder
    private func playbackRows(_ item: MediaItem) -> some View {

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

        TransitionMenu(current: item.transition, inherited: inheritedTransition) { transform in
            model.updateMedia(mediaID) { $0.transition = transform($0.transition) }
        }
    }
}

struct SpotReplace {
    let label: String
    let swap: (_ oldID: String, _ newID: String) -> Void
}

struct MediaEditorDoors: View {
    let model: AppModel
    let mediaID: String
    let item: MediaItem

    var body: some View {
        Button("Edit Media…") {
            model.openInEditor(entryID: mediaID)
            UserDefaults.standard.set(AppMode.edit.rawValue, forKey: "appMode")
        }
        .help("Opens this media in the editor.")
        Button("Show in Finder") {
            if let url = model.blobs?.url(forHash: item.fileHash) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .disabled(model.isMediaFileMissing(item))
        .help(model.isMediaFileMissing(item) ? "The file isn't on this Mac." : "Reveals the file in Finder.")
    }
}

struct MediaCueGrammarItems: View {
    let model: AppModel
    let actionRouter: ActionRouter?
    let mediaID: String
    let state: MediaCueMenuState

    var body: some View {
        if let item = model.media(mediaID) {
            ActionsMenu(
                model: model, actionRouter: actionRouter,
                actions: item.actions ?? [],
                add: { addAction($0, to: item) },
                edit: { state.actionPlacement = .init(mediaItemID: mediaID, draft: $0, editing: true) },
                remove: { action in
                    model.updateMedia(mediaID) {
                        $0.actions = SlideBulkEdit.removing(actionID: action.id, from: $0.actions)
                    }
                },
                editAll: { state.actionsEditorTargetID = mediaID },
                removeAll: { model.updateMedia(mediaID) { $0.actions = nil } }
            )
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
            .sheet(item: $state.replacing) { replacing in
                LibraryPickerSheet(appModel: model) { entry in replacing.swap(entry.id) }
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
                ActionPlacementSheet(model: model, editing: placement.editing, draft: placement.draft) { action in
                    model.updateMedia(placement.mediaItemID) { media in
                        media.actions = placement.editing
                            ? SlideBulkEdit.replacing(action, in: media.actions)
                            : (media.actions ?? []) + [action]
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
