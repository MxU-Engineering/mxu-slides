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

    @Environment(\.openWindow) private var openWindow
    @Environment(\.runOnly) private var runOnly
    @Environment(\.confidenceMonitor) private var confidenceMonitor
    @State private var previewHovering = false

    @AppStorage("preview.screenTarget") private var previewTarget = ""

    var body: some View {

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                livePreview
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, 2)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarSectionHeader("Output Preview", glyph: .media) {
                screenPicker
            }
        }
    }

    @ViewBuilder
    private var livePreview: some View {

        if let render {
            let resolved = resolvedTarget(render)
            LiveSceneView(render: render, screenTargetID: resolved?.id)
                .aspectRatio(
                    PreviewTargets.aspect(
                        of: resolved?.id, render: render,
                        layoutAspects: confidenceMonitor?.previewAspects ?? [:]),
                    contentMode: .fit)
                .modifier(PreviewedLayoutKeeper(target: resolved?.id))
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle.standard(CornerStandard.element))
                .overlay {
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
                }

                .overlay(alignment: .topTrailing) {
                    if previewHovering, !runOnly {
                        Button {
                            popOutPreview()
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
                .onHover { previewHovering = $0 }
                .contextMenu {
                    if !runOnly {
                        Button("Open in Window") { popOutPreview() }

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
    }

    private func popOutPreview() {
        guard let render else { return }
        let target = resolvedTarget(render)?.id ?? ""
        openWindow(id: "preview", value: target)
    }

    private func resolvedTarget(_ render: RenderContext) -> (id: String, name: String)? {
        PreviewTargets.resolve(
            previewTarget, render: render,
            layouts: confidenceMonitor?.previewLayoutChoices ?? [])
    }

    @ViewBuilder
    private var screenPicker: some View {
        if let render {
            let screens = PreviewTargets.screens(render)
            let layouts = confidenceMonitor?.previewLayoutChoices ?? []
            let resolved = resolvedTarget(render)
            Menu {
                Section("Screens") {
                    ForEach(screens, id: \.id) { screen in
                        Toggle(screen.name, isOn: Binding(
                            get: { resolved?.id == screen.id },
                            set: { _ in previewTarget = screen.id }
                        ))
                    }
                }

                if !layouts.isEmpty {
                    Section("Layouts") {
                        ForEach(layouts, id: \.id) { layout in
                            Toggle(layout.name, isOn: Binding(
                                get: { resolved?.id == layout.id },
                                set: { _ in previewTarget = layout.id }
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
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .help("Which screen or layout this preview shows — every screen composites its own view via the active preset")
        }
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
