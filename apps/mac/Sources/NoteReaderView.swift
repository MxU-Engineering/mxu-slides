import AppKit
import PresenterCore
import SwiftUI

enum NoteReaderHost: String {
    case library
    case window

    case panel

    case center

    case editor
}

@MainActor
@Observable
final class NoteEditorActions {
    var makeSlides: (() -> Void)?
    var setDisplay: ((NoteSlideDisplay) -> Void)?
    var display: NoteSlideDisplay = .full

    private(set) var note: NoteDocument?
    private(set) var noteLoads = 0

    func noteLoaded(_ note: NoteDocument?) {
        self.note = note
        noteLoads += 1
    }
}

enum CenterNoteMode {
    static func key(_ presentationID: String) -> String { "present.centerNote.\(presentationID)" }
    static func isNote(_ presentationID: String) -> Bool { UserDefaults.standard.bool(forKey: key(presentationID)) }
    static func set(_ note: Bool, _ presentationID: String) { UserDefaults.standard.set(note, forKey: key(presentationID)) }
}

struct CenterNoteSwitch: View {
    let model: AppModel
    let presentationID: String
    @Binding var showsNote: Bool

    var body: some View {
        if model.noteID(linkedToPresentation: presentationID) != nil {
            Picker("", selection: $showsNote) {
                Text("Slides").tag(false)
                Text("Note").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Run this deck from its slides or from the note they were made from")
        }
    }
}

struct NoteReaderView: View {
    let model: AppModel
    let noteID: String
    let host: NoteReaderHost

    var onBack: (() -> Void)? = nil

    var layout: PresentLayoutController? = nil

    var render: RenderContext? = nil
    var controls: ServiceControls? = nil

    var fitsContent: Bool = false

    @Environment(\.openWindow) private var openWindow
    @Environment(\.runOnly) private var runOnly
    @AppStorage("notes.fontSize.library") private var libraryFontSize = 13.0
    @AppStorage("notes.fontSize.window") private var windowFontSize = 16.0
    @AppStorage("notes.fontSize.panel") private var panelFontSize = 15.0
    @AppStorage("notes.fontSize.center") private var centerFontSize = 16.0
    @AppStorage("notes.fontSize.editor") private var editorFontSize = 16.0

    var editorActions: NoteEditorActions? = nil
    @State private var note: NoteDocument?

    @State private var carded: NoteBody?

    @State private var query = ""
    @State private var findVisible = false
    @State private var matchCursor = 0
    @FocusState private var findFocused: Bool
    @StateObject private var live = NoteSlideLive()
    @State private var scroller = NoteDocumentScroller()

    @State private var renameText: String?

    @State private var locked = false

    @State private var editingInPresent = false
    @State private var follow = NoteFollowModel()
    @State private var followScroller = NoteFollowScroller()
    @State private var noteLoads = 0
    @State private var insertingSlide = false
    @State private var insertDeckID: String?

    @State private var slideDisplay: NoteSlideDisplay = .full

    @State private var foldedPanels: Set<String> = []

    @State private var makingSlides = false

    @State private var shelfDeck: Presentation?
    @State private var shelf: [(number: Int, slide: Slide)] = []

    @State private var passages = NotePassagesMemo()

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue
    @StateObject private var metrics = NoteLayoutMetrics()

    private var fontSize: Double {
        switch host {
        case .library: libraryFontSize
        case .window: windowFontSize
        case .panel: panelFontSize
        case .center: centerFontSize
        case .editor: editorFontSize
        }
    }

    private func setFontSize(_ size: Double) {
        let clamped = min(28, max(10, size))
        switch host {
        case .library: libraryFontSize = clamped
        case .window: windowFontSize = clamped
        case .panel: panelFontSize = clamped
        case .center: centerFontSize = clamped
        case .editor: editorFontSize = clamped
        }
    }

    private var body_: NoteBody { carded ?? note?.body ?? NoteBody(blocks: [], plainText: "") }

    private var shown: NoteBody { body_ }
    private var matches: [NoteReading.Match] { NoteReading.matches(in: shown, query: query) }
    private var outline: [NoteReading.OutlineEntry] { NoteReading.outline(shown) }

    private var followHost: Bool { host == .panel || host == .center }

    private var followsAlong: Bool { followHost && !editingInPresent }

    private var editable: Bool {
        (followHost ? editingInPresent : !locked) && !runOnly && note != nil && slideDisplay != .hidden
            && slideDisplay != .slidesOnly && foldedPanels.isEmpty
    }

