import OutputEngine
import PresenterCore
import SlideScene
import SwiftUI

struct MakeSlidesSheet: View {
    let appModel: AppModel
    let render: RenderContext?
    let noteName: String
    let body_: NoteBody

    let linkedPresentationId: String?

    var memory: [NoteMadePassage] = []

    var mediaImports: [NoteMediaImport] = []

    let onCreated: (_ presentationId: String, _ isNew: Bool, _ body: NoteBody) -> Void

    let onOpenEditor: (_ presentationId: String) -> Void

    var onClose: ((_ body: NoteBody) -> Void)? = nil

    enum Target: Equatable { case new, existing }

    struct RowChoice: Equatable {
        var themeId: String?
        var design: String?
        var lines: Int?

        var kind: SlideKind?

        var lookDesigns: [String: String] = [:]

        var preset: NoteSlideBuilder.SwitchOverride = .typeDefault

        var blanks: BlankPlacement?

        var options: SlideOptions?

        var scaleChosen = false
    }

    @Environment(\.dismiss) private var dismiss

    @State private var selectedGroup: String?
    @State private var scroller = NoteDocumentScroller()
    @StateObject private var live = NoteSlideLive()

    @State private var rebuildDebounce: Task<Void, Never>?

    @State private var waitingForPictures = false

    @State private var mediaLine: String?
    @State private var target: Target = .new
    @State private var newName = ""
    @State private var newFolder = ""
    @State private var existingId: String?

    @State private var decksFilled = false
    @State private var pickingExisting = false
    @State private var choices: [String: RowChoice] = [:]
    @State private var preview: Preview?
    @State private var previewStamp = 0

    @State private var workingBody: NoteBody?

    @State private var enlarged: Slide?

    @State private var selectionPreview: NoteBody?

    @AppStorage(AppModel.autoMarkKey) private var autoMarkChoice = NoteSlideMarks.AutoMark.pickForMe.rawValue
    @State private var importingNotes = false

    @Environment(\.actionRouter) private var actionRouter
    @State private var editingDesigns = false

    @State private var reopenSlideTypes = false

    @State private var slideTypesPane = SlideKind.title.rawValue

    @State private var newTypeName = ""

    @FocusState private var newTypeNameFocused: Bool

    @State private var renamingType = ""

    @State private var designPick: DesignPick?

    struct DesignPick: Identifiable {
        let id = UUID()
        let current: SlideDesignMap.Entry?
        let scope: String
        let automatic: String
        let photoSpotsOnly: Bool

        var reopensSlideTypes = false
        let pick: (SlideDesignMap.Entry?) -> Void
    }

    private var designMap: SlideDesignMap {
        get { appModel.slideBuilding.slideDesignMap }
        nonmutating set { appModel.updateSlideBuilding { $0.setSlideDesignMap(newValue) } }
    }

    private var newThemeId: String { appModel.slideBuilding.notesThemeId(starter: appModel.starterNotesThemeId) }

    private var planner: DeterministicSlidePlanner { DeterministicSlidePlanner(options: designMap.options) }

    struct StreamLook: Identifiable {
        var id: String
        var label: String
        var theme: Theme

        var targets: String
    }

    private func streamLooks(forPreset presetID: String?) -> [StreamLook] {
        guard let actionRouter else { return [] }
        var names: [String: String] = [:]
        if let outputs = render?.outputs {
            for display in outputs.displays { names[display.uuid] = display.name }
            for screen in outputs.placeholderScreens { names[screen.id.uuidString] = screen.name }
        }
        let looks = presetID.map { actionRouter.overrideLooks(forPreset: $0) } ?? actionRouter.activeOverrideLooks()
        let presetName = presetID.flatMap { appModel.entry($0)?.name }.map { " once it switches to \($0)" } ?? ""
        return looks.map { look in
            let targets = look.targetIds.map { names[$0] ?? "Output" }.joined(separator: ", ")
            let scope = look.folder.map { " › \($0)" } ?? ""
            return StreamLook(id: look.id, label: "\(targets) shows this through \(look.theme.name)\(scope)\(presetName)", theme: look.theme, targets: targets)
        }
    }

    struct Preview {
        var presentation: Presentation
        var rows: [SlideRow]
        var built: NoteSlideBuilder.Built

        var decks: [String: String] = [:]
        var positions: [String: Int] = [:]

        var rowPresetIds: [String: String] = [:]
        var looksByPreset: [String: [StreamLook]] = [:]
        var madeSlideIds: [String: String] = [:]

        var deadCards: [String: Set<String>] = [:]
    }

    private var currentBody: NoteBody { workingBody ?? body_ }

    private var groups: [MarkedGroup] { NoteSlideBuilder.groups(in: currentBody) }

    private var madeSlideIds: [String: String] { preview?.madeSlideIds ?? [:] }

    private func madeSlideIds(of groupId: String, cards: [NoteSlideRef], stamped: String? = nil) -> [String] {
        let carded = cards.compactMap(\.slideId)
        if !carded.isEmpty { return carded }
        if let remembered = memory.first(where: { $0.groupId == groupId })?.slides.map(\.slideId), !remembered.isEmpty { return remembered }
        return (stamped ?? madeSlideIds[groupId]).map { [$0] } ?? []
    }

    private static func madeSlideIds(in body: NoteBody) -> [String: String] {
        Dictionary(uniqueKeysWithValues: NoteSlideMarks.groups(in: body).compactMap { g in g.slideId.map { (g.id, $0) } })
    }

    private var plannedGroups: [MarkedGroup] {
        selectionPreview.map { NoteSlideBuilder.groups(in: $0) } ?? groups
    }

