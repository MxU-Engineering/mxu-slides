import OutputEngine
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct LivePanel: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    @Environment(\.confidenceMonitor) private var confidenceMonitor

    @AppStorage("preview.screenTarget") private var previewTarget = ""
    @AppStorage("preview.extraTargets") private var extraTargetsRaw = ""

    var body: some View {

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let render {
                    PreviewTile(render: render, target: resolvedTarget(previewTarget, render)?.id)
                    let extras = extraTargets
                    ForEach(Array(extras.enumerated()), id: \.offset) { index, stored in
                        let resolved = resolvedTarget(stored, render)
                        HStack(spacing: 6) {
                            Spacer()
                            PreviewTargetMenu(render: render, resolved: resolved) {
                                setExtraTarget($0, at: index)
                            }
                            Button {
                                removeExtra(at: index)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Remove this preview")
                        }
                        PreviewTile(render: render, target: resolved?.id)
                    }
                    addPreviewButton(render)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 2)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSectionHeader("Output Preview", glyph: .media) {
                if let render {
                    PreviewTargetMenu(render: render, resolved: resolvedTarget(previewTarget, render)) {
                        previewTarget = $0
                    }
                }
            }
        }
    }

    private func addPreviewButton(_ render: RenderContext) -> some View {
        Button {
            addExtra(render)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .help("Add another preview below — watch several screens at once")
    }

    private var extraTargets: [String] {
        guard let data = extraTargetsRaw.data(using: .utf8),
              let targets = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return targets
    }

    private func storeExtraTargets(_ targets: [String]) {
        extraTargetsRaw = (try? JSONEncoder().encode(targets))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func addExtra(_ render: RenderContext) {
        let extras = extraTargets
        let shown = Set(([previewTarget] + extras).compactMap { resolvedTarget($0, render)?.id })
        let choices = PreviewTargets.screens(render).map(\.id)
            + (confidenceMonitor?.previewLayoutChoices ?? []).map(\.id)
        storeExtraTargets(extras + [choices.first { !shown.contains($0) } ?? ""])
    }

    private func setExtraTarget(_ target: String, at index: Int) {
        var extras = extraTargets
        guard extras.indices.contains(index) else { return }
        extras[index] = target
        storeExtraTargets(extras)
    }

    private func removeExtra(at index: Int) {
        var extras = extraTargets
        guard extras.indices.contains(index) else { return }
        extras.remove(at: index)
        storeExtraTargets(extras)
    }

    private func resolvedTarget(_ stored: String, _ render: RenderContext) -> (id: String, name: String)? {
        PreviewTargets.resolve(
            stored, render: render,
            layouts: confidenceMonitor?.previewLayoutChoices ?? [])
    }

}

struct PreviewTile: View {
    let render: RenderContext
    let target: String?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.runOnly) private var runOnly
    @Environment(\.confidenceMonitor) private var confidenceMonitor
    @State private var hovering = false

    var body: some View {
        LiveSceneView(render: render, screenTargetID: target)
            .aspectRatio(
                PreviewTargets.aspect(
                    of: target, render: render,
                    layoutAspects: confidenceMonitor?.previewAspects ?? [:]),
                contentMode: .fit)
            .modifier(PreviewedLayoutKeeper(target: target))
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            .overlay {
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
            }

            .overlay(alignment: .topTrailing) {
                if hovering, !runOnly {
                    Button {
                        popOut()
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(4)
                            .background(.black.opacity(0.45), in: RoundedRectangle.standard(CornerStandard.element))
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open this screen's preview in its own window")
                }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                if !runOnly {
                    Button("Open in Window") { popOut() }

                    let screens = PreviewTargets.screens(render)
                    let layouts = confidenceMonitor?.previewLayoutChoices ?? []
                    if screens.count + layouts.count > 1 {
                        Menu("Open Preview Window") {
                            ForEach(screens, id: \.id) { screen in
                                Button(screen.name) {
                                    openWindow(id: "preview", value: screen.id)
                                }
                            }
                            if !layouts.isEmpty {
                                Divider()
                                ForEach(layouts, id: \.id) { layout in
                                    Button(layout.name) {
                                        openWindow(id: "preview", value: layout.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
    }

    private func popOut() {
        openWindow(id: "preview", value: target ?? "")
    }
}

struct PreviewTargetMenu: View {
    let render: RenderContext
    let resolved: (id: String, name: String)?
    let onPick: (String) -> Void

    @Environment(\.confidenceMonitor) private var confidenceMonitor

    var body: some View {
        let screens = PreviewTargets.screens(render)
        let layouts = confidenceMonitor?.previewLayoutChoices ?? []
        Menu {
            Section("Screens") {
                ForEach(screens, id: \.id) { screen in
                    Toggle(screen.name, isOn: Binding(
                        get: { resolved?.id == screen.id },
                        set: { _ in onPick(screen.id) }
                    ))
                }
            }

            if !layouts.isEmpty {
                Section("Layouts") {
                    ForEach(layouts, id: \.id) { layout in
                        Toggle(layout.name, isOn: Binding(
                            get: { resolved?.id == layout.id },
                            set: { _ in onPick(layout.id) }
                        ))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(resolved?.name ?? "No Screens")
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(screens.isEmpty && layouts.isEmpty)
        .headerItemBackground()
        .help("Which screen or layout this preview shows — every screen composites its own view via the active preset")
    }
}

struct LiveSceneView: NSViewRepresentable {
    let render: RenderContext

    var screenTargetID: String?

    init(render: RenderContext, screenTargetID: String? = nil) {
        self.render = render
        self.screenTargetID = screenTargetID
    }

    func makeNSView(context: Context) -> MetalSceneView {
        let view = MetalSceneView(compositor: render.compositor)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: MetalSceneView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: MetalSceneView) {
        if let screenTargetID {
            view.sceneProvider = render.previewProvider(for: screenTargetID)
        } else {
            view.sceneProvider = { [transitions = render.transitions] in
                transitions.scene(at: Date())
            }
        }
    }
}

struct AudioTransportControls<Trailing: View>: View {
    let model: AppModel
    let player: AudioPlayer
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let livePlaylist = player.playlistID.flatMap { try? model.playlist($0) }
        HStack(spacing: 6) {
            TransportIconButton(symbol: "backward.fill", help: "Previous — restarts past 3s") {
                player.previous()
            }
            TransportIconButton(
                symbol: player.isPlaying ? "pause.fill" : "play.fill",
                help: player.isPlaying ? "Pause" : "Play"
            ) {
                player.togglePlayPause()
            }
            TransportIconButton(symbol: "forward.fill", help: "Next") {
                player.next()
            }
            if let livePlaylist {
                Divider().frame(height: 14)
                let shuffled = livePlaylist.shuffle ?? false
                TransportIconButton(
                    symbol: "shuffle", help: shuffled ? "Shuffle off" : "Shuffle",
                    active: shuffled
                ) {
                    model.updatePlaylist(livePlaylist.id) { $0.shuffle = !shuffled }
                    player.refreshFromDocument()
                }
                let mode = livePlaylist.playbackMode
                TransportIconButton(
                    symbol: mode == .loopSingle ? "repeat.1" : "repeat",
                    help: Self.repeatHelp(mode),
                    active: mode != .playAll
                ) {
                    model.updatePlaylist(livePlaylist.id) {
                        $0.playbackMode = Self.nextRepeatMode(mode)
                    }
                    player.refreshFromDocument()
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
    }

    private static func nextRepeatMode(_ mode: PlaybackMode) -> PlaybackMode {
        switch mode {
        case .playAll: .loopPlaylist
        case .loopPlaylist: .loopSingle
        case .loopSingle: .playAll
        }
    }

    private static func repeatHelp(_ mode: PlaybackMode) -> String {
        switch mode {
        case .playAll: "Repeat off — click for Loop Playlist"
        case .loopPlaylist: "Loop Playlist — click for Loop Single"
        case .loopSingle: "Loop Single — click for repeat off"
        }
    }
}

struct TransportIconButton: View {
    let symbol: String
    let help: String
    var active: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? Color.green : .secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(active ? 0.10 : 0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .help(help)
    }
}

extension Color {
    static var separator: Color { Color(nsColor: .separatorColor) }
}

@MainActor
enum PreviewTargets {
    static func screens(_ render: RenderContext) -> [(id: String, name: String)] {
        let outputs = render.outputs
        return outputs.placeholderScreens.map { ($0.id.uuidString, $0.name) }
            + outputs.displays.map { ($0.uuid, $0.name) }
    }

    static func resolve(
        _ stored: String, render: RenderContext,
        layouts: [PreviewTargetLogic.Choice] = []
    ) -> (id: String, name: String)? {
        PreviewTargetLogic.resolve(
            stored: stored,
            screens: screens(render).map { .init(id: $0.id, name: $0.name) },
            layouts: layouts
        ).map { ($0.id, $0.name) }
    }

    static func aspect(
        of targetID: String?, render: RenderContext,
        layoutAspects: [String: Double] = [:]
    ) -> CGFloat {
        guard let targetID else { return 16 / 9 }
        if let layoutID = PreviewTargetLogic.layoutID(for: targetID) {
            return CGFloat(layoutAspects[layoutID] ?? 16 / 9)
        }
        let outputs = render.outputs
        if let uuid = UUID(uuidString: targetID),
           let placeholder = outputs.placeholderScreens.first(where: { $0.id == uuid }),
           placeholder.height > 0 {
            return CGFloat(placeholder.width) / CGFloat(placeholder.height)
        }
        if let display = outputs.displays.first(where: { $0.uuid == targetID }),
           display.frame.height > 0 {
            return display.frame.width / display.frame.height
        }
        return 16 / 9
    }
}

struct PreviewedLayoutKeeper: ViewModifier {
    let target: String?
    @Environment(\.confidenceMonitor) private var confidenceMonitor

    private var layoutID: String? {
        target.flatMap(PreviewTargetLogic.layoutID)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { begin(layoutID) }
            .onDisappear { end(layoutID) }
            .onChange(of: layoutID) { old, new in
                end(old)
                begin(new)
            }
    }

    private func begin(_ layoutID: String?) {
        if let layoutID {
            confidenceMonitor?.beginPreview(layoutID: layoutID)
        }
    }

    private func end(_ layoutID: String?) {
        if let layoutID {
            confidenceMonitor?.endPreview(layoutID: layoutID)
        }
    }
}
