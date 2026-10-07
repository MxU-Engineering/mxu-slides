import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct SlideObjectInspector: View {
    let model: SlideEditorModel

    @Environment(\.actionRouter) private var router
    @FocusState private var textEditorFocused: Bool
    @State private var showingBackgroundPicker = false
    @State private var showingFillMediaPicker = false

    @State private var selectedLineIndex = 0

    @State private var insetsExpanded = false

    @State private var canvasCustomChosen = false
    @State private var canvasWidthDraft = ""
    @State private var canvasHeightDraft = ""

    @State private var customFormatObjectID: String?

    @State private var presetNamePrompt = false
    @State private var presetNameDraft = ""

    private static let defaultShadow = ObjectShadow(colorHex: "#00000080", blurRadius: 8, offsetX: 0, offsetY: 4)
    private static let defaultStroke = ObjectStroke(colorHex: "#000000FF", width: 2)

    private static let defaultLineFill = TextLineFill(
        fill: ObjectFill(fillKind: .solid, colorHex: "#000000FF"), widthMode: .lineWidth
    )

    enum Tab: String, CaseIterable {
        case slide, object, animation
    }

    @State private var tab: Tab = .object

    private var slideTabTitle: String {
        if model.isThemeEditor { return "Category" }
        if model.isOverlayEditor { return "Overlay" }
        if model.isConfidenceEditor { return "Layout" }
        return "Slide"
    }

    var body: some View {
        let _ = BodyMeter.tick(.slideObjectInspector)
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(slideTabTitle).tag(Tab.slide)

                Text(model.isMultiView ? "Tile" : "Object").tag(Tab.object)

                if model.editorMode == .design, !model.isMultiView {
                    Text("Animation").tag(Tab.animation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            switch tab {
            case .slide:
                cueInspector()
            case .object:

                if model.isMultiView {
                    MultiViewTileInspector(model: model, appModel: model.appModel)
                } else if let object = model.inspectedObject {
                    inspector(object)
                } else {

                    ContentUnavailableView(
                        "No Object Selected", systemImage: "cursorarrow.click",
                        description: Text("Click an object on the canvas or in the Objects panel to edit it.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .animation:
                AnimationTab(model: model)
            }
        }
        .onAppear {

            if model.selectedAnimationStepID != nil, model.editorMode == .design { tab = .animation }
            else if !model.selectedObjectIDs.isEmpty { tab = .object }
            else { tab = .slide }
        }
        .onChange(of: model.editorMode) { _, mode in

            if mode == .animate, tab == .animation { tab = .object }
        }
        .onChange(of: model.selectedObjectIDs) { _, ids in

            if !ids.isEmpty, model.selectedAnimationStepID == nil, !model.stepAddArmed { tab = .object }
        }
        .onChange(of: model.selectedAnimationStepID) { _, id in

            if id != nil, model.editorMode == .design { tab = .animation }
        }
        .onChange(of: model.selectedTileID) { _, id in
            if id != nil { tab = .object }
        }
        .onChange(of: model.textEditRequests) { _, _ in
            tab = .object
            textEditorFocused = true
        }

        .onChange(of: textEditorFocused) { _, focused in
            model.inspectorTextFocused = focused
        }
        .onDisappear {
            model.inspectorTextFocused = false
        }
    }

    private func cueInspector() -> some View {
        InspectorForm {
            if model.isThemeEditor {

                InspectorSection("Category") {
                    InspectorTextField("Name", text: slideNameBinding())
                    Text("Slides using this category take their text style and placement from the first text object, and render the other objects beneath their content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                InspectorSection("Actions") {
                    ActionListEditor(model: model.appModel, actions: slideActionsBinding())
                }
            } else {
                presentationCueSections()
            }
        }
        .sheet(isPresented: $showingBackgroundPicker) {
            LibraryPickerSheet(appModel: model.appModel) { entry in
                model.setBackground(mediaID: entry.id, scope: model.backgroundScope ?? .slide)
            }
        }
    }

    @ViewBuilder
    private func presentationCueSections() -> some View {
        InspectorSection("Slide") {
            InspectorTextField("Name", text: slideNameBinding())
            if !model.themeSlideNames.isEmpty || !model.otherThemeChoices.isEmpty {
                InspectorPicker("Theme Slide", selection: themeSlideSelection()) {
                    Text("Automatic").tag("")

                    ForEach(Array(model.themeSlideGroups.enumerated()), id: \.offset) { _, group in
                        if let folder = group.folder {
                            Section(folder) {
                                ForEach(group.names, id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            ForEach(group.names, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    ForEach(model.otherThemeChoices, id: \.theme.id) { choice in
                        Section(choice.theme.name) {
                            ForEach(choice.groups.flatMap(\.names), id: \.self) { name in
                                Text(name).tag("\(choice.theme.id)|\(name)")
                            }
                        }
                    }
                }
            }
        }
        InspectorSection("Background") {
            if let background = model.effectiveBackground {

                LabeledContent("Media") {
                    HStack(spacing: 6) {
                        Text(model.backgroundMediaName(background))
                        editMediaButton(background.mediaId)
                    }
                }
                InspectorPicker("Applies To", selection: backgroundScopeBinding()) {
                    ForEach(model.availableBackgroundScopes, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }

                InspectorPicker("Classification", selection: backgroundClassificationBinding(background)) {
                    Text("Foreground").tag(MediaClassification.foreground)
                    Text("Background").tag(MediaClassification.background)
                }
                InspectorPicker("Layer", selection: backgroundLayerBinding(background)) {
                    Text("Background Media").tag(CueMediaLayer.loopingVideos)
                    Text("Still Graphics").tag(CueMediaLayer.stillGraphics)
                    Text("Foreground Videos").tag(CueMediaLayer.videos)
                }
                Toggle("Loop", isOn: backgroundLoopBinding(background))
                HStack {
                    Button("Replace…") { showingBackgroundPicker = true }
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeBackground() }
                }
            } else {
                Text("No background: when presenting, the previous cue's background keeps playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose…") { showingBackgroundPicker = true }
            }
        }

        InspectorSection("Auto Advance") {
            AutoAdvanceControls(advance: Binding(
                get: { model.currentSlide?.autoAdvance },
                set: { model.setAutoAdvance($0) }
            ))
        }

        InspectorSection("Transition") {
            slideTransitionRows()
        }

        InspectorSection("Actions") {

            ActionListEditor(model: model.appModel, actions: slideActionsBinding())
        }

        InspectorSection("Presentation") {
            InspectorPicker("Resolution", selection: canvasSelectionBinding()) {
                ForEach(Self.canvasPresets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
                Text("Custom…").tag("custom")
            }
            if canvasIsCustom {
                InspectorTextField("Width", text: $canvasWidthDraft)
                    .onSubmit(commitCustomCanvas)
                InspectorTextField("Height", text: $canvasHeightDraft)
                    .onSubmit(commitCustomCanvas)
                Button("Apply") { commitCustomCanvas() }
            }
            Text("Every slide designs at this resolution. Outputs letterbox other aspects.")
                .font(.caption)
                .foregroundStyle(.secondary)

            InspectorPicker("Key", selection: musicKeyBinding()) {
                Text("None").tag("")
                Divider()
                ForEach(Self.keyNames, id: \.self) { name in
                    Text(name).tag(name)
                }
                ForEach(Self.keyNames, id: \.self) { name in
                    Text(name + "m").tag(name + "m")
                }
            }
            if let musicKey = model.presentation.musicKey {
                InspectorPicker("Display Key", selection: displayKeyBinding(musicKey: musicKey)) {
                    ForEach(ChordMath.keyChoices(matching: musicKey), id: \.self) { name in
                        if name.caseInsensitiveCompare(musicKey) == .orderedSame {
                            Text("\(name) (Original)").tag(name)
                        } else {
                            Text(name).tag(name)
                        }
                    }
                }
                .help("Chords transpose to this key on every screen that shows them")
            }
        }
    }

    private static let keyNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    private func musicKeyBinding() -> Binding<String> {
        Binding(
            get: { model.presentation.musicKey ?? "" },
            set: { model.setMusicKey($0.isEmpty ? nil : $0) }
        )
    }

    private func displayKeyBinding(musicKey: String) -> Binding<String> {
        Binding(
            get: { model.presentation.displayKey ?? musicKey },
            set: { model.setDisplayKey($0) }
        )
    }

    private static let canvasPresets: [(label: String, width: Int, height: Int)] = [
        ("1080p (1920×1080)", 1920, 1080),
        ("4K UHD (3840×2160)", 3840, 2160),
        ("720p (1280×720)", 1280, 720),
        ("Vertical (1080×1920)", 1080, 1920),
        ("Square (1080×1080)", 1080, 1080),
    ]

    private var canvasIsCustom: Bool {
        if canvasCustomChosen { return true }
        let size = model.canvasSize
        return !Self.canvasPresets.contains {
            $0.width == Int(size.width) && $0.height == Int(size.height)
        }
    }

    private func canvasSelectionBinding() -> Binding<String> {
        Binding(
            get: {
                if canvasIsCustom { return "custom" }
                let size = model.canvasSize
                return Self.canvasPresets.first {
                    $0.width == Int(size.width) && $0.height == Int(size.height)
                }?.label ?? "custom"
            },
            set: { label in
                if let preset = Self.canvasPresets.first(where: { $0.label == label }) {
                    canvasCustomChosen = false
                    model.setCanvasSize(width: preset.width, height: preset.height)
                } else {

                    canvasWidthDraft = String(Int(model.canvasSize.width))
                    canvasHeightDraft = String(Int(model.canvasSize.height))
                    canvasCustomChosen = true
                }
            }
        )
    }

    private func commitCustomCanvas() {
        guard let width = Int(canvasWidthDraft), let height = Int(canvasHeightDraft),
            width > 0, height > 0
        else { return }
        canvasCustomChosen = false
        model.setCanvasSize(width: width, height: height)
    }

    private func slideActionsBinding() -> Binding<[SlideAction]> {
        Binding(
            get: { model.currentSlide?.actions ?? [] },
            set: { model.setSlideActions($0) }
        )
    }

    private func slideNameBinding() -> Binding<String> {
        Binding(
            get: { model.currentSlide?.name ?? "" },
            set: { model.renameCurrentSlide($0) }
        )
    }

    private func themeSlideSelection() -> Binding<String> {
        Binding(
            get: {
                guard let slide = model.currentSlide else { return "" }
                let name = slide.themeSlideName ?? ""
                if let own = slide.themeId, !own.isEmpty { return "\(own)|\(name)" }
                return name
            },
            set: { value in
                guard let slideID = model.currentSlide?.id else { return }
                if let bar = value.firstIndex(of: "|") {
                    let themeId = String(value[..<bar])
                    let name = String(value[value.index(after: bar)...])
                    model.setThemeSlide(name.isEmpty ? nil : name, themeId: themeId, for: slideID)
                } else if model.currentSlide?.themeId?.isEmpty == false {

                    model.setThemeSlide(value.isEmpty ? nil : value, themeId: model.presentation.themeId, for: slideID)
                } else {
                    model.setThemeSlide(value.isEmpty ? nil : value, for: slideID)
                }
            }
        )
    }

    private func backgroundScopeBinding() -> Binding<SlideEditorModel.BackgroundScope> {
        Binding(
            get: { model.backgroundScope ?? .slide },
            set: { model.setBackgroundScope($0) }
        )
    }

    private func backgroundClassificationBinding(_ background: CueMedia) -> Binding<MediaClassification> {
        Binding(
            get: { background.resolvedClassification },
            set: { value in model.updateBackground { $0.classification = value } }
        )
    }

    private func backgroundLayerBinding(_ background: CueMedia) -> Binding<CueMediaLayer> {
        Binding(
            get: { background.layer ?? .loopingVideos },
            set: { layer in model.updateBackground { $0.layer = layer } }
        )
    }

    private func backgroundLoopBinding(_ background: CueMedia) -> Binding<Bool> {
        Binding(
            get: { model.backgroundLoops(background) },
            set: { loops in model.updateBackground { $0.loops = loops } }
        )
    }

    private var editingSelection: Bool { model.selectedObjectIDs.count > 1 }

    private var selectionSharesKind: Bool { SelectionFormatting.sharesKind(model.selectedObjects) }

    @ViewBuilder
    private func inspector(_ object: SlideObject) -> some View {
        let multi = editingSelection
        let sharesKind = !multi || selectionSharesKind
        InspectorForm {
            if multi {
                multiSelectionSection(object, count: model.selectedObjectIDs.count, sharesKind: sharesKind)
            }

            if let editing = model.animationStateEditing, editing.objectID == object.id {
                InspectorSection {
                    HStack {
                        Label(editing.isStart ? "Editing the START of an In step" : "Editing the END STATE of a Morph step",
                              systemImage: "arrow.triangle.swap")
                            .font(.caption)
                        Spacer()
                        Button("Done") { model.selectedAnimationStepID = nil }
                            .controlSize(.small)
                    }
                    Text("The canvas shows this state; the faint copy is the object's resting look. Position, size, shape, fill, color, effects: all of it is the state.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            objectSection(object, multi: multi)
            switch multi && !sharesKind ? nil : object.objectKind {
            case nil:
                EmptyView()
            case .text:
                if !multi {
                    textContentSection(object)
                    selectionSection(object)
                }
                typographySection(object)
                if model.isThemeEditor {
                    keepFromSlideSection(object)
                }
                if !multi {
                    chordsSection(object)
                    textPathSection(object)
                    lineStylesSection(object)
                }
                lineFillSection(object)
                textOutlineSection(object)
                shadowSection(
                    object, title: "Shadow",
                    read: { $0.textStyle?.shadow },
                    store: { obj, shadow in
                        var style = obj.textStyle ?? TextStyle()
                        style.shadow = shadow
                        obj.textStyle = style
                    }
                )
            case .shape, .media, .liveInput:

                if fillIsMediaKind(object) {
                    fillSection(object)
                    shapeSection(object)
                } else {
                    shapeSection(object)
                    fillSection(object)
                }
                strokeSection(object)
                shadowSection(
                    object, title: "Shadow",
                    read: { $0.shadow },
                    store: { obj, shadow in obj.shadow = shadow }
                )

                if !multi {
                    textContentSection(object, forShape: true)
                }
                if shapeHasText(object) {
                    if !multi {
                        selectionSection(object)
                    }
                    typographySection(object, forShape: true)
                    if !multi {
                        chordsSection(object)
                        textPathSection(object, forShape: true)
                    }
                }
            }
            if !multi {
                maskSection(object)
                effectsSection(object)
                visibilitySection(object)
            }
        }
    }

    private func multiSelectionSection(_ object: SlideObject, count: Int, sharesKind: Bool) -> some View {
        InspectorSection {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(count) Objects Selected", systemImage: "square.on.square")
                    .font(.headline)
                Text(sharesKind
                    ? "Showing \(displayName(object)). Every change here applies to all \(count)."
                    : "Text and shapes share only the Object properties; select one kind to edit its formatting together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    MixedValueDot()
                    Text("marks a value the selection disagrees on — setting it makes them match.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                SelectionGroupButtons(model: model)
                    .padding(.top, 4)
            }
        }
    }

    private func displayName(_ object: SlideObject) -> String {
        let name = current(object).name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallbackName(object) : name
    }

    private func visibilitySection(_ object: SlideObject) -> some View {
        InspectorSection("Visibility") {
            Toggle("Hidden", isOn: write(object, \.hidden, default: false))
            Toggle("Conditional Visibility", isOn: Binding(
                get: { !(current(object).visibilityConditions ?? []).isEmpty },
                set: { on in
                    commit(object) {
                        $0.visibilityConditions = on
                            ? [VisibilityCondition(conditionKind: .timer, state: .isRunning)]
                            : nil
                        if !on { $0.visibilityMatch = nil }
                    }
                }
            ))
            if let conditions = current(object).visibilityConditions, !conditions.isEmpty {
                InspectorPicker("Shown When", selection: write(object, \.visibilityMatch, default: .all)) {
                    Text("All Conditions Met").tag(VisibilityMatch.all)
                    Text("Any Condition Met").tag(VisibilityMatch.any)
                    Text("No Condition Met").tag(VisibilityMatch.none)
                }
                ForEach(Array(conditions.enumerated()), id: \.offset) { index, condition in
                    conditionRows(object, index: index, condition: condition)
                }
                Button("Add Condition") {
                    commit(object) {
                        var list = $0.visibilityConditions ?? []
                        list.append(VisibilityCondition(conditionKind: .timer, state: .isRunning))
                        $0.visibilityConditions = list
                    }
                }
                Text("Objects can share one spot, each shown only while its conditions hold. Evaluated live while presenting; the editor always shows the object.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updateCondition(
        _ object: SlideObject, at index: Int,
        _ mutate: @escaping (inout VisibilityCondition) -> Void
    ) {
        commit(object) {
            guard var list = $0.visibilityConditions, list.indices.contains(index) else { return }
            mutate(&list[index])
            $0.visibilityConditions = list
        }
    }

    private static func defaultState(for kind: VisibilityConditionKind) -> VisibilityConditionState {
        switch kind {
        case .timer, .audioPlayback: .isRunning
        case .videoCountdown: .hasTimeRemaining
        case .liveInput, .capture: .isActive
        case .objectText: .hasText
        }
    }

    private static func states(for kind: VisibilityConditionKind) -> [(VisibilityConditionState, String)] {
        switch kind {
        case .timer, .videoCountdown, .audioPlayback:
            [
                (.hasTimeRemaining, "Has Time Remaining"),
                (.hasExpired, "Has Expired"),
                (.isRunning, "Is Running"),
                (.isNotRunning, "Is Not Running"),
            ]
        case .liveInput:
            [
                (.isActive, "Is Live on Program"),
                (.isInactive, "Is Not on Program"),
                (.isConnected, "Is Connected"),
                (.isDisconnected, "Is Disconnected"),
            ]
        case .capture:
            [(.isActive, "Is Active"), (.isInactive, "Is Inactive")]
        case .objectText:
            [(.hasText, "Has Text"), (.hasNoText, "Has No Text")]
        }
    }

    @ViewBuilder
    private func conditionRows(_ object: SlideObject, index: Int, condition: VisibilityCondition) -> some View {
        InspectorPicker("Watch", selection: Binding(
            get: { condition.conditionKind },
            set: { kind in
                updateCondition(object, at: index) { target in
                    target.conditionKind = kind
                    target.state = Self.defaultState(for: kind)
                    target.timerId = nil
                    target.objectId = nil
                    target.liveInputId = nil
                }
            }
        )) {
            Text("Timer").tag(VisibilityConditionKind.timer)
            Text("Video Countdown").tag(VisibilityConditionKind.videoCountdown)
            Text("Audio").tag(VisibilityConditionKind.audioPlayback)
            Text("Video Input").tag(VisibilityConditionKind.liveInput)
            Text("Capture").tag(VisibilityConditionKind.capture)
            Text("Another Object").tag(VisibilityConditionKind.objectText)
        }
        switch condition.conditionKind {
        case .timer:
            InspectorPicker("Timer", selection: Binding(
                get: { condition.timerId ?? "" },
                set: { id in updateCondition(object, at: index) { $0.timerId = id.isEmpty ? nil : id } }
            )) {
                Text(AutomaticTimer.title).tag("")
                ForEach(router?.timerChoices ?? [], id: \.id) { timer in
                    Text(timer.name).tag(timer.id)
                }
            }
            .help(AutomaticTimer.help)
        case .objectText:
            InspectorPicker("Object", selection: Binding(
                get: { condition.objectId ?? "" },
                set: { id in updateCondition(object, at: index) { $0.objectId = id.isEmpty ? nil : id } }
            )) {
                Text("Choose…").tag("")
                ForEach((model.currentSlide?.objects ?? []).filter { $0.id != object.id }, id: \.id) { sibling in
                    Text(sibling.name).tag(sibling.id)
                }
            }
        case .liveInput:
            InspectorPicker("Input", selection: Binding(
                get: { condition.liveInputId ?? "" },
                set: { id in updateCondition(object, at: index) { $0.liveInputId = id.isEmpty ? nil : id } }
            )) {
                Text("Choose…").tag("")
                ForEach(LiveInputCatalog.choices) { choice in
                    Text(choice.name).tag(choice.id)
                }
            }
        case .videoCountdown, .audioPlayback, .capture:
            EmptyView()
        }
        InspectorPicker("State", selection: Binding(
            get: { condition.state },
            set: { state in updateCondition(object, at: index) { $0.state = state } }
        )) {
            ForEach(Self.states(for: condition.conditionKind), id: \.0) { state, label in
                Text(label).tag(state)
            }
        }
        Button("Remove Condition", role: .destructive) {
            commit(object) {
                guard var list = $0.visibilityConditions, list.indices.contains(index) else { return }
                list.remove(at: index)
                $0.visibilityConditions = list.isEmpty ? nil : list
                if list.isEmpty { $0.visibilityMatch = nil }
            }
        }
    }

    private func shapeHasText(_ object: SlideObject) -> Bool {
        let current = current(object)
        return !current.text.isEmpty || current.textLink != nil
    }

    @ViewBuilder
    private func slideTransitionRows() -> some View {
        let transition = model.currentSlide?.transition
        InspectorPicker("Transition", selection: Binding(
            get: { transition?.transitionKind.rawValue ?? "" },
            set: { raw in
                model.setSlideTransition(TransitionKind(rawValue: raw).map {
                    Transition(
                        transitionKind: $0,
                        durationSeconds: transition?.durationSeconds,
                        colorHex: transition?.colorHex
                    )
                })
            }
        )) {
            Text("Room Default").tag("")
            Divider()
            Text("Cut").tag(TransitionKind.cut.rawValue)
            Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
            Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
            Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
            Text("Fade Color").tag(TransitionKind.fadeColor.rawValue)
            Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
            Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
        }
        if let transition, transition.transitionKind != .cut {
            BoundedSliderRow(
                label: "Duration",
                value: Binding(
                    get: { model.currentSlide?.transition?.durationSeconds ?? 0.5 },
                    set: { seconds in
                        var updated = transition
                        updated.durationSeconds = seconds
                        model.setSlideTransition(updated)
                    }
                ),
                range: 0 ... 5, step: 0.05
            )
            if transition.transitionKind == .fadeColor {
                HexColorRow(
                    label: "Plate Color",
                    hex: Binding(
                        get: { model.currentSlide?.transition?.colorHex ?? "#000000FF" },
                        set: { hex in
                            var updated = transition
                            updated.colorHex = hex
                            model.setSlideTransition(updated)
                        }
                    )
                )
            }
        }
        Text("Room Default follows Settings › Transitions when this slide fires.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func objectSection(_ object: SlideObject, multi: Bool = false) -> some View {
        InspectorSection("Object") {
            if !multi {
                InspectorTextField("Name", text: write(object, \.name))

                ObjectGeometryRows(model: model, object: object)
            }
            ObjectArrangeRows(model: model, multi: multi)

            AngleDialRow(
                label: "Rotation", value: write(object, \.rotationDegrees, default: 0),
                onScrubPhase: { model.setScrubPreview($0) }
            )
            .mixedValue(objectMixed(\.rotationDegrees, default: 0))

            dialRow {
                sliderField("Tilt", write(object, \.tilt, default: 0), range: -85...85, step: 1)
                    .mixedValue(objectMixed(\.tilt, default: 0))
                sliderField("Swing", write(object, \.swing, default: 0), range: -85...85, step: 1)
                    .mixedValue(objectMixed(\.swing, default: 0))
            }

            dialRow {
                sliderField("Top Width %", write(object, \.keystoneTop, default: 100), range: 10...200, step: 1)
                    .mixedValue(objectMixed(\.keystoneTop, default: 100))
                sliderField("Bottom Width %", write(object, \.keystoneBottom, default: 100), range: 10...200, step: 1)
                    .mixedValue(objectMixed(\.keystoneBottom, default: 100))
            }

            dialRow {
                sliderField("Skew X", write(object, \.skewX, default: 0), range: -60...60, step: 1)
                    .mixedValue(objectMixed(\.skewX, default: 0))
                sliderField("Skew Y", write(object, \.skewY, default: 0), range: -60...60, step: 1)
                    .mixedValue(objectMixed(\.skewY, default: 0))
            }
            if (current(object).keystoneTop ?? 100) != 100 || (current(object).keystoneBottom ?? 100) != 100 {
                LabeledContent("Keystone") {
                    ChipPicker(
                        options: [(KeystoneMode.perspective, "Perspective"), (.stretch, "Stretch")],
                        selection: write(object, \.keystoneMode, default: .perspective)
                    )
                }
                .help("Perspective reads as depth (rows compress toward the narrow edge); Stretch only pulls the edge wider or narrower")
            }
            if (current(object).tilt ?? 0) != 0 {
                LabeledContent("Tilt Pivot") {
                    ChipPicker(
                        options: [(TiltPivot.top, "Top"), (.center, "Center"), (.bottom, "Bottom")],
                        selection: write(object, \.tiltPivot, default: .center)
                    )
                }
            }

            LabeledContent("Flip") {
                flipStrip(object)
            }
            .mixedValue(objectMixed(\.flipHorizontal, default: false) || objectMixed(\.flipVertical, default: false))
            LabeledContent("Opacity") {
                CommittingSlider(value: write(object, \.opacity, default: 1), range: 0...1)
            }
            .mixedValue(objectMixed(\.opacity, default: 1))
            InspectorPicker("Blend", selection: write(object, \.blendMode, default: .normal)) {
                ForEach(BlendMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .mixedValue(objectMixed(\.blendMode, default: .normal))
        }
    }

    private func textContentSection(_ object: SlideObject, forShape: Bool = false) -> some View {
        let link = current(object).textLink
        return InspectorSection("Text") {

            InspectorPicker("Linked To", selection: linkSourceBinding(object)) {
                Text("Static Text").tag(nil as TextSourceKind?)
                Divider()
                ForEach(LinkedText.authoringSources(current: link?.source), id: \.self) { source in
                    Text(source.displayName).tag(source as TextSourceKind?)
                }
            }
            if let link {
                if link.source == .timer {
                    InspectorPicker("Timer", selection: linkWrite(object, \.timerId, default: "")) {

                        Text(AutomaticTimer.title).tag("")
                        ForEach(router?.timerChoices ?? [], id: \.id) { timer in
                            Text(timer.name).tag(timer.id)
                        }
                    }
                    .help(AutomaticTimer.help)
                }
                if link.source == .clock {

                    InspectorPicker("Format", selection: clockFormatSelection(object)) {
                        ForEach(Self.clockFormatPresets, id: \.format) { preset in
                            Text(preset.label).tag(preset.format)
                        }
                        Text("Custom…").tag(Self.customFormatTag)
                    }
                    if clockFormatIsCustom(object) {
                        LabeledContent("Pattern") {
                            CommittedTextField("", text: linkWrite(object, \.clockFormat, default: ""))
                                .multilineTextAlignment(.trailing)
                        }
                        .help("A date pattern: h hour (1–12), HH hour (00–23), mm minutes, ss seconds, a AM/PM, EEE weekday, MMM d month and day — text in single quotes stays as written")
                        formatSampleCaption(link)
                    }
                }
                if link.source == .timer || link.source == .videoCountdown {

                    InspectorPicker("Format", selection: timerFormatSelection(object)) {
                        Text("83:18:23").tag(TimerTextFormat.digits.rawValue)
                        Text("3d 11h 18m 23s").tag(TimerTextFormat.abbreviated.rawValue)
                        Text("3 days 11 hours 18 minutes 23 seconds").tag(TimerTextFormat.words.rawValue)
                        Text("Custom…").tag(Self.customFormatTag)
                    }
                    if timerFormatIsCustom(object) {
                        LabeledContent("Pattern") {
                            CommittedTextField("", text: linkWrite(object, \.timerPattern, default: ""))
                                .multilineTextAlignment(.trailing)
                        }
                        .help("d h m s — days, hours in the day, minutes in the hour, seconds in the minute; a doubled token pads (ss → 07). H M S — every hour, minute, or second left, no rollover. f ff fff — tenths, hundredths, thousandths. Text in single quotes stays as written. Examples: m:ss.f · S · ss · d'd' H:mm")
                        Text("d h m s units · ss pads · H M S totals · f ff fff fractions · 'quoted' text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        formatSampleCaption(link)
                    }
                }
                if link.source == .timer || link.source == .videoCountdown {
                    Toggle(
                        "Warning Colors",
                        isOn: linkWrite(object, \.usesWarningColor, default: true)
                    )
                    .help("Read the timer's amber/red warning ink when it applies")
                }
                if link.source == .videoCountdown {
                    Toggle(
                        "Show Video Name",
                        isOn: linkWrite(object, \.showsVideoName, default: true)
                    )
                    .help("Prefix the remaining time with the playing video's name — useful on a stage read, usually off for the audience")

                    InspectorPicker("Video From", selection: linkWrite(object, \.videoLayer, default: "")) {
                        Text(LayerKind.videos.displayName).tag("")
                        Text(LayerKind.loopingVideos.displayName).tag(LayerKind.loopingVideos.rawValue)
                        Text(LayerKind.slide.displayName).tag(LayerKind.slide.rawValue)
                        Text(LayerKind.overlays.displayName).tag(LayerKind.overlays.rawValue)
                    }
                    .help("The render layer whose playing video this box counts down; Foreground Videos is the room default")
                }
                if [.currentSlide, .nextSlide, .lastSlide].contains(link.source) {

                    LabeledContent("From Object") {

                        CommittedTextField(
                            "",
                            text: linkWrite(object, \.sourceObjectName, default: "")
                        )
                        .multilineTextAlignment(.trailing)
                    }
                    .help("Show only the source slide's object with this name (e.g. Reference) — matched case-insensitively. A slide without that box shows nothing here. Empty = the whole slide's text.")

                    numberField("Line Limit", maxLinesBinding(object), range: 0...30)
                        .help("Show only the first N lines of the linked slide; 0 = all")
                }
                if link.source == .nextSlide {

                    Toggle("Show Upcoming Step", isOn: linkWrite(object, \.includeSteps, default: false))
                        .help("While the live slide still has animation steps, show what the next Advance reveals; once they're spent this reads the next slide again")
                }
            }

            if link == nil {
                TextEditor(text: write(object, \.text))
                    .font(.body)
                    .frame(minHeight: 64)
                    .focused($textEditorFocused)
            }
        }
    }

    @ViewBuilder
    private func typographySection(_ object: SlideObject, forShape: Bool = false) -> some View {
        let onEdge = forShape && (current(object).shapeTextPlacement ?? .inside) != .inside
        InspectorSection("Typography") {
            FontFaceRows(
                fontName: styleWrite(object, \.fontName, default: model.theme?.fontFamily ?? "HelveticaNeue-Bold")
            )
            .mixedValue(styleMixed(\.fontName, default: model.theme?.fontFamily ?? "HelveticaNeue-Bold"))

            HStack(spacing: 12) {
                numberField("Size", styleWrite(object, \.fontSize, default: model.theme?.fontSize ?? 96), range: 1...500)
                    .frame(width: 112)
                    .mixedValue(styleMixed(\.fontSize, default: model.theme?.fontSize ?? 96))
                Spacer(minLength: 8)
                HexColorRow(
                    label: "Color",
                    hex: styleWrite(object, \.colorHex, default: model.theme?.textColorHex ?? "#FFFFFFFF"),
                    labelHidden: true
                )
                .mixedValue(styleMixed(\.colorHex, default: model.theme?.textColorHex ?? "#FFFFFFFF"))
            }
            HStack(spacing: 6) {
                Text("Alignment")
                Spacer(minLength: 8)
                horizontalAlignmentStrip(object)
                    .mixedValue(styleMixed(\.horizontalAlignment, default: .center))
                if !onEdge {
                    verticalAlignmentStrip(object)
                        .mixedValue(styleMixed(\.verticalAlignment, default: .middle))
                }
            }
            LabeledContent("Style") {
                decorationStrip(object)
            }
            .mixedValue(decorationsMixed())
            if !onEdge {
                Toggle("Balanced Wrap", isOn: styleWrite(object, \.balancedWrap, default: false))
                    .help("When a line wraps, spread its words evenly across the rows — never one lone word on the last row")
                    .mixedValue(styleMixed(\.balancedWrap, default: false))
                Toggle("Auto-Shrink", isOn: styleWrite(object, \.autoShrink, default: false))
                    .mixedValue(styleMixed(\.autoShrink, default: false))
                Toggle("Page on Click", isOn: styleWrite(object, \.pageOnClick, default: false))
                    .help("For a design's text box on an alternate output (a side or lower third): text that still doesn't fit after Auto-Shrink continues on the next click as the next page of this box, instead of clipping. Every output that pages turns together; the projector's design keeps the whole text.")
                    .mixedValue(styleMixed(\.pageOnClick, default: false))
                if current(object).textStyle?.autoShrink == true {
                    Toggle("Keep Lines Whole", isOn: styleWrite(object, \.keepLinesWhole, default: false))
                        .help("Shrink further so no line wraps mid-phrase — no lone word on its own line")
                        .mixedValue(styleMixed(\.keepLinesWhole, default: false))
                    numberField(
                        "Min Size",
                        styleWrite(object, \.minFontSize, default: StyledText.defaultMinFontSize),
                        range: 1...500
                    )
                    .mixedValue(styleMixed(\.minFontSize, default: StyledText.defaultMinFontSize))
                }
            }

            if !forShape, !model.isThemeEditor, hasThemeOverrides(object) {
                Button("Reset to Theme") { model.resetObjectsToTheme(editTargets(object)) }
            }
        }
        InspectorSection("Spacing") {
            dialRow {
                numberField("Tracking", styleWrite(object, \.tracking, default: 0), range: -50...200, stacked: true)
                    .mixedValue(styleMixed(\.tracking, default: 0))
                numberField(
                    "Word Spacing", styleWrite(object, \.wordSpacing, default: 0),
                    range: -20...300, stacked: true
                )
                .mixedValue(styleMixed(\.wordSpacing, default: 0))
            }
            if !onEdge {
                dialRow {
                    numberField(
                        "Line Height", styleWrite(object, \.lineHeightMultiple, default: 1),
                        range: 0.5...3, step: 0.05, stacked: true
                    )
                    .mixedValue(styleMixed(\.lineHeightMultiple, default: 1))
                    numberField(
                        "Paragraph Spacing", styleWrite(object, \.paragraphSpacing, default: 0),
                        range: 0...500, stacked: true
                    )
                    .mixedValue(styleMixed(\.paragraphSpacing, default: 0))
                }
            }
        }
        if !onEdge {

            InspectorSection {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { insetsExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(insetsExpanded ? 90 : 0))
                        Text("Insets & Indents")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if insetsExpanded {
                    dialRow {
                        numberField("Top", styleWrite(object, \.insetTop, default: 0), range: 0...500, stacked: true)
                            .mixedValue(styleMixed(\.insetTop, default: 0))
                        numberField("Bottom", styleWrite(object, \.insetBottom, default: 0), range: 0...500, stacked: true)
                            .mixedValue(styleMixed(\.insetBottom, default: 0))
                    }
                    dialRow {
                        numberField("Left", styleWrite(object, \.insetLeft, default: 0), range: 0...500, stacked: true)
                            .mixedValue(styleMixed(\.insetLeft, default: 0))
                        numberField("Right", styleWrite(object, \.insetRight, default: 0), range: 0...500, stacked: true)
                            .mixedValue(styleMixed(\.insetRight, default: 0))
                    }
                    dialRow {
                        numberField(
                            "First Line", styleWrite(object, \.firstLineIndent, default: 0),
                            range: -2000...2000, stacked: true
                        )
                        .mixedValue(styleMixed(\.firstLineIndent, default: 0))
                        numberField("Left Indent", styleWrite(object, \.leftIndent, default: 0), range: 0...2000, stacked: true)
                            .mixedValue(styleMixed(\.leftIndent, default: 0))
                        numberField("Right Indent", styleWrite(object, \.rightIndent, default: 0), range: 0...2000, stacked: true)
                            .mixedValue(styleMixed(\.rightIndent, default: 0))
                    }
                }
            }
        }
    }

    private func flipStrip(_ object: SlideObject) -> some View {
        let horizontal = write(object, \.flipHorizontal, default: false)
        let vertical = write(object, \.flipVertical, default: false)
        return IconChipStrip<Bool>(
            items: [
                .init(id: true, systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "Flip Horizontal"),
                .init(id: false, systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down", title: "Flip Vertical"),
            ],
            isOn: { $0 ? horizontal.wrappedValue : vertical.wrappedValue },
            toggle: { if $0 { horizontal.wrappedValue.toggle() } else { vertical.wrappedValue.toggle() } }
        )
    }

    private func dialRow<Content: View>(spacing: CGFloat = 12, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            content()
        }
    }

    private func sliderField(
        _ label: String, _ binding: Binding<Double>, range: ClosedRange<Double>, step: Double,
        stacked: Bool = true
    ) -> some View {
        BoundedSliderRow(
            label: label, value: binding, range: range, step: step,
            onScrubPhase: { model.setScrubPreview($0) }, stacked: stacked
        )
    }

    private func horizontalAlignmentStrip(_ object: SlideObject) -> some View {
        let binding = styleWrite(object, \.horizontalAlignment, default: .center)
        return IconChipStrip<TextHorizontalAlignment>(
            items: [
                .init(id: .left, systemImage: "text.alignleft", title: "Align Left"),
                .init(id: .center, systemImage: "text.aligncenter", title: "Align Center"),
                .init(id: .right, systemImage: "text.alignright", title: "Align Right"),
            ],
            isOn: { binding.wrappedValue == $0 },
            toggle: { binding.wrappedValue = $0 }
        )
    }

    private func verticalAlignmentStrip(_ object: SlideObject) -> some View {
        let binding = styleWrite(object, \.verticalAlignment, default: .middle)
        return IconChipStrip<TextVerticalAlignment>(
            items: [
                .init(id: .top, systemImage: "align.vertical.top", title: "Align Top"),
                .init(id: .middle, systemImage: "align.vertical.center", title: "Align Middle"),
                .init(id: .bottom, systemImage: "align.vertical.bottom", title: "Align Bottom"),
            ],
            isOn: { binding.wrappedValue == $0 },
            toggle: { binding.wrappedValue = $0 }
        )
    }

    private func decorationStrip(_ object: SlideObject) -> some View {
        let toggles: [(TextDecoration, Binding<Bool>)] = [
            (.underline, styleWrite(object, \.underline, default: false)),
            (.strikethrough, styleWrite(object, \.strikethrough, default: false)),
            (.allCaps, allCapsBinding(object)),
            (.tabularFigures, styleWrite(object, \.tabularFigures, default: false)),
        ]
        return decorationStrip(toggles)
    }

    private func decorationStrip(_ toggles: [(TextDecoration, Binding<Bool>)]) -> some View {
        IconChipStrip<TextDecoration>(
            items: toggles.map { decoration, _ in
                .init(id: decoration, systemImage: decoration.systemImage, title: decoration.title)
            },
            isOn: { id in toggles.first { $0.0 == id }?.1.wrappedValue ?? false },
            toggle: { id in
                if let binding = toggles.first(where: { $0.0 == id })?.1 {
                    binding.wrappedValue.toggle()
                }
            }
        )
    }

    private enum TextDecoration: Hashable {
        case underline, strikethrough, allCaps, tabularFigures

        var systemImage: String {
            switch self {
            case .underline: "underline"
            case .strikethrough: "strikethrough"
            case .allCaps: "characters.uppercase"
            case .tabularFigures: "textformat.123"
            }
        }

        var title: String {
            switch self {
            case .underline: "Underline"
            case .strikethrough: "Strikethrough"
            case .allCaps: "All Caps"
            case .tabularFigures: "Tabular Figures"
            }
        }
    }

    private func keepFromSlideSection(_ object: SlideObject) -> some View {
        InspectorSection("Keep from Original Slide") {
            Text("When an output shows slides through this theme, styling a word carries only where it differs from the slide's own base style. Choose what this box keeps.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Bold Words", isOn: keepWrite(object, \.bold, default: true))
            Toggle("Italic Words", isOn: keepWrite(object, \.italic, default: true))
            Toggle("Underlines", isOn: keepWrite(object, \.underline, default: true))
            Toggle("Strikethroughs", isOn: keepWrite(object, \.strikethrough, default: true))
            Toggle("Bigger or Smaller Words", isOn: keepWrite(object, \.sizeEmphasis, default: true))
                .help("Carried as a proportion of the slide's size, applied to this box's size")
            Toggle("Letter Spacing on Words", isOn: keepWrite(object, \.wordLetterSpacing, default: true))
            Toggle("Highlights", isOn: keepWrite(object, \.highlight, default: false))
            Toggle("Text Colors", isOn: keepWrite(object, \.textColor, default: false))
        }
    }

    private func keepWrite(
        _ object: SlideObject,
        _ keyPath: WritableKeyPath<KeepFromSlideOptions, Bool?>,
        default fallback: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { current(object).keepFromSlide?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    var options = obj.keepFromSlide ?? KeepFromSlideOptions()
                    options[keyPath: keyPath] = value
                    obj.keepFromSlide = options
                }
            }
        )
    }

    @ViewBuilder
    private func selectionSection(_ object: SlideObject) -> some View {
        if model.canvasTextEditID == object.id, (model.canvasTextSelection?.length ?? 0) > 0 {
            let run = model.canvasSelectionRun
            let base = current(object).textStyle
            InspectorSection("Selection") {
                FontFaceRows(fontName: Binding(
                    get: { run?.fontName ?? base?.fontName ?? model.theme?.fontFamily ?? "HelveticaNeue-Bold" },
                    set: { name in model.applyStyleToSelection { $0.fontName = name.isEmpty ? nil : name } }
                ))
                HStack(spacing: 12) {
                    numberField("Size", Binding(
                        get: { run?.fontSize ?? base?.fontSize ?? model.theme?.fontSize ?? 96 },
                        set: { size in model.applyStyleToSelection { $0.fontSize = size } }
                    ), range: 1...500)
                    .frame(width: 112)
                    Spacer(minLength: 8)
                    HexColorRow(label: "Color", hex: Binding(
                        get: { run?.colorHex ?? base?.colorHex ?? model.theme?.textColorHex ?? "#FFFFFFFF" },
                        set: { hex in model.applyStyleToSelection { $0.colorHex = hex } }
                    ), labelHidden: true)
                }
                Toggle("Highlight", isOn: Binding(
                    get: { run?.highlightColorHex != nil },
                    set: { on in model.applyStyleToSelection { $0.highlightColorHex = on ? Self.defaultHighlightHex : nil } }
                ))
                if run?.highlightColorHex != nil {
                    HexColorRow(label: "Highlight Color", hex: Binding(
                        get: { run?.highlightColorHex ?? Self.defaultHighlightHex },
                        set: { hex in model.applyStyleToSelection { $0.highlightColorHex = hex } }
                    ))
                }
                numberField("Tracking", Binding(
                    get: { run?.tracking ?? base?.tracking ?? 0 },
                    set: { tracking in model.applyStyleToSelection { $0.tracking = tracking } }
                ), range: -50...200)
                LabeledContent("Style") {
                    decorationStrip([
                        (.underline, Binding(
                            get: { run?.underline == true },
                            set: { on in model.applyStyleToSelection { $0.underline = on ? true : nil } }
                        )),
                        (.strikethrough, Binding(
                            get: { run?.strikethrough == true },
                            set: { on in model.applyStyleToSelection { $0.strikethrough = on ? true : nil } }
                        )),
                    ])
                }
                Button("Clear Selection Style") {
                    model.applyStyleToSelection { run in
                        run.underline = nil
                        run.strikethrough = nil
                        run.fontName = nil
                        run.fontSize = nil
                        run.colorHex = nil
                        run.highlightColorHex = nil
                        run.tracking = nil
                    }
                }
            }
        }
    }

    private static let defaultHighlightHex = "#FFF176FF"

    @ViewBuilder
    private func chordsSection(_ object: SlideObject) -> some View {
        if current(object).textStyle?.pathData == nil {
            InspectorSection("Chords") {
                Toggle("Chords", isOn: styleWrite(object, \.showChords, default: false))
                    .help("Draw chord symbols above each line of this text")
                if current(object).textStyle?.showChords == true {
                    InspectorPicker("Notation", selection: styleWrite(object, \.chordNotation, default: .chords)) {
                        Text("Chords").tag(ChordNotation.chords)
                        Text("Numbers").tag(ChordNotation.numbers)
                        Text("Numerals").tag(ChordNotation.numerals)
                        Text("Do Re Mi").tag(ChordNotation.doReMi)
                    }
                    HexColorRow(
                        label: "Color",
                        hex: styleWrite(object, \.chordColorHex, default: "#FFB826FF")
                    )
                }
            }
        }
    }

    private func textPathSection(_ object: SlideObject, forShape: Bool = false) -> some View {
        InspectorSection("Text Path") {
            if forShape {

                InspectorPicker("Placement", selection: write(object, \.shapeTextPlacement, default: .inside)) {
                    Text("Inside").tag(ShapeTextPlacement.inside)
                    Text("On Edge — Outside").tag(ShapeTextPlacement.edgeOutside)
                    Text("On Edge — Inside").tag(ShapeTextPlacement.edgeInside)
                }
                if (current(object).shapeTextPlacement ?? .inside) != .inside {

                    if current(object).shapeKind == nil
                        || current(object).shapeKind == .rectangle
                        || current(object).shapeKind == .roundedRectangle {
                        numberField(
                            "Text Corners",
                            write(object, \.shapeTextCornerRadius,
                                  default: current(object).cornerRadius ?? 0),
                            range: 0...500
                        )
                    }
                    pathFlowRows(object)
                }
            } else {

                InspectorPicker("Path", selection: pathChoiceBinding(object)) {
                    ForEach(PathChoice.allCases.filter { $0 != .custom }, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                    if pathChoice(for: current(object).textStyle?.pathData) == .custom {
                        Text("Custom").tag(PathChoice.custom)
                    }
                }
                if current(object).textStyle?.pathData != nil {

                    InspectorPicker("Side", selection: styleWrite(object, \.pathSide, default: .outside)) {
                        Text("Outside").tag(TextPathSide.outside)
                        Text("Inside").tag(TextPathSide.inside)
                    }
                    pathFlowRows(object)
                } else {
                    blockScrollRows(object)
                }
            }
        }
    }

    @ViewBuilder
    private func blockScrollRows(_ object: SlideObject) -> some View {
        let scroll = current(object).textStyle?.scroll
        InspectorPicker("Scroll", selection: Binding<String>(
            get: { scroll.map { ($0.axis ?? .up).rawValue } ?? "off" },
            set: { value in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    if let axis = BlockScrollAxis(rawValue: value) {
                        var record = style.scroll ?? BlockScroll(speed: 60)
                        record.axis = axis
                        style.scroll = record
                    } else {
                        style.scroll = nil
                    }
                    obj.textStyle = style
                }
            }
        )) {
            Text("Off").tag("off")
            Text("Up (roll)").tag(BlockScrollAxis.up.rawValue)
            Text("Down").tag(BlockScrollAxis.down.rawValue)
            Text("Left").tag(BlockScrollAxis.left.rawValue)
            Text("Right").tag(BlockScrollAxis.right.rawValue)
        }
        .help("The whole text block moves as one unit through its box from the moment it fires (credits roll, crawl). Text longer than the box lays out in full and scrolls through.")
        if scroll != nil {
            numberField("Scroll Speed", scrollWrite(object, \.speed, default: 60), range: 1...2000)

            numberField(
                "Passes",
                Binding(
                    get: { Double(current(object).textStyle?.scroll?.passes ?? 0) },
                    set: { value in
                        commit(object) { obj in
                            guard var style = obj.textStyle, var record = style.scroll else { return }
                            record.passes = Int(value.rounded())
                            style.scroll = record
                            obj.textStyle = style
                        }
                    }
                ),
                range: 0...99
            )
            InspectorPicker("Ramp", selection: scrollWrite(object, \.ramp, default: .none)) {
                ForEach([AnimationRamp.none, .in, .out, .both], id: \.self) { Text($0.displayName).tag($0) }
            }
            .help("Eases each pass, so a finite roll starts and ends softly")
            if (scroll?.passes ?? 0) > 0 {
                Toggle("Rest on Last Lines", isOn: scrollWrite(object, \.restAtEnd, default: false))
                    .help("The last pass stops with the end of the block in the box instead of rolling fully off")
            }
            sliderField("Fade at Exit %", Binding(
                get: { (current(object).textStyle?.scroll?.fadeTowardTop ?? 0) * 100 },
                set: { value in
                    commit(object) { obj in
                        guard var style = obj.textStyle, var record = style.scroll else { return }
                        record.fadeTowardTop = value / 100
                        style.scroll = record
                        obj.textStyle = style
                    }
                }
            ), range: 0...100, step: 1)
            Text("Crawl: Up + a Tilt (Transform) + Fade at Exit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func scrollWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<BlockScroll, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object).textStyle?.scroll?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    guard var style = obj.textStyle, var record = style.scroll else { return }
                    record[keyPath: keyPath] = value
                    style.scroll = record
                    obj.textStyle = style
                }
            }
        )
    }

    private func scrollWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<BlockScroll, T>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object).textStyle?.scroll?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    guard var style = obj.textStyle, var record = style.scroll else { return }
                    record[keyPath: keyPath] = value
                    style.scroll = record
                    obj.textStyle = style
                }
            }
        )
    }

    private func hasThemeOverrides(_ object: SlideObject) -> Bool {
        let current = current(object)
        return current.textStyle != nil
            || current.x != nil || current.y != nil
            || current.width != nil || current.height != nil
    }

    @ViewBuilder
    private func maskSection(_ object: SlideObject) -> some View {
        let candidates = maskCandidates(for: object)
        if !candidates.isEmpty || current(object).maskObjectId != nil {
            InspectorSection("Mask") {
                InspectorPicker("Mask With", selection: maskObjectBinding(object)) {
                    Text("None").tag("")
                    ForEach(candidates, id: \.id) { candidate in
                        Text(candidate.name.isEmpty ? fallbackName(candidate) : candidate.name)
                            .tag(candidate.id)
                    }

                    if let maskID = current(object).maskObjectId, !maskID.isEmpty,
                       !candidates.contains(where: { $0.id == maskID }) {
                        Text("Missing object").tag(maskID)
                    }
                }
                if current(object).maskObjectId?.isEmpty == false {
                    InspectorPicker("Keep", selection: maskModeBinding(object)) {
                        Text("Inside").tag(MaskMode.in)
                        Text("Cut Out").tag(MaskMode.out)
                    }
                    .pickerStyle(.segmented)
                }
                if isMatte(object) {
                    Text("Used as a mask — hidden on outputs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fallbackName(_ object: SlideObject) -> String {
        let object = SlideObjectNormalization.normalized(object)
        switch object.objectKind {
        case .text: return "Text"
        case .shape, .media, .liveInput:
            guard let fill = object.fill, fill.fillKind == .media else { return "Shape" }

            return fillIsLibrary(object) ? "Media" : "Live Input"
        }
    }

    private func maskCandidates(for object: SlideObject) -> [SlideObject] {
        let objects = model.currentSlide?.objects ?? []
        let byID = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        return objects.filter { candidate in
            guard candidate.id != object.id else { return false }

            var cursor: String? = candidate.maskObjectId
            var hops = 0
            while let next = cursor, !next.isEmpty, hops < 16 {
                if next == object.id { return false }
                cursor = byID[next]?.maskObjectId
                hops += 1
            }
            return true
        }
    }

    private func isMatte(_ object: SlideObject) -> Bool {
        model.currentSlide?.objects.contains { $0.maskObjectId == object.id } ?? false
    }

    private func maskObjectBinding(_ object: SlideObject) -> Binding<String> {
        Binding(
            get: { current(object).maskObjectId ?? "" },
            set: { id in
                commit(object) { obj in
                    obj.maskObjectId = id.isEmpty ? nil : id
                    if id.isEmpty { obj.maskMode = nil }
                }
            }
        )
    }

    private func maskModeBinding(_ object: SlideObject) -> Binding<MaskMode> {
        Binding(
            get: { current(object).maskMode ?? .in },
            set: { mode in
                commit(object) { $0.maskMode = mode }
            }
        )
    }

    @ViewBuilder
    private func effectsSection(_ object: SlideObject) -> some View {
        let effects = current(object).effects ?? []
        InspectorSection("Effects") {
            ForEach(Array(effects.enumerated()), id: \.offset) { index, effect in
                HStack {

                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)

                    Toggle("", isOn: effectEnabledWrite(object, index: index))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .tint(.green)
                        .help("Bypass keeps the effect's settings")
                    Text(effect.effectKind.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(effect.enabled ?? true ? .primary : .tertiary)
                    Spacer()
                    Button {
                        removeEffect(object, at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this effect")
                }
                .contentShape(Rectangle())
                .draggable("fx:object:\(index)")
                .dropDestination(for: String.self) { payloads, _ in
                    guard let source = MediaEditorView.effectDragIndex(payloads, prefix: "fx:object:")
                    else { return false }
                    moveEffect(object, from: source, to: index)
                    return true
                }
                switch effect.effectKind {
                case .blur:
                    effectSlider(
                        "Radius",
                        effectWrite(object, index: index, \.radius, default: 12),
                        range: 0...200
                    )
                case .colorAdjust:
                    effectSlider(
                        "Hue",
                        effectWrite(object, index: index, \.hue, default: 0),
                        range: -180...180, step: 1
                    )
                    effectSlider(
                        "Brightness",
                        effectWrite(object, index: index, \.brightness, default: 0),
                        range: -1...1, step: 0.02
                    )
                    effectSlider(
                        "Contrast",
                        effectWrite(object, index: index, \.contrast, default: 0),
                        range: -1...1, step: 0.02
                    )
                    effectSlider(
                        "Saturation",
                        effectWrite(object, index: index, \.saturation, default: 1),
                        range: 0...2, step: 0.02
                    )
                default:

                    if let control = effect.effectKind.amountControl {
                        effectSlider(
                            control.label,
                            effectWrite(object, index: index, \.amount, default: control.fallback),
                            range: control.range, step: control.step
                        )
                    }
                    ForEach(effect.effectKind.extraControls) { control in
                        effectSlider(
                            control.label,
                            effectWrite(object, index: index, control.keyPath, default: control.fallback),
                            range: control.range, step: control.step
                        )
                    }
                }

                effectSlider(
                    "Mix",
                    effectWrite(object, index: index, \.opacity, default: 1),
                    range: 0...1, step: 0.02
                )
            }
            HStack {
                Menu("Add Effect") {
                    ForEach(EffectKind.addable, id: \.self) { kind in
                        Button(kind.displayName) { addEffect(object, kind: kind) }
                    }
                }
                Spacer()
                EffectPresetsMenu(
                    model: model.appModel, currentChain: effects,
                    apply: { chain in
                        commit(object) { obj in
                            obj.effects = chain.isEmpty ? nil : chain
                            if obj.effects == nil { obj.effectsApplyBelow = nil }
                        }
                    },
                    add: { chain in
                        commit(object) { obj in
                            obj.effects = (obj.effects ?? []) + chain
                        }
                    },
                    presetNamePrompt: $presetNamePrompt
                )
            }
            .alert("New Effect Preset", isPresented: $presetNamePrompt) {
                TextField("Name", text: $presetNameDraft)
                Button("Save") {
                    let name = presetNameDraft.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        model.appModel.saveEffectPreset(
                            name: name, effects: current(object).effects ?? []
                        )
                    }
                    presetNameDraft = ""
                }
                Button("Cancel", role: .cancel) { presetNameDraft = "" }
            }
            if object.objectKind == .shape, !effects.isEmpty {

                Toggle(
                    "Apply to Content Below",
                    isOn: write(object, \.effectsApplyBelow, default: false)
                )
            }
        }
    }

    private func moveEffect(_ object: SlideObject, from source: Int, to target: Int) {
        commit(object) { obj in
            guard var effects = obj.effects, effects.indices.contains(source), source != target
            else { return }
            let moved = effects.remove(at: source)
            effects.insert(moved, at: target > source ? target - 1 : target)
            obj.effects = effects
        }
    }

    private func addEffect(_ object: SlideObject, kind: EffectKind) {
        commit(object) { obj in
            var effects = obj.effects ?? []
            effects.append(kind.freshEffect)
            obj.effects = effects
        }
    }

    private func removeEffect(_ object: SlideObject, at index: Int) {
        commit(object) { obj in
            guard var effects = obj.effects, effects.indices.contains(index) else { return }
            effects.remove(at: index)
            obj.effects = effects.isEmpty ? nil : effects
            if obj.effects == nil { obj.effectsApplyBelow = nil }
        }
    }

    private func effectEnabledWrite(_ object: SlideObject, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let effects = current(object).effects, effects.indices.contains(index)
                else { return true }
                return effects[index].enabled ?? true
            },
            set: { value in
                commit(object) { obj in
                    guard var effects = obj.effects, effects.indices.contains(index) else { return }
                    effects[index].enabled = value ? nil : false
                    obj.effects = effects
                }
            }
        )
    }

    private func effectSlider(
        _ label: String, _ binding: Binding<Double>,
        range: ClosedRange<Double>, step: Double = 1
    ) -> some View {
        BoundedSliderRow(
            label: label, value: binding, range: range, step: step,
            onScrubPhase: { model.setScrubPreview($0) }
        )
    }

    private func effectWrite(
        _ object: SlideObject, index: Int,
        _ keyPath: WritableKeyPath<Effect, Double?>, default fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let effects = current(object).effects, effects.indices.contains(index)
                else { return fallback }
                return effects[index][keyPath: keyPath] ?? fallback
            },
            set: { value in
                commit(object) { obj in
                    guard var effects = obj.effects, effects.indices.contains(index) else { return }
                    effects[index][keyPath: keyPath] = value
                    obj.effects = effects
                }
            }
        )
    }

    @ViewBuilder
    private func lineStylesSection(_ object: SlideObject) -> some View {
        let lines = current(object).text.components(separatedBy: "\n")
        if lines.count > 1 {
            let line = min(selectedLineIndex, lines.count - 1)
            InspectorSection("Line Styles") {
                InspectorPicker("Line", selection: Binding(
                    get: { min(selectedLineIndex, lines.count - 1) },
                    set: { selectedLineIndex = $0 }
                )) {
                    ForEach(0..<lines.count, id: \.self) { index in
                        Text(lineLabel(
                            lines[index], index: index,
                            styled: lineOverride(object, line: index) != nil
                        )).tag(index)
                    }
                }
                HStack(spacing: 12) {
                    numberField(
                        "Size",
                        lineWrite(
                            object, line: line, \.fontSize,
                            default: current(object).textStyle?.fontSize ?? model.theme?.fontSize ?? 96
                        ),
                        range: 1...500
                    )
                    .frame(width: 112)
                    Spacer(minLength: 8)
                    HexColorRow(label: "Color", hex: lineWrite(
                        object, line: line, \.colorHex,
                        default: current(object).textStyle?.colorHex
                            ?? model.theme?.textColorHex ?? "#FFFFFFFF"
                    ), labelHidden: true)
                }
                numberField(
                    "Tracking",
                    lineWrite(object, line: line, \.tracking, default: 0),
                    range: -50...200
                )
                if lineOverride(object, line: line) != nil {
                    Button("Reset Line") { resetLineOverride(object, line: line) }
                }
            }
        }
    }

    private func lineLabel(_ text: String, index: Int, styled: Bool) -> String {
        let preview = text.trimmingCharacters(in: .whitespaces)
        let clipped = preview.count > 18 ? String(preview.prefix(18)) + "…" : preview
        let name = clipped.isEmpty ? "Line \(index + 1)" : "\(index + 1)  \(clipped)"

        return styled ? "• \(name)" : name
    }

    private func lineOverride(_ object: SlideObject, line: Int) -> LineStyleOverride? {
        current(object).textStyle?.lineStyles?.first { $0.lineIndex == line }
    }

    private func lineWrite<T: Equatable>(
        _ object: SlideObject, line: Int,
        _ keyPath: WritableKeyPath<LineStyleOverride, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { lineOverride(object, line: line)?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    var lines = style.lineStyles ?? []
                    if let index = lines.firstIndex(where: { $0.lineIndex == line }) {
                        lines[index][keyPath: keyPath] = value
                    } else {
                        var override = LineStyleOverride(lineIndex: line)
                        override[keyPath: keyPath] = value
                        lines.append(override)
                    }
                    style.lineStyles = lines
                    obj.textStyle = style
                }
            }
        )
    }

    private func resetLineOverride(_ object: SlideObject, line: Int) {
        commit(object) { obj in
            guard var style = obj.textStyle else { return }
            style.lineStyles?.removeAll { $0.lineIndex == line }
            if style.lineStyles?.isEmpty == true { style.lineStyles = nil }
            obj.textStyle = style
        }
    }

    private func lineFillSection(_ object: SlideObject) -> some View {
        InspectorSection {
            toggleRow("Line Fill", isOn: Binding(
                get: { current(object).textStyle?.lineFill != nil },
                set: { on in
                    commit(object) { obj in
                        var style = obj.textStyle ?? TextStyle()
                        style.lineFill = on ? Self.defaultLineFill : nil
                        obj.textStyle = style
                    }
                }
            ))
            .mixedValue(mixed { $0.textStyle?.lineFill })
            if current(object).textStyle?.lineFill != nil {
                HexColorRow(label: "Color", hex: lineFillColorBinding(object))
                InspectorPicker("Width", selection: lineFillWrite(object, \.widthMode, default: .fullWidth)) {
                    Text("Full Width").tag(TextLineFillWidthMode.fullWidth)
                    Text("Line Width").tag(TextLineFillWidthMode.lineWidth)
                    Text("Widest Line").tag(TextLineFillWidthMode.maxLineWidth)
                }
                numberField(
                    "Corner Radius", lineFillWrite(object, \.cornerRadius, default: 0),
                    range: 0...500
                )
                dialRow {
                    numberField(
                        "Padding Vertical", lineFillWrite(object, \.verticalPadding, default: 0),
                        range: -200...500, stacked: true
                    )
                    numberField(
                        "Padding Horizontal", lineFillWrite(object, \.horizontalPadding, default: 0),
                        range: -200...500, stacked: true
                    )
                }
                dialRow {
                    numberField(
                        "Offset Vertical", lineFillWrite(object, \.verticalOffset, default: 0),
                        range: -500...500, stacked: true
                    )
                    numberField(
                        "Offset Horizontal", lineFillWrite(object, \.horizontalOffset, default: 0),
                        range: -500...500, stacked: true
                    )
                }
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .fontWeight(.semibold)
        }
    }

    private func lineFillWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<TextLineFill, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: {
                (current(object).textStyle?.lineFill ?? Self.defaultLineFill)[keyPath: keyPath]
                    ?? fallback
            },
            set: { value in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    var lineFill = style.lineFill ?? Self.defaultLineFill
                    lineFill[keyPath: keyPath] = value
                    style.lineFill = lineFill
                    obj.textStyle = style
                }
            }
        )
    }

    private func lineFillColorBinding(_ object: SlideObject) -> Binding<String> {
        Binding(
            get: {
                current(object).textStyle?.lineFill?.fill.colorHex ?? "#000000FF"
            },
            set: { hex in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    var lineFill = style.lineFill ?? Self.defaultLineFill
                    lineFill.fill = ObjectFill(fillKind: .solid, colorHex: hex)
                    style.lineFill = lineFill
                    obj.textStyle = style
                }
            }
        )
    }

    private func textOutlineSection(_ object: SlideObject) -> some View {
        InspectorSection {
            toggleRow("Outline", isOn: Binding(
                get: { current(object).textStyle?.outline != nil },
                set: { on in
                    commit(object) { obj in
                        var style = obj.textStyle ?? TextStyle()
                        style.outline = on ? Self.defaultStroke : nil
                        obj.textStyle = style
                    }
                }
            ))
            .mixedValue(mixed { $0.textStyle?.outline })
            if current(object).textStyle?.outline != nil {
                HexColorRow(label: "Color", hex: textOutlineWrite(object, \.colorHex))
                numberField("Width", textOutlineWrite(object, \.width), range: 0...50)
            }
        }
    }

    private func allCapsBinding(_ object: SlideObject) -> Binding<Bool> {
        Binding(
            get: { current(object).textStyle?.textTransform == .uppercase },
            set: { on in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    style.textTransform = on ? .uppercase : TextTransform.none
                    obj.textStyle = style
                }
            }
        )
    }

    private func shapeSection(_ object: SlideObject) -> some View {
        InspectorSection("Shape") {
            InspectorPicker("Kind", selection: write(object, \.shapeKind, default: .rectangle)) {
                Text("Rectangle").tag(ShapeKind.rectangle)
                Text("Rounded Rectangle").tag(ShapeKind.roundedRectangle)
                Text("Ellipse").tag(ShapeKind.ellipse)
                if current(object).shapeKind == .path {
                    Text(IconCatalog.icon(matching: current(object).pathData) == nil ? "Custom Path" : "Icon").tag(ShapeKind.path)
                }
            }
            if current(object).shapeKind == .roundedRectangle {
                numberField("Corner Radius", write(object, \.cornerRadius, default: 0), range: 0...500)
            }

            InspectorPicker("Icon", selection: Binding<String>(
                get: { IconCatalog.icon(matching: current(object).pathData).map(\.id) ?? "" },
                set: { id in
                    commit(object) { obj in
                        if let icon = IconCatalog.shape(id: id) {
                            obj.shapeKind = .path
                            obj.pathData = icon.pathData
                        } else if IconCatalog.icon(matching: obj.pathData) != nil {
                            obj.shapeKind = .rectangle
                            obj.pathData = nil
                        }
                    }
                }
            )) {
                Text("None").tag("")
                ForEach(IconCatalog.all) { icon in Text(icon.name).tag(icon.id) }
            }
            .help("A built-in icon as the shape. Square frames keep it round; the Fill is its color")
        }
    }

    private func fillIsMediaKind(_ object: SlideObject) -> Bool {
        current(object).fill?.fillKind == .media
    }

    private func fillSection(_ object: SlideObject) -> some View {
        InspectorSection(fillIsMediaKind(object) ? "Media" : "Fill") {
            InspectorPicker("Fill", selection: fillKindBinding(object)) {
                Text("None").tag(FillKind.none)
                Text("Solid").tag(FillKind.solid)
                Text("Linear Gradient").tag(FillKind.linearGradient)
                Text("Media").tag(FillKind.media)
            }
            .mixedValue(mixed { $0.fill })
            switch current(object).fill?.fillKind ?? .solid {
            case .solid:
                HexColorRow(label: "Color", hex: fillWrite(object, \.colorHex, default: "#FFFFFFFF"))
            case .linearGradient:
                numberField("Angle", fillWrite(object, \.gradientAngleDegrees, default: 0), range: 0...360)
                HexColorRow(label: "Start", hex: gradientStopHex(object, index: 0))
                HexColorRow(label: "End", hex: gradientStopHex(object, index: 1))
            case .media:

                InspectorPicker("Source", selection: fillSourceBinding(object)) {
                    Text("Library Item").tag("")
                    ForEach(LiveInputCatalog.choices) { choice in
                        Text(choice.name).tag(choice.token)
                    }

                    if let fill = current(object).fill,
                       fill.liveInputId?.isEmpty != false,
                       let sourceId = fill.captureSourceId, !sourceId.isEmpty {
                        Text(LiveInputCatalog.legacyLabel(
                            kind: fill.captureSourceKind, id: sourceId))
                            .tag(LiveInputCatalog.selectionToken(
                                liveInputId: nil,
                                kind: fill.captureSourceKind, id: sourceId))
                    }
                    if !model.screenSourceChoices.isEmpty {
                        Section("Screens") {
                            ForEach(model.screenSourceChoices, id: \.id) { screen in
                                Text(screen.name)
                                    .tag(ScreenSourceToken.token(forScreenId: screen.id))
                            }
                        }
                    }
                }
                if fillIsLibrary(object) {
                    LabeledContent("Item") {
                        HStack(spacing: 6) {
                            Text(fillMediaName(object))
                            if let mediaID = current(object).fill?.mediaId, !mediaID.isEmpty {
                                editMediaButton(mediaID)
                            }
                        }
                    }
                }
                InspectorPicker("Scale", selection: fillWrite(object, \.mediaScaleMode, default: .fill)) {
                    Text("Fill").tag(MediaScaleMode.fill)
                    Text("Fit").tag(MediaScaleMode.fit)
                    Text("Stretch").tag(MediaScaleMode.stretch)
                }
                if fillIsLibrary(object) {

                    Toggle("Loop", isOn: Binding(
                        get: { model.fillLoops(current(object)) },
                        set: { loops in
                            commit(object) { obj in
                                var fill = obj.fill ?? ObjectFill(fillKind: .media)
                                fill.loops = loops
                                obj.fill = fill
                            }
                        }
                    ))
                    Button(current(object).fill?.mediaId?.isEmpty == false ? "Replace…" : "Choose…") {
                        showingFillMediaPicker = true
                    }
                    if current(object).fill?.mediaId?.isEmpty == false {

                        Button("Remove") {
                            commit(object) {
                                $0.fill = ObjectFill(fillKind: .solid, colorHex: "#FFFFFFFF")
                            }
                        }
                    }
                }
            case .none:
                EmptyView()
            }
        }
        .sheet(isPresented: $showingFillMediaPicker) {
            LibraryPickerSheet(appModel: model.appModel) { entry in
                commit(object) { obj in
                    var fill = obj.fill ?? ObjectFill(fillKind: .media)
                    fill.fillKind = .media
                    fill.mediaId = entry.id

                    fill.captureSourceKind = nil
                    fill.captureSourceId = nil
                    obj.fill = fill
                }
            }
        }
    }

    private func fillMediaName(_ object: SlideObject) -> String {
        guard let mediaID = current(object).fill?.mediaId, !mediaID.isEmpty else { return "None" }
        return model.appModel.indexEntry(mediaID)?.name ?? "Missing item"
    }

    private func editMediaButton(_ mediaID: String) -> some View {
        Button {
            model.appModel.openInEditor(entryID: mediaID)
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Edit Media")
    }

    private func fillIsLibrary(_ object: SlideObject) -> Bool {
        let fill = current(object).fill
        return fill?.liveInputId?.isEmpty != false
            && fill?.captureSourceId?.isEmpty != false
            && fill?.captureSourceKind == nil
            && fill?.screenSourceId?.isEmpty != false
    }

    private func fillSourceBinding(_ object: SlideObject) -> Binding<String> {
        Binding(
            get: {
                let fill = current(object).fill
                if let screenId = fill?.screenSourceId, !screenId.isEmpty {
                    return ScreenSourceToken.token(forScreenId: screenId)
                }
                return LiveInputCatalog.selectionToken(
                    liveInputId: fill?.liveInputId,
                    kind: fill?.captureSourceKind, id: fill?.captureSourceId
                )
            },
            set: { token in
                commit(object) { obj in
                    var fill = obj.fill ?? ObjectFill(fillKind: .media)
                    fill.fillKind = .media
                    fill.captureSourceKind = nil
                    fill.captureSourceId = nil
                    if let screenId = ScreenSourceToken.screenId(for: token) {
                        fill.screenSourceId = screenId
                        fill.liveInputId = nil
                    } else if let itemId = LiveInputCatalog.liveInputId(for: token) {
                        fill.screenSourceId = nil
                        fill.liveInputId = itemId
                    } else {

                        let choice = LiveInputCatalog.choice(for: token)
                        fill.screenSourceId = nil
                        fill.liveInputId = nil
                        fill.captureSourceKind = choice?.kind
                        fill.captureSourceId = choice?.id
                    }
                    obj.fill = fill
                }
            }
        )
    }

    private func strokeSection(_ object: SlideObject) -> some View {
        InspectorSection {
            toggleRow("Stroke", isOn: Binding(
                get: { current(object).stroke != nil },
                set: { on in
                    commit(object) { $0.stroke = on ? Self.defaultStroke : nil }
                }
            ))
            .mixedValue(mixed { $0.stroke })
            if current(object).stroke != nil {
                HexColorRow(label: "Color", hex: strokeWrite(object, \.colorHex))
                numberField("Width", strokeWrite(object, \.width), range: 0...50)
                InspectorPicker("Dash", selection: Binding(
                    get: { current(object).stroke?.dashKind ?? .solid },
                    set: { kind in
                        commit(object) {
                            $0.stroke?.dashKind = kind == .solid ? nil : kind
                        }
                    }
                )) {
                    Text("Solid").tag(StrokeDashKind.solid)
                    Text("Dashed").tag(StrokeDashKind.dashed)
                    Text("Dotted").tag(StrokeDashKind.dotted)
                }
            }
        }
    }

    private func fillKindBinding(_ object: SlideObject) -> Binding<FillKind> {
        Binding(
            get: { current(object).fill?.fillKind ?? .solid },
            set: { kind in
                commit(object) { obj in
                    var fill = obj.fill ?? ObjectFill(fillKind: kind)
                    fill.fillKind = kind
                    if kind == .solid, fill.colorHex == nil {
                        fill.colorHex = "#FFFFFFFF"
                    }
                    if kind == .linearGradient, (fill.gradientStops ?? []).count < 2 {
                        fill.gradientAngleDegrees = fill.gradientAngleDegrees ?? 0
                        fill.gradientStops = [
                            GradientStop(colorHex: "#4A90D9FF", position: 0),
                            GradientStop(colorHex: "#1B2A4AFF", position: 1),
                        ]
                    }
                    if kind == .media, fill.mediaScaleMode == nil {
                        fill.mediaScaleMode = .fill
                    }
                    obj.fill = fill
                }

                if kind == .media,
                   current(object).fill?.mediaId?.isEmpty != false,
                   current(object).fill?.captureSourceId?.isEmpty != false,
                   current(object).fill?.screenSourceId?.isEmpty != false {
                    showingFillMediaPicker = true
                }
            }
        )
    }

    private func shadowSection(
        _ object: SlideObject,
        title: String,
        read: @escaping (SlideObject) -> ObjectShadow?,
        store: @escaping (inout SlideObject, ObjectShadow?) -> Void
    ) -> some View {
        InspectorSection {
            toggleRow(title, isOn: Binding(
                get: { read(current(object)) != nil },
                set: { on in
                    commit(object) { store(&$0, on ? Self.defaultShadow : nil) }
                }
            ))
            .mixedValue(mixed(read))
            if read(current(object)) != nil {
                HexColorRow(label: "Color", hex: shadowWrite(object, \.colorHex, read: read, store: store))
                dialRow {
                    numberField("Blur", shadowWrite(object, \.blurRadius, read: read, store: store), range: 0...100, stacked: true)
                    numberField("Offset X", shadowWrite(object, \.offsetX, read: read, store: store), range: -200...200, stacked: true)
                    numberField("Offset Y", shadowWrite(object, \.offsetY, read: read, store: store), range: -200...200, stacked: true)
                }
            }
        }
    }

    private func commit(_ object: SlideObject, _ mutate: (inout SlideObject) -> Void) {
        model.updateObjects(ids: editTargets(object), mutate)
    }

    private func editTargets(_ object: SlideObject) -> Set<String> {
        model.selectedObjectIDs.contains(object.id) ? model.selectedObjectIDs : [object.id]
    }

    private func mixed<T: Equatable>(_ read: (SlideObject) -> T) -> Bool {
        model.selectedObjectIDs.count > 1 && SelectionFormatting.isMixed(model.selectedObjects, read)
    }

    private func objectMixed<T: Equatable>(_ keyPath: KeyPath<SlideObject, T?>, default fallback: T) -> Bool {
        mixed { $0[keyPath: keyPath] ?? fallback }
    }

    private func styleMixed<T: Equatable>(_ keyPath: KeyPath<TextStyle, T?>, default fallback: T) -> Bool {
        mixed { $0.textStyle?[keyPath: keyPath] ?? fallback }
    }

    private func decorationsMixed() -> Bool {
        styleMixed(\.underline, default: false) || styleMixed(\.strikethrough, default: false)
            || styleMixed(\.textTransform, default: TextTransform.none) || styleMixed(\.tabularFigures, default: false)
    }

    private func current(_ object: SlideObject) -> SlideObject {
        SlideObjectNormalization.normalized(model.object(id: object.id) ?? object)
    }

    private func write<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<SlideObject, T>
    ) -> Binding<T> {
        Binding(
            get: { current(object)[keyPath: keyPath] },
            set: { value in commit(object) { $0[keyPath: keyPath] = value } }
        )
    }

    private func write<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<SlideObject, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object)[keyPath: keyPath] ?? fallback },
            set: { value in commit(object) { $0[keyPath: keyPath] = value } }
        )
    }

    private func styleWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<TextStyle, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object).textStyle?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    style[keyPath: keyPath] = value
                    obj.textStyle = style
                }
            }
        )
    }

    private func linkSourceBinding(_ object: SlideObject) -> Binding<TextSourceKind?> {
        Binding(
            get: { current(object).textLink?.source },
            set: { source in
                commit(object) { obj in
                    obj.textLink = source.map { picked in
                        var link = TextLink(source: picked)

                        if picked == .videoCountdown, !model.isConfidenceEditor {
                            link.showsVideoName = false
                        }
                        return link
                    }
                }
            }
        )
    }

    private func maxLinesBinding(_ object: SlideObject) -> Binding<Double> {
        Binding(
            get: { Double(current(object).textLink?.maxLines ?? 0) },
            set: { value in
                commit(object) { obj in
                    guard var link = obj.textLink else { return }
                    link.maxLines = value <= 0 ? nil : Int(value)
                    obj.textLink = link
                }
            }
        )
    }

    private static let customFormatTag = "custom"

    static let clockFormatPresets: [(label: String, format: String)] = [
        ("10:25", ""),
        ("10:25:08", "h:mm:ss"),
        ("22:25", "HH:mm"),
        ("10:25 PM", "h:mm a"),
        ("10:25:08 PM", "h:mm:ss a"),
    ]

    private func formatSampleCaption(_ link: TextLink) -> some View {
        Text("Reads \(LinkedText.sampleText(for: link))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func clockFormatIsCustom(_ object: SlideObject) -> Bool {
        let format = current(object).textLink?.clockFormat ?? ""
        return customFormatObjectID == object.id
            || !Self.clockFormatPresets.contains { $0.format == format }
    }

    private func clockFormatSelection(_ object: SlideObject) -> Binding<String> {
        Binding(
            get: {
                clockFormatIsCustom(object)
                    ? Self.customFormatTag
                    : current(object).textLink?.clockFormat ?? ""
            },
            set: { picked in
                if picked == Self.customFormatTag {

                    customFormatObjectID = object.id
                } else {
                    customFormatObjectID = nil
                    linkWrite(object, \.clockFormat, default: "").wrappedValue = picked
                }
            }
        )
    }

    private func timerFormatIsCustom(_ object: SlideObject) -> Bool {
        customFormatObjectID == object.id
            || !(current(object).textLink?.timerPattern ?? "").isEmpty
    }

    private func timerFormatSelection(_ object: SlideObject) -> Binding<String> {
        Binding(
            get: {
                timerFormatIsCustom(object)
                    ? Self.customFormatTag
                    : (current(object).textLink?.timerFormat ?? .digits).rawValue
            },
            set: { picked in
                if picked == Self.customFormatTag {
                    customFormatObjectID = object.id

                    if (current(object).textLink?.timerPattern ?? "").isEmpty {
                        linkWrite(object, \.timerPattern, default: "").wrappedValue = "H:mm:ss"
                    }
                } else if let format = TimerTextFormat(rawValue: picked) {
                    customFormatObjectID = nil
                    commit(object) { obj in
                        if var link = obj.textLink {
                            link.timerFormat = format
                            link.timerPattern = nil
                            obj.textLink = link
                        }
                    }
                }
            }
        )
    }

    private func linkWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<TextLink, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object).textLink?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    guard var link = obj.textLink else { return }
                    link[keyPath: keyPath] = value
                    obj.textLink = link
                }
            }
        )
    }

    private enum PathChoice: CaseIterable {
        case off, ellipse, perimeter, line, arc, custom

        var label: String {
            switch self {
            case .off: "Off"
            case .ellipse: "Ellipse"
            case .perimeter: "Perimeter"
            case .line: "Line"
            case .arc: "Arc"
            case .custom: "Custom"
            }
        }

        var pathData: String? {
            switch self {
            case .off, .custom: nil
            case .ellipse: PathPresets.ellipse
            case .perimeter: PathPresets.rectanglePerimeter
            case .line: PathPresets.line
            case .arc: PathPresets.arc
            }
        }
    }

    @ViewBuilder
    private func pathFlowRows(_ object: SlideObject) -> some View {

        numberField(
            "Flow Speed", styleWrite(object, \.tickerSpeed, default: 0),
            range: 0...500
        )

        numberField(
            "Edge Offset", styleWrite(object, \.pathOffset, default: 0),
            range: -200...200
        )
        if (current(object).textStyle?.tickerSpeed ?? 0) != 0 {
            let streaming = current(object).textStyle?.tickerStream ?? false

            InspectorPicker("Direction", selection: styleWrite(object, \.tickerDirection, default: .rightToLeft)) {
                Text("Right to Left").tag(TickerDirection.rightToLeft)
                Text("Left to Right").tag(TickerDirection.leftToRight)
            }

            InspectorPicker("Repeat Style", selection: styleWrite(object, \.tickerStream, default: false)) {
                Text("After Exit").tag(false)
                Text("Continuous").tag(true)
            }
            if streaming {

                numberField(
                    "Gap", styleWrite(object, \.tickerGap, default: 0),
                    range: 0...500
                )
                InspectorTextField(
                    "Separator",
                    text: styleWrite(object, \.tickerSeparator, default: "")
                )
            } else {

                numberField(
                    "Repeats",
                    Binding(
                        get: { Double(current(object).textStyle?.tickerRepeat ?? 0) },
                        set: { value in
                            commit(object) { obj in
                                var style = obj.textStyle ?? TextStyle()
                                style.tickerRepeat = Int(value.rounded())
                                obj.textStyle = style
                            }
                        }
                    ),
                    range: 0...99
                )
                if (current(object).textStyle?.tickerRepeat ?? 0) > 0 {

                    InspectorPicker("Ramp", selection: styleWrite(object, \.tickerRamp, default: .none)) {
                        ForEach([AnimationRamp.none, .in, .out, .both], id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
        }
    }

    private func pathChoice(for pathData: String?) -> PathChoice {
        guard let pathData, !pathData.isEmpty else { return .off }
        return PathChoice.allCases.first { $0.pathData == pathData } ?? .custom
    }

    private func pathChoiceBinding(_ object: SlideObject) -> Binding<PathChoice> {
        Binding(
            get: { pathChoice(for: current(object).textStyle?.pathData) },
            set: { choice in
                guard choice != .custom else { return }
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    style.pathData = choice.pathData
                    obj.textStyle = style
                }
            }
        )
    }

    private func textOutlineWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<ObjectStroke, T>
    ) -> Binding<T> {
        Binding(
            get: { (current(object).textStyle?.outline ?? Self.defaultStroke)[keyPath: keyPath] },
            set: { value in
                commit(object) { obj in
                    var style = obj.textStyle ?? TextStyle()
                    var outline = style.outline ?? Self.defaultStroke
                    outline[keyPath: keyPath] = value
                    style.outline = outline
                    obj.textStyle = style
                }
            }
        )
    }

    private func strokeWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<ObjectStroke, T>
    ) -> Binding<T> {
        Binding(
            get: { (current(object).stroke ?? Self.defaultStroke)[keyPath: keyPath] },
            set: { value in
                commit(object) { obj in
                    var stroke = obj.stroke ?? Self.defaultStroke
                    stroke[keyPath: keyPath] = value
                    obj.stroke = stroke
                }
            }
        )
    }

    private func fillWrite<T: Equatable>(
        _ object: SlideObject, _ keyPath: WritableKeyPath<ObjectFill, T?>, default fallback: T
    ) -> Binding<T> {
        Binding(
            get: { current(object).fill?[keyPath: keyPath] ?? fallback },
            set: { value in
                commit(object) { obj in
                    var fill = obj.fill ?? ObjectFill(fillKind: .solid)
                    fill[keyPath: keyPath] = value
                    obj.fill = fill
                }
            }
        )
    }

    private func gradientStopHex(_ object: SlideObject, index: Int) -> Binding<String> {
        Binding(
            get: {
                let stops = current(object).fill?.gradientStops ?? []
                return stops.indices.contains(index) ? stops[index].colorHex : "#FFFFFFFF"
            },
            set: { value in
                commit(object) { obj in
                    var fill = obj.fill ?? ObjectFill(fillKind: .linearGradient)
                    var stops = fill.gradientStops ?? []
                    while stops.count < 2 {
                        stops.append(GradientStop(colorHex: "#FFFFFFFF", position: Double(stops.count)))
                    }
                    stops[index].colorHex = value
                    fill.gradientStops = stops
                    obj.fill = fill
                }
            }
        )
    }

    private func shadowWrite<T: Equatable>(
        _ object: SlideObject,
        _ keyPath: WritableKeyPath<ObjectShadow, T>,
        read: @escaping (SlideObject) -> ObjectShadow?,
        store: @escaping (inout SlideObject, ObjectShadow?) -> Void
    ) -> Binding<T> {
        Binding(
            get: { (read(current(object)) ?? Self.defaultShadow)[keyPath: keyPath] },
            set: { value in
                commit(object) { obj in
                    var shadow = read(obj) ?? Self.defaultShadow
                    shadow[keyPath: keyPath] = value
                    store(&obj, shadow)
                }
            }
        )
    }

    private func numberField(
        _ label: String, _ binding: Binding<Double>,
        range: ClosedRange<Double>? = nil, step: Double = 1, stacked: Bool = false
    ) -> some View {
        ScrubbableNumberField(
            label: label, value: binding, range: range, step: step,
            onScrubPhase: { model.setScrubPreview($0) }, stacked: stacked
        )
    }
}

