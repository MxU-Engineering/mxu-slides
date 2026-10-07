import PresenterCore
import SwiftUI

struct MultiViewToolbar: View {
    let model: SlideEditorModel

    private static let presets: [(title: String, columns: Int, rows: Int)] = [
        ("2 × 2", 2, 2), ("3 × 3", 3, 3), ("4 × 2", 4, 2), ("2 × 4", 2, 4),
        ("2 Across", 2, 1), ("3 Across", 3, 1), ("2 Stacked", 1, 2), ("3 Stacked", 1, 3),
    ]

    @State private var pendingPreset: Int?

    var body: some View {
        HStack(spacing: 12) {
            ToolbarCluster {
                Menu {
                    ForEach(Self.presets.indices, id: \.self) { index in
                        Button(Self.presets[index].title) { pendingPreset = index }
                    }
                } label: {
                    Label("Preset", systemImage: "square.grid.2x2")
                }
                .help("Start the wall over from a preset grid")
            }
            .fixedSize()
            ToolbarCluster {
                Button {
                    model.splitSelectedTile(.columns)
                } label: {
                    Label("Split Side by Side", systemImage: "rectangle.split.2x1")
                }
                .help("Split the tile into two, side by side")
                Button {
                    model.splitSelectedTile(.rows)
                } label: {
                    Label("Split Stacked", systemImage: "rectangle.split.1x2")
                }
                .help("Split the tile into two, stacked")
                Button {
                    model.quadSelectedTile()
                } label: {
                    Label("Quad Split", systemImage: "rectangle.split.2x2")
                }
                .help("Split the tile into a 2 × 2")
                Button {
                    model.mergeSelectedTile()
                } label: {
                    Label("Merge", systemImage: "rectangle.compress.vertical")
                }
                .help("Fold this tile's group back into this one tile")
                .disabled(!model.canMergeSelectedTile)
            }
            .fixedSize()
            .disabled(model.selectedTile == nil)
            ToolbarCluster {
                Button {
                    if let id = model.duplicateMultiViewTurned() {
                        model.appModel.selectedEntryID = id
                    }
                } label: {
                    Label(
                        model.multiViewIsTall ? "Duplicate as Wide" : "Duplicate as Tall",
                        systemImage: model.multiViewIsTall ? "rectangle" : "rectangle.portrait")
                }
                .help(model.multiViewIsTall
                    ? "Make a wide copy of this wall — same tiles and sources, turned"
                    : "Make a tall copy of this wall for the Output Preview rail — same tiles and sources, turned")
            }
            .fixedSize()
        }
        .confirmationDialog(
            "Start over from \(pendingPreset.map { Self.presets[$0].title } ?? "this preset")?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace Tiles") {
                if let index = pendingPreset {
                    model.applyMultiViewGrid(
                        columns: Self.presets[index].columns, rows: Self.presets[index].rows)
                }
                pendingPreset = nil
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil }
        } message: {
            Text("Every tile and its source is replaced. Undo brings them back.")
        }
    }
}

struct MultiViewTileInspector: View {
    let model: SlideEditorModel
    let appModel: AppModel

    @Environment(\.actionRouter) private var router
    @State private var showingMediaPicker = false
    @State private var confirmingUnlock = false

