import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

struct ServiceItemChooser: View {
    enum Purpose {

        case link(itemID: String, planSync: PlanSyncController)

        case add
    }

    let model: AppModel
    let serviceID: String
    let purpose: Purpose

    var render: RenderContext? = nil

    let openInEditor: (String) -> Void

    var showItem: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var tab: ServiceItemChooserLogic.Tab = .library
    @State private var query = ""
    @State private var filter: ServiceItemChooserLogic.KindFilter = .all
    @State private var suggestions: [LibraryIndex.Entry] = []

    @State private var queryHits: [LibraryIndex.Hit] = []

    @State private var proPresenterIDs: Set<String> = []

    @State private var idleOrder: [String] = []
    @State private var choosingFiles = false
    @State private var dropTargeted = false

    @State private var skippedNote: String?
    @State private var newName = ""
    @State private var newThemeId = ""
    @FocusState private var searchFocused: Bool

    private var linkTarget: (itemID: String, planSync: PlanSyncController)? {
        if case .link(let itemID, let planSync) = purpose { (itemID, planSync) } else { nil }
    }

    private var tabs: [ServiceItemChooserLogic.Tab] {
        ServiceItemChooserLogic.tabs(offersPlanningCenter: linkTarget.map {
            $0.planSync.canCreateFromLyrics(serviceID: serviceID, itemID: $0.itemID)
        } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $tab) {
                ForEach(tabs, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if tab == .planningCenter, let linkTarget {

                LyricsCreateSheet(
                    appModel: model, render: render, planSync: linkTarget.planSync,
                    serviceID: serviceID, itemID: linkTarget.itemID
                ) { id, edit in
                    if edit {
                        openInEditor(id)
                    } else {
                        showItem?(linkTarget.itemID)
                    }
                }
            } else {
                Group {
                    switch tab {
                    case .importFile: importPane
                    case .new: newPane
                    default: libraryPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
                    .padding(10)
            }
        }
        .frame(width: tab == .planningCenter ? nil : 600, height: tab == .planningCenter ? nil : 480)
        .onAppear {
            searchFocused = true
            idleOrder = ServiceItemChooserLogic.results(query: "", hits: [], idle: idleEntries, filter: .all).map(\.entry.id)
        }
        .task { proPresenterIDs = await model.proPresenterImportIDs() }
        .task {
            if let linkTarget {
                suggestions = await linkTarget.planSync.linkSuggestions(serviceID: serviceID, itemID: linkTarget.itemID)
                newName = linkTarget.planSync.newPresentationName(serviceID: serviceID, itemID: linkTarget.itemID) ?? ""
            }
        }
        .task(id: query) {
            queryHits = await model.search(query)
        }
        .fileImporter(
            isPresented: $choosingFiles, allowedContentTypes: ServiceItemChooserLogic.importTypes,
            allowsMultipleSelection: linkTarget == nil
        ) { result in
            if case .success(let urls) = result { importUsable(urls) }
        }
    }

    private var libraryPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    TextField("Search the library", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle.standard(CornerStandard.element))
                Picker("Show", selection: $filter) {
                    ForEach(ServiceItemChooserLogic.KindFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(10)
            Divider()
            if !suggestions.isEmpty, query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Suggested")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    ForEach(suggestions.filter { filter.includes($0.kind) }, id: \.id) { entry in
                        row(LibraryIndex.Hit(entry: entry, snippet: nil))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 6)
                Divider()
            }
            let hits = results
            List(hits, id: \.entry.id) { hit in
                row(hit)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if hits.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "No Slides or Media", systemImage: "magnifyingglass",
                            description: Text("Import a file or make a new presentation from the tabs above.")
                        )
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
    }

    private var results: [LibraryIndex.Hit] {
        let hits = ServiceItemChooserLogic.results(query: query, hits: queryHits, idle: idleEntries, filter: filter)
        return query.trimmingCharacters(in: .whitespaces).isEmpty
            ? ServiceItemChooserLogic.steady(hits, order: idleOrder)
            : hits
    }

    private var idleEntries: [LibraryIndex.Entry] {
        model.entries(of: .presentation) + model.entries(of: .media)
    }

    @ViewBuilder
    private func row(_ hit: LibraryIndex.Hit) -> some View {
        let accessory = linkTarget == nil ? "plus.circle" : nil
        if hit.entry.kind == .presentation {
            LibraryPickerDeckRow(
                appModel: model, render: render, entry: hit.entry,
                proPresenterIDs: proPresenterIDs, snippet: hit.snippet, accessory: accessory
            ) {
                pick(hit.entry)
            }
        } else {
            Button {
                pick(hit.entry)
            } label: {
                HStack(spacing: 8) {
                    if hit.entry.kind == .media {

                        Color.black
                            .overlay { PosterImage(model: model, mediaId: hit.entry.id) }
                            .frame(width: 46, height: 26)
                            .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    } else {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                            .frame(width: 46)
                    }
                    Text(hit.entry.name)
                        .lineLimit(1)
                    Spacer()
                    if let used = hit.entry.lastUsedAt {
                        Text("Used \(used, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let accessory {
                        Image(systemName: accessory)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func pick(_ entry: LibraryIndex.Entry) {
        if let linkTarget {
            linkTarget.planSync.link(serviceID: serviceID, itemID: linkTarget.itemID, to: entry)
            dismiss()
        } else {
            model.addServiceItem(serviceID, refID: entry.id)
        }
    }

    private var importPane: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Drop a file here, or choose one")
                .font(.headline)
            Text("Images and video, ProPresenter (.pro), PowerPoint (.pptx), MxU Slides (.mxuslides), lyrics or ChordPro text, chord chart PDFs")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text(linkTarget == nil ? "Each file becomes a service item." : "One file links this item.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let skippedNote {
                Label(skippedNote, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .padding(16)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            importUsable(urls)
        } isTargeted: { dropTargeted = $0 }
    }

    @discardableResult
    private func importUsable(_ urls: [URL]) -> Bool {
        if let refusal = ServiceItemChooserLogic.refusal(urls, linking: linkTarget != nil) {
            skippedNote = refusal
            return false
        } else {
            importNow(urls.filter { ServiceItemChooserLogic.route($0) != nil })
            return true
        }
    }

    private func importNow(_ urls: [URL]) {
        let serviceID = serviceID
        let model = model
        let linkTarget = linkTarget
        dismiss()
        Task { @MainActor in
            if let linkTarget {
                await linkTarget.planSync.importAndLink(serviceID: serviceID, itemID: linkTarget.itemID, urls: urls)
            } else {
                for id in await model.importForService(urls) {
                    model.addServiceItem(serviceID, refID: id)
                }
            }
        }
    }

    private var newPane: some View {
        Form {
            TextField("Name", text: $newName, prompt: Text("Untitled Presentation"))
            LabeledContent("Theme") {
                LyricsThemeChooser(appModel: model, render: render, themeId: newThemeId) { themeId, _ in
                    newThemeId = themeId
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func createNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? "Untitled Presentation" : trimmed
        if let linkTarget {
            if let id = linkTarget.planSync.createPresentationAndLink(
                serviceID: serviceID, itemID: linkTarget.itemID, name: name, themeId: newThemeId) {
                dismiss()
                openInEditor(id)
            }
        } else if let id = model.createPresentation(named: name, themeId: newThemeId) {
            model.addServiceItem(serviceID, refID: id)
            dismiss()
        }
    }

    private var footer: some View {
        HStack {
            if tab == .importFile {
                Button("Choose Files…") { choosingFiles = true }
            }
            Spacer()
            if linkTarget == nil, tab == .library {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if tab == .new {
                Button(linkTarget == nil ? "Create and Add" : "Create and Link") { createNew() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension AppModel {

    func importForService(_ urls: [URL]) async -> [String] {
        var landed: [String] = []
        for route in ServiceItemChooserLogic.ImportRoute.allCases {
            let files = urls.filter { ServiceItemChooserLogic.route($0) == route }
            if !files.isEmpty {
                landed += await importFiles(files, through: route)
            }
        }
        await client.settled()
        return landed
    }

    private func importFiles(_ files: [URL], through route: ServiceItemChooserLogic.ImportRoute) async -> [String] {
        switch route {
        case .slidesFile: await importPresentationFiles(files)
        case .proPresenter: await runProPresenterImport(files)
        case .powerPoint: await runPowerPointImport(files)
        case .lyrics: await importLyricsFiles(files)
        case .media: await importFiles(files)
        }
    }

    func importLyricsFiles(_ urls: [URL]) async -> [String] {
        var ids: [String] = []
        for url in urls {
            let text = await Task.detached {
                (try? Data(contentsOf: url)).flatMap { ChordChartPDF.importText(from: $0, filename: url.lastPathComponent) }
            }.value
            if let text, let id = importLyrics(
                text: text,
                fallbackTitle: url.deletingPathExtension().lastPathComponent,
                themeId: slideBuilding.lyricsImportThemeId ?? "",
                themeSlideName: slideBuilding.lyricsDesign,
                origin: PresentationOrigin(
                    url.pathExtension.lowercased() == "pdf" ? .chartFile : .lyricsFile,
                    detail: url.lastPathComponent)
            ) {
                ids.append(id)
            }
        }
        return ids
    }
}