private struct MixedValueDot: View {
    var body: some View {
        Circle()
            .fill(.orange)
            .frame(width: 6, height: 6)
    }
}

private struct MixedValueBadge: ViewModifier {
    let mixed: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if mixed {
                MixedValueDot()
                    .offset(x: -8)
                    .help("The selected objects differ here. Changing it sets them all.")
            }
        }
    }
}

extension View {
    func mixedValue(_ mixed: Bool) -> some View {
        modifier(MixedValueBadge(mixed: mixed))
    }
}

private struct ObjectGeometryRows: View {
    let model: SlideEditorModel
    let object: SlideObject

    var body: some View {

        let frame = model.isDraggingObjects
            ? model.documentFrame(for: object) : model.displayFrame(for: object)
        HStack(alignment: .top, spacing: 8) {
            field("X", \.x, default: frame.origin.x, range: -2000...4000)
            field("Y", \.y, default: frame.origin.y, range: -2000...4000)
            field("W", \.width, default: frame.width, range: 1...4000)
            field("H", \.height, default: frame.height, range: 1...4000)
        }
    }

    private func field(
        _ label: String, _ keyPath: WritableKeyPath<SlideObject, Double?>,
        default fallback: Double, range: ClosedRange<Double>
    ) -> some View {
        ScrubbableNumberField(
            label: label,
            value: Binding(
                get: { current[keyPath: keyPath] ?? fallback },
                set: { value in model.updateObject(id: object.id) { $0[keyPath: keyPath] = value } }
            ),
            range: range, step: 1,
            onScrubPhase: { model.setScrubPreview($0) }, stacked: true
        )
    }

