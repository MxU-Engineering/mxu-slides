import AppKit
import BibleKit
import PresenterCore
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

private struct BibleInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let copyright: String
    var chapters: [String: [Int]]
    var apiBibleID: String? = nil
    var abbreviation: String? = nil
    var directESV = false
    var pickerLabel: String { "\(abbreviation ?? id) — \(name)" + (directESV ? " · Crossway API" : (apiBibleID == nil ? "" : " · API.Bible")) }
}

// Translation decoding and text search stay off the UI actor. Only imports write
// to disk; passage lookups and live presentation never change the library.
private actor BibleRepository {
    private var corpora: [String: BibleCorpus] = [:]

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MxU Slides/Bibles", isDirectory: true)
    }

    func load() throws -> (bibles: [BibleInfo], warnings: String) {
        let web = try BibleCorpus(.bundledWEB())
        corpora = [web.translation.id: web]
        var warnings: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let corpus = try BibleCorpus(BibleTranslation.read(file))
                guard corpus.translation.id != "WEB" else { continue }
                corpora[corpus.translation.id] = corpus
            } catch { warnings.append("\(file.lastPathComponent): \(error.localizedDescription)") }
        }
        return (infos(), warnings.joined(separator: "\n"))
    }

    func importBible(_ url: URL) throws -> [BibleInfo] {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let translation = try BibleTranslation.read(url)
        guard corpora[translation.id] == nil else {
            throw BibleError.message("\(translation.id) is already installed. Give the imported edition a different ID to keep both.")
        }
        let corpus = try BibleCorpus(translation)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(translation).write(to: directory.appendingPathComponent(translation.id + ".json"), options: .atomic)
        corpora[translation.id] = corpus
        return infos()
    }

    func lookup(id: String, query: String, search: Bool) throws -> (BibleTranslation, [BibleVerse]) {
        guard let corpus = corpora[id] else { throw BibleError.message("Select an installed translation.") }
        let verses = search ? corpus.search(query, limit: 201) : try corpus.passage(query)
        // Pass only the metadata with a result, not all 31,000 verses, to the UI.
        let text = corpus.translation
        return (BibleTranslation(id: text.id, name: text.name, language: text.language,
                                copyright: text.copyright, source: text.source, verses: []), verses)
    }

    func adjacent(id: String, verse: BibleVerse, offset: Int) -> BibleVerse? {
        corpora[id]?.adjacent(to: verse, offset: offset)
    }

    private func infos() -> [BibleInfo] {
        corpora.values.map { corpus in
            BibleInfo(id: corpus.translation.id, name: corpus.translation.name, copyright: corpus.translation.copyright,
                      chapters: Dictionary(uniqueKeysWithValues: corpus.books.map { ($0.id, corpus.chapters(in: $0.id)) }))
        }.sorted { $0.id == "WEB" ? $1.id != "WEB" : ($1.id != "WEB" && $0.id < $1.id) }
    }
}