    var body: some View {
        if let tile = model.selectedTile {
            InspectorForm {
                InspectorSection("Tile") {
                    InspectorPicker("Source", selection: kindBinding(tile)) {
                        Text("None").tag(MultiViewSourceKind.empty)
                        Text("Screen").tag(MultiViewSourceKind.screen)
                        Text("Video Input").tag(MultiViewSourceKind.liveInput)
                        Text("Media").tag(MultiViewSourceKind.media)
                        Divider()
                        Text("Clock").tag(MultiViewSourceKind.clock)
                        Text("Timer").tag(MultiViewSourceKind.timer)
                        Text("Video Countdown").tag(MultiViewSourceKind.videoCountdown)
                        Text("Text").tag(MultiViewSourceKind.text)
                    }
                    sourceRows(tile)
                    InspectorTextField("Label", text: Binding(
                        get: { tile.label ?? MultiViewTiles.defaultLabel(tile, in: model.multiViewContext) },
                        set: { label in model.updateSelectedTile { $0.label = label } }
                    ))
                }
                if isPicture(tile) {
                    InspectorSection("Picture") {
                        InspectorPicker("Scale", selection: Binding(
                            get: { tile.scaleMode ?? .fit },
                            set: { mode in model.updateSelectedTile { $0.scaleMode = mode } }
                        )) {
                            Text("Fit").tag(MediaScaleMode.fit)
                            Text("Fill").tag(MediaScaleMode.fill)
                            Text("Stretch").tag(MediaScaleMode.stretch)
                        }
                        Toggle("Match Tile to Source Shape", isOn: Binding(
                            get: { tile.matchSourceShape ?? false },
                            set: { on in model.updateSelectedTile { $0.matchSourceShape = on ? true : nil } }
                        ))
                        .help("The tile takes its source's shape — a vertical screen gets a vertical tile. Dragging a divider beside it turns this off.")
                    }
                }
                InspectorSection {
                    Button("Unlock Tiles…") { confirmingUnlock = true }
                        .help("Turn the tiles into regular objects you can place anywhere")
                }
            }
            .sheet(isPresented: $showingMediaPicker) {
                LibraryPickerSheet(appModel: appModel) { entry in
                    model.updateSelectedTile {
                        $0.sourceKind = .media
                        $0.mediaId = entry.id
                    }
                }
            }
            .confirmationDialog(
                "Unlock this MultiView's tiles?", isPresented: $confirmingUnlock, titleVisibility: .visible
            ) {
                Button("Unlock Tiles") { model.unlockMultiViewTiles() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Tiles become regular objects. Split and Merge won't be available for this layout.")
            }
        } else {
            ContentUnavailableView(
                "No Tile Selected", systemImage: "square.grid.2x2",
                description: Text("Click a tile to choose what it shows. Drag the lines between tiles to resize them.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isPicture(_ tile: MultiViewNode) -> Bool {
        switch tile.sourceKind ?? .empty {
        case .screen, .liveInput, .media: true
        case .empty, .clock, .timer, .videoCountdown, .text: false
        }
    }

    private func kindBinding(_ tile: MultiViewNode) -> Binding<MultiViewSourceKind> {
        Binding(
            get: { tile.sourceKind ?? .empty },
            set: { kind in
                let firstScreen = model.screenSourceChoices.first
                let firstInput = LiveInputCatalog.choices.first
                model.updateSelectedTile {
                    $0.sourceKind = kind
                    $0.screenSourceId = kind == .screen ? firstScreen?.id : nil
                    $0.screenSourceName = kind == .screen ? firstScreen?.name : nil
                    $0.liveInputId = kind == .liveInput ? firstInput?.id : nil
                    $0.mediaId = nil
                    $0.timerId = nil
                    $0.text = kind == .text ? "Text" : nil
                }
                if kind == .media {
                    showingMediaPicker = true
                }
            }
        )
    }

    @ViewBuilder
    private func sourceRows(_ tile: MultiViewNode) -> some View {
        switch tile.sourceKind ?? .empty {
        case .screen:

            InspectorPicker("Screen", selection: Binding(
                get: { MultiViewTiles.resolvedScreen(tile, in: model.multiViewContext)?.id ?? "" },
                set: { id in
                    let name = model.screenSourceChoices.first { $0.id == id }?.name
                    model.updateSelectedTile {
                        $0.screenSourceId = id
                        $0.screenSourceName = name
                    }
                }
            )) {
                if MultiViewTiles.resolvedScreen(tile, in: model.multiViewContext) == nil {
                    Text(tile.screenSourceName.map { "\($0) (not on this Mac)" } ?? "Choose…").tag("")
                }
                ForEach(model.screenSourceChoices, id: \.id) { screen in
                    Text(screen.name).tag(screen.id)
                }
            }
        case .liveInput:
            InspectorPicker("Input", selection: Binding(
                get: { tile.liveInputId ?? "" },
                set: { id in model.updateSelectedTile { $0.liveInputId = id } }
            )) {
                if tile.liveInputId == nil {
                    Text("Choose…").tag("")
                }
                ForEach(LiveInputCatalog.choices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        case .media:
            LabeledContent("Item") {
                Button(tile.mediaId.flatMap { appModel.entry($0)?.name } ?? "Choose…") {
                    showingMediaPicker = true
                }
            }
        case .text:
            InspectorTextField("Text", text: Binding(
                get: { tile.text ?? "" },
                set: { text in model.updateSelectedTile { $0.text = text } }
            ))
        case .timer:
            InspectorPicker("Timer", selection: Binding(
                get: { tile.timerId ?? "" },
                set: { id in

                    let name = router?.timerChoices.first { $0.id == id }?.name
                    model.updateSelectedTile {
                        $0.timerId = id.isEmpty ? nil : id
                        if $0.label == nil { $0.label = name }
                    }
                }
            )) {

                Text(AutomaticTimer.title).tag("")
                ForEach(router?.timerChoices ?? [], id: \.id) { timer in
                    Text(timer.name).tag(timer.id)
                }
            }
            .help(AutomaticTimer.help)
        case .empty, .clock, .videoCountdown:
            EmptyView()
        }
    }
}