    private var current: SlideObject {
        SlideObjectNormalization.normalized(model.object(id: object.id) ?? object)
    }
}

private struct SelectionGroupButtons: View {
    let model: SlideEditorModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SlideEditorModel.ArrangeAction.grouping, id: \.self) { action in
                Button {
                    model.perform(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(!model.canPerform(action))
            }
        }
        .controlSize(.small)
    }
}

private struct ObjectArrangeRows: View {
    let model: SlideEditorModel
    let multi: Bool

    var body: some View {
        LabeledContent("Align") {
            HStack(spacing: 8) {
                strip(SlideEditorModel.ArrangeAction.horizontalAlign)
                strip(SlideEditorModel.ArrangeAction.verticalAlign)
            }
        }
        if multi {
            LabeledContent("Distribute") {
                strip(SlideEditorModel.ArrangeAction.distribute)
            }
        } else {
            LabeledContent("Layer") {
                strip(SlideEditorModel.ArrangeAction.layerOrder)
            }
        }
    }

    private func strip(_ actions: [SlideEditorModel.ArrangeAction]) -> some View {
        IconChipStrip<SlideEditorModel.ArrangeAction>(
            items: actions.map { .init(id: $0, systemImage: $0.systemImage, title: $0.title) },
            isOn: { _ in false },
            toggle: { model.perform($0) },
            isEnabled: { model.canPerform($0) }
        )
    }
}

