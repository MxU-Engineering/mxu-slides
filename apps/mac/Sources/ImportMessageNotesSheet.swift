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
    @AppStorage("messageNotesStyle") private var storedStyle = ""
    @AppStorage("messageNotesKindThemes") private var storedKindThemes = ""
    @State private var choosingKindThemes = false
    @AppStorage("messageNotesShowVerseNumbers") private var showVerseNumbers = true
    @AppStorage("messageNotesBlankSlidesBetween") private var blankSlidesBetweenSlides = false
    @AppStorage("messageNotesKeepScriptureTogether") private var keepScripturePassagesTogether = true
    @AppStorage("messageNotesBlankSlideAtBeginning") private var blankSlideAtBeginning = true
    @State private var addedBlankSlideSlots: Set<Int> = []
    @State private var blankSlideAfterSlots: Set<Int> = []
    @State private var removedBlankSlideAfterSlots: Set<Int> = []
    @State private var removedBlankSlideSlots: Set<Int> = []
    @State private var revealingPointIndices: Set<Int> = []
    @State private var imageMediaIDs: [Int: [String]] = [:]
    @State private var blankSlideImageMediaIDs: [Int: [String]] = [:]
    @State private var designOverrides: [Int: String] = [:]
    @State private var fontSizes: [Int: Double] = [:]
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
        var style: String?
        var revealingPointIndices: Set<Int>
        var showVerseNumbers: Bool
        var blankSlidesBetweenSlides: Bool
        var keepScripturePassagesTogether: Bool
        var blankSlideAtBeginning: Bool
        var addedBlankSlideSlots: Set<Int>
        var blankSlideAfterSlots: Set<Int>
        var removedBlankSlideAfterSlots: Set<Int>
        var removedBlankSlideSlots: Set<Int>
        var designOverrides: [Int: String]
        var fontSizes: [Int: Double]
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

    private var styles: [String] { MessageNotes.styles(in: model.theme(themeId)) }

    private var style: String? { styles.contains(storedStyle) ? storedStyle : nil }

    static let themedKinds: [MessageNotes.Kind] = [.title, .point, .scripture, .quote]

    private var kindThemeIds: [MessageNotes.Kind: String] {
        let stored = storedKindThemes.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        var chosen: [MessageNotes.Kind: String] = [:]
        for kind in Self.themedKinds {
            if let id = stored[kind.rawValue], !id.isEmpty, id != themeId, model.entry(id) != nil { chosen[kind] = id }
        }
        return chosen
    }

    private func setKindTheme(_ kind: MessageNotes.Kind, _ id: String) {
        var stored = storedKindThemes.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        stored[kind.rawValue] = id.isEmpty ? nil : id
        storedKindThemes = (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
            style: style,
            revealingPointIndices: revealingPointIndices,
            showVerseNumbers: showVerseNumbers,
            blankSlidesBetweenSlides: blankSlidesBetweenSlides,
            keepScripturePassagesTogether: keepScripturePassagesTogether,
            blankSlideAtBeginning: blankSlideAtBeginning,
            addedBlankSlideSlots: addedBlankSlideSlots,
            blankSlideAfterSlots: blankSlideAfterSlots,
            removedBlankSlideAfterSlots: removedBlankSlideAfterSlots,
            removedBlankSlideSlots: removedBlankSlideSlots,
            designOverrides: designOverrides, fontSizes: fontSizes, imageMediaIDs: imageMediaIDs,
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
        .onChange(of: themeId) { _, _ in designOverrides = [:] }
        .onChange(of: storedStyle) { _, _ in designOverrides = [:] }
        .task(id: input) {
            let input = input
            await model.themesFilled([input.themeId] + Array(input.kindThemes.values))
            let theme = model.theme(input.themeId)
            var kindThemes: [MessageNotes.Kind: Theme] = [:]
            for (raw, id) in input.kindThemes {
                if let kind = MessageNotes.Kind(rawValue: raw), let own = model.theme(id) { kindThemes[kind] = own }
            }
            let built = await Task.detached(priority: .userInitiated) {
                Self.build(input, theme: theme, kindThemes: kindThemes)
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
        revealingPointIndices = []
        imageMediaIDs = [:]
        blankSlideImageMediaIDs = [:]
        designOverrides = [:]
        fontSizes = [:]
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

    private func revealBinding(for item: Preview.Item) -> Binding<Bool> {
        Binding(
            get: { item.sourceIndices.allSatisfy(revealingPointIndices.contains) },
            set: { isSelected in
                if isSelected {
                    revealingPointIndices.formUnion(item.sourceIndices)
                } else {
                    revealingPointIndices.subtract(item.sourceIndices)
                }
            })
    }

    private var previewPane: some View {
        Group {
            if let preview, !isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Turn on “Combine adjacent points” for each point you want on a shared slide; each point appears on its own click. Drop images onto any slide, including blank slides, or use Add image.")
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
                                    Text(item.caption)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if item.isPoint {
                                        Toggle("Combine adjacent points", isOn: revealBinding(for: item))
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                            .font(.caption2)
                                            .help("Select adjacent point slides to combine them. Each selected point will appear on a separate click.")
                                    }
                                    HStack {
                                        Button {
                                            chooseImage(for: item)
                                        } label: {
                                            Label("Add image…", systemImage: "photo.badge.plus")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(imageKey(for: item) == nil)
                                        Spacer(minLength: 0)
                                    }
                                    if let blankSlideSlot = item.blankSlideSlot {
                                        Button(role: .destructive) {
                                            if item.isAdditionalBlankAfter {
                                                removedBlankSlideAfterSlots.insert(blankSlideSlot)
                                            } else {
                                                removedBlankSlideSlots.insert(blankSlideSlot)
                                            }
                                        } label: {
                                            Label("Delete this blank slide", systemImage: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Remove only this blank slide from the imported presentation.")
                                    }
                                    if let imageID = imageIDs(for: item).first {
                                        HStack(spacing: 5) {
                                            Image(systemName: "photo")
                                            Text(imageIDs(for: item).count > 1
                                                 ? "\(imageIDs(for: item).count) images"
                                                 : model.media(imageID)?.name ?? "Attached image")
                                                .lineLimit(1)
                                            Spacer()
                                            Button {
                                                removeImages(for: item)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(.plain)
                                            .help("Remove images from this slide")
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    if !item.isBlank {
                                        slideControls(for: item, theme: itemTheme)
                                    }
                                    if !item.isAdditionalBlankAfter,
                                       !item.isBlank || item.blankSlideSlot != nil {
                                        Button {
                                            addBlankSlide(afterItemAt: offset)
                                        } label: {
                                            Label("Add blank slide after", systemImage: "plus.rectangle.on.rectangle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Insert a blank slide immediately after this slide, including after an image on a blank slide.")
                                    }
                                }
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
                if styles.count > 1 {
                    Picker("Style", selection: Binding(get: { style ?? styles[0] }, set: { storedStyle = $0 })) {
                        ForEach(styles, id: \.self) { style in
                            Text(style.isEmpty ? "Unfiled" : style).tag(style)
                        }
                    }
                    .fixedSize()
                    .help("The theme folder the Point, Verse and Quote designs come from — full slides, or thirds over the camera")
                }
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
                Picker(Self.name(kind), selection: Binding(
                    get: { kindThemeIds[kind] ?? "" }, set: { setKindTheme(kind, $0) }
                )) {
                    Text("Same as deck theme").tag("")
                    Divider()
                    ForEach(themes, id: \.id) { Text($0.name).tag($0.id) }
                }
                .frame(width: 320)
            }
            Text("A slide takes its design from that theme's Title, Point, Verse or Quote design.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
        }
        .padding(14)
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
        _ input: Input, theme: Theme?, kindThemes: [MessageNotes.Kind: Theme] = [:]
    ) -> Preview {
        let parsed = MessageNotes.parse(
            input.text, hints: input.hints, overrides: input.overrides, boldOnly: input.boldOnly)
        let made = parsed.splittingVerses()
        let groups = MessageNotes.slideGroups(
            in: made.blocks, revealingPointIndices: input.revealingPointIndices,
            includeTitleSlide: false)
        let blankSlots = MessageNotes.blankSlideSlots(
            in: made.blocks, revealingPointIndices: input.revealingPointIndices,
            includeTitleSlide: false,
            blankSlidesBetweenSlides: input.blankSlidesBetweenSlides,
            keepScripturePassagesTogether: input.keepScripturePassagesTogether,
            blankSlideAtBeginning: input.blankSlideAtBeginning,
            additionalBlankSlideSlots: input.addedBlankSlideSlots)
        let removedBlankSlideSlots = input.removedBlankSlideSlots.intersection(blankSlots)
        let presentation = MessageNotes.makePresentation(
            made, id: "message-notes-import-preview", themeId: input.themeId, theme: theme, style: input.style,
            kindThemes: kindThemes,
            revealingPointIndices: input.revealingPointIndices,
            fontSizes: input.fontSizes,
            designOverrides: input.designOverrides,
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

    @ViewBuilder
    private func slideControls(for item: Preview.Item, theme: Theme?) -> some View {
        if let index = item.sourceIndices.first {
            let designs = MessageNotes.designNames(for: item.kind, in: theme, style: style)
            if !designs.isEmpty {
                Picker("Design", selection: designBinding(for: index)) {
                    Text("Theme default").tag("")
                    ForEach(designs, id: \.self) { name in Text(name).tag(name) }
                }
                .controlSize(.small)
                .help("Choose this slide's theme design, or use the theme's automatic choice.")
            }
            Picker("Font size", selection: fontSizeBinding(for: index)) {
                Text("Theme default").tag(0.0)
                ForEach([36.0, 42, 48, 54, 60, 66, 72, 80, 88], id: \.self) { size in
                    Text("\(Int(size)) pt").tag(size)
                }
            }
            .controlSize(.small)
            .help("Set this slide's text size. More typography controls are available in the Object inspector.")
        }
    }

    private func designBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { designOverrides[index] ?? "" },
            set: { value in
                if value.isEmpty { designOverrides.removeValue(forKey: index) }
                else { designOverrides[index] = value }
            })
    }

    private func fontSizeBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { fontSizes[index] ?? 0 },
            set: { value in
                if value == 0 { fontSizes.removeValue(forKey: index) }
                else { fontSizes[index] = value }
            })
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
        let id = model.importMessageNotes(
            parsed.splittingVerses(),
            fallbackTitle: fallback.isEmpty ? nil : fallback,
            themeId: themeId,
            style: style,
            kindThemeIds: kindThemeIds,
            revealingPointIndices: revealingPointIndices,
            fontSizes: fontSizes,
            designOverrides: designOverrides,
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
