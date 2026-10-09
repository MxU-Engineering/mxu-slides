import PresenterCore
import SwiftUI

struct LibraryPickerDeckRow: View {
    let appModel: AppModel
    let render: RenderContext?
    let entry: LibraryIndex.Entry

    let proPresenterIDs: Set<String>
    let onPick: () -> Void

    @State private var hovering = false
    @State private var peeking = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .lineLimit(1)
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(when)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }

        .task(id: hovering) {
            if hovering, render != nil {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { peeking = true }
            } else {
                peeking = false
            }
        }
        .popover(isPresented: $peeking, arrowEdge: .trailing) {
            DeckPeek(appModel: appModel, render: render, entry: entry, origin: origin)
        }
    }

    private var origin: String {
        if !entry.origin.isEmpty {
            entry.origin
        } else if proPresenterIDs.contains(entry.id) {
            "ProPresenter import"
        } else {
            ""
        }
    }

    private var details: String {
        let folder = entry.subkind.replacingOccurrences(of: "/", with: " › ")
        return [folder, origin].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var when: String {
        if let used = entry.lastUsedAt {
            "Used \(used.formatted(.relative(presentation: .named)))"
        } else {
            "Edited \(entry.updatedAt.formatted(.relative(presentation: .named)))"
        }
    }
}

private struct DeckPeek: View {
    let appModel: AppModel
    let render: RenderContext?
    let entry: LibraryIndex.Entry
    let origin: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.headline)
                    .lineLimit(1)
                if !origin.isEmpty {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let presentation = appModel.presentation(entry.id) {
                Text(summary(presentation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let shown = Array(presentation.slides.filter { !$0.objects.isEmpty }.prefix(6))
                LazyVGrid(columns: [GridItem(.fixed(132), spacing: 6), GridItem(.fixed(132), spacing: 6)], spacing: 6) {
                    ForEach(shown, id: \.id) { slide in
                        SlideThumbnailView(
                            model: appModel, render: render,
                            slide: slide, presentation: presentation,
                            theme: appModel.theme(presentation.themeId),
                            arrangementId: nil,
                            hideScopedBackgrounds: false, legibleText: false,
                            contentStamp: "peek-\(entry.updatedAt.timeIntervalSince1970)"
                        )
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: CornerStandard.element, style: .continuous))
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 270, height: 80)
            }
        }
        .padding(12)
        .frame(width: 294)
    }

    private func summary(_ presentation: Presentation) -> String {
        let sections = (presentation.sections ?? []).map(\.name)
        let uniqueSections = sections.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return [
            "\(presentation.slides.count) slide\(presentation.slides.count == 1 ? "" : "s")",
            presentation.musicKey.map { "Key of \($0)" },
            uniqueSections.isEmpty ? nil : uniqueSections.prefix(6).joined(separator: ", "),
            "Edited \(entry.updatedAt.formatted(date: .abbreviated, time: .omitted))",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}
