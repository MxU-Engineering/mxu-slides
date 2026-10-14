import PresenterCore
import PPTXImport
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

private enum MessageNotesLoadResult: Sendable {
    case success(MessageNotesFile.Loaded)
    case failure(String)
}

struct ImportMessageNotesSheet: View {
    let model: AppModel
    let render: RenderContext?
    let onImported: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    @State private var hints: [String: MessageNotes.Hint] = [:]

    @State private var overrides: [String: MessageNotes.Kind] = [:]
    @State private var loadedFrom: PresentationOrigin?
    @State private var title = ""
    @AppStorage("messageNotesKindLooks") private var storedKindLooks = ""
    @State private var choosingKindThemes = false
    @AppStorage("messageNotesShowVerseNumbers") private var showVerseNumbers = true
    @AppStorage("messageNotesBlankSlidesBetween") private var blankSlidesBetweenSlides = false
    @AppStorage("messageNotesKeepScriptureTogether") private var keepScripturePassagesTogether = true
    @AppStorage("messageNotesBlankSlideAtBeginning") private var blankSlideAtBeginning = true
    @State private var addedBlankSlideSlots: Set<Int> = []
    @State private var blankSlideAfterSlots: Set<Int> = []
    @State private var removedBlankSlideAfterSlots: Set<Int> = []
    @State private var removedBlankSlideSlots: Set<Int> = []
    @AppStorage("messageNotesCombinePoints") private var combineAdjacentPoints = false
    @State private var imageMediaIDs: [Int: [String]] = [:]
    @State private var blankSlideImageMediaIDs: [Int: [String]] = [:]
    @State private var removedSlideIndices: Set<Int> = []
    @State private var showAdvanceOptions = false

    @State private var boldOnly = false
    @State private var fileImportError: String?

    @State private var preview: Preview?

    private var themeId: String { model.slideBuilding.messageNotesThemeId ?? "" }

    struct Input: Equatable, Sendable {
        var text: String
        var hints: [String: MessageNotes.Hint]
        var overrides: [String: MessageNotes.Kind]
        var themeId: String
        var themeStamp: Double
        var kindThemes: [String: String] = [:]
        var kindStamps: [String: Double] = [:]
        var kindStyles: [String: String] = [:]
        var combineAdjacentPoints: Bool
        var showVerseNumbers: Bool
        var blankSlidesBetweenSlides: Bool
        var keepScripturePassagesTogether: Bool
        var blankSlideAtBeginning: Bool
        var addedBlankSlideSlots: Set<Int>
        var blankSlideAfterSlots: Set<Int>
        var removedBlankSlideAfterSlots: Set<Int>
        var removedBlankSlideSlots: Set<Int>
        var removedSlideIndices: Set<Int>
        var imageMediaIDs: [Int: [String]]
        var blankSlideImageMediaIDs: [Int: [String]]
        var boldOnly: Bool
    }

    struct Preview: Sendable {
        struct Item: Sendable {
            var caption: String
            var slide: Slide
            var sourceIndices: [Int]
            var isPoint: Bool
            var isBlank: Bool
            var kind: MessageNotes.Kind
            var blankSlideSlot: Int?
            var isAdditionalBlankAfter = false
        }

        var parsed: MessageNotes.Parsed
        var presentation: Presentation
        var items: [Item]
    }

    struct KindLook: Codable, Equatable {
        var theme: String
        var style: String?
    }

    static let themedKinds: [MessageNotes.Kind] = [.title, .point, .scripture, .quote]

