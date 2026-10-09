import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct SlideEditorView: View {
    let appModel: AppModel
    let render: RenderContext?

    let presentationID: String
    var isTheme = false

    var isOverlay = false

    var isConfidenceLayout = false

    private struct QuickEditTarget: Identifiable {
        let id: String
    }

    @State private var model: SlideEditorModel?
    @State private var showingMediaPicker = false
    @State private var showingBackgroundFill = false

    @State private var pendingThemeID: String?

    @Environment(\.actionRouter) private var actionRouter

    @AppStorage("editor.inspectorWidth") private var inspectorWidth = PanelWidthGrip.minPanelWidth

    @AppStorage("editor.timelineHeight") private var timelineHeight = 236.0
    @State private var quickEditTarget: QuickEditTarget?
    @State private var newSectionTarget: QuickEditTarget?
    @State private var newSectionName = ""
    @State private var renameSectionTarget: PresentationSection?
    @State private var renameSectionName = ""
    @State private var showingArrangement = false
    @State private var showingReflow = false
    @State private var showingChords = false

    @AppStorage("shell.sidebarVisible") private var sidebarVisible = true

    @State private var dropTargetID: String?

    @State private var backgroundDropID: String?

    @State private var dropSettleUntil = Date.distantPast

    @State private var renamingSlideID: String?
    @State private var slideNameDraft = ""

    @State private var selectionChangedAt = Date.distantPast

    @State private var canvasDropTargeted = false

    @State private var canvasViewSize = CGSize.zero

    @State private var toolbarWidth: CGFloat = 0

    @State private var renamingObjectID: String?
    @State private var objectNameDraft = ""
    @State private var objectSelectionChangedAt = Date.distantPast

    @State private var slideRowFrames: [String: CGRect] = [:]
    @State private var slideMarquee: CGRect?
    @State private var slideMarqueeBase: Set<String> = []
    @State private var objectRowFrames: [String: CGRect] = [:]
    @State private var objectMarquee: CGRect?
    @State private var objectMarqueeBase: Set<String> = []

    @FocusState private var slideListFocused: Bool
    @FocusState private var objectsPanelFocused: Bool

    @State private var spinnerDue = false
    private static let spinnerDelay: Duration = .milliseconds(150)

    var body: some View {
        let _ = BodyMeter.tick(.slideEditor)
        Group {
            if let model {
                editor(model)
            } else {

                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(spinnerDue ? 1 : 0)
                    .task {
                        if (try? await Task.sleep(for: Self.spinnerDelay)) != nil {
                            spinnerDue = true
                        }
                    }
            }
        }

        .focusedSceneValue(\.slideEditor, model)
        .task(id: presentationID) {

            let built = if isTheme {
                await SlideEditorModel(appModel: appModel, render: render, themeID: presentationID)
            } else if isOverlay {
                await SlideEditorModel(appModel: appModel, render: render, overlayID: presentationID)
            } else if isConfidenceLayout {
                await SlideEditorModel(
                    appModel: appModel, render: render, confidenceLayoutID: presentationID
                )
            } else {
                await SlideEditorModel(appModel: appModel, render: render, presentationID: presentationID)
            }

            if !Task.isCancelled {
                model = built

                if let slideID = appModel.pendingEditorSlideID {
                    appModel.pendingEditorSlideID = nil
                    model?.selectSlide(slideID)
                }
            } else {
                built?.endSession()
            }
        }
        .onDisappear { model?.teardown() }
    }

    private func editor(_ model: SlideEditorModel) -> some View {

        VStack(spacing: CornerStandard.panelInset) {
        HStack(spacing: CornerStandard.panelInset) {
            VStack(spacing: 0) {

                Color.clear
                    .frame(height: ShellView.headerHeight - CornerStandard.panelInset)

                if !model.isSingleComposition {
                    slideList(model)
                    Divider()
                }
                objectsPanel(model)
                    .frame(maxHeight: model.isSingleComposition ? .infinity : 220)
            }
            .frame(width: 190)
            .floatingPanel()
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: ShellView.headerHeight - CornerStandard.panelInset)
                editorToolbar(model)
                Divider()
                canvas(model)

                if model.editorMode == .design, model.compositionHasAnimationSteps {
                    Divider()
                    AnimationPreviewStrip(model: model)
                }
            }

            .frame(minWidth: 0, maxWidth: .infinity)
            VStack(spacing: 0) {

                Color.clear
                    .frame(height: ShellView.headerHeight - CornerStandard.panelInset)
                SlideObjectInspector(model: model)
            }

            .frame(width: max(inspectorWidth, PanelWidthGrip.minPanelWidth))
            .floatingPanel()
            .overlay(alignment: .leading) {
                PanelWidthGrip(width: $inspectorWidth)
            }
        }

        if model.editorMode == .animate {
            AnimationTimelinePanel(model: model)
                .frame(height: min(max(timelineHeight, 170), 620))
                .floatingPanel()
                .overlay(alignment: .top) {
                    PanelHeightGrip(height: $timelineHeight)
                }
        }
        }
        .navigationTitle(model.presentation.name)
        .sheet(isPresented: $showingMediaPicker) {
            LibraryPickerSheet(
                appModel: appModel,
                onImportMedia: { placement in
                    MediaFilePicker.choose { urls in
                        model.importMediaObjects(urls, placement: placement)
                    }
                }
            ) { entry in
                model.addMediaObject(mediaID: entry.id, name: entry.name)
            }
        }
        .sheet(item: $quickEditTarget) { target in
            QuickEditView(
                slide: { model.presentation.slides.first { $0.id == target.id } },
                write: { objectID, text in
                    model.quickEditText(slideID: target.id, objectID: objectID, text: text)
                }
            )
        }
        .sheet(isPresented: $showingReflow) {
            ReflowSheet(model: model)
        }

        .sheet(isPresented: Binding(get: { model.choosingNewSlide }, set: { model.choosingNewSlide = $0 })) {
            NewSlideSheet(appModel: appModel, render: render, deckThemeId: model.presentation.themeId) { choice in
                model.addSlide(choice)
            }
        }
    }

    private func slideList(_ model: SlideEditorModel) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                slideRows(model)

                    .onAppear {
                        if let id = model.selectedSlideID {
                            proxy.scrollTo(id)
                        }
                    }

                    .onChange(of: model.selectedSlideID) { _, _ in
                        selectionChangedAt = Date()
                    }
            }
            Divider()
            HStack {
                Button {
                    model.addSlide()
                } label: {
                    Label(model.isThemeEditor ? "Add Category" : "Add Slide…", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(model.isThemeEditor ? "Add Category" : "Add Slide: Blank or From Theme")
                Spacer()
            }
            .padding(6)
        }
        .alert("New Section", isPresented: newSectionActive) {
            TextField("Name (Verse 1, Chorus…)", text: $newSectionName)
            Button("Create") {
                if let target = newSectionTarget {
                    model.startSection(named: newSectionName, at: target.id)
                }
                newSectionTarget = nil
            }
            Button("Cancel", role: .cancel) { newSectionTarget = nil }
        } message: {
            Text("The slide and the rest of its current run move into the new section.")
        }
        .alert("Rename Section", isPresented: renameSectionActive) {
            TextField("Name", text: $renameSectionName)
            Button("Rename") {
                if let target = renameSectionTarget {
                    model.renameSection(target.id, to: renameSectionName)
                }
                renameSectionTarget = nil
            }
            Button("Cancel", role: .cancel) { renameSectionTarget = nil }
        }
    }

    private enum SlideListRow: Identifiable {
        case header(PresentationSection)
        case slide(Slide)

        var id: String {
            switch self {
            case .header(let section): "header::" + section.id
            case .slide(let slide): slide.id
            }
        }
    }

    private func flatRows(_ model: SlideEditorModel) -> [SlideListRow] {
        model.slideGroups.flatMap { group in
            (group.section.map { [SlideListRow.header($0)] } ?? [])
                + group.slides.map(SlideListRow.slide)
        }
    }

    private func slideRows(_ model: SlideEditorModel) -> some View {
        let rows = flatRows(model)
        return List(selection: slideSelection(model)) {
            ForEach(rows) { row in
                switch row {
                case .header(let section):
                    sectionHeaderRow(model, section: section)
                case .slide(let slide):
                    slideRow(model, slide: slide)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())

                        .overlay {
                            if renamingSlideID != slide.id {
                                RowMouseHandler(
                                    renameDeadZone: 30,

                                    isSelected: { model.selectedSlideIDs == [slide.id] },
                                    selectionSettled: {
                                        RowInteraction.settled(selectionChangedAt)
                                    },

                                    select: {
                                        if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) {
                                            model.selectSlide(slide.id)
                                        }
                                    },
                                    beginRename: { beginSlideRename(slide) }
                                )
                            }
                        }

                        .onDrop(
                            of: [.plainText, .fileURL],
                            delegate: rowDropDelegate(model, slide: slide)
                        )
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)

                        .overlay(alignment: .top) {
                            if dropTargetID == slide.id {
                                RowInsertionLine()
                                    .offset(y: RowInsertionLine.rowGapOffset)
                            }
                        }
                        .overlay {
                            if backgroundDropID == slide.id {

                                RoundedRectangle.standard(CornerStandard.element)
                                    .strokeBorder(
                                        Color(nsColor: .controlAccentColor)
                                            .opacity(0.9),
                                        lineWidth: 2)
                            }
                        }

                        .draggable(EditSlideDrag.payload(model.slideBatch(for: slide.id)))
                        .reportingGlobalFrame(id: slide.id, into: $slideRowFrames)
                        .tag(slide.id)
                }
            }
            .onInsert(of: [.plainText, .text]) { index, providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let payload = object as? String else { return }
                        Task { @MainActor in
                            insertListPayload(
                                model, rows: rows, index: index, payload: payload)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)

        .listMarquee(
            active: true, rowFrames: Array(slideRowFrames.values),
            began: { modifiers in
                slideMarqueeBase = modifiers.contains(.shift) ? model.selectedSlideIDs : []
            },
            changed: { band in
                slideMarquee = band
                let swept = RunOrderSelection.swept(frames: slideRowFrames, band: band, keeping: slideMarqueeBase)

                model.setSlideSelection(swept.isEmpty ? Set(model.selectedSlideID.map { [$0] } ?? []) : swept)
            },
            ended: {
                slideMarquee = nil
                slideMarqueeBase = []
            })
        .overlay { ListMarqueeBand(rect: slideMarquee) }
        .focused($slideListFocused)
        .onSlideClipboardKeys(active: slideListFocused) { verb in
            switch verb {
            case .copy: model.copySelectedSlides()
            case .cut: model.cutSelectedSlides()
            case .paste: model.paste()
            case .selectAll: model.selectAllSlides()
            }
        }
    }

    private func sectionHeaderRow(
        _ model: SlideEditorModel, section: PresentationSection
    ) -> some View {
        HStack(spacing: 5) {

            if let fill = GroupColor.fill(
                section, palette: model.appModel.groupColors
            ) {
                Circle().fill(fill).frame(width: 7, height: 7)
            }
            Text(section.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .selectionDisabled()
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .onDrop(
            of: [.plainText],
            delegate: GutterDropDelegate(
                enabled: true,
                breadcrumb: "editor.headerDrop",
                dropStarted: {
                    dropSettleUntil = Date().addingTimeInterval(0.6)
                    backgroundDropID = nil
                },
                setLine: { _ in },
                setRing: { on in
                    if on {
                        guard Date() >= dropSettleUntil else { return }
                        backgroundDropID = "header::" + section.id
                    } else if backgroundDropID == "header::" + section.id {
                        backgroundDropID = nil
                    }
                },
                performText: { payload, _ in
                    backgroundDropID = nil
                    return model.setDroppedBackground(
                        mediaID: payload, onSection: section.id)
                },
                performFiles: { _, _ in },
                rejectPrefixes: ["mxueditslide::", "mxuslide::", "mxuobj::"]
            )
        )
        .overlay {
            if backgroundDropID == "header::" + section.id {
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        Color(nsColor: .controlAccentColor).opacity(0.9),
                        lineWidth: 2)
            }
        }
        .contextMenu {
            Button("Rename Section…") {
                renameSectionTarget = section
                renameSectionName = section.name
            }
            Button("Delete Section", role: .destructive) {
                model.deleteSection(section.id)
            }
        }
    }

    private func insertListPayload(
        _ model: SlideEditorModel, rows: [SlideListRow], index: Int, payload: String
    ) {
        guard !payload.hasPrefix("mxuobj::") else { return }
        let anchor = rows.indices.contains(index) ? rows[index] : nil
        if let slideIDs = EditSlideDrag.ids(in: payload) {
            switch anchor {
            case .slide(let slide):
                model.moveSlides(slideIDs, beforeSlideID: slide.id)
            case .header:

                if index > 0, case .slide(let previous) = rows[index - 1] {
                    model.moveSlides(slideIDs, afterSlideID: previous.id)
                } else if let first = firstSlideID(rows, from: index) {
                    model.moveSlides(slideIDs, beforeSlideID: first)
                }
            case nil:
                model.moveSlides(slideIDs, beforeSlideID: nil)
            }
            return
        }

        let beforeID: String?
        switch anchor {
        case .slide(let slide): beforeID = slide.id
        case .header: beforeID = firstSlideID(rows, from: index)
        case nil: beforeID = nil
        }
        _ = model.insertMediaSlide(mediaID: payload, beforeSlideID: beforeID)
    }

    private func firstSlideID(_ rows: [SlideListRow], from index: Int) -> String? {
        for row in rows[min(index, rows.count)...] {
            if case .slide(let slide) = row { return slide.id }
        }
        return nil
    }

    private func beginSlideRename(_ slide: Slide) {
        slideNameDraft = slide.name
        renamingSlideID = slide.id
    }

    private func rowDropDelegate(
        _ model: SlideEditorModel, slide: Slide
    ) -> GutterDropDelegate {
        GutterDropDelegate(
            enabled: true,
            breadcrumb: "editor.drop",
            dropStarted: {
                dropSettleUntil = Date().addingTimeInterval(0.6)
                dropTargetID = nil
                backgroundDropID = nil
            },
            setLine: { on in
                if on {
                    guard Date() >= dropSettleUntil else { return }
                    dropTargetID = slide.id
                } else if dropTargetID == slide.id {
                    dropTargetID = nil
                }
            },
            setRing: { on in
                if on {
                    guard Date() >= dropSettleUntil else { return }
                    backgroundDropID = slide.id
                } else if backgroundDropID == slide.id {
                    backgroundDropID = nil
                }
            },
            performText: { payload, insertZone in
                handleRowText(model, payload, slide: slide, insertZone: insertZone)
            },
            performFiles: { urls, insertZone in
                handleRowFiles(model, urls, slide: slide, insertZone: insertZone)
            },
            rejectPrefixes: ["mxueditslide::", "mxuslide::", "mxuobj::"]
        )
    }

    private func handleRowText(
        _ model: SlideEditorModel, _ payload: String, slide: Slide, insertZone: Bool
    ) -> Bool {

        dropTargetID = nil
        backgroundDropID = nil
        defer {
            Task { @MainActor in
                dropTargetID = nil
                backgroundDropID = nil
            }
        }

        if insertZone {
            return model.insertMediaSlide(mediaID: payload, beforeSlideID: slide.id)
        }
        return model.setDroppedBackground(mediaID: payload, onSlide: slide.id)
    }

    private func handleRowFiles(
        _ model: SlideEditorModel, _ urls: [URL], slide: Slide, insertZone: Bool
    ) {
        dropTargetID = nil
        backgroundDropID = nil
        guard !urls.isEmpty else { return }
        let slideID = slide.id
        Task { @MainActor in

            let imported = await appModel.importFiles(urls)
            guard let first = imported.first else { return }
            if insertZone {
                _ = model.insertMediaSlide(mediaID: first, beforeSlideID: slideID)
            } else {
                _ = model.setDroppedBackground(mediaID: first, onSlide: slideID)
            }
        }
    }

    private func slideRow(_ model: SlideEditorModel, slide: Slide) -> some View {
        let index = model.presentation.slides.firstIndex { $0.id == slide.id } ?? 0
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            let rowText = SlidePreview.rowText(
                for: slide,
                backgroundMediaName: model.declaredBackgroundName(for: slide))
            if renamingSlideID == slide.id || rowText == .name {
                RowNameField(
                    id: slide.id,
                    name: slide.name,
                    renamingID: $renamingSlideID,
                    draft: $slideNameDraft,
                    commit: { model.renameSlide(slide.id, to: $0) }
                )
            } else if case .preview(let preview) = rowText {
                Text(preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)

            if model.clippedSlideIDs.contains(slide.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Text on this slide doesn't fit its box — the overflow is clipped on the output. Open the slide to see the outlined box.")
            }

            if let name = model.declaredBackgroundName(for: slide) {
                Image(systemName: "film.fill")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .help("Background: \(name)")
            }
        }
        .tag(slide.id)
        .contextMenu {

            let batch = model.slideBatch(for: slide.id)
            if batch.count > 1 {
                Button("Copy \(batch.count) Slides") { model.copySlides(batch) }
                moveToThemeMenu(model, batch: batch)
                Divider()
                Button("Duplicate \(batch.count) Slides") { model.duplicateSlides(batch) }
                Button("Delete \(batch.count) Slides", role: .destructive) {
                    model.deleteSlides(batch)
                }
                .disabled(batch.count >= model.presentation.slides.count)
            } else {
                Button("Rename Slide") { beginSlideRename(slide) }
                if !model.isThemeEditor {
                    Button("Quick Edit…") { quickEditTarget = QuickEditTarget(id: slide.id) }
                    Divider()
                    Button("Start New Section Here…") {
                        newSectionTarget = QuickEditTarget(id: slide.id)
                        newSectionName = ""
                    }
                    if !model.sections.isEmpty {
                        Menu("Move to Section") {
                            ForEach(model.sections) { section in
                                Button(section.name) {
                                    model.moveSlide(slide.id, toSection: section.id)
                                }
                                .disabled(slide.sectionId == section.id)
                            }
                        }
                    }

                    if !model.themeSlideNames.isEmpty {
                        let edited = model.slideHasLocalEdits(slide)
                        Menu("Theme Slide") {
                            Toggle(
                                "Automatic" + (editedSuffix(model, slide: slide, name: nil, edited: edited)),
                                isOn: themeSlideBinding(model, slide: slide, name: nil)
                            )

                            Toggle("Blank (No Theme)", isOn: Binding(
                                get: { model.presentation.slides.first { $0.id == slide.id }?.unthemed == true },
                                set: { _ in model.setSlideBlank(slide.id) }))
                            Divider()
                            ForEach(Array(model.themeSlideGroups.enumerated()), id: \.offset) { _, group in
                                if let folder = group.folder {
                                    Section(folder) {
                                        ForEach(group.names, id: \.self) { name in
                                            Toggle(
                                                name + editedSuffix(model, slide: slide, name: name, edited: edited),
                                                isOn: themeSlideBinding(model, slide: slide, name: name)
                                            )
                                        }
                                    }
                                } else {
                                    ForEach(group.names, id: \.self) { name in
                                        Toggle(
                                            name + editedSuffix(model, slide: slide, name: name, edited: edited),
                                            isOn: themeSlideBinding(model, slide: slide, name: name)
                                        )
                                    }
                                }
                            }

                            let looks = actionRouter?.activeOverrideLooks() ?? []
                            if !looks.isEmpty {
                                Divider()
                                ForEach(looks) { look in
                                    let chosen = model.presentation.slides.first { $0.id == slide.id }?.overrideDesignName(forTheme: look.theme.id)
                                    Menu("On \(look.theme.name)\(look.folder.map { " › \($0)" } ?? "") outputs") {
                                        Toggle("Same as this slide", isOn: Binding(
                                            get: { chosen == nil },
                                            set: { _ in model.setOverrideDesign(nil, forTheme: look.theme.id, for: slide.id) }))
                                        Divider()
                                        ForEach(look.theme.slides ?? [], id: \.id) { design in
                                            Toggle(design.name, isOn: Binding(
                                                get: { chosen?.caseInsensitiveCompare(design.name) == .orderedSame },
                                                set: { _ in model.setOverrideDesign(design.name, forTheme: look.theme.id, for: slide.id) }))
                                        }
                                    }
                                }
                            }

                            let others = model.otherThemeChoices
                            if !others.isEmpty {
                                Divider()
                                ForEach(others, id: \.theme.id) { choice in
                                    Menu(choice.theme.name) {
                                        ForEach(Array(choice.groups.enumerated()), id: \.offset) { _, group in
                                            if let folder = group.folder {
                                                Section(folder) {
                                                    ForEach(group.names, id: \.self) { name in
                                                        Toggle(name, isOn: otherThemeSlideBinding(model, slide: slide, themeId: choice.theme.id, name: name))
                                                    }
                                                }
                                            } else {
                                                ForEach(group.names, id: \.self) { name in
                                                    Toggle(name, isOn: otherThemeSlideBinding(model, slide: slide, themeId: choice.theme.id, name: name))
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                }

                Button("Copy Slide") { model.copySlides([slide.id]) }
                Button("Paste Slide After") { model.pasteSlides(after: slide.id) }
                    .disabled(!SlidePasteboard.hasSlide)
                moveToThemeMenu(model, batch: [slide.id])
                Button("Duplicate") { model.duplicateSlide(slide.id) }
                Button("Delete", role: .destructive) { model.deleteSlide(slide.id) }
                    .disabled(model.presentation.slides.count == 1)
            }
        }
    }

    @ViewBuilder
    private func moveToThemeMenu(_ model: SlideEditorModel, batch: [String]) -> some View {
        let targets = model.moveTargetThemes
        if !targets.isEmpty {
            Menu(batch.count > 1 ? "Move \(batch.count) Slides to Theme" : "Move to Theme") {
                ForEach(targets, id: \.id) { entry in
                    Button(entry.name) { model.moveSlides(batch, toTheme: entry.id) }
                }
            }

            .disabled(batch.count >= model.presentation.slides.count)
        }
    }

    private func editedSuffix(
        _ model: SlideEditorModel, slide: Slide, name: String?, edited: Bool
    ) -> String {
        guard edited else { return "" }
        let current = model.presentation.slides.first { $0.id == slide.id }?.themeSlideName
        let isCurrent = name == nil
            ? (current ?? "").isEmpty
            : current?.caseInsensitiveCompare(name!) == .orderedSame
        return isCurrent ? " (edited)" : ""
    }

    private func themeSlideBinding(
        _ model: SlideEditorModel, slide: Slide, name: String?
    ) -> Binding<Bool> {
        Binding(
            get: {
                let held = model.presentation.slides.first { $0.id == slide.id }
                let current = held?.themeSlideName
                return held?.unthemed != true && (name == nil
                    ? (current ?? "").isEmpty
                    : current?.caseInsensitiveCompare(name!) == .orderedSame)
            },

            set: { _ in model.setThemeSlide(name, for: slide.id) }
        )
    }

    private func otherThemeSlideBinding(
        _ model: SlideEditorModel, slide: Slide, themeId: String, name: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                let current = model.presentation.slides.first { $0.id == slide.id }
                return current?.unthemed != true && current?.themeId == themeId
                    && current?.themeSlideName?.caseInsensitiveCompare(name) == .orderedSame
            },
            set: { _ in model.setThemeSlide(name, themeId: themeId, for: slide.id) }
        )
    }

    private var newSectionActive: Binding<Bool> {
        Binding(get: { newSectionTarget != nil }, set: { if !$0 { newSectionTarget = nil } })
    }

    private var renameSectionActive: Binding<Bool> {
        Binding(get: { renameSectionTarget != nil }, set: { if !$0 { renameSectionTarget = nil } })
    }

    private func slideSelection(_ model: SlideEditorModel) -> Binding<Set<String>> {
        Binding(
            get: { model.selectedSlideIDs },
            set: { model.setSlideSelection($0) }
        )
    }

    @ViewBuilder
    private func objectRowArrangeItems(
        _ model: SlideEditorModel, id: String, row: ObjectRowArrangeState
    ) -> some View {
        Button("Group") { arrangeFromRow(.group, id: id, model) }
            .disabled(!row.canGroup)
        Button("Ungroup") { arrangeFromRow(.ungroup, id: id, model) }
            .disabled(!row.canUngroup)
        Divider()
        Menu("Align") {
            ForEach(SlideEditorModel.ArrangeAction.horizontalAlign, id: \.self) { action in
                Button(action.title) { arrangeFromRow(action, id: id, model) }
            }
            Divider()
            ForEach(SlideEditorModel.ArrangeAction.verticalAlign, id: \.self) { action in
                Button(action.title) { arrangeFromRow(action, id: id, model) }
            }
            Divider()
            ForEach(SlideEditorModel.ArrangeAction.distribute, id: \.self) { action in
                Button(action.title) { arrangeFromRow(action, id: id, model) }
                    .disabled(!row.canDistribute)
            }
        }
        ForEach(SlideEditorModel.ArrangeAction.layerOrder, id: \.self) { action in
            Button(action.title) {
                model.setSelection([id])
                model.perform(action)
            }
        }
    }

    private struct ObjectRowArrangeState {
        let canGroup: Bool
        let canUngroup: Bool
        let canDistribute: Bool

        init(object: SlideObject, isSelected: Bool, selection: ObjectRowArrangeState) {
            canGroup = isSelected && selection.canGroup
            canUngroup = isSelected ? selection.canUngroup : object.groupId?.isEmpty == false
            canDistribute = isSelected && selection.canDistribute
        }

        init(canGroup: Bool, canUngroup: Bool, canDistribute: Bool) {
            self.canGroup = canGroup
            self.canUngroup = canUngroup
            self.canDistribute = canDistribute
        }
    }

    private func arrangeFromRow(_ action: SlideEditorModel.ArrangeAction, id: String, _ model: SlideEditorModel) {
        if !model.selectedObjectIDs.contains(id) {
            model.setSelection([id])
        }
        model.perform(action)
    }

    private func pathDrawingBinding(_ model: SlideEditorModel) -> Binding<Bool> {
        Binding(
            get: { model.pathDrawing != nil },
            set: { on in
                if on {
                    model.beginPathDrawing()
                } else {
                    model.cancelPathDrawing()
                }
            }
        )
    }

    private func objectsPanel(_ model: SlideEditorModel) -> some View {
        List(selection: objectSelection(model)) {
            Section("Objects") {

                let selectionArrange = ObjectRowArrangeState(
                    canGroup: model.canGroup, canUngroup: model.canUngroup,
                    canDistribute: model.canDistribute
                )
                ForEach(model.panelStackTopFirst) { entry in
                    if entry.fromTheme {
                        HStack(spacing: 4) {
                            Label(entry.object.name, systemImage: Self.objectIcon(entry.object))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "paintpalette")
                                .imageScale(.small)
                        }
                        .foregroundStyle(.tertiary)
                        .help("From the theme — edit it in the theme editor")
                        .selectionDisabled()
                        .padding(.vertical, 4)
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: Self.objectIcon(entry.object))
                                .frame(width: 16)

                            RowNameField(
                                id: entry.object.id,
                                name: entry.object.name,
                                renamingID: $renamingObjectID,
                                draft: $objectNameDraft,
                                commit: { name in
                                    model.updateObject(id: entry.object.id) {
                                        $0.name = name
                                    }
                                }
                            )
                            Spacer(minLength: 4)

                            if entry.object.hidden == true {
                                Image(systemName: "eye.slash")
                                    .imageScale(.small)
                                    .foregroundStyle(.tertiary)
                                    .help("Hidden — shown on no surface")
                            }
                        }
                            .opacity(entry.object.hidden == true ? 0.5 : 1)
                            .tag(entry.object.id)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())

                            .overlay {
                                if renamingObjectID != entry.object.id {
                                    RowMouseHandler(
                                        renameDeadZone: 24,
                                        isSelected: {
                                            model.selectedObjectIDs == [entry.object.id]
                                        },
                                        selectionSettled: {
                                            RowInteraction.settled(objectSelectionChangedAt)
                                        },

                                        select: {
                                            if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) {
                                                model.setSelection([entry.object.id])
                                            }
                                        },
                                        beginRename: {
                                            objectNameDraft = entry.object.name
                                            renamingObjectID = entry.object.id
                                        }
                                    )
                                }
                            }
                            .listRowInsets(EdgeInsets(
                                top: 0, leading: 8, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                            .draggable("mxuobj::" + entry.object.id)
                            .reportingGlobalFrame(id: entry.object.id, into: $objectRowFrames)

                            .contextMenu {
                                Button(entry.object.hidden == true ? "Show" : "Hide") {
                                    model.updateObject(id: entry.object.id) {
                                        $0.hidden = $0.hidden == true ? nil : true
                                    }
                                }
                                Button("Duplicate") {
                                    model.setSelection([entry.object.id])
                                    model.duplicateSelectedObjects()
                                }
                                Divider()
                                objectRowArrangeItems(
                                    model, id: entry.object.id,
                                    row: ObjectRowArrangeState(
                                        object: entry.object,
                                        isSelected: model.selectedObjectIDs.contains(entry.object.id),
                                        selection: selectionArrange
                                    )
                                )
                                Divider()
                                Button("Rename") {
                                    objectNameDraft = entry.object.name
                                    renamingObjectID = entry.object.id
                                }
                                Button("Delete", role: .destructive) {
                                    model.setSelection([entry.object.id])
                                    model.deleteSelectedObjects()
                                }
                            }
                    }
                }

                .onInsert(of: [.plainText, .text]) { index, providers in
                    let stack = model.panelStackTopFirst
                    let beforeID = stack.indices.contains(index)
                        ? stack[index].object.id : nil
                    for provider in providers {
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let payload = object as? String,
                                  payload.hasPrefix("mxuobj::") else { return }
                            let objectID = String(payload.dropFirst("mxuobj::".count))
                            Task { @MainActor in
                                model.movePanelObject(id: objectID, beforeID: beforeID)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)

        .listMarquee(
            active: true, rowFrames: Array(objectRowFrames.values),
            began: { modifiers in
                objectMarqueeBase = modifiers.contains(.shift) ? model.selectedObjectIDs : []
                if modifiers.isDisjoint(with: [.command, .shift]) { model.setSelection([]) }
            },
            changed: { band in
                objectMarquee = band
                model.setSelection(
                    RunOrderSelection.swept(frames: objectRowFrames, band: band, keeping: objectMarqueeBase))
            },
            ended: {
                objectMarquee = nil
                objectMarqueeBase = []
            })
        .overlay { ListMarqueeBand(rect: objectMarquee) }
        .onChange(of: model.selectedObjectIDs) { _, _ in
            objectSelectionChangedAt = Date()
        }
        .focused($objectsPanelFocused)
        .onSlideClipboardKeys(active: objectsPanelFocused) { verb in
            switch verb {
            case .copy: model.copySelectedObjects()
            case .cut: model.cutSelectedObjects()
            case .paste: model.paste()
            case .selectAll: model.selectAllObjects(includingHidden: true)
            }
        }
    }

    private func objectSelection(_ model: SlideEditorModel) -> Binding<Set<String>> {
        Binding(
            get: { model.selectedObjectIDs },
            set: { model.setSelection($0) }
        )
    }

    private func themeSelection(_ model: SlideEditorModel) -> Binding<String> {
        Binding(
            get: { model.presentation.themeId },
            set: { id in
                if !id.isEmpty, model.presentationHasSlideThemes {
                    pendingThemeID = id
                } else {
                    model.setTheme(id)
                }
            }
        )
    }

    static func objectIcon(_ object: SlideObject) -> String {
        let object = SlideObjectNormalization.normalized(object)
        switch object.objectKind {
        case .text: return "textformat"
        case .shape, .media, .liveInput:

            guard let fill = object.fill, fill.fillKind == .media else {
                return "square.fill.on.circle.fill"
            }
            let isLive = fill.liveInputId?.isEmpty == false
                || fill.captureSourceId?.isEmpty == false
                || fill.captureSourceKind != nil
                || fill.screenSourceId?.isEmpty == false
            return isLive ? "video" : "photo"
        }
    }

    private func editorToolbar(_ model: SlideEditorModel) -> some View {
        ViewThatFits(in: .horizontal) {
            if model.isMultiView {

                HStack(spacing: 12) {
                    MultiViewToolbar(model: model)
                    Spacer()
                    undoRedoTools(model)
                }
            }
            HStack(spacing: 12) {
                addObjectTools(model)
                Spacer()
                chordsToggle(model)
                presentationTools(model)
                undoRedoTools(model)
                Spacer(minLength: 8)
                modePicker(model)
            }
            HStack(spacing: 12) {
                addObjectTools(model)
                Spacer()
                chordsToggle(model)
                presentationMenu(model)
                undoRedoTools(model)
                Spacer(minLength: 8)
                modePicker(model)
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: toolbarWidth, alignment: .leading)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }

        .clipped()

        .sheet(isPresented: $showingChords) {
            ChordEditorSheet(model: model.appModel, render: render, presentationID: model.presentation.id)
        }
        .confirmationDialog(
            "Apply \(pendingThemeID.flatMap { appModel.entry($0)?.name } ?? "this theme") to every slide?",
            isPresented: Binding(get: { pendingThemeID != nil }, set: { if !$0 { pendingThemeID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply to Every Slide") {
                if let id = pendingThemeID { model.setTheme(id) }
                pendingThemeID = nil
            }
            Button("Cancel", role: .cancel) { pendingThemeID = nil }
        } message: {
            Text("Slides that follow a theme of their own will follow this one instead.")
        }
    }

    private func addObjectTools(_ model: SlideEditorModel) -> some View {
        ToolbarCluster {
            Button {
                model.addTextObject()
            } label: {
                Label("Add Text", systemImage: "textformat")
            }
            .help("Add Text")
            Button {
                model.addShapeObject()
            } label: {
                Label("Add Shape", systemImage: "rectangle")
            }
            .help("Add Shape")
            Button {
                showingMediaPicker = true
            } label: {
                Label("Add Image", systemImage: "photo")
            }
            .help("Add Image or Video from the library")
            Button {
                model.addLiveInputObject()
            } label: {
                Label("Add Live Input", systemImage: "video")
            }
            .help("Add a live input — a camera or NDI source (plays in Present)")

            Toggle(isOn: pathDrawingBinding(model)) {
                Label("Draw Path", systemImage: "pencil.tip")
            }
            .toggleStyle(.button)
            .help("Draw a path — click for corners, drag for curves; click the first point to close")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func presentationTools(_ model: SlideEditorModel) -> some View {
        if !model.isThemeEditor, !model.isSingleComposition {
            Button {
                showingReflow = true
            } label: {
                Label("Reflow", systemImage: "text.alignleft")
            }
            .help("Reflow — paste text, get slides")

            Button {
                showingArrangement.toggle()
            } label: {
                Label("Arrangement", systemImage: "rectangle.grid.1x2")
            }
            .help("Arrangement")
            .popover(isPresented: $showingArrangement, arrowEdge: .bottom) {
                ArrangementPopover(model: model)
            }

            Button {
                showingChords = true
            } label: {
                Label("Chord Chart", systemImage: "music.note.list")
            }
            .help("Chord Chart — every line's chords as ChordPro text")

            Menu {
                themeItems(model)
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Theme")

            if !model.presentation.themeId.isEmpty {
                Button {
                    model.toggleThemeContent()
                } label: {
                    Label(
                        model.showsThemeContent ? "Hide Theme Content" : "Show Theme Content",
                        systemImage: model.showsThemeContent ? "eye" : "eye.slash"
                    )
                }
                .help(model.showsThemeContent
                    ? "Hide theme content while editing"
                    : "Show theme content")
            }

            Button {
                showingBackgroundFill = true
            } label: {
                Label("Background", systemImage: "rectangle.inset.filled")
            }
            .help("Presentation background")
            .popover(isPresented: $showingBackgroundFill, arrowEdge: .bottom) {
                PresentationBackgroundPopover(model: model)
            }

            Button {
                model.appModel.exportPresentation(model.presentation, render: render)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export — an MxU Slides file, a PDF, slide images, or a song's ChordPro text")
        }
    }

    @ViewBuilder
    private func chordsToggle(_ model: SlideEditorModel) -> some View {
        if !model.isThemeEditor, !model.isSingleComposition {
            Toggle(isOn: Binding(get: { model.showsChords }, set: { _ in model.toggleChords() })) {
                Label("Chords", systemImage: "music.note")
            }
            .toggleStyle(.button)
            .help(model.showsChords
                ? "Hide chords — back to the audience view"
                : "Show chords on the slides to add, move, and change them")
        }
    }

    @ViewBuilder
    private func presentationMenu(_ model: SlideEditorModel) -> some View {
        if !model.isThemeEditor, !model.isSingleComposition {
            Menu {
                Button("Reflow…") { showingReflow = true }
                Button("Arrangement…") { showingArrangement = true }
                Button("Chord Chart…") { showingChords = true }

                Button("Export…") { model.appModel.exportPresentation(model.presentation, render: render) }
                Divider()
                Menu("Theme") { themeItems(model) }
                if !model.presentation.themeId.isEmpty {
                    Button(model.showsThemeContent ? "Hide Theme Content" : "Show Theme Content") {
                        model.toggleThemeContent()
                    }
                }
                Button("Background…") { showingBackgroundFill = true }
            } label: {
                Label("Presentation", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reflow, arrangement, chords, theme, and background")
            .popover(isPresented: $showingArrangement, arrowEdge: .bottom) {
                ArrangementPopover(model: model)
            }
            .popover(isPresented: $showingBackgroundFill, arrowEdge: .bottom) {
                PresentationBackgroundPopover(model: model)
            }
        }
    }

    @ViewBuilder
    private func themeItems(_ model: SlideEditorModel) -> some View {
        Picker("Theme", selection: themeSelection(model)) {
            Text("None").tag("")
            ForEach(appModel.entries(in: .themes), id: \.id) { entry in
                let isCurrent = entry.id == model.presentation.themeId
                Text(entry.name + (isCurrent && model.presentationHasLocalEdits
                    ? " (edited)" : ""))
                    .tag(entry.id)
            }
        }
        .pickerStyle(.inline)
        if !model.presentation.themeId.isEmpty, model.presentationHasLocalEdits {
            Divider()
            Button("Reapply Theme (Clear Slide Edits)") { model.reapplyTheme() }
        }
    }

    private func undoRedoTools(_ model: SlideEditorModel) -> some View {
        ToolbarCluster {
            Button {
                model.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help("Undo (⌘Z)")
            Button {
                model.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help("Redo (⇧⌘Z)")
        }
        .fixedSize()
    }

    private func modePicker(_ model: SlideEditorModel) -> some View {
        Picker("", selection: Binding(
            get: { model.editorMode },
            set: { model.editorMode = $0 }
        )) {
            ForEach(SlideEditorModel.EditorMode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Design edits the slide; Animate edits its steps on the timeline")
    }

    @ViewBuilder
    private func canvas(_ model: SlideEditorModel) -> some View {
        if let render {
            ZStack {

                Color.basePlane
                EditorCanvasMargin(model: model)

                ZStack {

                    TransparencyGrid(square: 12)
                        .aspectRatio(model.canvasSize, contentMode: .fit)
                        .padding(EditorGeometry.pasteboardInset)
                    SceneCanvas(render: render, transparentBackground: true, inset: EditorGeometry.pasteboardInset)
                    EditorInteractionView(model: model)

                    if model.editorMode == .animate {
                        AnimateCanvasOverlay(model: model)
                            .aspectRatio(model.canvasSize, contentMode: .fit)
                            .padding(EditorGeometry.pasteboardInset)
                    }
                    if canvasDropTargeted {

                        Rectangle()
                            .strokeBorder(
                                Color(nsColor: .controlAccentColor).opacity(0.9),
                                lineWidth: 2
                            )
                            .aspectRatio(model.canvasSize, contentMode: .fit)
                            .padding(EditorGeometry.pasteboardInset)
                            .allowsHitTesting(false)
                    }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { canvasViewSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in canvasViewSize = size }
                    }
                }

                .onDrop(
                    of: [.plainText, .fileURL],
                    delegate: CanvasDropDelegate(
                        enabled: true,
                        viewSize: { canvasViewSize },
                        canvasSize: model.canvasSize,
                        setTargeted: { canvasDropTargeted = $0 },
                        performText: { payload, point in
                            guard !payload.contains("::") else { return false }
                            return model.dropMediaObject(mediaID: payload, at: point)
                        },
                        performFiles: { urls, point in
                            model.dropFiles(urls, at: point)
                        }
                    )
                )
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            .overlay(alignment: .top) {
                if let editing = model.animationStateEditing {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.swap")
                        Text(editing.isStart
                             ? "Move or restyle the object to where it should START. The faint copy is where it rests."
                             : "Move or restyle the object to where it should END UP. The faint copy is where it starts.")
                            .font(.caption)
                        Button("Done") { model.selectedAnimationStepID = nil }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                }
            }
        } else {
            ContentUnavailableView(
                "Metal Unavailable", systemImage: "display.trianglebadge.exclamationmark",
                description: Text("The canvas needs a GPU. Object properties can still be edited in the inspector.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EditorCommands: Commands {
    @FocusedValue(\.slideEditor) private var editor

    var journal: MoveUndoJournal?

    @AppStorage(PresentLayoutController.lockedKey) private var runOnly = false

    var body: some Commands {

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Group") { editor?.perform(.group) }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(editor?.canGroup != true)
            Button("Ungroup") { editor?.perform(.ungroup) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(editor?.canUngroup != true)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(UndoMenuLogic.disabled(editorOpen: editor != nil, editorCan: editor?.canUndo ?? false))
            Button("Redo") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(UndoMenuLogic.disabled(editorOpen: editor != nil, editorCan: editor?.canRedo ?? false))
        }
    }

    private func undo() {
        let fieldEditor = fieldEditorCan(\.canUndo)
        switch UndoMenuLogic.target(
            editorOpen: editor != nil, fieldEditorCan: fieldEditor, journalCan: !runOnly && journal?.canUndo == true
        ) {
        case .editor:
            DiagnosticsStore.shared.note("undo.menu", detail: "editor")
            editor?.undo()
        case .journal:
            let applied = journal?.undo() ?? false
            DiagnosticsStore.shared.note("undo.menu", detail: "journal \(applied ? "applied" : "nothing applied")")
        case .responderChain:
            DiagnosticsStore.shared.note("undo.menu", detail: "field editor")
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case .nothing:
            DiagnosticsStore.shared.note("undo.menu", detail: "nothing to undo")
        }
    }

    private func redo() {
        switch UndoMenuLogic.target(
            editorOpen: editor != nil, fieldEditorCan: fieldEditorCan(\.canRedo), journalCan: !runOnly && journal?.canRedo == true
        ) {
        case .editor:
            editor?.redo()
        case .journal:
            _ = journal?.redo()
        case .responderChain:
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        case .nothing:
            DiagnosticsStore.shared.note("undo.menu", detail: "nothing to redo")
        }
    }

    private func fieldEditorCan(_ ability: KeyPath<UndoManager, Bool>) -> Bool {
        guard let text = NSApp.keyWindow?.firstResponder as? NSTextView,
              let manager = text.undoManager else { return false }
        return manager[keyPath: ability]
    }
}

private struct PresentationBackgroundPopover: View {
    let model: SlideEditorModel

    var body: some View {
        Form {
            Toggle("Background Fill", isOn: enabledBinding)
            if let fill = model.presentation.backgroundFill {
                if fill.fillKind == .linearGradient {
                    LabeledContent("Fill", value: "Gradient (imported)")
                } else {
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 240)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.presentation.backgroundFill != nil },
            set: { on in
                model.setBackgroundFill(
                    on ? ObjectFill(fillKind: .solid, colorHex: "#000000FF") : nil
                )
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                guard let scene = ColorHex.color(
                    model.presentation.backgroundFill?.colorHex ?? ""
                ) else { return .black }
                return Color(
                    .sRGB, red: scene.red, green: scene.green,
                    blue: scene.blue, opacity: scene.alpha
                )
            },
            set: { color in
                let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
                model.setBackgroundFill(ObjectFill(
                    fillKind: .solid,
                    colorHex: ColorHex.hex(SceneColor(
                        red: Double(ns.redComponent),
                        green: Double(ns.greenComponent),
                        blue: Double(ns.blueComponent),
                        alpha: Double(ns.alphaComponent)
                    ))
                ))
            }
        )
    }
}

struct LibraryPickerSheet: View {
    let appModel: AppModel
    var kind: DocumentKind = .media

    var kinds: [DocumentKind]? = nil

    var onImportMedia: ((LibraryHome.Placement) -> Void)? = nil
    let onPick: (LibraryIndex.Entry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var importFolder: String?
    @State private var query = ""
    @State private var scope: DocumentKind?

    @State private var queryHits: [LibraryIndex.Entry] = []
    @FocusState private var searchFocused: Bool

    private var activeKind: DocumentKind { scope ?? kinds?.first ?? kind }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(10)
            if let kinds, kinds.count > 1 {
                Picker("Scope", selection: Binding(
                    get: { activeKind },
                    set: { scope = $0 }
                )) {
                    ForEach(kinds, id: \.self) { candidate in
                        Text(Self.scopeTitle(candidate)).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider()
            let entries = results
            if entries.isEmpty {
                if activeKind == .audio {
                    ContentUnavailableView(
                        "No Music", systemImage: "music.note",
                        description: Text(query.isEmpty
                            ? "Import songs in the Music section first."
                            : "Nothing matches “\(query)”.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Media", systemImage: "photo.on.rectangle.angled",
                        description: Text(query.isEmpty
                            ? (onImportMedia == nil
                                ? "Import images or videos in the Media section first."
                                : "Add an image or video from disk below.")
                            : "Nothing matches “\(query)”.")
                    )
                    .frame(maxHeight: .infinity)
                }
            } else {
                List(entries, id: \.id) { entry in
                    Button {
                        onPick(entry)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            if kind == .media {

                                Color.black
                                    .overlay { PosterImage(model: appModel, mediaId: entry.id) }
                                    .frame(width: 46, height: 26)
                                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                            } else {
                                Image(systemName: symbol(entry))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                            }
                            Text(entry.name)
                            Spacer()

                            if let used = entry.lastUsedAt {
                                Text("Used \(used, format: .relative(presentation: .named))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            if onImportMedia != nil, activeKind == .media {
                importDestination
            }
            HStack {
                if let onImportMedia, activeKind == .media {
                    Button("Add Media from Disk…") {
                        let placement = importPlacement
                        dismiss()
                        onImportMedia(placement)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 480, height: 420)
        .onAppear { searchFocused = true }
        .task(id: query) {
            queryHits = await appModel.search(query).map(\.entry)
        }
    }

    private var importDestination: some View {
        let current = currentImportFolder
        let folders = Set(appModel.driveFolders(in: .media) + [current])
            .subtracting([LibraryHome.needsSorted])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.secondary)
            Text("Saves to Media ›")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Picker("Folder", selection: Binding(get: { current }, set: { importFolder = $0 })) {
                Text(LibraryHome.needsSorted).tag(LibraryHome.needsSorted)
                ForEach(folders, id: \.self) { folder in
                    Text(folder.replacingOccurrences(of: "/", with: " › ")).tag(folder)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var currentImportFolder: String {
        importFolder
            ?? LibraryHome.folder(for: .media, named: nil, viewing: appModel.viewedLibraryFolder)
            ?? LibraryHome.needsSorted
    }

    private var importPlacement: LibraryHome.Placement {
        .drive(viewing: .init(kind: .media, area: .team, path: currentImportFolder))
    }

    static func scopeTitle(_ kind: DocumentKind) -> String {
        switch kind {
        case .presentation: "Slides"
        case .media: "Media"
        case .audio: "Music"
        default: kind.rawValue.capitalized
        }
    }


    private var results: [LibraryIndex.Entry] {
        let kind = activeKind
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return queryHits.filter { $0.kind == kind }
        }
        let entries = appModel.entries(of: kind)
        return entries.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (usedA?, usedB?): usedA > usedB
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    private func symbol(_ entry: LibraryIndex.Entry) -> String {
        if entry.kind == .presentation { return "rectangle.on.rectangle" }
        if activeKind == .audio { return "music.note" }

        guard let item = appModel.media(entry.id) else { return "photo" }
        return item.mediaKind == .video ? "film" : "photo"
    }
}

enum EditSlideDrag {
    static let prefix = "mxueditslide::"

    static func payload(_ slideIDs: [String]) -> String {
        prefix + slideIDs.joined(separator: ",")
    }

    static func ids(in payload: String) -> [String]? {
        if payload.hasPrefix(prefix) {
            return payload.dropFirst(prefix.count).split(separator: ",").map(String.init)
        } else {
            return nil
        }
    }
}

enum MediaFilePicker {
    @MainActor static func choose(_ handler: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            handler(panel.urls)
        }
    }
}