    private var noteIsEmpty: Bool {
        currentBody.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sheetDeckIDs: [String] {
        [linkedPresentationId, existingId].compactMap { $0 }
            + groups.flatMap { NoteSlideUpdate.cards(afterGroup: $0.id, in: currentBody).compactMap(\.presentationId) }
    }

    private var deckThemeId: String {
        switch target {
        case .new: newThemeId
        case .existing: existingId.flatMap { appModel.presentation($0) }?.themeId ?? ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                notePane
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                slidesPane
                    .frame(width: 440)
                    .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 880, idealWidth: 1240, maxWidth: 1500, minHeight: 620, idealHeight: 760, maxHeight: 820)
        .onAppear {
            newName = noteName
            mediaLine = NoteMedia.footerLine(for: NoteMedia.importable(
                in: body_, remembered: mediaImports, libraryHas: { appModel.media($0) != nil }))
            if let linkedPresentationId, appModel.presentationExists(linkedPresentationId) {
                target = .existing
                existingId = linkedPresentationId
            }

            if groups.isEmpty, !memory.isEmpty {
                let matched = NoteSlideMatch.match(fresh: body_, memory: memory)
                if !matched.matches.isEmpty { workingBody = matched.body }
            }
            rebuildPreview()

            if noteIsEmpty { DispatchQueue.main.async { scroller.focus() } }
        }
        .task(id: existingId) {
            decksFilled = false
            await appModel.resident.ready([.theme])
            _ = await appModel.presentationsFilled(sheetDeckIDs)
            decksFilled = true
            rebuildPreview()
        }
        .onChange(of: target) { rebuildPreview() }
        .onChange(of: newThemeId) { rebuildPreview() }
        .onReceive(NoteImageStore.shared.$version) { _ in if waitingForPictures { rebuildPreview() } }
        .onChange(of: existingId) { rebuildPreview() }
        .onChange(of: choices) { rebuildPreview() }
        .onChange(of: designMap) { rebuildPreview() }
        .sheet(isPresented: $pickingExisting) {
            LibraryPickerSheet(appModel: appModel, kind: .presentation) { entry in
                existingId = entry.id
                target = .existing
            }
        }
        .sheet(item: $designPick, onDismiss: {
            if reopenSlideTypes {
                reopenSlideTypes = false
                DispatchQueue.main.async { editingDesigns = true }
            }
        }) { pick in
            DesignPickSheet(
                appModel: appModel, render: render, deckThemeId: deckThemeId, current: pick.current,
                scope: pick.scope, automatic: pick.automatic, photoSpotsOnly: pick.photoSpotsOnly, onPick: pick.pick)
                .onAppear { reopenSlideTypes = pick.reopensSlideTypes }
        }
        .sheet(item: $enlarged) { slide in
            VStack(spacing: 10) {
                if let preview {
                    SlideThumbnailView(
                        model: appModel, render: render,
                        slide: slide, presentation: preview.presentation,
                        theme: appModel.theme(for: slide, in: preview.presentation),
                        arrangementId: nil, hideScopedBackgrounds: false,
                        contentStamp: "\(previewStamp)|large")
                    .aspectRatio(SlideGridMetrics.tileAspect(for: preview.presentation), contentMode: .fit)
                    .frame(width: 800)
                    .clipShape(.rect(cornerRadius: CornerStandard.element, style: .continuous))
                }
                Button("Done") { enlarged = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Make Slides").font(.headline)
                Text(headerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            targetPicker
            Button {
                editingDesigns.toggle()
            } label: {
                Label("Slide Types", systemImage: "gearshape")
            }
            .help("Slide Types: design, Output Preset and options for each kind of slide")
            .popover(isPresented: $editingDesigns, arrowEdge: .bottom) { designSettings }
        }
        .padding(10)
    }

    private var designSettings: some View {
        let map = designMap
        let panes = slideTypePanes(map)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slide Types").font(.headline)
                Text("Used for every note on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(panes, id: \.id) { pane in
                        if pane.id == "other" { Divider().padding(.vertical, 4) }
                        Button {
                            if pane.id == Self.addPane { newTypeName = "" }
                            slideTypesPane = pane.id
                        } label: {
                            Text(pane.id == Self.addPane ? "Add Type" : pane.name)
                                .foregroundStyle(pane.id == Self.addPane && slideTypesPane != pane.id ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(slideTypesPane == pane.id ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 5))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 130)
                .padding(.trailing, 10)
                Divider()
                slideTypePane(panes: panes, map: map)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 540, height: 340, alignment: .topLeading)
    }

    typealias SlideTypePane = (id: String, name: String, about: String)

    static let builtInPanes: [SlideTypePane] = [
        (SlideKind.title.rawValue, "Title", "A heading in the note, with the short line under it."),
        (SlideKind.body.rawValue, "Statement", "Plain words on a slide: a sentence, a question or a big idea, with no number, letter or label."),
        (SlideKind.points.rawValue, "Points", "A list of points, or a labelled line like “Big idea:”."),
        (SlideKind.scripture.rawValue, "Scripture", "A Bible passage and its reference."),
        (SlideKind.quote.rawValue, "Quote", "Words in quotation marks, and who said them."),
        (SlideKind.lyrics.rawValue, "Lyrics", "Song words with sections like Verse and Chorus."),
        (SlideKind.picture.rawValue, "Pictures", "A picture in the note: full screen, or in a design's photo spots."),
        (SlideKind.video.rawValue, "Videos", "A video in the note, full screen. A “Video:” line with a link makes a slide to drop the video on."),
        (SlideKind.blank.rawValue, "Blank", "An empty slide that takes the words down between passages."),
    ]
    static let otherPanes: [SlideTypePane] = [
        ("other", "All other", "The Output Preset for every type with none of its own."),
        ("note", "From the Note", "How the note's words become slide words, for every type."),
    ]

    static func ownPane(_ name: String) -> String { "own:" + name }

    static let addPane = "add"

    private func slideTypePanes(_ map: SlideDesignMap) -> [SlideTypePane] {
        Self.builtInPanes + map.options.ownTypes.map { (Self.ownPane($0.name), $0.name, "Lines in the note that start with “\($0.name):”.") }
            + [(Self.addPane, "New Type", "Lines in the note that start with the name and a colon (“Announcement: …”) become this type.")]
            + Self.otherPanes
    }

    @ViewBuilder
    private var addTypeRows: some View {
        GridRow {
            paneLabel("Name")
            TextField("Announcement", text: $newTypeName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($newTypeNameFocused)
                .onAppear { newTypeNameFocused = true }
                .onSubmit { addOwnType(named: newTypeName) }
        }
        GridRow {
            Text("")
            HStack(spacing: 8) {
                Button("Add") { addOwnType(named: newTypeName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!designMap.canAddOwnType(named: newTypeName))
                Button("Cancel") { slideTypesPane = SlideKind.title.rawValue }
            }
        }
    }

    private func addOwnType(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        var map = designMap
        guard map.canAddOwnType(named: name) else { return }
        map.options.ownTypes.append(SlideOptions.OwnType(name: name))
        designMap = map
        slideTypesPane = Self.ownPane(name)
    }

    private func renameOwnType(_ old: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard name != old else { return }
        var map = designMap
        guard map.canAddOwnType(named: name) else { return renamingType = old }
        map.renameOwnType(old, to: name)
        designMap = map
        slideTypesPane = Self.ownPane(name)
    }

    private func updateOwnType(_ name: String, _ change: (inout SlideOptions.OwnType) -> Void) {
        var map = designMap
        guard let index = map.options.ownTypes.firstIndex(where: { $0.name == name }) else { return }
        change(&map.options.ownTypes[index])
        designMap = map
    }

    @ViewBuilder
    private func slideTypePane(panes: [SlideTypePane], map: SlideDesignMap) -> some View {
        let pane = panes.first { $0.id == slideTypesPane } ?? panes[0]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.name).font(.callout.weight(.semibold))
                Text(pane.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                if pane.id == "note" {
                    GridRow {
                        Text("")
                        optionToggle("Keep underlines", \.keepUnderlines)
                            .help("Underlined words in the note (fill-in-the-blank notes) stay underlined on the slide.")
                    }
                    GridRow {
                        Text("")
                        optionToggle("Words in (parentheses) go to slide notes", \.parenthesesToNotes)
                            .help("Words in parentheses are for whoever makes the slides: they go in the slide's notes, not on the screen. A translation like (NIV) and a reference stay.")
                    }
                } else if pane.id == "other" {
                    GridRow {
                        paneLabel("Output Preset")
                        switchMenu(current: map.otherPreset, noneLabel: "Keep current look") { pick in
                            var map = designMap
                            map.otherPreset = pick
                            designMap = map
                        }
                        .menuStyle(.borderlessButton)
                    }
                } else if pane.id == Self.addPane {
                    addTypeRows
                } else if pane.id.hasPrefix("own:"), let own = map.options.ownType(named: String(pane.id.dropFirst(4))) {
                    ownTypeRows(own, map: map)
                } else if let kind = SlideKind(rawValue: pane.id) {
                    GridRow {
                        paneLabel("Design")
                        if kind == .video {
                            Text("Full screen")
                        } else if kind == .picture {
                            designMenu(forType: kind.rawValue, name: pane.name, automatic: "Full screen", map: map)
                        } else {
                            designMenu(forType: kind.rawValue, name: pane.name, automatic: "Automatic (\(pane.name))", map: map)
                        }
                    }
                    GridRow {
                        paneLabel("Output Preset")
                        switchMenu(current: map.ownPreset(for: kind), noneLabel: map.otherPreset == nil ? "Keep current look" : "Same as all other") { pick in
                            var map = designMap
                            map.setPreset(pick, for: kind)
                            designMap = map
                        }
                        .menuStyle(.borderlessButton)
                    }
                    typeOptions(for: kind, map: map)
                }
            }
        }
    }

    private func paneLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func ownTypeRows(_ own: SlideOptions.OwnType, map: SlideDesignMap) -> some View {
        GridRow {
            paneLabel("Name")
            TextField("Name", text: $renamingType)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { renameOwnType(own.name, to: renamingType) }
                .task(id: own.name) { renamingType = own.name }
        }
        GridRow {
            paneLabel("Design")
            designMenu(forType: own.name, name: own.name, automatic: "Automatic (\(own.name))", map: map)
        }
        GridRow {
            paneLabel("Output Preset")
            switchMenu(current: map.ownPreset(forType: own.name), noneLabel: map.otherPreset == nil ? "Keep current look" : "Same as all other") { pick in
                var map = designMap
                map.setPreset(pick, forType: own.name)
                designMap = map
            }
            .menuStyle(.borderlessButton)
        }
        GridRow {
            paneLabel("Split")
            paneMenu(value: own.split.title) {
                ForEach(SlideOptions.OwnType.Split.allCases, id: \.rawValue) { split in
                    Button(split.title + (own.split == split ? " ✓" : "")) { updateOwnType(own.name) { $0.split = split } }
                }
            }
        }
        GridRow {
            paneLabel("Reveal")
            Toggle("One line per click", isOn: Binding(get: { own.reveal }, set: { on in updateOwnType(own.name) { $0.reveal = on } }))
                .toggleStyle(.checkbox)
                .help("Each line fades in on its own click.")
        }
        GridRow {
            Text("")
            Button("Remove Type", role: .destructive) {
                var map = designMap
                map.removeOwnType(named: own.name)
                designMap = map
                slideTypesPane = SlideKind.title.rawValue
            }
        }
    }

    private func designMenu(forType type: String, name: String, automatic: String, map: SlideDesignMap) -> some View {
        let current = map.entry(forType: type)
        return Button {
            designPick = DesignPick(
                current: current, scope: "Applies to every \(name) slide.", automatic: automatic,
                photoSpotsOnly: type == SlideKind.picture.rawValue, reopensSlideTypes: true
            ) { entry in
                var map = designMap
                map.set(entry, forType: type)
                designMap = map
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.map { "\($0.themeSlideName) — \(appModel.entry($0.themeId)?.name ?? "Missing theme")" } ?? automatic)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help("Automatic finds a design named like the type in the deck's theme. A chosen design is used instead, and brings its theme.")
    }

    @ViewBuilder
    private func typeOptions(for kind: SlideKind, map: SlideDesignMap) -> some View {
        switch kind {
        case .points:
            GridRow {
                paneLabel("Reveal")
                optionToggle("One point per click", \.revealPoints)
                    .help("Each point fades in on its own click.")
            }
        case .scripture:
            GridRow {
                paneLabel("Split")
                paneMenu(value: map.options.scriptureSplit == .oneVerse ? "One verse per slide" : "Fit to box") {
                    ForEach(SlideOptions.ScriptureSplit.allCases, id: \.rawValue) { split in
                        Button((split == .oneVerse ? "One verse per slide" : "Fit to box") + (map.options.scriptureSplit == split ? " ✓" : "")) {
                            var map = designMap
                            map.options.scriptureSplit = split
                            designMap = map
                        }
                    }
                }
            }
            GridRow {
                Text("")
                optionToggle("Show verse numbers", \.verseNumbers)
            }
        case .picture:
            GridRow {
                paneLabel("Scale")
                paneMenu(value: Self.scaleTitle(map.options.pictureScale)) {
                    ForEach([MediaScaleMode.scaleAndBlur, .fit, .fill, .stretch], id: \.rawValue) { mode in
                        Button(Self.scaleTitle(mode) + (map.options.pictureScale == mode ? " ✓" : "")) {
                            var map = designMap
                            map.options.pictureScale = mode
                            designMap = map
                        }
                    }
                }
                .help("Scale and Blur shows the whole picture over a blurred copy of itself; on a design's photo spots the picture fills the spot instead. Fit shows it whole, Fill covers, Stretch fills it out of shape. Each picture can change it in its label's menu.")
            }
            GridRow {
                paneLabel("Several in a row")
                paneMenu(value: map.options.picturesTogether ? "Together" : "One slide each") {
                    ForEach([false, true], id: \.self) { together in
                        Button((together ? "Together" : "One slide each") + (map.options.picturesTogether == together ? " ✓" : "")) {
                            var map = designMap
                            map.options.picturesTogether = together
                            designMap = map
                        }
                    }
                }
                .help("Together puts pictures in a row on one slide, in a design of the theme with that many photo spots.")
            }
        case .video:
            GridRow {
                paneLabel("When it ends")
                paneMenu(value: map.options.videoEnd.title) {
                    ForEach(SlideOptions.VideoEnd.allCases, id: \.rawValue) { end in
                        Button(end.title + (map.options.videoEnd == end ? " ✓" : "")) {
                            var map = designMap
                            map.options.videoEnd = end
                            designMap = map
                        }
                    }
                }
                .help("Go to next slide fires the next slide the moment the video ends. Fade to clear dissolves into whatever is behind it, best over a background.")
            }
        case .blank:
            GridRow {
                paneLabel("After")
                paneMenu(value: BlankChoice.current(in: map).label) { blankChoiceItems(map) }
                    .help("Every slide but verses keeps a scripture passage's verses together, with one blank after the passage.")
            }
        default:
            EmptyView()
        }
    }

    private func optionToggle(_ title: String, _ key: WritableKeyPath<SlideOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { designMap.options[keyPath: key] },
            set: { on in
                var map = designMap
                map.options[keyPath: key] = on
                designMap = map
            }))
        .toggleStyle(.checkbox)
    }

    private func paneMenu<Items: View>(value: String, @ViewBuilder items: () -> Items) -> some View {
        Menu(content: items) { Text(value) }
            .menuStyle(.borderlessButton)
            .fixedSize()
    }

    struct BlankChoice: Hashable {
        var label: String
        var placement: BlankPlacement
        var betweenVerses = false

        static let all = [
            BlankChoice(label: "Don't add", placement: .none),
            BlankChoice(label: "Each passage", placement: .afterPassage),
            BlankChoice(label: "Every slide but verses", placement: .afterSlide),
            BlankChoice(label: "Every slide", placement: .afterSlide, betweenVerses: true),
        ]

        static func current(in map: SlideDesignMap) -> BlankChoice {
            all.first { $0.placement == map.blanks && (map.blanks != .afterSlide || $0.betweenVerses == map.options.blanksBetweenVerses) } ?? all[0]
        }
    }

    @ViewBuilder
    private func blankChoiceItems(_ map: SlideDesignMap) -> some View {
        let current = BlankChoice.current(in: map)
        ForEach(BlankChoice.all, id: \.self) { choice in
            Button(choice.label + (choice == current ? " ✓" : "")) {
                var map = designMap
                map.blanks = choice.placement
                map.options.blanksBetweenVerses = choice.betweenVerses
                designMap = map
            }
        }
    }

    static func blankLabel(_ placement: BlankPlacement) -> String {
        switch placement {
        case .none: "Don't add"
        case .afterPassage: "After each passage"
        case .afterSlide: "After every slide"
        }
    }

    private func switchMenu(current: SlidePresetChoice?, noneLabel: String, onPick: @escaping (SlidePresetChoice?) -> Void) -> some View {
        let presets = appModel.entries(of: .outputPreset)
        let combos = appModel.entries(of: .actionCombo)
        return Menu {
            Button(noneLabel + (current == nil ? " ✓" : "")) { onPick(nil) }
            if !presets.isEmpty {
                Section("Output Presets") {
                    ForEach(presets, id: \.id) { entry in
                        Button(entry.name + (current == .preset(entry.id) ? " ✓" : "")) { onPick(.preset(entry.id)) }
                    }
                }
            }
            if !combos.isEmpty {
                Section("Action Combos") {
                    ForEach(combos, id: \.id) { entry in
                        Button(entry.name + (current == .combo(entry.id) ? " ✓" : "")) { onPick(.combo(entry.id)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Glyph(kind: .screens, size: 12)
                Text(current.map { switchName($0) } ?? noneLabel).lineLimit(1)
            }
        }
        .fixedSize()
    }

    private func switchName(_ choice: SlidePresetChoice) -> String {
        let name = appModel.entry(choice.id)?.name ?? "Missing"
        return choice.kind == .actionCombo ? "Combo: \(name)" : name
    }

    private var targetPicker: some View {
        Picker("", selection: $target) {
            Text("New Presentation").tag(Target.new)
            Text("Add to Existing").tag(Target.existing)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var themeChooser: some View {
        LyricsThemeChooser(appModel: appModel, render: render, themeId: newThemeId) { themeId, design in
            appModel.updateSlideBuilding { $0.setLyricsLook(themeId: themeId, design: design) }
        }
    }

    @ViewBuilder
    private var targetDetails: some View {
        switch target {
        case .new:
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 220)

            Picker("in", selection: $newFolder) {
                Text(LibraryHome.needsSorted).tag("")
                ForEach(appModel.driveFolders(in: .presentations).filter { $0 != LibraryHome.needsSorted }, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .fixedSize()
        case .existing:
            Button {
                pickingExisting = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                    Text(existingId.flatMap { appModel.entry($0)?.name } ?? "Choose a presentation…")
                        .lineLimit(1)
                }
            }
            if let existingId, let deck = appModel.presentation(existingId) {
                Text("Adding to it: \(deck.slides.count) slides on \(deck.themeId.isEmpty ? "no theme" : (appModel.entry(deck.themeId)?.name ?? "a missing theme"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var headerSummary: String {
        let counted = groups.count
        var parts = [noteName]
        if counted > 0, createCount > 0 {
            parts.append("\(counted) \(counted == 1 ? "passage makes" : "passages make") \(createCount) \(createCount == 1 ? "slide" : "slides")")
        } else if counted > 0 {
            parts.append("\(counted) \(counted == 1 ? "passage" : "passages")")
        }
        return parts.joined(separator: " · ")
    }

    private var countedIds: Set<String> { Set(groups.map(\.id)) }

    private var notePane: some View {
        let ownTypes = designMap.options.ownTypes
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Note").font(.callout.weight(.semibold))
                Spacer()
                if noteIsEmpty {
                    Button {
                        importNotesFile()
                    } label: {
                        Label("Import File…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(importingNotes)
                    .help("Word, RTF, ODT, PDF, PowerPoint or text")
                }
                Menu {
                    Button("Slide") { scroller.markWillBeSlide(type: nil) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                    Divider()
                    ForEach(NoteSlideMarks.SlideType.textKinds, id: \.rawValue) { type in
                        Button(type.label) { scroller.markWillBeSlide(type: type.rawValue) }
                    }
                    ForEach(ownTypes) { own in
                        Button(own.name) { scroller.markWillBeSlide(type: own.name) }
                    }
                } label: {
                    Text("Will Be Slide")
                }
                .fixedSize()
                .help("Make the selected text a slide")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            NoteDocumentView(
                body: currentBody,
                style: NoteReaderStyle(fontSize: 14, compact: false, slideDisplay: .hidden),
                query: "", slides: nil, live: live, scroller: scroller, maxLineWidth: 680,
                editable: true,
                onEdit: { edited in
                    workingBody = edited
                    scheduleRebuild()
                },
                marksInMargin: true,
                selectedGroup: selectedGroup,
                onSelectGroup: { selectedGroup = $0 },
                onSelectionPreview: { body in
                    selectionPreview = body
                    scheduleRebuild()
                },
                onNotesArrive: { pasted in notesArrived(NoteFileReader.body(attributed: pasted, save: NoteMediaFiles.save)) },
                kindMenuExtras: { group, type in kindMenuExtras(group: group, type: type) },
                parenthesesToNotes: designMap.options.parenthesesToNotes,
                parenthesesByGroup: choices.compactMapValues { $0.options?.parenthesesToNotes })
            .padding(.horizontal, 8)
            .overlay(alignment: .top) {
                if noteIsEmpty { startNote }
            }
        }
    }

    private var startNote: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste the notes, or start typing…")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.arrow.up").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(importingNotes ? "Reading…" : "Drop a file here").font(.callout)
                Text("Word, RTF, ODT, PDF, PowerPoint or text. Bold and underlines come with it, the same as when you paste.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background {
                RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                readNotesFile(url)
                return true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func importNotesFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.noteFileTypes
        panel.message = "Choose notes"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in readNotesFile(url) }
        }
    }

    private func readNotesFile(_ url: URL) {
        importingNotes = true
        Task {
            let body = await AppModel.noteBody(of: url, save: NoteMediaFiles.save)
            importingNotes = false
            if let body {
                notesArrived(body)
            } else {
                appModel.noteImportSummary("Can't read \(url.lastPathComponent) as notes. MxU Slides reads Word, RTF, ODT, PDF, PowerPoint and text files.")
            }
        }
    }

    private func notesArrived(_ body: NoteBody) {
        let mode = NoteSlideMarks.AutoMark(rawValue: autoMarkChoice) ?? .pickForMe
        let ownTypes = designMap.options.ownTypes.map(\.name)
        Task {
            workingBody = await Task.detached(priority: .userInitiated) { mode.marking(body, ownTypes: ownTypes) }.value
            rebuildPreview()
        }
    }

    private var autoMarkChoices: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Slides appear here as the note fills in").font(.headline)
                Text("MxU Slides picks the likely slides for you. Change any of them, or select text in the note to make a slide yourself.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick slides when notes come in").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Pick slides when notes come in", selection: $autoMarkChoice) {
                    ForEach(NoteSlideMarks.AutoMark.allCases, id: \.rawValue) { choice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice == .nothing ? "Nothing, I’ll choose them myself" : choice.title)
                            if let detail = Self.autoMarkDetail(choice) {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Text("Words in (parentheses) stay off the screen and go in the slide notes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func autoMarkDetail(_ choice: NoteSlideMarks.AutoMark) -> String? {
        switch choice {
        case .pickForMe: "Bold lines when the notes mix bold and plain text, otherwise by structure."
        case .boldLines: "Scripture and quotes are picked either way."
        case .structure: "Each heading, list, quote and short line."
        case .nothing: nil
        }
    }

    private var slidesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Slides").font(.callout.weight(.semibold))

                if target == .new {
                    themeChooser
                } else if let theme = appModel.entry(deckThemeId)?.name {
                    Text(theme).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    if let selectedGroup { choices[selectedGroup, default: RowChoice()].blanks = .afterPassage }
                } label: {
                    Label("Add Blank", systemImage: "rectangle.dashed")
                }
                .disabled(selectedGroup == nil)
                .help("A blank slide after the selected passage's slides")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            slidesColumn
                .frame(maxHeight: .infinity)
        }
    }

    private struct Tile: Identifiable {
        var id: String { slide.id }
        var slide: Slide
        var group: String
        var number: Int?
        var caption: String
        var extra: String
        var blank: Bool

        var preview = false
    }

    private func tiles(_ preview: Preview) -> [Tile] {
        let rows = Dictionary(preview.rows.map { ($0.groupId, $0) }, uniquingKeysWith: { first, _ in first })
        var number = 0
        return preview.presentation.slides.compactMap { slide in
            guard let group = preview.built.group(of: slide.id), let row = rows[group] else { return nil }
            let blank = preview.built.blankFollows[slide.id] != nil
            let previewing = group == NoteDocumentTextView.selectionPreviewGroup
            if !previewing { number += 1 }
            let clicks = slide.objects.compactMap(\.animationSteps).reduce(0) { $0 + $1.count }
            var extra = previewing ? "preview" : (clicks > 0 ? "\(clicks) \(clicks == 1 ? "click" : "clicks")" : "")

            if !previewing, !blank, row.kind == .picture, slide.background != nil { extra = Self.scaleTitle(row.scale ?? .fill) }

            if !previewing, !blank, row.kind == .picture, row.themeSlideName != nil { extra = Self.scaleTitle(row.shownScale) }
            if !previewing, !blank, let shape = preview.built.pictureShapes[slide.id] { extra = shape.caption }
            if !previewing, !blank, row.kind == .video, slide.background != nil { extra = (row.videoEnd ?? .next).title }

            if !previewing, !blank, let choice = choices[group] {
                if let design = choice.design { extra = design }
                if let lines = choice.lines { extra = lines == 1 ? "1 line" : "\(lines) lines" }
            }
            return Tile(
                slide: slide, group: group, number: previewing ? nil : number,
                caption: blank ? "Blank" : NoteDocumentTextView.kindLabel(row.ownType ?? row.kind.rawValue),
                extra: extra, blank: blank, preview: previewing)
        }
    }

    @ViewBuilder
    private var slidesColumn: some View {
        if noteIsEmpty {
            autoMarkChoices
        } else if plannedGroups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No slides yet. Select text in the note to make a slide, or let MxU Slides pick them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Pick for Me") {
                        let matched = NoteSlideMatch.match(fresh: currentBody, memory: memory)
                        workingBody = NoteSlideMarks.suggesting(matched.body, ownTypes: designMap.options.ownTypes.map(\.name))
                        rebuildPreview()
                    }
                    Button("Pick by Structure") {
                        let matched = NoteSlideMatch.match(fresh: currentBody, memory: memory)
                        workingBody = NoteSlideMarks.markingByStructure(matched.body)
                        rebuildPreview()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let preview {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 12) {
                        ForEach(tiles(preview)) { tile in
                            tileView(tile, preview: preview).id(tile.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: selectedGroup) { _, group in
                    guard let group, let first = tiles(preview).first(where: { $0.group == group }) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(first.id, anchor: .center) }
                }
                .onChange(of: previewStamp) {
                    guard selectionPreview != nil,
                          let first = tiles(preview).first(where: { $0.preview }) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(first.id, anchor: .center) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)) { note in
                    guard scroller.scrolls(note.object), let group = scroller.firstVisibleGroup(), group != scroller.followedGroup else { return }
                    scroller.followedGroup = group
                    guard let first = tiles(preview).first(where: { $0.group == group }) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tileView(_ tile: Tile, preview: Preview) -> some View {
        let selected = tile.group == selectedGroup && !tile.blank
        return VStack(alignment: .leading, spacing: 4) {
            SlideThumbnailView(
                model: appModel, render: render,
                slide: tile.slide, presentation: preview.presentation,
                theme: appModel.theme(for: tile.slide, in: preview.presentation),
                arrangementId: nil, hideScopedBackgrounds: false,
                contentStamp: "\(previewStamp)")
            .aspectRatio(SlideGridMetrics.tileAspect(for: preview.presentation), contentMode: .fit)
            .overlay { pendingMediaFace(tile.slide) }
            .clipShape(.rect(cornerRadius: CornerStandard.element, style: .continuous))
            .opacity(tile.preview ? 0.85 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: CornerStandard.element, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: tile.preview ? 2 : 1, dash: tile.blank || tile.preview ? [4, 3] : []))
                    .foregroundStyle(tile.preview ? Color.accentColor : tile.blank ? Color.secondary : Color.clear)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: CornerStandard.element, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                }
            }
            .overlay(TileMenuBacking { tile.preview ? nil : scroller.kindMenu(for: tile.group) })
            .contentShape(.rect)
            .onTapGesture {
                selectedGroup = tile.group
                scroller.scrollToGroup(tile.group)
            }
            .help(tile.blank ? "A blank slide. Fire it to take the words down." : "Click to select this passage; double-click to see it large")
            .simultaneousGesture(TapGesture(count: 2).onEnded { if !tile.blank { enlarged = tile.slide } })
            HStack(spacing: 6) {
                if let number = tile.number {
                    Text("\(number)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(tile.caption).font(.caption2).lineLimit(1)
                Spacer(minLength: 0)
                Text(tile.extra).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private struct TileMenuBacking: NSViewRepresentable {
        let menu: () -> NSMenu?

        final class Backing: NSView {
            var menuSource: () -> NSMenu? = { nil }
            override func mouseDown(with event: NSEvent) {
                if event.modifierFlags.contains(.control) { rightMouseDown(with: event) } else { superview?.mouseDown(with: event) }
            }
            override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
            override func rightMouseDown(with event: NSEvent) {
                guard let menu = menuSource() else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            }

            override func isAccessibilityElement() -> Bool { true }
            override func accessibilityRole() -> NSAccessibility.Role? { .group }
            override func accessibilityLabel() -> String? { "Slide options" }
            override func accessibilityPerformShowMenu() -> Bool {
                guard let menu = menuSource() else { return false }
                menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
                return true
            }
        }

        func makeNSView(context: Context) -> Backing {
            let view = Backing()
            view.menuSource = menu
            return view
        }

        func updateNSView(_ view: Backing, context: Context) { view.menuSource = menu }
    }

    @ViewBuilder
    private func pendingMediaFace(_ slide: Slide) -> some View {
        if let cue = slide.background, let key = NoteMedia.key(ofPendingId: cue.mediaId) {
            if cue.layer != .videos {
                NotePictureFace(key: key, mode: cue.scaleMode)
            } else {
                mediaPlaceholder("film", "Video comes in on Create")
            }
        }
    }

    private struct NotePictureFace: View {
        let key: String
        let mode: MediaScaleMode?
        @ObservedObject private var images = NoteImageStore.shared

        var body: some View {
            if let image = images.image(for: key) {
                ScaledPicture(image: Image(nsImage: image), mode: mode)
            } else {
                Color.black
            }
        }
    }

    private func mediaPlaceholder(_ symbol: String, _ text: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(text).font(.caption2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(6)
        }
    }

    static func scaleTitle(_ mode: MediaScaleMode) -> String {
        switch mode {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        case .scaleAndBlur: "Scale and Blur"
        }
    }

    private func kindMenuExtras(group: String, type: String?) -> [NSMenuItem] {
        let options = choices[group]?.options ?? designMap.options
        func set(_ change: @escaping (inout SlideOptions) -> Void) {
            var next = choices[group]?.options ?? designMap.options
            change(&next)
            choices[group, default: RowChoice()].options = next
            rebuildPreview()
        }
        func header(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }
        switch type {
        case NoteSlideMarks.SlideType.picture.rawValue:

            let current = preview?.rows.first { $0.groupId == group }?.shownScale ?? options.pictureScale
            var items = [header("Scale")] + [MediaScaleMode.scaleAndBlur, .fit, .fill, .stretch].map { mode in
                ClosureMenuItem(Self.scaleTitle(mode), checked: current == mode, indent: 1) {
                    choices[group, default: RowChoice()].scaleChosen = true
                    set { $0.pictureScale = mode }
                }
            }

            if (plannedGroups.first { $0.id == group }?.media.count ?? 0) > 1 {
                items += [.separator(), header("Several Pictures")] + [false, true].map { together in
                    ClosureMenuItem(together ? "Together" : "One slide each", checked: options.picturesTogether == together, indent: 1) {
                        set { $0.picturesTogether = together }
                    }
                }
            }
            return items
        case NoteSlideMarks.SlideType.video.rawValue:
            return [header("When It Ends")] + SlideOptions.VideoEnd.allCases.map { end in
                ClosureMenuItem(end.title, checked: options.videoEnd == end, indent: 1) { set { $0.videoEnd = end } }
            }
        case SlideKind.media.rawValue:

            return []
        default:

            let row = preview?.rows.first { $0.groupId == group }
            let kind = choices[group]?.kind ?? row?.kind ?? .body
            var items: [NSMenuItem] = []
            var splitsByBox = true
            if let own = row?.ownType, let index = options.ownTypes.firstIndex(where: { $0.name == own }) {
                splitsByBox = options.ownTypes[index].split == .fitToBox
                items += [header("Split")] + SlideOptions.OwnType.Split.allCases.map { split in
                    ClosureMenuItem(split.title, checked: options.ownTypes[index].split == split, indent: 1) { set { $0.ownTypes[index].split = split } }
                }
                items += [.separator(), ClosureMenuItem("Reveal one line per click", checked: options.ownTypes[index].reveal) { set { $0.ownTypes[index].reveal.toggle() } }]
            } else if kind == .scripture {
                items += [header("Split")] + SlideOptions.ScriptureSplit.allCases.map { split in
                    ClosureMenuItem(split == .oneVerse ? "One verse per slide" : "Fit to box", checked: options.scriptureSplit == split, indent: 1) { set { $0.scriptureSplit = split } }
                }
                items += [.separator(), ClosureMenuItem("Show verse numbers", checked: options.verseNumbers) { set { $0.verseNumbers.toggle() } }]
            } else if kind == .points {
                items.append(ClosureMenuItem("Reveal one point per click", checked: options.revealPoints) { set { $0.revealPoints.toggle() } })
            }
            if splitsByBox, kind != .title {
                items.append(linesPerSlideItem(group: group))
            }
            items.append(designItem(group: group, kind: kind))

            if kind != .lyrics, let text = plannedGroups.first(where: { $0.id == group })?.text,
               !DeterministicSlidePlanner.asideRanges(in: text).isEmpty {
                items += [.separator(), header("Words in (Parentheses)")] + [true, false].map { toNotes in
                    ClosureMenuItem(toNotes ? "Slide Notes" : "On the Slide", checked: options.parenthesesToNotes == toNotes, indent: 1) {
                        set { $0.parenthesesToNotes = toNotes }
                    }
                }
            }
            return items
        }
    }

    private func linesPerSlideItem(group: String) -> NSMenuItem {
        let current = choices[group]?.lines
        func pick(_ lines: Int?) { choices[group, default: RowChoice()].lines = lines }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Automatic", checked: current == nil) { pick(nil) })
        menu.addItem(.separator())
        for lines in 1...6 {
            menu.addItem(ClosureMenuItem(lines == 1 ? "1 line" : "\(lines) lines", checked: current == lines) { pick(lines) })
        }
        let item = NSMenuItem(title: "Lines per Slide", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func designItem(group: String, kind: SlideKind) -> NSMenuItem {
        let chosen = choices[group].flatMap { choice in
            choice.themeId.flatMap { themeId in choice.design.map { SlideDesignMap.Entry(themeId: themeId, themeSlideName: $0) } }
        }
        func pick(themeId: String?, design: String?) {
            choices[group, default: RowChoice()].themeId = themeId
            choices[group, default: RowChoice()].design = design
        }
        return ClosureMenuItem(chosen.map { "Design: \($0.themeSlideName)…" } ?? "Design…") {
            designPick = DesignPick(
                current: chosen, scope: "Applies to this passage only.", automatic: "Automatic",
                photoSpotsOnly: kind == .picture
            ) { pick(themeId: $0?.themeId, design: $0?.themeSlideName) }
        }
    }

    private func scheduleRebuild() {
        rebuildDebounce?.cancel()
        rebuildDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            rebuildPreview()
        }
    }

    private var blankBadge: some View {
        Text("Blank")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
    }

    private func existingSlidePosition(_ slideId: String) -> Int? {
        preview?.positions[slideId]
    }

    private var createCount: Int {
        guard let preview else { return 0 }
        let counted = countedIds
        return preview.presentation.slides.filter { slide in
            preview.built.group(of: slide.id).map { counted.contains($0) && madeSlideIds[$0] == nil } ?? false
        }.count
    }

    private var footer: some View {
        HStack(spacing: 10) {
            targetDetails
            if preview != nil {
                let madeCount = groups.filter { madeSlideIds[$0.id] != nil }.count
                VStack(alignment: .leading, spacing: 2) {
                    if madeCount > 0 {
                        Text("Updates the \(madeCount) \(madeCount == 1 ? "passage" : "passages") that already have slides.")
                    }
                    if let mediaLine { Text(mediaLine) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)

            Menu {
                Button("Create and Open in Editor") { create(openEditor: true) }
            } label: {
                Text(createCount > 0 ? "Create \(createCount) \(createCount == 1 ? "Slide" : "Slides")"
                     : (groups.contains { madeSlideIds[$0.id] != nil } ? "Update Slides" : "Create Slides"))
            } primaryAction: {
                create()
            }
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding(10)
    }

    private func close() {
        if let workingBody, workingBody != body_ { onClose?(workingBody) }
        dismiss()
    }

    private var canCreate: Bool {
        guard decksFilled, let preview, !preview.presentation.slides.isEmpty || groups.contains(where: { madeSlideIds[$0.id] != nil }) else { return false }
        switch target {
        case .new: return true
        case .existing: return existingId != nil
        }
    }

    private func pictureAspects(mediaIds: [String: String]) -> [String: Double] {
        var aspects = appModel.pictureAspects(mediaIds)
        for key in plannedGroups.flatMap(\.media) where aspects[key] == nil && !key.hasPrefix("hex:") {
            if let size = NoteImageStore.shared.image(for: key)?.size, size.height > 0 { aspects[key] = size.width / size.height }
        }
        let waiting = plannedGroups.flatMap(\.media).contains { aspects[$0] == nil && !$0.hasPrefix("hex:") }
        if waiting != waitingForPictures { waitingForPictures = waiting }
        return aspects
    }

    private func rebuildPreview() {
        let deckThemeId = deckThemeId
        var rows: [SlideRow] = []
        var rowThemeIds: [String: String] = [:]
        let map = designMap

        let mediaIds = appModel.noteMediaIds(mediaImports)
        let aspects = pictureAspects(mediaIds: mediaIds)
        for group in plannedGroups {
            let choice = choices[group.id] ?? RowChoice()

            var themeId = choice.themeId ?? (deckThemeId.isEmpty ? newThemeId : deckThemeId)
            var design = choice.design

            if choice.themeId == nil, choice.design == nil,
               let key = choice.kind?.rawValue ?? planner.plan([group], theme: appModel.theme(themeId), overrides: [:]).rows.first?.typeKey,
               let entry = map.entry(forType: key), appModel.theme(entry.themeId) != nil {
                themeId = entry.themeId
                design = entry.themeSlideName
            }
            let theme = appModel.theme(themeId)
            let override = SlideRowOverride(kind: choice.kind, themeSlideName: design, linesPerSlide: choice.lines)
            let rowPlanner = DeterministicSlidePlanner(
                options: choice.options ?? map.options, pictureAspects: aspects, pictureScaleChosen: choice.scaleChosen)
            if let row = rowPlanner.plan([group], theme: theme, overrides: [group.id: override]).rows.first {
                rows.append(row)
                if themeId != deckThemeId, !themeId.isEmpty { rowThemeIds[group.id] = themeId }
            }
        }

        var blanks: [String: BlankPlacement] = [:]
        for group in plannedGroups {
            let placement = choices[group.id]?.blanks ?? map.blanks
            if placement != .none { blanks[group.id] = placement }
        }
        var built = NoteSlideBuilder.build(
            SlidePlan(rows: rows), blanks: blanks, blank: blankStyle(map, deckThemeId: deckThemeId), options: map.options,
            media: { mediaIds[$0] })
        NoteSlideBuilder.attachingSwitches(
            to: &built, rows: rows, settings: map,
            overrides: choices.mapValues(\.preset))

        for index in built.slides.indices {
            if let group = built.groupBySlideId[built.slides[index].id], let own = rowThemeIds[group] {
                built.slides[index].themeId = own
            }
        }
        NoteSlideBuilder.attachingDesignActions(to: &built, deckThemeId: deckThemeId) { appModel.theme($0) }

        var looksByPreset: [String: [StreamLook]] = ["": streamLooks(forPreset: nil)]
        var rowPresetIds: [String: String] = [:]
        for group in plannedGroups {
            let first = built.slides.first { built.groupBySlideId[$0.id] == group.id }
            guard let presetId = actionRouter?.declaredPresetID(actions: first?.actions) else { continue }
            rowPresetIds[group.id] = presetId
            if looksByPreset[presetId] == nil { looksByPreset[presetId] = streamLooks(forPreset: presetId) }
        }

        for index in built.slides.indices {
            guard let group = built.groupBySlideId[built.slides[index].id] else { continue }
            for (themeId, design) in lookDesigns(group: group, rows: rows, looks: looksByPreset[rowPresetIds[group] ?? ""] ?? []) {
                built.slides[index].setOverrideDesign(design, forTheme: themeId)
            }
        }
        var presentation = Presentation(
            id: "make-slides-preview", name: newName, presentationKind: .deck,
            themeId: deckThemeId, slides: built.slides
        )
        presentation.sections = built.sections.isEmpty ? nil : built.sections

        if target == .existing, let deck = existingId.flatMap({ appModel.presentation($0) }) {
            presentation.canvasWidth = deck.canvasWidth
            presentation.canvasHeight = deck.canvasHeight
        }
        var next = Preview(presentation: presentation, rows: rows, built: built)
        let body = currentBody

        let stamped = Self.madeSlideIds(in: body)
        for group in plannedGroups {
            if let stamp = stamped[group.id] {
                let cards = NoteSlideUpdate.cards(afterGroup: group.id, in: body)
                let deckId = cards.first?.presentationId ?? existingId ?? linkedPresentationId
                let made = NoteSlideUpdate.madeSlides(
                    ids: madeSlideIds(of: group.id, cards: cards, stamped: stamp), deckId: deckId
                ) { appModel.presentation($0) }
                if made.isMade {
                    next.madeSlideIds[group.id] = stamp
                    next.decks[group.id] = deckId
                    next.positions.merge(made.positions) { _, new in new }
                } else {
                    next.deadCards[group.id] = Set(cards.compactMap(\.slideId))
                }
            }
        }
        next.looksByPreset = looksByPreset
        next.rowPresetIds = rowPresetIds
        preview = next
        previewStamp += 1
    }

    private func lookDesigns(group: String, rows: [SlideRow], looks: [StreamLook]) -> [String: String] {
        let kind = rows.first { $0.groupId == group }?.kind ?? .body
        return NoteSlideBuilder.lookDesigns(for: kind, looks: looks.map(\.theme), chosen: choices[group]?.lookDesigns ?? [:])
    }

    private func blankStyle(_ map: SlideDesignMap, deckThemeId: String) -> NoteSlideBuilder.BlankStyle {
        var style = NoteSlideBuilder.BlankStyle(actions: map.preset(for: .blank).map { [$0.action()] } ?? [])
        if let entry = map.entry(for: .blank), appModel.theme(entry.themeId) != nil {
            style.themeId = entry.themeId == deckThemeId ? nil : entry.themeId
            style.themeSlideName = entry.themeSlideName
        } else {
            style.themeSlideName = NoteSlideBuilder.designName(for: .blank, in: appModel.theme(deckThemeId))
        }
        return style
    }

    private struct CreateJob {
        struct DeckEdit {
            var updated: [Slide] = []
            var appends: [(after: String, slides: [Slide])] = []
            var blanks: [(after: String, slides: [Slide])] = []
            var removing: Set<String> = []
        }
        struct CardSync {
            var group: String
            var deckId: String
            var appended: [Slide]
            var removed: Set<String>
        }
        var body: NoteBody
        var edits: [String: DeckEdit] = [:]
        var cardSyncs: [CardSync] = []
        var newSlides: [Slide]
        var sections: [PresentationSection]
        var arrangement: Arrangement?
        var groupBySlideId: [String: String]
        var groupOrder: [String]
        var target: Target
        var existingId: String?
        var newName: String
        var newFolder: String
        var newThemeId: String
        var openEditor: Bool

        var createdDeckId: String?

        var deadCards: [String: Set<String>] = [:]
    }

    private func create(openEditor: Bool = false) {
        guard var job = createJob(openEditor: openEditor) else { return }
        dismiss()

        var editorDeck: String?
        if openEditor {
            switch job.target {
            case .new:
                if !job.newSlides.isEmpty, let id = appModel.createPresentation(
                    named: job.newName, folder: job.newFolder.isEmpty ? nil : job.newFolder,
                    themeId: job.newThemeId, slides: job.newSlides, sections: job.sections, arrangement: job.arrangement
                ) {
                    job.createdDeckId = id
                    editorDeck = id
                }
            case .existing:
                editorDeck = job.existingId
            }
            if let editorDeck {
                if job.edits[editorDeck] != nil || (job.target == .existing && !job.newSlides.isEmpty) {
                    appModel.decksBeingMade.insert(editorDeck)
                }
                onOpenEditor(editorDeck)
            }
        }

        let pending = job
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))

            let decks = Array(pending.edits.keys) + [pending.existingId, pending.createdDeckId].compactMap { $0 }
            _ = await appModel.presentationsFilled(decks)
            perform(pending)
            if let editorDeck, appModel.decksBeingMade.contains(editorDeck) {
                appModel.noteDeckRewritten(editorDeck)
            }
        }
    }

    private func createJob(openEditor: Bool) -> CreateJob? {
        guard let preview else { return nil }
        let built = preview.built
        let body = currentBody
        var job = CreateJob(
            body: body,
            newSlides: preview.presentation.slides.filter { slide in
                built.group(of: slide.id).map { countedIds.contains($0) && madeSlideIds[$0] == nil } ?? false
            },
            sections: [], arrangement: built.arrangement, groupBySlideId: built.groupBySlideId, groupOrder: groups.map(\.id),
            target: target, existingId: existingId, newName: newName.trimmingCharacters(in: .whitespaces),
            newFolder: newFolder, newThemeId: newThemeId, openEditor: openEditor)
        job.sections = built.sections.filter { section in job.newSlides.contains { $0.sectionId == section.id } }
        job.deadCards = preview.deadCards

        for group in groups {
            guard madeSlideIds[group.id] != nil, let row = preview.rows.first(where: { $0.groupId == group.id }) else { continue }
            let cards = NoteSlideUpdate.cards(afterGroup: group.id, in: body)
            guard let deckId = cards.first?.presentationId ?? preview.decks[group.id], let deck = appModel.heldPresentation(deckId) else { continue }
            let slides = madeSlideIds(of: group.id, cards: cards).compactMap { id in deck.slides.first { $0.id == id } }
            guard !slides.isEmpty else { continue }

            let restored: [Slide] = cards.isEmpty ? slides : []
            var result = NoteSlideUpdate.updating(slides, to: row)
            for index in result.updated.indices { result.updated[index].themeSlideName = row.themeSlideName ?? result.updated[index].themeSlideName }

            let choice = NoteSlideBuilder.presetChoice(forType: row.typeKey, override: (choices[group.id] ?? RowChoice()).preset, settings: designMap)
            result.updated = NoteSlideUpdate.applyingSwitch(choice, to: result.updated)
            result.appended = NoteSlideUpdate.applyingSwitch(choice, to: result.appended)

            let designs = lookDesigns(group: group.id, rows: preview.rows, looks: preview.looksByPreset[preview.rowPresetIds[group.id] ?? ""] ?? [])
            for index in result.updated.indices {
                for (themeId, design) in designs { result.updated[index].setOverrideDesign(design, forTheme: themeId) }
            }
            for index in result.appended.indices {
                for (themeId, design) in designs { result.appended[index].setOverrideDesign(design, forTheme: themeId) }
            }
            var edit = job.edits[deckId] ?? CreateJob.DeckEdit()
            edit.updated += result.updated
            edit.removing.formUnion(result.removedIds)
            if !result.appended.isEmpty, let last = (result.updated.last ?? slides.last)?.id {
                edit.appends.append((after: last, slides: result.appended))
            }

            let placement = (choices[group.id] ?? RowChoice()).blanks ?? designMap.blanks
            if placement != .none {
                let kept = result.updated + result.appended
                let anchors = placement == .afterPassage ? Array(kept.suffix(1)) : kept
                let style = blankStyle(designMap, deckThemeId: deck.themeId)
                for anchor in anchors {
                    if let index = deck.slides.firstIndex(where: { $0.id == anchor.id }) {
                        let next = index + 1 < deck.slides.count ? deck.slides[index + 1] : nil
                        if next.map(\.objects.isEmpty) ?? false { continue }
                    }
                    edit.blanks.append((after: anchor.id, slides: [NoteSlideBuilder.blankSlide(after: anchor, style: style)]))
                }
            }
            job.edits[deckId] = edit
            let restoredKept = restored.filter { !result.removedIds.contains($0.id) }
            job.cardSyncs.append(CreateJob.CardSync(group: group.id, deckId: deckId, appended: restoredKept + result.appended, removed: Set(result.removedIds)))
        }
        return job
    }

    private func perform(_ job: CreateJob) {
        var body = job.body

        var fresh: [String: Presentation] = [:]
        for (deckId, edit) in job.edits {
            fresh[deckId] = appModel.rewriteSlides(in: deckId) { presentation in
                let byId = Dictionary(edit.updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in presentation.slides.indices {
                    if let replacement = byId[presentation.slides[index].id] { presentation.slides[index] = replacement }
                }
                presentation.slides.removeAll { edit.removing.contains($0.id) }
                for insert in edit.appends + edit.blanks {
                    let at = presentation.slides.firstIndex { $0.id == insert.after }.map { $0 + 1 } ?? presentation.slides.count
                    presentation.slides.insert(contentsOf: insert.slides, at: at)
                }
            }
        }
        for sync in job.cardSyncs {
            guard let deck = fresh[sync.deckId] else { continue }
            let appended = sync.appended.compactMap { NoteSlides.dropRef(presentationId: sync.deckId, slideId: $0.id, presentation: { _ in deck }) }
            body = NoteSlideUpdate.syncingCards(afterGroup: sync.group, appending: appended, removing: sync.removed, in: body)
        }

        var presentationId: String? = job.target == .existing ? job.existingId : nil
        var isNew = false
        if let created = job.createdDeckId {
            presentationId = created
            isNew = true
        } else if !job.newSlides.isEmpty {
            switch job.target {
            case .new:
                guard let id = appModel.createPresentation(
                    named: job.newName, folder: job.newFolder.isEmpty ? nil : job.newFolder,
                    themeId: job.newThemeId, slides: job.newSlides, sections: job.sections, arrangement: job.arrangement
                ) else { return }
                presentationId = id
                isNew = true
            case .existing:
                guard let id = job.existingId, appModel.appendSlides(job.newSlides, sections: job.sections, to: id) else { return }
                presentationId = id
            }
        }
        if !job.newSlides.isEmpty {
            if let presentationId, let deck = appModel.heldPresentation(presentationId) {
                var byGroup: [String: [NoteSlideRef]] = [:]
                for slide in job.newSlides {
                    guard let group = job.groupBySlideId[slide.id],
                          let ref = NoteSlides.dropRef(presentationId: presentationId, slideId: slide.id, presentation: { _ in deck })
                    else { continue }
                    byGroup[group, default: []].append(ref)
                }
                let made = job.groupOrder.compactMap { group in byGroup[group].map { (groupId: group, refs: $0) } }

                for (group, dead) in job.deadCards where byGroup[group] != nil {
                    body = NoteSlideUpdate.syncingCards(afterGroup: group, appending: [], removing: dead, in: body)
                }
                body = NoteSlideMarks.placingMadeSlides(made, in: body)
            }
        }
        onCreated(presentationId ?? linkedPresentationId ?? "", isNew, body)
    }
}
