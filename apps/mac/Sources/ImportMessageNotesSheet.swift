import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage("messageNotesVersePerSlide") private var versePerSlide = true
    @AppStorage("messageNotesKindThemes") private var storedKindThemes = ""
    @State private var choosingKindThemes = false

    @State private var boldOnly = false

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
        var versePerSlide: Bool
        var boldOnly: Bool
    }

    struct Preview: Sendable {
        struct Item: Sendable {
            var caption: String
            var slide: Slide
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
            versePerSlide: versePerSlide, boldOnly: boldOnly && mixesBold)
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
            set: { overrides[block.source] = $0 }
        )
    }

    private var previewPane: some View {
        Group {
            if let preview, !isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(Array(preview.items.enumerated()), id: \.offset) { _, item in
                            let themeId = item.slide.themeId ?? preview.presentation.themeId
                            let stamp = model.entry(themeId)?.updatedAt.timeIntervalSince1970 ?? 0
                            VStack(alignment: .leading, spacing: 3) {
                                ImportSlideThumbnail(
                                    model: model, render: render, slide: item.slide, theme: model.theme(themeId),
                                    showChords: false,
                                    cacheKey: Self.cacheKey(item.slide, themeId: themeId, themeStamp: stamp))
                                Text(item.caption)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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
            HStack(spacing: 14) {
                Toggle("A verse per slide", isOn: $versePerSlide)
                    .fixedSize()
                    .help("Split a passage like John 3:16-18 into one slide per verse. Verse numbers in the text mark the breaks; without them the passage breaks at sentences and each slide keeps the whole reference")
                if mixesBold {
                    Toggle("Bold lines only", isOn: $boldOnly)
                        .fixedSize()
                        .help("For notes where only the bold lines belong on screen: unbolded lines are left off as slide notes. Scripture and quotes still make slides")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: importNow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
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

    static func name(_ kind: MessageNotes.Kind) -> String {
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
        let made = input.versePerSlide ? parsed.splittingVerses() : parsed
        let presentation = MessageNotes.makePresentation(
            made, id: "message-notes-import-preview", themeId: input.themeId, theme: theme, style: input.style,
            kindThemes: kindThemes)
        let shown = made.blocks.filter { $0.kind != .skip }
        let items = zip(shown, presentation.slides).map { block, slide in
            Preview.Item(
                caption: ([name(block.kind)] + [block.kind == .title ? nil : block.detail].compactMap { $0 })
                    .joined(separator: " · "),
                slide: slide)
        }
        return Preview(parsed: parsed, presentation: presentation, items: items)
    }

    static func cacheKey(_ slide: Slide, themeId: String, themeStamp: Double) -> String {
        let content = slide.objects.map { object in
            object.name + "=" + object.text + "|"
                + (object.styleRuns ?? []).map { "\($0.line).\($0.column).\($0.length)" }.joined(separator: ",")
        }.joined(separator: "¶")
        return "message-notes-import|\(themeId)|\(themeStamp)|\(slide.themeSlideName ?? "")|\(content)"
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MessageNotesFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            Task { @MainActor in
                let loaded = await Task.detached { MessageNotesFile.load(data, filename: url.lastPathComponent) }.value
                if let loaded {
                    text = loaded.text
                    hints = loaded.hints
                    overrides = [:]
                    boldOnly = false
                    loadedFrom = PresentationOrigin(.messageNotes, detail: url.lastPathComponent)
                    if title.isEmpty, MessageNotes.parse(loaded.text, hints: loaded.hints).title == nil {
                        title = url.deletingPathExtension().lastPathComponent
                    }
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    private func importNow() {
        let fallback = title.trimmingCharacters(in: .whitespaces)
        let parsed = MessageNotes.parse(text, hints: hints, overrides: overrides, boldOnly: boldOnly && mixesBold)
        let id = model.importMessageNotes(
            versePerSlide ? parsed.splittingVerses() : parsed,
            fallbackTitle: fallback.isEmpty ? nil : fallback,
            themeId: themeId,
            style: style,
            kindThemeIds: kindThemeIds,
            origin: loadedFrom ?? PresentationOrigin(.messageNotes)
        )
        dismiss()
        if let id { onImported(id) }
    }
}
