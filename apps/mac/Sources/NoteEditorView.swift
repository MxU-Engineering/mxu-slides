import PresenterCore
import SwiftUI

struct NoteEditorView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let noteID: String

    @State private var actions = NoteEditorActions()

    var body: some View {
        HStack(spacing: 0) {
            NoteReaderView(model: model, noteID: noteID, host: .editor, render: render, controls: controls, editorActions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NoteInspectorView(model: model, render: render, noteID: noteID, actions: actions)
                .frame(width: 300)
        }
    }
}

struct NoteInspectorView: View {
    let model: AppModel
    let render: RenderContext?
    let noteID: String
    let actions: NoteEditorActions

    @AppStorage("notes.fontSize.editor") private var editorFontSize = 16.0
    @State private var note: NoteDocument?
    @State private var deck: Presentation?
    @State private var shelf: [(number: Int, slide: Slide)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                slidesPane
                displayPane
                infoPane
            }
            .padding(14)
        }
        .task(id: NoteDeckKey(deck: actions.note?.presentationId.flatMap { $0.isEmpty ? nil : model.presentation($0) }, noteVersion: actions.noteLoads)) {
            note = actions.note
            guard let deckID = note?.presentationId, !deckID.isEmpty, let loaded = model.presentation(deckID),
                  let body = note?.body else {
                deck = nil
                shelf = []
                return
            }
            deck = loaded
            let unplaced = Set(NoteDeckCards.unplaced(deck: loaded, in: body).map(\.id))
            shelf = loaded.slides.enumerated().filter { unplaced.contains($0.element.id) }.map { (number: $0.offset + 1, slide: $0.element) }
        }
    }

    private func pane<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var slidesPane: some View {
        pane("Slides") {
            if let deck {
                HStack(spacing: 8) {
                    Text("\(deck.name)").font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(deck.slides.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Deck") { model.openInEditor(entryID: deck.id) }.font(.caption)
                }
            } else {
                Text("No deck yet. Make Slides turns the marked passages into one.").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                actions.makeSlides?()
            } label: {
                Label("Make Slides…", systemImage: "rectangle.on.rectangle")
            }
            if let deck, !shelf.isEmpty {
                Text("Not in this note").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                thumbnailRow(shelf.map { ($0.number, $0.slide, deck) })
            }
            let decks = servicePresentations
            if !decks.isEmpty {
                Text("Insert a slide: drag into the note").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(decks, id: \.id) { source in
                    DisclosureGroup("\(source.name) (\(source.slides.count))") {
                        thumbnailRow(source.slides.enumerated().map { ($0.offset + 1, $0.element, source) })
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func thumbnailRow(_ entries: [(Int, Slide, Presentation)]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(entries, id: \.1.id) { number, slide, source in
                    VStack(spacing: 2) {
                        SlideThumbnailView(
                            model: model, render: render, slide: slide, presentation: source,
                            theme: model.theme(for: slide, in: source), arrangementId: nil,
                            hideScopedBackgrounds: false)
                        .aspectRatio(SlideGridMetrics.tileAspect(for: source), contentMode: .fit)
                        .frame(width: 96)
                        .clipShape(RoundedRectangle.standard(CornerStandard.element))
                        Text("\(number)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .draggablePayload("mxuslide::\(source.id)::\(slide.id)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var servicePresentations: [Presentation] {
        guard let serviceID = model.currentServiceID, let service = try? model.service(serviceID) else { return [] }
        var seen: Set<String> = []
        return service.items.compactMap { item in
            guard item.itemKind == .presentation, !item.refId.isEmpty, !seen.contains(item.refId),
                  let presentation = model.presentation(item.refId) else { return nil }
            seen.insert(item.refId)
            return presentation
        }
    }

    private var displayPane: some View {
        pane("Display") {
            Picker("In-line slides", selection: Binding(
                get: { actions.display },
                set: { actions.setDisplay?($0) })) {
                ForEach(NoteSlideDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Text size").font(.caption)
                Spacer()
                Stepper("\(Int(editorFontSize))", value: $editorFontSize, in: 10 ... 28).font(.caption)
            }
        }
    }

    private var infoPane: some View {
        pane("Info") {
            if let note {
                Text(note.name).font(.callout.weight(.medium))
                if let folder = note.folder, !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
