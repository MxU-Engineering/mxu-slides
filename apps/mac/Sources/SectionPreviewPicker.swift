import PresenterCore
import SwiftUI

struct SectionPreviewPicker: View {
    let model: AppModel
    let render: RenderContext?
    let presentation: Presentation

    var contentStamp: String? = nil

    var shown: (Slide) -> Slide = { $0 }
    let onPick: (PresentationSection) -> Void

    private let rows: [Row]
    @State private var hovered: String?

    struct Row: Identifiable {
        let section: PresentationSection
        let slides: [Slide]
        let firstLine: String

        let chords: String
        var id: String { section.id }
    }

    init(model: AppModel, render: RenderContext?, presentation: Presentation, contentStamp: String? = nil,
         shown: @escaping (Slide) -> Slide = { $0 }, onPick: @escaping (PresentationSection) -> Void) {
        self.model = model
        self.render = render
        self.presentation = presentation
        self.contentStamp = contentStamp
        self.shown = shown
        self.onPick = onPick
        let slides = Dictionary(grouping: presentation.slides) { $0.sectionId ?? "" }
        rows = (presentation.sections ?? []).map { section in
            let own = slides[section.id] ?? []
            let line = own.lazy.flatMap(\.objects).map(\.text)
                .compactMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let chords = own.first?.objects.flatMap { $0.chords ?? [] }.map(\.symbol) ?? []
            return Row(section: section, slides: own, firstLine: line ?? "", chords: chords.prefix(6).joined(separator: "  "))
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(6)
            }
            .frame(width: 230)
            Divider()
            previewPane
                .frame(width: 340)
        }
        .frame(height: 340)
    }

    private func rowView(_ row: Row) -> some View {
        Button {
            onPick(row.section)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(GroupColor.fill(row.section, palette: model.groupColors) ?? Color.secondary)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(row.section.name)
                            .font(.callout.weight(.medium))
                        Text(row.slides.count == 1 ? "1 slide" : "\(row.slides.count) slides")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if !row.firstLine.isEmpty {
                        Text(row.firstLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !row.chords.isEmpty {
                        Text(row.chords)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.orange.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovered == row.id ? Color.accentColor.opacity(0.18) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = row.id
            } else if hovered == row.id {
                hovered = nil
            }
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let row = rows.first(where: { $0.id == hovered }) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(row.slides, id: \.id) { slide in
                        SlideThumbnailView(
                            model: model, render: render,
                            slide: shown(slide), presentation: presentation, theme: model.theme(presentation.themeId),
                            arrangementId: nil, hideScopedBackgrounds: false,
                            contentStamp: contentStamp
                        )
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: CornerStandard.element, style: .continuous))
                    }
                }
                .padding(10)
            }
        } else {
            Text("Point at a section to see its slides")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