private struct CommittingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @State private var live: Double?

    var body: some View {
        Slider(
            value: Binding(get: { live ?? value }, set: { live = $0 }),
            in: range
        ) { editing in
            if !editing, let final = live {
                value = final
                live = nil
            }
        }
    }
}

struct HexColorRow: View {
    let label: String
    @Binding var hex: String

    var labelHidden = false

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if labelHidden {
                controls
            } else {
                LabeledContent(label) { controls }
            }
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { _, newValue in
            if !focused { draft = newValue }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ColorPicker(label, selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
            TextField("#RRGGBBAA", text: $draft)
                .labelsHidden()
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: 84)
                .focused($focused)
                .onSubmit(commit)
        }
        .fixedSize()
    }

    private func commit() {
        if ColorHex.color(draft) != nil, draft != hex {
            hex = draft
        } else {
            draft = hex
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                guard let color = ColorHex.color(hex) else { return .white }
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
                hex = ColorHex.hex(SceneColor(
                    red: Double(ns.redComponent),
                    green: Double(ns.greenComponent),
                    blue: Double(ns.blueComponent),
                    alpha: Double(ns.alphaComponent)
                ))
            }
        )
    }
}

extension TextSourceKind {
    var displayName: String {
        switch self {
        case .currentSlide: "Current Slide"
        case .nextSlide: "Next Slide"
        case .lastSlide: "Last Slide"
        case .clock: "Clock"
        case .timer: "Timer"
        case .videoCountdown: "Video Countdown"
        case .slidePosition: "Slide Position"
        case .currentServiceItem: "Current Service Item"
        case .nextServiceItem: "Next Service Item"
        case .stageMessage: "Stage Message"
        case .currentGroup: "Group Name"
        case .currentPresentation: "Presentation Name"
        case .nextServiceTitle: "Next Service Title"
        }
    }
}
