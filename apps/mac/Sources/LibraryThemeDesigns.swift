import PresenterCore
import SwiftUI

struct LibraryThemeDesigns: View {
    let model: AppModel
    let render: RenderContext?
    let entry: LibraryIndex.Entry

    let editor: SlideEditorModel?

    let gridColumns: Int?

    let opensOnClick: Bool
    let close: () -> Void
    let edit: (_ designID: String) -> Void

    @Environment(\.runOnly) private var runOnly

    @State private var look: ThemeLook?
    @State private var selection: String?

    var body: some View {
        let theme = model.theme(entry.id)
        VStack(spacing: 0) {
            header
            Group {
                if let gridColumns {
                    grid(columns: gridColumns)
                } else {
                    list
                }
            }
            .overlay {
                if look == nil {
                    ProgressView()
                } else if look?.theme.slides?.isEmpty != false {
                    ContentUnavailableView("No Designs", systemImage: "paintpalette", description: Text("This theme has no designs yet."))
                }
            }
        }
        .task(id: entry.id) { await model.themesFilled([entry.id]) }
        .onChange(of: selection) { _, id in
            if let id { pick(id) }
        }
        .onChange(of: theme, initial: true) { _, theme in
            look = theme.map { ThemeLook($0, stamp: "\(model.entry(entry.id)?.updatedAt.timeIntervalSince1970 ?? 0)") }
        }
    }

    private func pick(_ id: String) {
        if let editor {
            editor.selectSlide(id)
        } else if opensOnClick {
            edit(id)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if let look {
                ForEach(ThemeExplorer.looseDesigns(in: look.theme), id: \.id) { row($0, in: look) }
                ForEach(ThemeExplorer.folders(in: look.theme), id: \.name) { folder in
                    Section(folder.name) {
                        ForEach(folder.designs, id: \.id) { row($0, in: look) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func grid(columns: Int) -> some View {
        ScrollView {
            if let look {
                VStack(alignment: .leading, spacing: 10) {
                    cards(ThemeExplorer.looseDesigns(in: look.theme), in: look, columns: columns)
                    ForEach(ThemeExplorer.folders(in: look.theme), id: \.name) { folder in
                        Text(folder.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        cards(folder.designs, in: look, columns: columns)
                    }
                }
                .padding(8)
            }
        }
    }

    private func cards(_ designs: [Slide], in look: ThemeLook, columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 10) {
            ForEach(designs, id: \.id) { design in
                VStack(spacing: 4) {
                    face(design, in: look)
                        .frame(maxWidth: .infinity)
                    Text(design.name).font(.caption).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .modifier(LibraryCardFireOverlay(actions: actions(design)))
                .contentShape(Rectangle())
                .onTapGesture { selection = design.id }
                .accessibilityAddTraits(.isButton)
                .overlay {
                    if selection == design.id {
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .modifier(DesignDragAndMenu(design: design, look: look, runOnly: runOnly, edit: edit))
            }
        }
    }

    private func actions(_ design: Slide) -> LibraryFireActions? {
        LibraryFireActions(model: model, controls: nil, entry: entry) { edit(design.id) }
    }

    private func face(_ design: Slide, in look: ThemeLook) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            if let slide = look.previews[design.id] {
                SlideThumbnailView(
                    model: model, render: render,
                    slide: slide, presentation: look.deck, theme: look.theme,
                    arrangementId: nil, hideScopedBackgrounds: false,
                    contentStamp: look.stamp
                )
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 3) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back")
            Button(action: close) {
                Text("Themes").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(entry.name).font(.caption.weight(.medium)).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func row(_ design: Slide, in look: ThemeLook) -> some View {
        DesignRow(actions: actions(design)) {
            face(design, in: look).frame(width: 64)
            Text(design.name).lineLimit(1)
        }
        .tag(design.id)
        .modifier(DesignDragAndMenu(design: design, look: look, runOnly: runOnly, edit: edit))
    }
}

private struct DesignRow<Label: View>: View {
    let actions: LibraryFireActions?
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            label()
            Spacer(minLength: 4)
            if let actions {
                LibraryRowFireControls(actions: actions, hovering: hovering)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct DesignDragAndMenu: ViewModifier {
    let design: Slide
    let look: ThemeLook
    let runOnly: Bool
    let edit: (String) -> Void

    func body(content: Content) -> some View {
        content
            .draggablePayload(runOnly ? nil : ThemeDesignDrag.payload(themeId: look.theme.id, designId: design.id))
            .contextMenu {
                if !runOnly {
                    Button("Edit…") { edit(design.id) }
                }
            }
            .help(runOnly ? design.name : "Drag onto a slide to give it this design")
    }
}