    private var kindLooks: [String: KindLook] {
        storedKindLooks.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: KindLook].self, from: $0) } ?? [:]
    }

    private func look(for kind: MessageNotes.Kind) -> KindLook? {
        guard let look = kindLooks[kind.rawValue] else { return nil }
        return look.theme.isEmpty || look.theme == themeId || model.entry(look.theme) != nil ? look : nil
    }

    private var kindThemeIds: [MessageNotes.Kind: String] {
        var chosen: [MessageNotes.Kind: String] = [:]
        for kind in Self.themedKinds {
            if let look = look(for: kind), !look.theme.isEmpty, look.theme != themeId { chosen[kind] = look.theme }
        }
        return chosen
    }

    private var kindStyles: [MessageNotes.Kind: String] {
        var chosen: [MessageNotes.Kind: String] = [:]
        for kind in Self.themedKinds {
            if let style = look(for: kind)?.style { chosen[kind] = style }
        }
        return chosen
    }

    private func setKindLook(_ kind: MessageNotes.Kind, theme: String, style: String?) {
        var stored = kindLooks
        stored[kind.rawValue] = KindLook(theme: theme, style: style)
        storedKindLooks = (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private var input: Input {
        let chosen = kindThemeIds
        return Input(
            text: text, hints: hints, overrides: overrides, themeId: themeId,
            themeStamp: model.entry(themeId)?.updatedAt.timeIntervalSince1970 ?? 0,
            kindThemes: Dictionary(uniqueKeysWithValues: chosen.map { ($0.key.rawValue, $0.value) }),
            kindStamps: Dictionary(
                chosen.map { ($0.value, model.entry($0.value)?.updatedAt.timeIntervalSince1970 ?? 0) },
                uniquingKeysWith: { first, _ in first }),
            kindStyles: Dictionary(uniqueKeysWithValues: kindStyles.map { ($0.key.rawValue, $0.value) }),
            combineAdjacentPoints: combineAdjacentPoints,
            showVerseNumbers: showVerseNumbers,
            blankSlidesBetweenSlides: blankSlidesBetweenSlides,
            keepScripturePassagesTogether: keepScripturePassagesTogether,
            blankSlideAtBeginning: blankSlideAtBeginning,
            addedBlankSlideSlots: addedBlankSlideSlots,
            blankSlideAfterSlots: blankSlideAfterSlots,
            removedBlankSlideAfterSlots: removedBlankSlideAfterSlots,
            removedBlankSlideSlots: removedBlankSlideSlots,
            removedSlideIndices: removedSlideIndices, imageMediaIDs: imageMediaIDs,
            blankSlideImageMediaIDs: blankSlideImageMediaIDs,
            boldOnly: boldOnly && mixesBold)
    }

    private var mixesBold: Bool {
        hints.values.contains { $0.bold } && hints.values.contains { !$0.bold }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Message Notes")
                    .font(.headline)
                Spacer()
                if let parsed = preview?.parsed, !isEmpty {
                    Text(Self.summary(parsed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            HSplitView {
                editor
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                previewPane
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
                .padding(12)
        }
        .frame(minWidth: 980, minHeight: 640)
        .alert("Couldn’t import file", isPresented: Binding(
            get: { fileImportError != nil },
            set: { if !$0 { fileImportError = nil } }
        )) {
            Button("OK", role: .cancel) { fileImportError = nil }
        } message: {
            Text(fileImportError ?? "")
        }
        .onChange(of: text) { _, _ in clearSlideOptions() }
        .onChange(of: boldOnly) { _, _ in clearSlideOptions() }
        .onChange(of: blankSlideAtBeginning) { _, _ in clearBlankSlideSelections() }
        .onChange(of: blankSlidesBetweenSlides) { _, _ in clearBlankSlideSelections() }
        .onChange(of: keepScripturePassagesTogether) { _, _ in clearBlankSlideSelections() }
        .task(id: input) {
            let input = input
            await model.themesFilled([input.themeId] + Array(input.kindThemes.values))
            let theme = model.theme(input.themeId)
            var kindThemes: [MessageNotes.Kind: Theme] = [:]
            for (raw, id) in input.kindThemes {
                if let kind = MessageNotes.Kind(rawValue: raw), let own = model.theme(id) { kindThemes[kind] = own }
            }
            var kindStyles: [MessageNotes.Kind: String] = [:]
            for (raw, style) in input.kindStyles {
                if let kind = MessageNotes.Kind(rawValue: raw) { kindStyles[kind] = style }
            }
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(input, theme: theme, kindThemes: kindThemes, kindStyles: kindStyles)
            }.value
            if !Task.isCancelled { preview = built }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.body)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste the message outline, or load the Word document. Short lines become points; a line with a reference — “John 3:16 – For God so loved…” — becomes scripture; a quoted line with a name becomes a quote. Anything in (parentheses) stays off the screen as a slide note.")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let blocks = preview?.parsed.blocks, !blocks.isEmpty, !isEmpty {
                lineList(blocks)
            }
        }
        .padding(12)
    }

    private func lineList(_ blocks: [MessageNotes.Block]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How each line was read — change any that are wrong")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        HStack(spacing: 8) {
                            Picker("", selection: kindBinding(block)) {
                                ForEach(MessageNotes.Kind.allCases, id: \.self) { kind in
                                    Text(Self.name(kind)).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 104)
                            .help("Title, Point, Scripture and Quote each make a slide on that design; Leave Off keeps the line as a note on the slide before it")
                            if let detail = block.detail, block.kind != .title {
                                Text(detail)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            Text(block.text)
                                .font(.callout)
                                .foregroundStyle(block.kind == .skip ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 240)
        }
    }

    private func kindBinding(_ block: MessageNotes.Block) -> Binding<MessageNotes.Kind> {
        Binding(
            get: { block.kind },
            set: {
                overrides[block.source] = $0
                clearSlideOptions()
            }
        )
    }

    private func clearSlideOptions() {
        imageMediaIDs = [:]
        blankSlideImageMediaIDs = [:]
        removedSlideIndices = []
        clearBlankSlideSelections()
    }

    private func clearBlankSlideSelections() {
        addedBlankSlideSlots = []
        blankSlideAfterSlots = []
        removedBlankSlideAfterSlots = []
        removedBlankSlideSlots = []
    }

    private func addBlankSlide(afterItemAt itemOffset: Int) {
        guard let preview else { return }
        let item = preview.items[itemOffset]
        if item.isBlank, !item.isAdditionalBlankAfter, let slot = item.blankSlideSlot {
            blankSlideAfterSlots.insert(slot)
            removedBlankSlideAfterSlots.remove(slot)
            return
        }
        let followingContent = preview.items.dropFirst(itemOffset + 1).first { !$0.isBlank }
        let slot = followingContent?.sourceIndices.first ?? preview.parsed.blocks.count
        addedBlankSlideSlots.insert(slot)
        removedBlankSlideSlots.remove(slot)
    }

    private func canRemove(_ item: Preview.Item) -> Bool {
        item.isBlank ? item.blankSlideSlot != nil : !item.sourceIndices.isEmpty
    }

    private func removeSlide(_ item: Preview.Item) {
        if item.isBlank, let slot = item.blankSlideSlot {
            if item.isAdditionalBlankAfter {
                removedBlankSlideAfterSlots.insert(slot)
            } else {
                removedBlankSlideSlots.insert(slot)
            }
        } else {
            removedSlideIndices.formUnion(item.sourceIndices)
        }
    }

    private func canAddBlank(after item: Preview.Item) -> Bool {
        !item.isAdditionalBlankAfter && (!item.isBlank || item.blankSlideSlot != nil)
    }

    private var previewPane: some View {
        Group {
            if let preview, !isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hover a slide to add an image, or drop images onto it. Use the red minus to remove a slide and the green plus between slides to add a blank one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(Array(preview.items.enumerated()), id: \.offset) { offset, item in
                                let itemThemeId = item.slide.themeId ?? preview.presentation.themeId
                                let itemTheme = model.theme(itemThemeId)
                                let stamp = model.entry(itemThemeId)?.updatedAt.timeIntervalSince1970 ?? 0
                                VStack(alignment: .leading, spacing: 5) {
                                    ImportSlideThumbnail(
                                        model: model, render: render, slide: item.slide, theme: itemTheme, showChords: false,
                                        cacheKey: Self.cacheKey(item.slide, themeId: itemThemeId, themeStamp: stamp))
                                        .overlay(alignment: .topLeading) {
                                            if canRemove(item) {
                                                SlideBadgeButton(
                                                    systemImage: "minus.circle.fill", tint: .red,
                                                    help: "Remove this slide from the import"
                                                ) { removeSlide(item) }
                                                .offset(x: -7, y: -7)
                                            }
                                        }
                                        .overlay {
                                            if imageKey(for: item) != nil {
                                                SlideImageHover(
                                                    imageCount: imageIDs(for: item).count,
                                                    add: { chooseImage(for: item) },
                                                    remove: { removeImages(for: item) })
                                            }
                                        }
                                        .overlay(alignment: .trailing) {
                                            if canAddBlank(after: item) {
                                                BlankSlideGap { addBlankSlide(afterItemAt: offset) }
                                                    .offset(x: 15)
                                            }
                                        }
                                    Text(item.caption)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .zIndex(Double(preview.items.count - offset))
                                .dropDestination(for: URL.self) { urls, _ in
                                    guard imageKey(for: item) != nil, !urls.isEmpty else { return false }
                                    importImages(urls, for: item)
                                    return true
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            } else {
                ContentUnavailableView(
                    "Paste Message Notes", systemImage: "text.book.closed",
                    description: Text("The slides appear here as you type.")
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button("Load File…", action: loadFile)
                    .help("A Word document, RTF, PDF or text file. A Word document's bold and underlines are kept: unbolded lines stay off the screen, underlined words stay underlined")
                TextField("Title (optional — the first line names it)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: .infinity)
                LyricsThemeChooser(
                    appModel: model, render: render, themeId: themeId
                ) { [model] themeId, _ in
                    model.updateSlideBuilding { $0.messageNotesThemeId = themeId.isEmpty ? nil : themeId }
                }
                Button("By Type…") { choosingKindThemes = true }
                    .help("Give titles, points, scriptures and quotes each their own theme")
                    .popover(isPresented: $choosingKindThemes, arrowEdge: .top) { kindThemesPopover }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importNow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
            }
            Toggle("Advanced options", isOn: $showAdvanceOptions)
                .toggleStyle(.switch)
                .controlSize(.large)
                .font(.headline)
            if showAdvanceOptions {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Verse numbers", isOn: $showVerseNumbers)
                        .help("Show or hide individual verse numbers. The full passage reference remains on the slide.")
                    if mixesBold {
                        Toggle("Bold lines only", isOn: $boldOnly)
                            .help("Leave unbolded lines off screen as slide notes. Scripture and quotes still make slides.")
                    }
                    Toggle("Combine adjacent points", isOn: $combineAdjacentPoints)
                        .help("Put runs of consecutive points on one slide; each point appears on its own click.")
                    Toggle("Blank slide between each slide", isOn: $blankSlidesBetweenSlides)
                        .help("Insert an empty slide between unrelated generated content slides.")
                    Toggle("Keep scripture passages together", isOn: $keepScripturePassagesTogether)
                        .help("Do not insert optional blank slides between consecutive verses in the same passage.")
                    Toggle("Blank slide at beginning", isOn: $blankSlideAtBeginning)
                        .help("Start the imported presentation with an empty slide.")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.caption)
                .padding(.leading, 22)
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    private var kindThemesPopover: some View {
        let themes = model.entries(of: .theme).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Theme for each kind of slide")
                .font(.headline)
            ForEach(Self.themedKinds, id: \.self) { kind in
                HStack {
                    Text(Self.name(kind))
                        .frame(width: 80, alignment: .leading)
                    kindMenu(kind, themes: themes)
                }
            }
            Text("Pick a theme, then its style where it has more than one. A slide takes its design from that theme's Title, Point, Verse or Quote design.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 380, alignment: .leading)
        }
        .padding(14)
        .task { await model.themesFilled(themes.map(\.id)) }
    }

    private func kindMenu(_ kind: MessageNotes.Kind, themes: [LibraryIndex.Entry]) -> some View {
        let current = look(for: kind)
        let currentTheme = current?.theme ?? ""
        func themeItem(id: String, name: String) -> some View {
            let styles = MessageNotes.styles(in: model.theme(id.isEmpty ? themeId : id))
            return Group {
                if styles.count > 1 {
                    Menu(name) {
                        ForEach(styles, id: \.self) { style in
                            Button {
                                setKindLook(kind, theme: id, style: style)
                            } label: {
                                let chosen = currentTheme == id && current?.style == style
                                Text((chosen ? "✓ " : "") + (style.isEmpty ? "Unfiled" : style))
                            }
                        }
                    }
                } else {
                    Button((currentTheme == id ? "✓ " : "") + name) {
                        setKindLook(kind, theme: id, style: styles.first)
                    }
                }
            }
        }
        let deckName = model.entry(themeId)?.name ?? "None"
        let label = currentTheme.isEmpty ? "Deck theme (\(deckName))" : model.entry(currentTheme)?.name ?? "Missing"
        let styleLabel = current?.style.flatMap { $0.isEmpty ? nil : " › " + $0 } ?? ""
        return Menu(label + styleLabel) {
            themeItem(id: "", name: "Deck theme (\(deckName))")
            Divider()
            ForEach(themes, id: \.id) { entry in
                themeItem(id: entry.id, name: entry.name)
            }
        }
        .frame(width: 280)
    }

    nonisolated static func name(_ kind: MessageNotes.Kind) -> String {
        switch kind {
        case .title: "Title"
        case .point: "Point"
        case .scripture: "Scripture"
        case .quote: "Quote"
        case .skip: "Leave Off"
        }
    }

    static func summary(_ parsed: MessageNotes.Parsed) -> String {
        func counted(_ kind: MessageNotes.Kind, _ one: String, _ many: String) -> String? {
            let count = parsed.count(of: kind)
            return count == 0 ? nil : "\(count) \(count == 1 ? one : many)"
        }
        return [
            counted(.point, "point", "points"), counted(.scripture, "scripture", "scriptures"),
            counted(.quote, "quote", "quotes"), counted(.skip, "line left off", "lines left off"),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    nonisolated static func build(
        _ input: Input, theme: Theme?, kindThemes: [MessageNotes.Kind: Theme] = [:],
        kindStyles: [MessageNotes.Kind: String] = [:]
    ) -> Preview {
        let parsed = MessageNotes.parse(
            input.text, hints: input.hints, overrides: input.overrides, boldOnly: input.boldOnly)
        let made = parsed.splittingVerses().removingBlocks(at: input.removedSlideIndices)
        let revealing = input.combineAdjacentPoints ? made.pointIndices() : []
        let groups = MessageNotes.slideGroups(
            in: made.blocks, revealingPointIndices: revealing,
            includeTitleSlide: false)
        let blankSlots = MessageNotes.blankSlideSlots(
            in: made.blocks, revealingPointIndices: revealing,
            includeTitleSlide: false,
            blankSlidesBetweenSlides: input.blankSlidesBetweenSlides,
            keepScripturePassagesTogether: input.keepScripturePassagesTogether,
            blankSlideAtBeginning: input.blankSlideAtBeginning,
            additionalBlankSlideSlots: input.addedBlankSlideSlots)
        let removedBlankSlideSlots = input.removedBlankSlideSlots.intersection(blankSlots)
        let presentation = MessageNotes.makePresentation(
            made, id: "message-notes-import-preview", themeId: input.themeId, theme: theme,
            kindThemes: kindThemes, kindStyles: kindStyles,
            revealingPointIndices: revealing,
            showVerseNumbers: input.showVerseNumbers, includeTitleSlide: false,
            blankSlidesBetweenSlides: input.blankSlidesBetweenSlides,
            keepScripturePassagesTogether: input.keepScripturePassagesTogether,
            blankSlideAtBeginning: input.blankSlideAtBeginning,
            additionalBlankSlideSlots: input.addedBlankSlideSlots,
            blankSlideAfterSlots: input.blankSlideAfterSlots,
            removedBlankSlideAfterSlots: input.removedBlankSlideAfterSlots,
            removedBlankSlideSlots: removedBlankSlideSlots,
            imageMediaIDs: input.imageMediaIDs,
            blankSlideImageMediaIDs: input.blankSlideImageMediaIDs)
        var items: [Preview.Item] = []
        var slideIndex = 0
        if blankSlots.contains(-1), !removedBlankSlideSlots.contains(-1),
           let blank = presentation.slides.first {
            items.append(Preview.Item(
                caption: "Blank", slide: blank, sourceIndices: [], isPoint: false, isBlank: true,
                kind: .skip, blankSlideSlot: -1))
            slideIndex = 1
            if input.blankSlideAfterSlots.contains(-1),
               !input.removedBlankSlideAfterSlots.contains(-1),
               slideIndex < presentation.slides.count {
                items.append(Preview.Item(
                    caption: "Blank", slide: presentation.slides[slideIndex], sourceIndices: [],
                    isPoint: false, isBlank: true, kind: .skip, blankSlideSlot: -1,
                    isAdditionalBlankAfter: true))
                slideIndex += 1
            }
        }
        for (_, indices) in groups.enumerated() {
            let blankSlot = indices.first
            if let blankSlot, blankSlots.contains(blankSlot), !removedBlankSlideSlots.contains(blankSlot),
               slideIndex < presentation.slides.count {
                items.append(Preview.Item(
                    caption: "Blank", slide: presentation.slides[slideIndex],
                    sourceIndices: [], isPoint: false, isBlank: true, kind: .skip,
                    blankSlideSlot: blankSlot))
                slideIndex += 1
                if input.blankSlideAfterSlots.contains(blankSlot),
                   !input.removedBlankSlideAfterSlots.contains(blankSlot),
                   slideIndex < presentation.slides.count {
                    items.append(Preview.Item(
                        caption: "Blank", slide: presentation.slides[slideIndex], sourceIndices: [],
                        isPoint: false, isBlank: true, kind: .skip, blankSlideSlot: blankSlot,
                        isAdditionalBlankAfter: true))
                    slideIndex += 1
                }
            }
            guard slideIndex < presentation.slides.count else { break }
            let slide = presentation.slides[slideIndex]
            let blocks = indices.map { made.blocks[$0] }
            let caption: String
            if blocks.count > 1 {
                caption = "\(blocks.count) points · reveal on click"
            } else if let block = blocks.first {
                caption = ([name(block.kind)] + [block.kind == .title ? nil : block.detail].compactMap { $0 })
                    .joined(separator: " · ")
            } else {
                caption = ""
            }
            items.append(Preview.Item(
                caption: caption,
                slide: slide,
                sourceIndices: indices,
                isPoint: blocks.allSatisfy { $0.kind == .point },
                isBlank: false,
                kind: blocks.first?.kind ?? .skip,
                blankSlideSlot: nil))
            slideIndex += 1
        }
        let endSlot = made.blocks.count
        if blankSlots.contains(endSlot), !removedBlankSlideSlots.contains(endSlot),
           slideIndex < presentation.slides.count {
            items.append(Preview.Item(
                caption: "Blank", slide: presentation.slides[slideIndex], sourceIndices: [], isPoint: false, isBlank: true,
                kind: .skip, blankSlideSlot: endSlot))
            slideIndex += 1
            if input.blankSlideAfterSlots.contains(endSlot),
               !input.removedBlankSlideAfterSlots.contains(endSlot),
               slideIndex < presentation.slides.count {
                items.append(Preview.Item(
                    caption: "Blank", slide: presentation.slides[slideIndex], sourceIndices: [],
                    isPoint: false, isBlank: true, kind: .skip, blankSlideSlot: endSlot,
                    isAdditionalBlankAfter: true))
            }
        }
        if items.isEmpty, let blank = presentation.slides.first {
            items.append(Preview.Item(
                caption: "Blank", slide: blank, sourceIndices: [], isPoint: false, isBlank: true,
                kind: .skip, blankSlideSlot: nil))
        }
        return Preview(parsed: parsed, presentation: presentation, items: items)
    }

    static func cacheKey(_ slide: Slide, themeId: String, themeStamp: Double) -> String {
        let content = slide.objects.map { object in
            object.name + "=" + object.text + "|"
                + (object.styleRuns ?? []).map { "\($0.line).\($0.column).\($0.length)" }.joined(separator: ",")
                + "|\(object.textStyle?.fontSize ?? 0)|"
                + "|\(object.fill?.mediaId ?? "")|\(object.opacity ?? 1)|"
                + (object.animationSteps ?? []).map { step in
                    step.animation.rawValue + ":" + (step.ranges ?? []).map { "\($0.line).\($0.column).\($0.length)" }.joined(separator: ",")
                }.joined(separator: ";")
        }.joined(separator: "¶")
        return "message-notes-import|\(themeId)|\(themeStamp)|\(slide.themeSlideName ?? "")|\(content)"
    }

    private func chooseImage(for item: Preview.Item) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            importImages(panel.urls, for: item)
        }
    }

    private func importImages(_ urls: [URL], for item: Preview.Item) {
        guard let key = imageKey(for: item) else { return }
        let images = urls.filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
        guard !images.isEmpty else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let ids = await model.importFiles(images)
            let imageIDs = ids.filter { model.media($0)?.mediaKind == .image }
            guard !imageIDs.isEmpty else {
                NSSound.beep()
                return
            }
            if item.isBlank {
                blankSlideImageMediaIDs[key] = imageIDs
            } else {
                imageMediaIDs[key] = imageIDs
            }
        }
    }

    private func imageKey(for item: Preview.Item) -> Int? {
        guard !item.isAdditionalBlankAfter else { return nil }
        return item.isBlank ? item.blankSlideSlot : item.sourceIndices.first
    }

    private func imageIDs(for item: Preview.Item) -> [String] {
        guard let key = imageKey(for: item) else { return [] }
        return item.isBlank ? blankSlideImageMediaIDs[key, default: []] : imageMediaIDs[key, default: []]
    }

    private func removeImages(for item: Preview.Item) {
        guard let key = imageKey(for: item) else { return }
        if item.isBlank {
            blankSlideImageMediaIDs.removeValue(forKey: key)
        } else {
            imageMediaIDs.removeValue(forKey: key)
        }
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MessageNotesFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let outcome = await Task.detached(priority: .userInitiated) { () -> MessageNotesLoadResult in
                    do {
                        if url.pathExtension.lowercased() == "pages" {
                            return .success(try MessageNotesFile.loadPages(at: url))
                        }
                        if url.pathExtension.lowercased() == "pptx" {
                            let text = try PPTXNotesExtractor.extractText(from: url)
                            return .success(MessageNotesFile.Loaded(text: text))
                        }
                        let data = try Data(contentsOf: url)
                        guard let loaded = MessageNotesFile.load(data, filename: url.lastPathComponent) else {
                            return .failure("The selected file did not contain readable text.")
                        }
                        return .success(loaded)
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }.value
                if case .success(let loaded) = outcome {
                    text = loaded.text
                    hints = loaded.hints
                    overrides = [:]
                    boldOnly = false
                    loadedFrom = PresentationOrigin(.messageNotes, detail: url.lastPathComponent)
                    if title.isEmpty, MessageNotes.parse(loaded.text, hints: loaded.hints).title == nil {
                        title = url.deletingPathExtension().lastPathComponent
                    }
                } else {
                    if case .failure(let message) = outcome {
                        fileImportError = message
                    }
                }
            }
        }
    }

    private func importNow() {
        let fallback = title.trimmingCharacters(in: .whitespaces)
        let parsed = MessageNotes.parse(text, hints: hints, overrides: overrides, boldOnly: boldOnly && mixesBold)
        let prepared = parsed.splittingVerses().removingBlocks(at: removedSlideIndices)
        let id = model.importMessageNotes(
            prepared,
            fallbackTitle: fallback.isEmpty ? nil : fallback,
            themeId: themeId,
            kindThemeIds: kindThemeIds,
            kindStyles: kindStyles,
            revealingPointIndices: combineAdjacentPoints ? prepared.pointIndices() : [],
            showVerseNumbers: showVerseNumbers,
            blankSlidesBetweenSlides: blankSlidesBetweenSlides,
            keepScripturePassagesTogether: keepScripturePassagesTogether,
            blankSlideAtBeginning: blankSlideAtBeginning,
            additionalBlankSlideSlots: addedBlankSlideSlots,
            blankSlideAfterSlots: blankSlideAfterSlots,
            removedBlankSlideAfterSlots: removedBlankSlideAfterSlots,
            removedBlankSlideSlots: removedBlankSlideSlots,
            imageMediaIDs: imageMediaIDs,
            blankSlideImageMediaIDs: blankSlideImageMediaIDs,
            origin: loadedFrom ?? PresentationOrigin(.messageNotes)
        )
        dismiss()
        if let id { onImported(id) }
    }
}

private struct SlideBadgeButton: View {
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .font(.system(size: 17))
                .background(Circle().fill(.white).padding(2))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct BlankSlideGap: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering {
                SlideBadgeButton(
                    systemImage: "plus.circle.fill", tint: .green,
                    help: "Add a blank slide here", action: action)
            }
        }
        .frame(width: 26)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SlideImageHover: View {
    let imageCount: Int
    let add: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering {
                VStack(spacing: 6) {
                    Button(action: add) {
                        Label("Add image…", systemImage: "photo.badge.plus")
                    }
                    if imageCount > 0 {
                        Button(role: .destructive, action: remove) {
                            Label(imageCount > 1 ? "Remove \(imageCount) images" : "Remove image", systemImage: "xmark.circle")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