struct BibleBrowser: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    var isActive = true
    @Environment(\.openSettings) private var openSettings
    @State private var apiSettings = BibleAPISettings.shared
    @State private var esvSettings = ESVSettings.shared
    @State private var appliedESVRevision = -1
    @State private var appliedAPIRevision = -1
    @State private var appliedCredentialRevision = -1
    @State private var offlineBibles: [BibleInfo] = []
    @State private var searchTotal = 0
    @State private var repository = BibleRepository()
    @State private var bibles: [BibleInfo] = []
    @State private var translationID = "WEB"
    @State private var translation: BibleTranslation?
    @State private var query = "John 3:16–18"
    @State private var keywordMode = false
    @State private var bookID = "JHN"
    @State private var chapter = 3
    @State private var matches: [BibleVerse] = []
    @State private var passage: [BibleVerse] = []
    @State private var slides: [Slide] = []
    @State private var playback = BiblePresentationState()
    @State private var oneVerse = true
    @State private var verseNumbers = true
    @State private var showTranslation = true
    @AppStorage("bible.showCopyright") private var showCopyright = true
    @State private var blockMapping = BibleBlockMapping()
    @State private var showingBlockMapping = false
    @State private var saving = false
    @AppStorage("bible.shortCopyright") private var shortCopyright = true
    @State private var themeID = ""
    @State private var design = BibleSlideStyle.dark.rawValue
    @State private var savedID: String?
    @State private var previewPresentationID = "bible-preview-" + UUID().uuidString
    @State private var targetID = ""
    @State private var busy = true
    @State private var requestID = UUID()
    @State private var errorText = ""
    @State private var notice = ""
    @State private var showingError = false

    private var selectedInfo: BibleInfo? { bibles.first { $0.id == translationID } }
    private var designs: [Slide] {
        (model.theme(themeID)?.slides ?? []).filter { $0.objects.filter { $0.objectKind == .text }.count >= 2 }
    }
    private var isESV: Bool { selectedInfo?.directESV == true }
    private var isOnline: Bool { selectedInfo?.apiBibleID != nil || isESV }
    private var style: BibleSlideStyle { BibleSlideStyle(rawValue: design) ?? .dark }
    private var selectedTemplate: Slide? { designs.first { $0.name == design } }
    private var textBlocks: [SlideObject] { selectedTemplate?.objects.filter { $0.objectKind == .text } ?? [] }
    private var mappingKey: String { "bible.blockMapping." + themeID + "/" + design }
    private var hasValidMapping: Bool {
        themeID.isEmpty || (blockMapping.resolved(in: selectedTemplate).verse != nil && blockMapping.resolved(in: selectedTemplate).reference != nil)
    }
    private var title: String { BibleCorpus.reference(for: passage) + " (\(translation?.id ?? selectedInfo?.abbreviation ?? translationID))" }
    private var canUse: Bool { !busy && !saving && !slides.isEmpty && model.isLibraryReady && hasValidMapping }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 18) {
                    lookupControls.frame(minWidth: 220, maxWidth: .infinity)
                    formatControls.frame(minWidth: 240, maxWidth: .infinity)
                }
                .padding(12)
            }
            .floatingPanel()
            HStack(alignment: .top, spacing: 10) {
                if keywordMode && !matches.isEmpty {
                    searchResults.frame(width: 220).floatingPanel()
                }
                previewPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer.floatingPanel()
        }
        .frame(minWidth: 560, minHeight: 540)
        .task(id: isActive) {
            guard isActive else { return }
            if bibles.isEmpty {
                await reloadSources()
                if model.selectedSection == .presentations { targetID = model.selectedEntryID ?? "" }
                await lookup()
            } else if appliedAPIRevision != apiSettings.revision || appliedESVRevision != esvSettings.revision {
                await reloadSources()
            }
        }
        .onChange(of: apiSettings.revision) {
            if isActive { Task { await reloadSources() } }
        }
        .onChange(of: esvSettings.revision) {
            if isActive { Task { await reloadSources() } }
        }
        .onChange(of: translationID) { Task { await lookup() } }
        .onChange(of: isActive) { if !isActive { playback.leaveWorkspace() } }
        .onChange(of: oneVerse) { rebuild() }
        .onChange(of: verseNumbers) { rebuild() }
        .onChange(of: showTranslation) { rebuild() }
        .onChange(of: showCopyright) { rebuild() }
        .onChange(of: shortCopyright) { rebuild() }
        .onChange(of: blockMapping) {
            UserDefaults.standard.set(try? JSONEncoder().encode(blockMapping), forKey: mappingKey)
            rebuild()
        }
        .onChange(of: themeID) {
            design = designs.first(where: { $0.name == "Bible" || $0.name.localizedCaseInsensitiveContains("Verse") })?.name
                ?? designs.first?.name ?? BibleSlideStyle.dark.rawValue
            loadBlockMapping()
            rebuild()
        }
        .onChange(of: design) { loadBlockMapping(); rebuild() }
        .alert("Bible", isPresented: $showingError) { Button("OK", role: .cancel) {} } message: { Text(errorText) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
            Text("Bible").font(.headline)
            Picker("Translation", selection: $translationID) {
                ForEach(bibles) { bible in Text(bible.pickerLabel).tag(bible.id) }
            }
            .frame(maxWidth: 340)
            .disabled(bibles.isEmpty)
            Spacer()
            Menu {
                Button("Import Bible JSON…", action: importBible)
                Button("Export Import Example…", action: exportExample)
                Divider()
                Button("Online Bible Settings…") {
                    SettingsRouter.shared.pending = .bible
                    openSettings()
                }
            } label: { Label("Translations", systemImage: "plus") }
            .disabled(bibles.isEmpty)
        }
        .padding(12)
    }

    private var lookupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Lookup mode", selection: $keywordMode) {
                Text("Passage").tag(false)
                Text("Search Words").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: keywordMode) { matches = []; notice = "" }
            HStack {
                TextField(keywordMode ? "Words to find…" : "John 3:16–18", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await lookup() } }
                Button { Task { await lookup() } } label: { Image(systemName: "magnifyingglass") }
                    .help("Look up Scripture")
                    .disabled(busy || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !keywordMode {
                HStack {
                    Picker("Book", selection: $bookID) {
                        ForEach(BibleBook.all.filter { selectedInfo?.chapters[$0.id] != nil }, id: \.id) { book in
                            Text(book.name).tag(book.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: bookID) { chapter = selectedInfo?.chapters[bookID]?.first ?? 1 }
                    Picker("Chapter", selection: $chapter) {
                        ForEach(selectedInfo?.chapters[bookID] ?? [], id: \.self) { Text("\($0)").tag($0) }
                    }
                    // The form label used to consume most of this narrow picker,
                    // clipping the chosen number. Keep it accessible but hide it visually.
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                    .help("Chapter \(chapter)")
                    Button("Go") {
                        query = "\(BibleBook.name(bookID)) \(chapter)"
                        Task { await lookup() }
                    }
                    .disabled(busy)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            Text("Find a reference, browse a chapter, or search words.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(isOnline ? "Online via \(isESV ? "ESV.org" : "API.Bible") · internet required" : "Available offline.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searchTotal > min(matches.count, 200) ? "First \(min(matches.count, 200)) of \(searchTotal) matches" : "\(matches.count) matches")
                .font(.caption).foregroundStyle(.secondary).padding([.top, .horizontal], 10)
            List(Array(matches.prefix(200))) { verse in
                Button { passage = [verse]; rebuild() } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verse.reference).font(.callout.bold()).foregroundStyle(.primary)
                        Text(verse.text).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Theme", selection: $themeID) {
                Text("Built-in").tag("")
                ForEach(model.entries(in: .themes)) { Text($0.name).tag($0.id) }
            }
            HStack {
                Picker("Design", selection: $design) {
                    if themeID.isEmpty {
                        ForEach(BibleSlideStyle.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    } else {
                        ForEach(designs) { Text($0.name).tag($0.name) }
                    }
                }
                Button { showingBlockMapping.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Assign verse, reference, and copyright text blocks")
                    .popover(isPresented: $showingBlockMapping) { blockMappingPopover }
            }
            if !hasValidMapping { Text("Choose a design with at least two text blocks.").font(.caption).foregroundStyle(.orange) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 8) {
                Toggle("One verse per slide", isOn: $oneVerse)
                Toggle("Verse numbers", isOn: $verseNumbers)
                Toggle("Translation", isOn: Binding(get: { showTranslation || isOnline }, set: { showTranslation = $0 })).disabled(isOnline)
                Toggle("Copyright", isOn: Binding(get: { showCopyright || isOnline }, set: { showCopyright = $0 })).disabled(isOnline)
            }
            .font(.caption)
            .toggleStyle(.checkbox)
            if isOnline { Text("Source attribution is included. Full copyright information is retained below.").font(.caption2).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
    }

    private var blockMappingPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bible Text Blocks").font(.headline)
            if themeID.isEmpty {
                Text("Built-in designs provide their own Verse, Reference and Copyright blocks.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let resolved = blockMapping.resolved(in: selectedTemplate)
                Picker("Verse", selection: $blockMapping.verse) {
                    Text("Automatic").tag("")
                    ForEach(Array(textBlocks.enumerated()), id: \.element.id) { index, block in
                        Text("\(index + 1). \(block.name)").tag(block.id).disabled(block.id == blockMapping.reference || block.id == blockMapping.copyright)
                    }
                }
                Picker("Reference", selection: $blockMapping.reference) {
                    Text("Automatic").tag("")
                    ForEach(Array(textBlocks.enumerated()), id: \.element.id) { index, block in
                        Text("\(index + 1). \(block.name)").tag(block.id).disabled(block.id == resolved.verse?.id || block.id == blockMapping.copyright)
                    }
                }
                Picker("Copyright", selection: $blockMapping.copyright) {
                    Text("Automatic (Copyright block or footer)").tag("")
                    Text("Small footer at bottom").tag(BibleBlockMapping.footer)
                    ForEach(Array(textBlocks.enumerated()), id: \.element.id) { index, block in
                        Text("\(index + 1). \(block.name)").tag(block.id).disabled(block.id == resolved.verse?.id || block.id == resolved.reference?.id)
                    }
                }
                Text("Verse: \(resolved.verse?.name ?? "None") · Reference: \(resolved.reference?.name ?? "None") · Copyright: \(resolved.copyright?.name ?? "Small footer")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Short copyright notice", isOn: $shortCopyright)
            Text("Full publisher notices stay in the app and saved slide notes. Block choices are remembered per theme and design.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
        .padding(18).frame(width: 400)
    }

    private func loadBlockMapping() {
        blockMapping = UserDefaults.standard.data(forKey: mappingKey)
            .flatMap { try? JSONDecoder().decode(BibleBlockMapping.self, from: $0) } ?? BibleBlockMapping()
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(passage.isEmpty ? "Scripture Preview" : title).font(.headline).textSelection(.enabled)
                Spacer()
                Button { Task { await adjacent(-1) } } label: { Image(systemName: "chevron.left") }
                    .help("Previous verse (preview)")
                Button { Task { await adjacent(1) } } label: { Image(systemName: "chevron.right") }
                    .help("Next verse (preview)")
            }
            .disabled(busy || passage.isEmpty)
            if !slides.isEmpty {
                Text(playback.isPresenting
                     ? "\(slides.count) slides · Presentation Mode is on · click to go live"
                     : "\(slides.count) slides · click to select · enable Presentation Mode to go live")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                            slideCard(slide, index: index)
                        }
                    }
                    .padding(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Passage Preview", systemImage: "rectangle.on.rectangle",
                    description: Text(notice.isEmpty ? "Find Scripture above to prepare slides or present it live." : notice))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            DisclosureGroup("Copyright & source") {
                Text(translation?.copyright ?? selectedInfo?.copyright ?? "").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if isESV {
                    Link("English Standard Version · ESV.org", destination: URL(string: "https://www.esv.org")!).font(.caption)
                } else if isOnline {
                    Link("Scripture provided by API.Bible", destination: URL(string: "https://api.bible")!).font(.caption)
                }
            }
            if isOnline {
                Link(isESV ? "ESV.org" : "API.Bible", destination: URL(string: isESV ? "https://www.esv.org" : "https://api.bible")!).font(.caption2)
            }
        }
        .padding(.horizontal, 4)
    }

    private func slideCard(_ slide: Slide, index: Int) -> some View {
        let live = controls?.liveSlideID == slide.id
        return Button {
            if let requested = playback.select(index, slideCount: slides.count) {
                presentSlide(at: requested)
            } else {
                notice = "Selected \(slide.name) · slide \(index + 1) of \(slides.count)"
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                BibleSlidePreview(model: model, render: render, slide: slide, theme: model.theme(themeID))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(live ? Color.red : (playback.selectedIndex == index ? Color.accentColor : Color.clear), lineWidth: 3))
                HStack {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(slide.name).lineLimit(1)
                    Spacer(minLength: 2)
                    if live { Text("LIVE").font(.caption2.bold()).foregroundStyle(.red) }
                }
                .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canUse || (!themeID.isEmpty && designs.isEmpty))
        .help(playback.isPresenting ? "Present \(slide.name) now" : "Select \(slide.name)")
        .accessibilityLabel("\(playback.isPresenting ? "Present" : "Select") slide \(index + 1): \(slide.name)")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !notice.isEmpty { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Picker("Add to", selection: $targetID) {
                    Text("Choose Presentation…").tag("")
                    ForEach(model.entries(in: .presentations)) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 300)
                Button("Add Slides") { Task { await append() } }
                    .disabled(!canUse || targetID.isEmpty || (!themeID.isEmpty && designs.isEmpty))
                Spacer()
            }
            HStack {
                Text(playback.isPresenting ? "Presentation Mode is on · slide clicks go live" : "Preparation · slide clicks select only")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(savedID == nil ? "Save as New Presentation" : "Saved to Library") { Task { await save() } }
                    .disabled(!canUse || savedID != nil || (!themeID.isEmpty && designs.isEmpty))
                Button {
                    if let requested = playback.togglePresentationMode(slideCount: slides.count) {
                        presentSlide(at: requested)
                    }
                } label: {
                    Label("Presentation Mode", systemImage: playback.isPresenting ? "record.circle.fill" : "play.circle")
                }
                    .buttonStyle(.borderedProminent)
                    .tint(playback.isPresenting ? .red : .accentColor)
                    .help("Turn on to present the selected slide and make future slide clicks go live. Turn off to select without changing output.")
                    .accessibilityValue(playback.isPresenting ? "On" : "Off")
                    .disabled(!canUse || controls == nil || (!themeID.isEmpty && designs.isEmpty))
            }
        }
        .padding(14)
    }

    private func lookup() async {
        // A translation change can overtake an earlier lookup. Ignore old results
        // so the displayed translation, verses, and generated slides always agree.
        let request = UUID(); requestID = request
        busy = true; matches = []; passage = []; slides = []; translation = nil; savedID = nil; notice = ""
        do {
            let metadata: BibleTranslation
            let verses: [BibleVerse]
            let total: Int
            var viewReport: (BibleAPIClient, String?)?
            if isESV {
                let client = try await esvSettings.client()
                let result = try await client.lookup(query: query, search: keywordMode)
                try await checkESVStorage(result.verses)
                metadata = result.translation; verses = result.verses; total = result.total
            } else if let apiID = selectedInfo?.apiBibleID {
                let client = try await apiSettings.client()
                let details = try await client.details(id: apiID)
                guard requestID == request else { return }
                if let index = bibles.firstIndex(where: { $0.id == translationID }) {
                    bibles[index].chapters = details.chapters
                }
                if details.chapters[bookID] == nil, let first = BibleBook.all.first(where: { details.chapters[$0.id] != nil }) {
                    bookID = first.id
                }
                if !(details.chapters[bookID] ?? []).contains(chapter) { chapter = details.chapters[bookID]?.first ?? 1 }
                let result = try await client.lookup(bible: details.bible, query: query, search: keywordMode)
                metadata = result.translation; verses = result.verses; total = result.total
                viewReport = (client, result.viewToken)
            } else {
                let result = try await repository.lookup(id: translationID, query: query, search: keywordMode)
                metadata = result.0; verses = result.1; total = verses.count
            }
            guard requestID == request else { return }
            translation = metadata; matches = verses; searchTotal = total
            passage = keywordMode ? verses.first.map { [$0] } ?? [] : verses
            rebuild()
            if matches.isEmpty { notice = "No verses matched. Try another search." }
            if !verses.isEmpty, let (client, token) = viewReport {
                Task { await client.reportView(token: token) }
            }
        } catch {
            guard requestID == request else { return }
            notice = error.localizedDescription
        }
        busy = false
    }

    private func rebuild() {
        // Stable slide IDs between rebuilds let the grid identify the on-air card.
        // Editing options creates a new draft; it must not relabel existing output.
        savedID = nil; playback.resetSelection(); notice = ""
        previewPresentationID = "bible-preview-" + UUID().uuidString
        guard let translation else { slides = []; return }
        let pages = BibleSlides.pages(verses: passage, oneVersePerSlide: oneVerse, verseNumbers: verseNumbers,
                                     maxCharacters: style == .lowerThird ? 240 : 450)
        slides = pages.map { BibleSlides.slide(page: $0, translation: translation, style: style,
                        showTranslation: showTranslation || isOnline, showCopyright: showCopyright || isOnline, themeID: themeID, design: design,
                        template: selectedTemplate, mapping: blockMapping, shortCopyright: shortCopyright) }
        if !themeID.isEmpty, blockMapping.resolved(in: selectedTemplate).copyright == nil,
           let color = model.theme(themeID)?.textColorHex {
            for index in slides.indices {
                if let footer = slides[index].objects.firstIndex(where: { $0.name == "Copyright" }) {
                    slides[index].objects[footer].textStyle?.colorHex = color
                }
            }
        }
    }

    private func adjacent(_ offset: Int) async {
        guard !busy, let verse = offset < 0 ? passage.first : passage.last else { return }
        let sourceID = translationID
        let reference: String?
        do {
            if isESV {
                let client = try await esvSettings.client()
                reference = try await client.adjacent(to: verse, offset: offset)
            } else if let apiID = selectedInfo?.apiBibleID {
                let client = try await apiSettings.client()
                reference = try await client.adjacentReference(bibleID: apiID, verseID: verse.id, offset: offset)
            } else {
                reference = await repository.adjacent(id: sourceID, verse: verse, offset: offset)?.reference
            }
            guard translationID == sourceID, let reference else { return }
            keywordMode = false; query = reference
            await lookup()
        } catch { notice = error.localizedDescription }
    }

    private func reloadSources() async {
        do {
            if offlineBibles.isEmpty {
                let loaded = try await repository.load()
                offlineBibles = loaded.bibles
                if !loaded.warnings.isEmpty { showError(loaded.warnings) }
            }
            // Namespace online IDs so an imported translation can never shadow
            // an account's Bible. Settings metadata contains no Scripture or keys.
            let online = apiSettings.available.map { bible in
                BibleInfo(id: "api:" + bible.id, name: bible.name, copyright: bible.copyright,
                          chapters: bibles.first(where: { $0.apiBibleID == bible.id })?.chapters ?? [:],
                          apiBibleID: bible.id, abbreviation: bible.abbreviation)
            }
            let wasOnline = isOnline
            var direct: [BibleInfo] = []
            if esvSettings.hasKey && esvSettings.enabled {
                direct = [BibleInfo(id: "esv:crossway", name: "English Standard Version", copyright: ESVClient.copyright,
                    chapters: offlineBibles.first(where: { $0.id == "WEB" })?.chapters ?? [:], abbreviation: "ESV", directESV: true)]
            }
            bibles = offlineBibles + online + direct
            appliedAPIRevision = apiSettings.revision
            let credentialsChanged = appliedCredentialRevision != apiSettings.credentialRevision || appliedESVRevision != esvSettings.revision
            appliedESVRevision = esvSettings.revision
            appliedCredentialRevision = apiSettings.credentialRevision
            if !bibles.contains(where: { $0.id == translationID }) {
                // Removing a selected translation invalidates its pending request
                // and disarms clicks; it must never silently change live output.
                requestID = UUID(); playback.leaveWorkspace()
                translationID = "WEB"
            } else if wasOnline, credentialsChanged {
                playback.leaveWorkspace()
                await lookup()
            }
        } catch { busy = false; showError(error.localizedDescription) }
    }

    private func presentSlide(at index: Int) {
        guard canUse, let controls, slides.indices.contains(index) else { return }
        // ServiceControls retains this complete in-memory presentation for rendering
        // and next-slide confidence data. No AppModel.createPresentation call here:
        // only Save as New Presentation and Add Slides may persist Scripture.
        let presentation = Presentation(id: previewPresentationID, name: title,
                                        presentationKind: .deck, themeId: themeID, slides: slides)
        controls.fire(slide: slides[index], in: presentation,
                      contextID: previewPresentationID, occurrence: index, slideActions: false)
        notice = "Presenting \(slides[index].name) · slide \(index + 1) of \(slides.count)"
    }

    private func checkESVStorage(_ pending: [BibleVerse]) async throws {
        let entries = model.entries(of: .presentation)
        let documents = await model.presentationsFilled(entries.map(\.id))
        guard documents.count == entries.count else { throw BibleError.message("The library is still loading. Please try again before saving ESV slides.") }
        let ids = ESVStorage.ids(in: documents.values.flatMap(\.slides))
        try ESVStorage.validate(pending: pending, saved: ids)
    }

    private func save() async {
        guard canUse else { return }
        let draft = previewPresentationID
        saving = true
        defer { saving = false }
        if isESV {
            do { try await checkESVStorage(passage) } catch { showError(error.localizedDescription); return }
            guard draft == previewPresentationID else { return }
        }
        let id: String
        if let savedID { id = savedID }
        else {
            guard let created = model.createPresentation(named: title, folder: nil, themeId: themeID, slides: slides,
                                                        sections: [], arrangement: nil) else {
                showError("The presentation could not be saved."); return
            }
            id = created; savedID = id
        }
        model.selectedSection = .presentations
        model.selectedEntryID = id
        model.libraryRevealID = id
        notice = "Saved \(title) · \(slides.count) slides"
    }

    private func append() async {
        guard canUse, !targetID.isEmpty else { return }
        let draft = previewPresentationID
        saving = true
        defer { saving = false }
        if isESV {
            do { try await checkESVStorage(passage) } catch { showError(error.localizedDescription); return }
            guard draft == previewPresentationID else { return }
        }
        // A second insertion must have fresh object and slide identities.
        let copies = slides.map { slide in
            var copy = slide; copy.id = UUID().uuidString
            copy.objects = copy.objects.map { object in var item = object; item.id = UUID().uuidString; return item }
            return copy
        }
        if model.appendSlides(copies, sections: [], to: targetID) {
            notice = "Added \(slides.count) slides to \(model.entry(targetID)?.name ?? "the presentation")."
        } else { showError("The destination presentation is unavailable. Choose another presentation.") }
    }

    private func importBible() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Import a translation you are authorized to use. Use Export Import Example to see the supported format."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let old = Set(bibles.map(\.id))
                    offlineBibles = try await repository.importBible(url)
                    bibles = offlineBibles + bibles.filter { $0.apiBibleID != nil || $0.directESV }
                    if let added = bibles.first(where: { !old.contains($0.id) }) { translationID = added.id }
                    notice = "Translation installed. It is available offline on this Mac."
                } catch { showError(error.localizedDescription) }
            }
        }
    }

    private func exportExample() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Bible-import-example.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let example = BibleTranslation(id: "MY-BIBLE", name: "My Bible Translation", copyright: "Supply the translation's required copyright notice.",
                    verses: [BibleVerse(book: "GEN", chapter: 1, verse: 1, text: "In the beginning, God created the heavens and the earth.")])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(example).write(to: url, options: .atomic)
            } catch { showError(error.localizedDescription) }
        }
    }

    private func showError(_ message: String) { errorText = message; showingError = true }
}

private struct BibleSlidePreview: View {
    let model: AppModel
    let render: RenderContext?
    let slide: Slide
    let theme: Theme?

    var body: some View {
        ZStack {
            TransparencyGrid()
            if let image = ThumbnailStore.shared.slideContent(slide: slide, theme: theme, render: render, model: model,
                canvas: SlideSceneBuilder.canvasSize, cacheKey: "bible|\(slide.id)|\(theme?.id ?? "")|\(model.entry(theme?.id ?? "")?.updatedAt.timeIntervalSince1970 ?? 0)") {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
