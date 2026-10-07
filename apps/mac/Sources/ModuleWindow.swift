import AppKit
import SwiftUI

struct ModuleWindowView: View {
    let module: ServiceControlsModule
    let model: AppModel
    let controls: ServiceControls?
    let presets: OutputPresetsController?
    let layout: PresentLayoutController?

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let allowed = layout?.volunteerModules, !allowed.contains(module) {
                        Text("\(module.title) is locked in run-only mode.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let controls {
                        switch module {
                        case .audio: AudioModule(model: model, controls: controls)
                        case .mixer: AudioMixerModule(model: model, controls: controls)
                        case .media: MediaPlaylistsModule(model: model, controls: controls)
                        case .timers: TimersModule(model: model, controls: controls)
                        case .tracking: ServiceTrackingModule(model: model, controls: controls)
                        case .alerts: AlertsModule(model: model, controls: controls)
                        case .overlays: OverlaysModule(model: model, controls: controls)
                        case .combos: ActionCombosModule(model: model, controls: controls)
                        case .confidence: ConfidenceModule(model: model, controls: controls)
                        case .outputs: OutputsModule(model: model, controls: controls, presets: presets)
                        }
                    }
                }
                .padding(12)
            }
            .scrollContentBackground(.hidden)

            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: ModuleViewportHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ModuleViewportHeightKey.self) { viewportHeight = $0 }
            .environment(\.moduleViewportHeight, viewportHeight)
        }
        .background(Color.basePlane)

        .environment(\.moduleCompact, false)

        .environment(\.runOnly, layout?.runOnly ?? false)

        .focusedSceneValue(\.serviceControls, controls)
        .background(
            ModuleWindowConfigurator(autosaveName: "serviceControls.module.\(module.rawValue)") {
                layout?.returnToRail(module)
            }
        )
        .navigationTitle(module.title)
        .frame(minWidth: 300, minHeight: 320)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)

        .onAppear { WindowBridge.openMain = { openWindow(id: "main") } }
    }

    @Environment(\.openWindow) private var openWindow
}

struct ServiceControlsWindowView: View {
    let model: AppModel
    let controls: ServiceControls?
    let presets: OutputPresetsController?
    let layout: PresentLayoutController?

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ServiceControlsPanel(model: model, controls: controls, presets: presets, layout: layout)
            .frame(minWidth: 300, minHeight: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.basePlane)
            .environment(\.runOnly, layout?.runOnly ?? false)
            .focusedSceneValue(\.serviceControls, controls)
            .background(
                ModuleWindowConfigurator(
                    autosaveName: PresentLayoutController.serviceControlsAutosaveName
                ) {
                    layout?.serviceControlsWindowClosed()
                }
            )
            .navigationTitle("Service Controls")
            .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
            .onAppear {
                layout?.serviceControlsWindowOpened()
                WindowBridge.openMain = { openWindow(id: "main") }
            }
    }
}

struct PreviewWindowView: View {
    let render: RenderContext?
    let controls: ServiceControls?
    let layout: PresentLayoutController?

    let target: String

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @Environment(\.confidenceMonitor) private var confidenceMonitor

    static func autosaveName(for target: String) -> String {
        target.isEmpty ? "live.preview" : "live.preview.\(target)"
    }

    var body: some View {
        Group {
            if let render {
                let resolved = PreviewTargets.resolve(
                    target, render: render,
                    layouts: confidenceMonitor?.previewLayoutChoices ?? [])

                LiveSceneView(render: render, screenTargetID: resolved?.id)
                    .aspectRatio(
                        PreviewTargets.aspect(
                            of: resolved?.id, render: render,
                            layoutAspects: confidenceMonitor?.previewAspects ?? [:]),
                        contentMode: .fit)
                    .modifier(PreviewedLayoutKeeper(target: resolved?.id))
                    .background(Color.black)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .padding(10)
                    .navigationTitle(resolved.map { "Preview — \($0.name)" } ?? "Output Preview")
            } else {
                Text("Metal is not available on this machine.")
                    .padding(40)
            }
        }
        .frame(minWidth: 220, minHeight: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.basePlane)
        .focusedSceneValue(\.serviceControls, controls)
        .background(
            ModuleWindowConfigurator(autosaveName: Self.autosaveName(for: target)) {
                layout?.previewClosed(target)
            }
        )
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
        .onAppear { layout?.previewOpened(target) }
    }
}

struct ModuleWindowConfigurator: NSViewRepresentable {
    let autosaveName: String
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window, coordinator: context.coordinator)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window, coordinator.window !== window else { return }
        window.isRestorable = false
        window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        coordinator.attach(to: window)
    }

    @MainActor
    final class Coordinator {
        private(set) weak var window: NSWindow?
        private let onClose: () -> Void
        private var terminating = false

        private nonisolated(unsafe) var observers: [any NSObjectProtocol] = []

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func attach(to window: NSWindow) {
            self.window = window
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.terminating = true }
                },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.terminating else { return }
                        self.onClose()
                    }
                },
            ]
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
