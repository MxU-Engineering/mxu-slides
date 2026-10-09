import PresenterCore
import SwiftUI

struct ThemeLook: Identifiable {
    let theme: Theme
    let deck: Presentation
    let previews: [String: Slide]
    let stamp: String
    var id: String { theme.id }

    @MainActor
    static func load(_ appModel: AppModel, firstThemeId: String) async -> [ThemeLook] {
        let entries = appModel.entries(in: .themes)
        await appModel.themesFilled(entries.map(\.id))
        let ordered = entries.filter { $0.id == firstThemeId } + entries.filter { $0.id != firstThemeId }
        return ordered.compactMap { entry in
            appModel.theme(entry.id).map { theme in
                let designs = theme.slides ?? []
                let slides = designs.map { NewSlide.preview(of: $0, themeId: theme.id) }
                return ThemeLook(
                    theme: theme,
                    deck: Presentation(
                        id: "newSlide|\(theme.id)", name: theme.name, presentationKind: .deck,
                        themeId: theme.id, slides: slides),

                    previews: Dictionary(zip(designs.map(\.id), slides), uniquingKeysWith: { first, _ in first }),
                    stamp: "\(entry.updatedAt.timeIntervalSince1970)")
            }
        }
    }
}

struct ThemeExplorerView: View {
    let appModel: AppModel
    let render: RenderContext?

    let deckThemeId: String

    let looks: [ThemeLook]?
    var emptyHint = "Make a theme in the Library first."

    var currentBadge = "This deck"

    var currentDesign: String?

    var onPickTheme: ((Theme) -> Void)?
    var pickThemeVerb = "Apply"
    var pickThemeHelp = "Each slide keeps its kind of design (a verse stays a verse) in this theme. Or pick one design below for every slide."
    let onPickDesign: (_ themeId: String, _ design: Slide) -> Void

    @State private var place = ThemeExplorer.Place.themes
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            explorer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
                }
                Button(step.name) {
                    query = ""
                    place = step.place
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(index == trail.count - 1 && query.isEmpty ? Color.primary : Color.secondary)
            }
            Spacer()
            if let onPickTheme, let theme = placeTheme {
                Button("\(pickThemeVerb) \u{201C}\(theme.name)\u{201D}") { onPickTheme(theme) }
                    .buttonStyle(.borderedProminent)
                    .help(pickThemeHelp)
            }
            TextField("Search themes and designs", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(12)
    }

    private var placeTheme: Theme? {
        switch place {
        case .themes: nil
        case .theme(let id), .folder(let id, _): look(id)?.theme
        }
    }

    private var trail: [(name: String, place: ThemeExplorer.Place)] {
        var steps: [(name: String, place: ThemeExplorer.Place)] = [("Themes", .themes)]
        switch place {
        case .themes:
            break
        case .theme(let id):
            steps.append((look(id)?.theme.name ?? "Theme", place))
        case .folder(let id, let name):
            steps.append((look(id)?.theme.name ?? "Theme", .theme(id)))
            steps.append((name, place))
        }
        return steps
    }

    @ViewBuilder
    private var explorer: some View {
        if let looks {
            if looks.isEmpty {
                ContentUnavailableView(
                    "No Themes", systemImage: "paintpalette",
                    description: Text(emptyHint))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        level(looks)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func level(_ looks: [ThemeLook]) -> some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = ThemeExplorer.search(query, in: looks.map(\.theme))
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                grid {

                    ForEach(Array(matches.enumerated()), id: \.offset) { _, match in
                        if let look = look(match.theme.id) {
                            designCard(
                                match.design, in: look,
                                caption: ([look.theme.name] + [match.design.folder ?? ""].filter { !$0.isEmpty }).joined(separator: " › "))
                        }
                    }
                }
            }
        } else {
            switch place {
            case .themes:
                grid {
                    ForEach(looks) { look in themeCard(look) }
                }
            case .theme(let id):
                if let look = look(id) {
                    let folders = ThemeExplorer.folders(in: look.theme)
                    let loose = ThemeExplorer.looseDesigns(in: look.theme)
                    if !folders.isEmpty {
                        sectionTitle("Folders")
                        grid {
                            ForEach(folders, id: \.name) { folder in folderCard(folder, in: look) }
                        }
                    }
                    if !loose.isEmpty {
                        if !folders.isEmpty { sectionTitle("Designs") }
                        grid {
                            ForEach(loose, id: \.id) { design in designCard(design, in: look, caption: nil) }
                        }
                    }
                    if folders.isEmpty, loose.isEmpty {
                        Text("This theme has no designs yet.").foregroundStyle(.secondary)
                    }
                }
            case .folder(let id, let name):
                if let look = look(id) {
                    grid {
                        ForEach(ThemeExplorer.designs(in: look.theme, folder: name), id: \.id) { design in
                            designCard(design, in: look, caption: nil)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)], alignment: .leading, spacing: 14) {
            content()
        }
    }

    private func themeCard(_ look: ThemeLook) -> some View {
        let count = look.theme.slides?.count ?? 0
        return card(
            title: look.theme.name,
            caption: count == 1 ? "1 design" : "\(count) designs",
            badge: look.theme.id == deckThemeId ? currentBadge : nil,
            systemImage: "chevron.right"
        ) {
            preview(look.theme.slides?.first, in: look)
        } action: {
            place = .theme(look.theme.id)
        }
    }

    private func folderCard(_ folder: ThemeExplorer.Folder, in look: ThemeLook) -> some View {
        card(
            title: folder.name,
            caption: folder.designs.count == 1 ? "1 design" : "\(folder.designs.count) designs",
            badge: nil, systemImage: "folder"
        ) {
            preview(folder.designs.first, in: look)
        } action: {
            place = .folder(themeId: look.theme.id, name: folder.name)
        }
    }

    private func designCard(_ design: Slide, in look: ThemeLook, caption: String?) -> some View {
        card(title: design.name, caption: caption, badge: isCurrent(design, in: look) ? currentBadge : nil, systemImage: nil) {
            preview(design, in: look)
        } action: {
            onPickDesign(look.theme.id, design)
        }
    }

    private func card(
        title: String, caption: String?, badge: String?, systemImage: String?,
        @ViewBuilder picture: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                picture()
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
                HStack(spacing: 4) {
                    if let systemImage {
                        Image(systemName: systemImage).imageScale(.small).foregroundStyle(.secondary)
                    }
                    Text(title).font(.callout).lineLimit(1)
                }
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder
    private func preview(_ design: Slide?, in look: ThemeLook) -> some View {
        if let design, let slide = look.previews[design.id] {
            SlideThumbnailView(
                model: appModel, render: render,
                slide: slide, presentation: look.deck, theme: look.theme,
                arrangementId: nil, hideScopedBackgrounds: false, legibleText: false,
                contentStamp: look.stamp
            )
        } else {
            Color.secondary.opacity(0.1)
        }
    }

    private func isCurrent(_ design: Slide, in look: ThemeLook) -> Bool {
        if let currentDesign, look.theme.id == deckThemeId {
            look.theme.slides?.first { $0.name.caseInsensitiveCompare(currentDesign) == .orderedSame }?.id == design.id
        } else {
            false
        }
    }

    private func look(_ id: String) -> ThemeLook? {
        looks?.first { $0.theme.id == id }
    }
}