    var body: some View {
        let version = model.version(of: .note)
        let liveSlideID = controls?.liveSlideID
        VStack(spacing: 0) {
            header
            if findVisible { findBar }
            Divider()
            Group {
            if followsAlong {
                NoteFollowAlongView(
                    model: model, render: render, controls: controls, follow: follow,
                    fontSize: fontSize, query: findVisible ? query : "", fitsContent: fitsContent,
                    live: live, scroller: followScroller)
                .equatable()
            } else {
            NoteDocumentView(
                body: shown, style: style, query: findVisible ? query : "",
                slides: slideContext(liveSlideID: liveSlideID),
                live: live, scroller: scroller,
                maxLineWidth: host == .library ? nil : (host == .editor ? 820 : 720),
                editable: editable,
                onEdit: { edited in
                    let saved = NoteLiveUpdates.savedBody(edited, deckId: note?.presentationId)
                    carded = edited
                    note?.body = saved
                    model.recordNoteEdit(noteID, body: saved)
                },
                slideRefForDrop: { presentationId, slideId in
                    NoteSlides.handRef(presentationId: presentationId, slideId: slideId) { model.presentation($0) }
                },
                slideRefForPaste: { afterSlideId in pasteSlide(after: afterSlideId) },
                onMakeSlides: { makingSlides = true },
                onFoldPanel: { id in toggleFold(id) },
                onInsertSlideHere: editable ? {
                    if insertDeckID == nil { insertDeckID = servicePresentations.first?.id }
                    insertingSlide = true
                } : nil,
                fitsContent: fitsContent, metrics: metrics,
                marksInMargin: host != .library)
            .frame(height: fitsContent && metrics.contentHeight > 0 ? metrics.contentHeight : nil)
            .padding(.horizontal, (host == .library ? 12 : 20) - NoteDocumentTextView.gutter)
            .overlay(alignment: .topLeading) {
                if editable, shown.blocks.allSatisfy({ $0.type == .paragraph && NoteReading.text(of: $0).trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text("Paste your notes, or start typing… Make Slides can import a Word, PDF or text file.")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, host == .library ? 12 : 20)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            }
            }
            .onChange(of: matchCursor) { _, cursor in jump(toMatch: cursor) }
            .onChange(of: query) { _, _ in
                matchCursor = 0
                jump(toMatch: 0)
            }
            .onChange(of: liveSlideID) { _, slideID in
                live.slideID = slideID

                guard !editable, let slideID else { return }
                if followsAlong {
                    if let line = follow.lineBySlide[slideID] { followScroller.scrollTo?(line) }
                } else if let target = NoteSlides.blockIndex(ofLiveSlide: slideID, in: shown) {
                    scroller.scroll(toBlock: target)
                }
            }
            .onAppear { live.slideID = liveSlideID }
            if !followsAlong { unplacedShelf }
        }
        .task(id: NoteFollowKey(deck: NoteDeckKey(deck: note?.presentationId.flatMap { $0.isEmpty ? nil : model.presentation($0) }, noteVersion: version), loads: noteLoads, follows: followsAlong)) {
            guard followsAlong else { return }
            rebuildFollow()
        }
        .task(id: NoteDeckKey(deck: note?.presentationId.flatMap { $0.isEmpty ? nil : model.presentation($0) }, noteVersion: version)) {
            guard let deckID = note?.presentationId, !deckID.isEmpty, let deck = model.presentation(deckID) else {
                shelfDeck = nil
                shelf = []
                carded = nil
                return
            }
            shelfDeck = deck
            if let saved = note?.body { carded = NoteLiveUpdates.displayBody(saved, memory: note?.madePassages ?? [], deck: deck) }
            let unplaced = Set(NoteDeckCards.unplaced(deck: deck, in: body_).map(\.id))
            shelf = deck.slides.enumerated().filter { unplaced.contains($0.element.id) }.map { (number: $0.offset + 1, slide: $0.element) }
        }
        .onAppear {
            guard let actions = editorActions else { return }
            actions.makeSlides = { makingSlides = true }
            actions.setDisplay = { display in
                slideDisplay = display
                UserDefaults.standard.set(display.rawValue, forKey: Self.slideDisplayKey(noteID))
            }
        }
        .onChange(of: slideDisplay) { _, display in editorActions?.display = display }
        .task(id: "\(noteID):\(version)") {
            let loaded = try? await model.client.loadValue(NoteDocument.self, id: noteID)
            if !Task.isCancelled {
                note = loaded
                carded = note?.body.map { body in
                    NoteLiveUpdates.displayBody(
                        body, memory: loaded?.madePassages ?? [],
                        deck: loaded?.presentationId.flatMap { $0.isEmpty ? nil : model.presentation($0) })
                }
                noteLoads += 1
                editorActions?.noteLoaded(loaded)
                locked = UserDefaults.standard.bool(forKey: Self.lockKey(noteID))
                slideDisplay = UserDefaults.standard.string(forKey: Self.slideDisplayKey(noteID))
                    .flatMap(NoteSlideDisplay.init(rawValue:)) ?? .full
                foldedPanels = Set(UserDefaults.standard.stringArray(forKey: Self.foldedPanelsKey(noteID)) ?? [])
            }
        }
    }

    private var style: NoteReaderStyle {
        NoteReaderStyle(
            fontSize: fontSize, compact: host == .library, slideDisplay: slideDisplay,
            panelLayout: NotePanelMetrics.layout(column: metrics.columnWidth), foldedPanels: foldedPanels,
            pictureWidth: NotePanelMetrics.pictureWidth(column: metrics.columnWidth))
    }

    static func foldedPanelsKey(_ noteID: String) -> String { "notes.foldedPanels.\(noteID)" }

    private func toggleFold(_ panelID: String) {
        if foldedPanels.contains(panelID) { foldedPanels.remove(panelID) } else { foldedPanels.insert(panelID) }
        UserDefaults.standard.set(Array(foldedPanels).sorted(), forKey: Self.foldedPanelsKey(noteID))
    }

    private func slideContext(liveSlideID: String?) -> NoteSlideContext {
        let waiting = Set((model.liveUpdates[noteID]?.updates ?? []).compactMap(\.slideId))
        return NoteSlideContext(
            model: model, render: render, controls: controls, liveSlideID: liveSlideID,
            isBehind: { ref in ref.slideId.map(waiting.contains) ?? false },
            updateFromNote: { _ in model.reviewingNoteID = noteID },
            makeSlides: editable ? { makingSlides = true } : nil)
    }

    private func passage(of ref: NoteSlideRef) -> (group: MarkedGroup, slides: [Slide], theme: Theme?, deck: Presentation)? {
        var result: (group: MarkedGroup, slides: [Slide], theme: Theme?, deck: Presentation)?
        if let slideId = ref.slideId, let deck = ref.presentationId.flatMap({ model.presentation($0) }),
           let found = passages.passages(for: body_).passage(containingSlide: slideId) {
            let slides = found.cards.compactMap { card in deck.slides.first { $0.id == card.slideId } }
            if let first = slides.first {
                result = (found.group, slides, model.theme(for: first, in: deck), deck)
            }
        }
        return result
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to Notes")
            }
            Text(note?.name ?? "Note")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !outline.isEmpty {
                Menu {
                    ForEach(outline) { entry in
                        Button {
                            scroll(toBlock: entry.blockIndex)
                        } label: {
                            Text(String(repeating: "    ", count: max(0, entry.level - 1)) + entry.title)
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Outline")
            }
            if editable {
                Button {
                    if insertDeckID == nil { insertDeckID = servicePresentations.first?.id }
                    insertingSlide.toggle()
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.system(size: 12))
                        .foregroundStyle(insertingSlide ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Insert a slide at the cursor")
                .popover(isPresented: $insertingSlide, arrowEdge: .bottom) { insertSlidePopover }

                let marked = passages.passages(for: body_).groups.count
                Button {
                    makingSlides = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12))
                        if marked > 0 {
                            Text("\(marked)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                    }
                    .foregroundStyle(marked > 0 ? Color.accentColor : Color.secondary)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(marked > 0 ? "Make Slides from the \(marked) \(marked == 1 ? "passage" : "passages") chosen as slides" : "Make Slides: choose text as Will Be Slide first")
                .sheet(isPresented: $makingSlides) {
                    MakeSlidesSheet(
                        appModel: model, render: render, noteName: note?.name ?? "Note",
                        body_: body_, linkedPresentationId: note?.presentationId,
                        memory: note?.madePassages ?? [], mediaImports: note?.mediaImports ?? []
                    ) { presentationId, isNew, placed in
                        scroller.replaceBody(
                            with: placed,
                            slides: slideContext(liveSlideID: live.slideID),
                            live: live)
                        if isNew || note?.presentationId == nil {
                            note?.presentationId = presentationId
                            model.linkNote(noteID, toPresentation: presentationId, body: placed)
                        } else {
                            model.rememberMadePassages(noteID: noteID, body: placed, presentationId: presentationId)
                        }

                        Task {
                            let remembered = await model.importNoteMedia(noteID: noteID, body: placed)
                            if !presentationId.isEmpty { model.fillNoteMediaSlides(in: presentationId, remembered: remembered) }
                        }
                    } onOpenEditor: { presentationId in
                        model.selectedSection = .presentations
                        model.selectedEntryID = presentationId
                        appModeRaw = AppMode.edit.rawValue
                    } onClose: { edited in
                        scroller.replaceBody(with: edited, slides: slideContext(liveSlideID: live.slideID), live: live)
                    }
                }
                Menu {
                    Section("Text") {
                        Button("Body") { scroller.setBlockKind(.paragraph) }
                        Button("Heading 1") { scroller.setBlockKind(.heading(level: 1)) }
                        Button("Heading 2") { scroller.setBlockKind(.heading(level: 2)) }
                        Button("Heading 3") { scroller.setBlockKind(.heading(level: 3)) }
                    }
                    Section("Lists") {
                        Button("Bullet List") { scroller.setBlockKind(.listItem(ordered: false, depth: 0)) }
                        Button("Numbered List") { scroller.setBlockKind(.listItem(ordered: true, depth: 0)) }
                        Button("Checklist") { scroller.setBlockKind(.taskItem(checked: false, depth: 0)) }
                    }
                    Section("Blocks") {
                        Button("Quote") { scroller.setBlockKind(.quote(depth: 0)) }
                        Button("Code") { scroller.setBlockKind(.code(language: nil)) }
                        Button("Divider") { scroller.setBlockKind(.rule) }
                    }
                    if !markerIndexes.isEmpty {
                        PlaceSlidesMenu(model: model, markerCount: markerIndexes.count) { placeSlides(from: $0) }
                    }
                    Section("Marks") {
                        Button("Bold") { scroller.toggleMark(.bold) }
                        Button("Italic") { scroller.toggleMark(.italic) }
                        Button("Underline") { scroller.toggleMark(.underline) }.keyboardShortcut("u", modifiers: .command)
                        Button("Strikethrough") { scroller.toggleMark(.strike) }
                        Button("Highlight") { scroller.toggleMark(.highlight) }
                    }
                    Section("Slides") {
                        Menu("Will Be Slide") {
                            Button("Slide") { scroller.markWillBeSlide(type: nil) }
                                .keyboardShortcut("s", modifiers: [.command, .option])
                            Divider()
                            ForEach(NoteSlideMarks.SlideType.textKinds, id: \.rawValue) { type in
                                Button(type.label) { scroller.markWillBeSlide(type: type.rawValue) }
                            }
                        }
                        Button("Remove from slides") { scroller.unmarkWillBeSlide() }
                    }
                } label: {
                    Image(systemName: "textformat")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Format")
            }
            if !runOnly, followHost, note != nil {
                Button(editingInPresent ? "Done" : "Edit") { editingInPresent.toggle() }
                    .font(.caption)
                    .controlSize(.small)
                    .help(editingInPresent ? "Back to following the slides" : "Edit the note's text and its slides")
            } else if !runOnly, note != nil {
                Button {
                    locked.toggle()
                    UserDefaults.standard.set(locked, forKey: Self.lockKey(noteID))
                } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 12))
                        .foregroundStyle(locked ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(locked ? "Locked: read only. Click to edit." : "Editing. Click to lock.")
            }
            Button {
                findVisible.toggle()
                if findVisible { findFocused = true } else { query = "" }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(findVisible ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Find in note")
            Menu {
                Button("Smaller Text") { setFontSize(fontSize - 1) }
                Button("Larger Text") { setFontSize(fontSize + 1) }
                if !followsAlong {
                    Picker("In-line Slides", selection: $slideDisplay) {
                        ForEach(NoteSlideDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: slideDisplay) { _, display in
                        UserDefaults.standard.set(display.rawValue, forKey: Self.slideDisplayKey(noteID))
                    }
                }
                Divider()
                if !runOnly, let note {
                    Button("Rename\u{2026}") { renameText = note.name }
                }
                if host != .window, !runOnly {
                    Button("Pop Out") { openWindow(id: "note", value: noteID) }
                }
                if host != .editor, !runOnly {
                    Button("Open in Editor") {
                        model.openInEditor(entryID: noteID)
                        appModeRaw = AppMode.edit.rawValue
                    }
                }
                if let layout, !runOnly {
                    Divider()
                    if host != .panel || layout.notesPanel != .beside {
                        Button("Show Beside Slides") { place(.beside, layout) }
                    }
                    if host != .panel || layout.notesPanel != .below {
                        Button("Show Below Slides") { place(.below, layout) }
                    }
                    if host == .panel {
                        Button("Hide Panel") { layout.hideNotesPanel() }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .alert("Rename", isPresented: Binding(get: { renameText != nil }, set: { if !$0 { renameText = nil } })) {
            TextField("Name", text: Binding(get: { renameText ?? "" }, set: { renameText = $0 }))
            Button("Rename") {
                if let entry = model.libraryEntry(noteID), let renameText { model.rename(entry, to: renameText) }
                renameText = nil
            }
            Button("Cancel", role: .cancel) { renameText = nil }
        }
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($findFocused)
                .onSubmit { step(1) }
            Text(matches.isEmpty ? (query.isEmpty ? "" : "0") : "\(matchCursor + 1) of \(matches.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { step(-1) } label: { Image(systemName: "chevron.up").imageScale(.small) }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
            Button { step(1) } label: { Image(systemName: "chevron.down").imageScale(.small) }
                .buttonStyle(.plain)
                .disabled(matches.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func place(_ placement: PresentLayoutController.NotesPanelPlacement, _ layout: PresentLayoutController) {
        layout.showNotesPanel(placement, noteID: noteID)
        if host == .library { onBack?() }
    }

    private func jump(toMatch cursor: Int) {
        guard matches.indices.contains(cursor) else { return }
        let match = matches[cursor]
        let occurrence = matches[..<cursor].filter { $0.blockIndex == match.blockIndex }.count
        if followsAlong {
            scroll(toBlock: match.blockIndex)
        } else {
            scroller.scroll(toBlock: match.blockIndex, selectNeedle: query, occurrence: occurrence)
        }
    }

    private func scroll(toBlock index: Int) {
        if followsAlong {
            if let line = follow.lineByBlock[index] { followScroller.scrollTo?(line) }
        } else {
            scroller.scroll(toBlock: index)
        }
    }

    private func rebuildFollow() {
        let options = model.slideBuilding.slideDesignMap.options
        let deck = note?.presentationId.flatMap { $0.isEmpty ? nil : model.presentation($0) }
        var decks: [String: Presentation] = [:]
        if let deck { decks[deck.id] = deck }
        func lookup(_ slot: NoteFollowAlong.Slot) -> (Presentation, Int)? {
            if decks[slot.presentationId] == nil, let other = model.presentation(slot.presentationId) { decks[other.id] = other }
            guard let held = decks[slot.presentationId], let index = held.slides.firstIndex(where: { $0.id == slot.slideId }) else { return nil }
            return (held, index)
        }
        let body = shown
        let items = NoteFollowAlong.items(
            body: body, deck: deck, memory: note?.madePassages ?? [],
            slide: { slot in lookup(slot).map { $0.0.slides[$0.1] } },
            replan: { group, slides in
                guard let first = slides.first, let held = deck ?? decks.values.first else { return nil }
                return NoteSlideUpdate.replan(group, like: slides, theme: model.theme(for: first, in: held), options: options)
            })
        var slides: [String: NoteFollowSlide] = [:]
        for slot in items.flatMap(\.slots) {
            if let (held, index) = lookup(slot) {
                let slide = held.slides[index]
                slides[slot.slideId] = NoteFollowSlide(deck: held, slide: slide, number: index + 1, isBlank: NoteFollowAlong.isBlank(slide))
            }
        }
        let index = NoteFollowAlong.lineIndex(items)
        follow = NoteFollowModel(
            version: follow.version + 1, body: body, lines: NoteFollowAlong.lines(items), slides: slides,
            lineBySlide: index.bySlide, lineByBlock: index.byBlock,
            passages: items.compactMap { item in
                if case .passage(_, _, let blocks, let rows) = item { (blocks, rows) } else { nil }
            })
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchCursor = (matchCursor + delta + matches.count) % matches.count
    }

    private static func lockKey(_ noteID: String) -> String { "notes.locked.\(noteID)" }
    static func slideDisplayKey(_ noteID: String) -> String { "notes.slideDisplay.\(noteID)" }

    private var markerIndexes: [Int] { NoteSlides.markerBlockIndexes(in: body_) }

    private var servicePresentations: [Presentation] { Self.servicePresentations(model) }

    static func servicePresentations(_ model: AppModel) -> [Presentation] {
        guard let serviceID = model.currentServiceID, let service = try? model.service(serviceID) else { return [] }
        var seen: Set<String> = []
        return service.items.compactMap { item in
            guard item.itemKind == .presentation, seen.insert(item.refId).inserted else { return nil }
            return model.presentation(item.refId)
        }
    }

    private func placeSlides(from presentation: Presentation) {
        let placed = NoteSlides.placeSlides(in: body_, from: presentation)
        guard placed != body_ else { return }

        scroller.replaceBody(
            with: placed,
            slides: slideContext(liveSlideID: live.slideID),
            live: live)
    }

    private func pasteSlide(after cardSlideId: String?) -> NoteSlideRef? {
        guard let deckID = note?.presentationId, !deckID.isEmpty,
              let deck = model.heldPresentation(deckID), let slide = SlidePasteboard.paste() else { return nil }
        let anchor = cardSlideId.flatMap { id in deck.slides.contains { $0.id == id } ? id : nil }
        model.insertSlide(deckID, slide: slide, afterSlideID: anchor, cardingNote: false)
        return NoteSlides.handRef(presentationId: deckID, slideId: slide.id) { model.presentation($0) }
    }

    @ViewBuilder private var unplacedShelf: some View {
        if let deck = shelfDeck, !shelf.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Not in this note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(shelf, id: \.slide.id) { entry in
                            VStack(spacing: 2) {
                                SlideThumbnailView(
                                    model: model, render: render, slide: entry.slide, presentation: deck,
                                    theme: model.theme(for: entry.slide, in: deck), arrangementId: nil,
                                    hideScopedBackgrounds: false)
                                .aspectRatio(SlideGridMetrics.tileAspect(for: deck), contentMode: .fit)
                                .frame(width: host == .library ? 72 : 96)
                                .clipShape(RoundedRectangle.standard(CornerStandard.element))
                                Text("\(entry.number)\(entry.slide.name.isEmpty ? "" : " · \(entry.slide.name)")")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .draggablePayload(editable ? "mxuslide::\(deck.id)::\(entry.slide.id)" : nil)
                            .help(editable ? "Drag into the note to place it" : "In the deck, not in this note")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var insertSlidePopover: some View {
        let decks = servicePresentations
        return VStack(alignment: .leading, spacing: 8) {
            Text("Insert Slide").font(.caption.weight(.semibold))
            if decks.isEmpty {
                Text("No presentations in the current service").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Presentation", selection: $insertDeckID) {
                    ForEach(decks, id: \.id) { deck in
                        Text("\(deck.name) (\(deck.slides.count))").tag(Optional(deck.id))
                    }
                }
                .labelsHidden()
                if let deck = decks.first(where: { $0.id == insertDeckID }) ?? decks.first {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                                Button {
                                    if let ref = NoteSlides.handRef(presentationId: deck.id, slideId: slide.id, presentation: { model.presentation($0) }) {
                                        scroller.insertSlide(ref)
                                    }
                                    insertingSlide = false
                                } label: {
                                    VStack(spacing: 2) {
                                        SlideThumbnailView(
                                            model: model, render: render, slide: slide, presentation: deck,
                                            theme: model.theme(for: slide, in: deck), arrangementId: nil,
                                            hideScopedBackgrounds: false)
                                        .aspectRatio(SlideGridMetrics.tileAspect(for: deck), contentMode: .fit)
                                        .clipShape(RoundedRectangle.standard(CornerStandard.element))
                                        Text("\(index + 1)\(slide.name.isEmpty ? "" : " · \(slide.name)")")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct NoteFollowKey: Equatable {
    let deck: NoteDeckKey
    let loads: Int
    let follows: Bool
}

struct NoteDeckKey: Equatable {
    let deck: Presentation?
    let noteVersion: Int
}

private struct PlaceSlidesMenu: View {
    let model: AppModel
    let markerCount: Int
    let place: (Presentation) -> Void

    var body: some View {
        Menu("Place Slides at Slide Markers (\(markerCount))") {
            let decks = NoteReaderView.servicePresentations(model)
            if decks.isEmpty {
                Text("No presentations in the current service")
            }
            ForEach(decks, id: \.id) { deck in
                Button("\(deck.name) (\(deck.slides.count) slides)") { place(deck) }
            }
        }
    }
}

enum NoteSlideDisplay: String, CaseIterable {
    case full, slidesOnly, compact, hidden

    var label: String {
        switch self {
        case .full: "Words and slides"
        case .slidesOnly: "Slides only"
        case .compact: "Chips"
        case .hidden: "Hidden"
        }
    }

    var drawsPanels: Bool { self == .full || self == .slidesOnly }
}

struct NoteReaderStyle: Equatable {
    var fontSize: Double
    var compact: Bool
    var slideDisplay: NoteSlideDisplay = .full

    var panelLayout: NotePanelLayout = .side

    var foldedPanels: Set<String> = []
    var pictureWidth: CGFloat = 180

    var editable = false

    func isFolded(_ panelID: String) -> Bool { slideDisplay == .slidesOnly || foldedPanels.contains(panelID) }

    func headingSize(_ level: Int) -> Double {
        switch level {
        case 1: fontSize * 1.6
        case 2: fontSize * 1.35
        default: fontSize * 1.15
        }
    }
}

struct NoteSlideContext {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    var liveSlideID: String?

    var isBehind: ((NoteSlideRef) -> Bool)? = nil
    var updateFromNote: ((NoteSlideRef) -> Void)? = nil

    var makeSlides: (() -> Void)? = nil

    func withLive(_ slideID: String?) -> NoteSlideContext {
        var copy = self
        copy.liveSlideID = slideID
        return copy
    }
}

struct NoteSlideCard: View {
    let slide: NoteSlideRef
    let style: NoteReaderStyle
    var context: NoteSlideContext? = nil

    var onChange: ((NoteSlideRef) -> Void)? = nil

    var onPreview: ((NoteSlideRef) -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var availableWidth: CGFloat? = nil

    var compact: Bool = false

    var panel: Bool = false
    @State private var dragStartWidth: CGFloat?

    private var cardWidth: CGFloat {
        let set = CGFloat(slide.width ?? 300)
        guard let availableWidth, availableWidth > 0 else { return set }
        return min(set, max(160, availableWidth))
    }

    private var resolution: NoteSlides.Resolution {
        guard let context else { return .notPresenter }
        return NoteSlides.resolve(slide) { context.model.presentation($0) }
    }

    private var behind: Bool { context?.isBehind?(slide) == true }

    private var behindDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .help("The notes changed this slide's words. Right-click: Review Changes from the Notes.")
    }

    var body: some View {
        resolvedCard
    }

    @ViewBuilder private var resolvedCard: some View {
        switch resolution {
        case .slide(let presentation, let slide, let index):
            presenterCard(presentation: presentation, slide: slide, index: index)
        case .missingPresentation:
            warningCard("Slide not in this library", detail: slide.presentationName)
        case .missingSlide(let presentation):
            warningCard("Slide no longer in \(presentation.name)", detail: slide.slideLabel ?? slide.slideText)
        case .notPresenter:
            textCard
        }
    }

    @ViewBuilder
    private func presenterCard(presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        if compact {
            compactChip(presentation: presentation, slide: fired, index: index)
        } else if panel {
            panelPicture(presentation: presentation, slide: fired, index: index)
        } else {
            fullCard(presentation: presentation, slide: fired, index: index)
        }
    }

    private func panelPicture(presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        let isLive = context?.liveSlideID == fired.id
        return VStack(alignment: .leading, spacing: 3) {
            if slide.showThumbnail != false, let context {
                tile(context, presentation: presentation, slide: fired, index: index)
            } else {
                Button {
                    fire(fired, in: presentation, index: index)
                } label: {
                    HStack(spacing: 6) {
                        if slide.showNumber != false {
                            Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if slide.showLabels != false, !fired.name.isEmpty {
                            Text(fired.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if isLive {
                            Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.green)
                        }
                        if behind { behindDot }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isLive ? "Live" : "Fire this slide")
            }
            if slide.showText == true {
                let text = fired.objects.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty {
                    Text(text).font(.system(size: style.fontSize * 0.85)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .overlay(alignment: .topTrailing) { if behind, slide.showThumbnail != false { behindDot.padding(6) } }
        .contextMenu { if onChange != nil { cardMenu(presentation: presentation, slide: fired, index: index) } }
    }

    private func compactChip(presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        let isLive = context?.liveSlideID == fired.id
        return Button {
            fire(fired, in: presentation, index: index)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                Text("Slide \(index + 1)").font(.caption2.weight(.semibold))
                if !fired.name.isEmpty {
                    Text(fired.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if isLive {
                    Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.green)
                }
                if behind { behindDot }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isLive ? Color.green.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(isLive ? Color.green : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isLive ? "Live" : "Fire this slide")
        .contextMenu { if onChange != nil { cardMenu(presentation: presentation, slide: fired, index: index) } }
    }

    private func fullCard(presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        let isLive = context?.liveSlideID == fired.id
        return VStack(alignment: .leading, spacing: 4) {
            if slide.showName != false {
                Text(presentation.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if slide.showThumbnail != false, let context {
                tile(context, presentation: presentation, slide: fired, index: index)
            } else {
                Button {
                    fire(fired, in: presentation, index: index)
                } label: {
                    HStack(spacing: 6) {
                        if isLive {
                            Text("LIVE").font(.caption2.weight(.bold)).foregroundStyle(.green)
                        }
                        if slide.showLabels != false, !fired.name.isEmpty {
                            Text(fired.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        if slide.showNumber != false {
                            Text("Slide \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isLive ? "Live" : "Fire this slide")
            }
            if slide.showText == true {
                let text = fired.objects.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
                if !text.isEmpty {
                    Text(text).font(.system(size: style.fontSize * 0.95)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .frame(width: cardWidth, alignment: .leading)
        .background(
            (isLive ? Color.green.opacity(0.08) : Color.primary.opacity(0.04)),
            in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(alignment: .bottomTrailing) { if onChange != nil { resizeHandle } }
        .overlay(alignment: .topTrailing) { if behind { behindDot.padding(6) } }
        .contextMenu { if onChange != nil { cardMenu(presentation: presentation, slide: fired, index: index) } }
    }

    private func tile(_ context: NoteSlideContext, presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        SlideTile(
            model: context.model, render: context.render,
            slide: fired, index: index, aspect: SlideGridMetrics.tileAspect(for: presentation),
            presentation: presentation, theme: context.model.theme(for: fired, in: presentation),
            arrangementId: nil, showsSectionLabel: true, controls: context.controls,
            roundedCorners: UserDefaults.standard.object(forKey: "slideGrid.roundedCorners") as? Bool ?? true,
            hideScopedBackgrounds: false,
            liveOverride: context.liveSlideID == fired.id
        ) {
            fire(fired, in: presentation, index: index)
        }
        .frame(width: tileWidth, height: tileWidth / SlideGridMetrics.tileAspect(for: presentation) + 4 + SlideGridMetrics.labelHeight)
    }

    private var tileWidth: CGFloat { panel ? (availableWidth ?? 180) : cardWidth - 16 }

    @ViewBuilder
    private func cardMenu(presentation: Presentation, slide fired: Slide, index: Int) -> some View {
        Button("Fire Slide") { fire(fired, in: presentation, index: index) }
        if behind, let review = context?.updateFromNote {
            Button("Review Changes from the Notes…") { review(slide) }
        }

        Section("Card") {
            Menu("Show") {
                Toggle("Thumbnail", isOn: flag(\.showThumbnail, default: true))
                Toggle("Slide Text", isOn: flag(\.showText, default: false))
                Toggle("Slide Label", isOn: flag(\.showLabels, default: true))
                Toggle("Presentation Name", isOn: flag(\.showName, default: false))
                Toggle("Slide Number", isOn: flag(\.showNumber, default: true))
            }
            if !panel {
                Menu("Card Size") {
                    Button("Small") { setWidth(220) }
                    Button("Medium") { setWidth(300) }
                    Button("Large") { setWidth(420) }
                    Button("Extra Large") { setWidth(560) }
                }
            }
        }
        if let context {
            Section("Words") {
                Toggle("Keep My Words", isOn: Binding(
                    get: { fired.keepWords == true },
                    set: { context.model.setKeepWords($0, presentationID: presentation.id, slideID: fired.id) }))
                if let history = fired.history, !history.isEmpty {
                    Menu("Previous Versions") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, version in
                            Button("\(version.reason) · \(Self.shortTime(version.at))") {
                                context.model.restoreSlideVersion(version, presentationID: presentation.id, slideID: fired.id)
                            }
                        }
                    }
                }
            }
        }
        Divider()
        Button("Remove Slide", role: .destructive) { onRemove?() }
    }

    static func shortTime(_ iso: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = ISO8601DateFormatter().date(from: iso) ?? fractional.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func flag(_ keyPath: WritableKeyPath<NoteSlideRef, Bool?>, default fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { slide[keyPath: keyPath] ?? fallback },
            set: { value in
                var changed = slide
                changed[keyPath: keyPath] = value
                onChange?(changed)
            })
    }

    private func setWidth(_ width: CGFloat, preview: Bool = false) {
        var changed = slide
        changed.width = Int(width)
        if preview, let onPreview { onPreview(changed) } else { onChange?(changed) }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .padding(3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartWidth ?? cardWidth
                        dragStartWidth = start
                        setWidth(min(max(start + value.translation.width, 160), 800), preview: true)
                    }
                    .onEnded { value in
                        let start = dragStartWidth ?? cardWidth
                        dragStartWidth = nil
                        setWidth(min(max(start + value.translation.width, 160), 800))
                    }
            )
            .help("Drag to resize")
    }

    private func fire(_ fired: Slide, in presentation: Presentation, index: Int) {
        guard let context, let controls = context.controls else { return }
        Self.fire(fired, in: presentation, index: index, model: context.model, controls: controls)
    }

    static func fire(_ fired: Slide, in presentation: Presentation, index: Int, model: AppModel, controls: ServiceControls) {
        let row = model.currentServiceID
            .flatMap { try? model.service($0) }?
            .items.first { $0.refId == presentation.id }
        let baseOrder = row?.arrangementId == nil && presentation.defaultArrangementId == nil

        if controls.liveSlideID == fired.id, controls.slideAnimationStep.map({ $0.consumed < $0.total }) == true {
            controls.advance(steps: 1) {}
            return
        }
        controls.fire(
            slide: fired, in: presentation, arrangementId: row?.arrangementId,
            contextID: row?.id, occurrence: row != nil && baseOrder ? index : nil)
    }

    private func warningCard(_ title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle.standard(CornerStandard.element))
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if slide.showName == true, let name = slide.presentationName, !name.isEmpty {
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if slide.showLabels != false, let label = slide.slideLabel, !label.isEmpty {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(labelColor.opacity(0.25), in: Capsule())
                }
                if slide.showNumber != false, let index = slide.slideIndex ?? slide.ppSlideIndex {
                    Text("Slide \(index + 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if slide.showText == true, let text = slide.slideText, !text.isEmpty {
                Text(text).font(.system(size: style.fontSize * 0.95)).fixedSize(horizontal: false, vertical: true)
            }
            if slide.showNotes != false, let notes = slide.slideNotes, !notes.isEmpty {
                Text(notes).font(.system(size: style.fontSize * 0.85)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var labelColor: Color {
        slide.slideLabelColor.flatMap(NoteRunText.color(hex:)) ?? .accentColor
    }
}

enum NoteRunText {
    static func color(hex: String) -> Color? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let shift: UInt64 = digits.count == 8 ? 8 : 0
        let r = Double((value >> (16 + shift)) & 0xFF) / 255
        let g = Double((value >> (8 + shift)) & 0xFF) / 255
        let b = Double((value >> shift) & 0xFF) / 255
        let a = digits.count == 8 ? Double(value & 0xFF) / 255 : 1
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}
