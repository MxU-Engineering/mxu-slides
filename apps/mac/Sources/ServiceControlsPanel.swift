import PresenterCore
import SlideScene
import SwiftUI

struct ServiceControlsPanel: View {
    let model: AppModel
    let controls: ServiceControls?
    let presets: OutputPresetsController?
    let layout: PresentLayoutController?

    @AppStorage("serviceControls.module") private var moduleRaw = ServiceControlsModule.audio.rawValue

    @AppStorage("serviceControls.moduleOrder") private var moduleOrderRaw = ""
    @AppStorage("serviceControls.hiddenModules") private var hiddenModulesRaw = ""
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.runOnly) private var runOnly
    @Environment(\.signage) private var signage

    private var orderedModules: [ServiceControlsModule] {
        TabRowLogic.mergedOrder(
            stored: moduleOrderRaw.split(separator: ",").map(String.init),
            all: ServiceControlsModule.defaultOrder.map(\.rawValue)
        ).compactMap(ServiceControlsModule.init(rawValue:))
    }

    private var hiddenModules: Set<ServiceControlsModule> {
        Set(hiddenModulesRaw.split(separator: ",").compactMap {
            ServiceControlsModule(rawValue: String($0))
        })
    }

    private var volunteerModules: Set<ServiceControlsModule>? {
        layout?.volunteerModules
    }

    private var enabledModules: [ServiceControlsModule] {
        if let allowed = volunteerModules {
            orderedModules.filter(allowed.contains)
        } else {
            TabRowLogic.enabled(
                order: orderedModules.map(\.rawValue),
                hidden: Set(hiddenModules.map(\.rawValue))
            ).compactMap(ServiceControlsModule.init(rawValue:))
        }
    }

    private var railModules: [ServiceControlsModule] {
        enabledModules.filter { !isPopped($0) }
    }

    private func isPopped(_ module: ServiceControlsModule) -> Bool {
        layout?.poppedOut.contains(module) ?? false
    }

    private var selectedModule: ServiceControlsModule? {
        let stored = ServiceControlsModule(rawValue: moduleRaw) ?? .audio
        if !isPopped(stored),
           enabledModules.contains(stored) || (volunteerModules == nil && moduleActivity(stored) != nil) {
            return stored
        }
        return railModules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader("Service Controls", glyph: .viewOptions) {
                if let selectedModule, !runOnly {
                    Button {
                        popOut(selectedModule)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(selectedModule.title) in its own window")
                }
            }
            modulePicker
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let controls, let selectedModule {
                        moduleContent(selectedModule, controls: controls)
                    } else if controls != nil {
                        Text("Every module is in its own window.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
            }
            .scrollContentBackground(.hidden)

            .background(GeometryReader { proxy in
                Color.clear.preference(
                    key: ModuleViewportHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(ModuleViewportHeightKey.self) { viewportHeight = $0 }
            .environment(\.moduleViewportHeight, viewportHeight)
        }
    }

    private func popOut(_ module: ServiceControlsModule) {
        layout?.popOut(module)
        openWindow(id: "module", value: module)
    }

    @ViewBuilder
    private func moduleContent(
        _ module: ServiceControlsModule, controls: ServiceControls
    ) -> some View {
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

    @State private var viewportHeight: CGFloat = 0

    private var modulePicker: some View {
        PriorityTabRow(
            card: "serviceControls",
            tabs: enabledModules.map(descriptor),

            overflowExtras: orderedModules
                .filter { volunteerModules == nil && hiddenModules.contains($0) && moduleActivity($0) != nil }
                .map(descriptor),
            selectedID: selectedModule?.rawValue,
            onSelect: { id in
                guard let module = ServiceControlsModule(rawValue: id) else { return }
                if isPopped(module) {

                    openWindow(id: "module", value: module)
                } else {
                    moduleRaw = module.rawValue
                }
            },
            onReorder: reorderModule
        ) { id in
            if let module = ServiceControlsModule(rawValue: id) {
                moduleTabMenu(module)
            }
        }
    }

    private func descriptor(_ module: ServiceControlsModule) -> PriorityTabDescriptor {
        PriorityTabDescriptor(
            id: module.rawValue,
            title: module.title,
            glyph: module.glyph,

            tint: moduleActivity(module),
            isPopped: isPopped(module)
        )
    }

    @ViewBuilder
    private func moduleTabMenu(_ module: ServiceControlsModule) -> some View {
        if !runOnly {
            if isPopped(module) {
                Button("Return to Rail") {

                    dismissWindow(id: "module", value: module)
                    layout?.returnToRail(module)
                }
            } else {
                Button("Open in Window") { popOut(module) }
            }
            Divider()
            Section("Modules") {
                ForEach(orderedModules, id: \.self) { candidate in
                    Toggle(candidate.title, isOn: Binding(
                        get: { !hiddenModules.contains(candidate) },
                        set: { show in setModule(candidate, visible: show) }
                    ))
                }
            }
            Divider()
            Button("Reset Tabs") {
                moduleOrderRaw = ""
                hiddenModulesRaw = ""
            }
        }
    }

    private func reorderModule(_ movedID: String, beforeID: String?) {
        guard let moved = ServiceControlsModule(rawValue: movedID) else { return }
        var order = orderedModules
        order.removeAll { $0 == moved }
        let index = beforeID
            .flatMap(ServiceControlsModule.init(rawValue:))
            .flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(moved, at: index)
        moduleOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    private func setModule(_ module: ServiceControlsModule, visible: Bool) {
        var hidden = hiddenModules
        if visible {
            hidden.remove(module)
        } else {
            guard enabledModules.count > 1 else { return }
            hidden.insert(module)
        }
        hiddenModulesRaw = hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func moduleActivity(_ module: ServiceControlsModule) -> Color? {
        guard let controls else { return nil }
        switch module {
        case .audio:
            return controls.state.liveAudio.isEmpty ? nil : .green
        case .mixer:

            return controls.mixer.anyInputLive ? .green : nil
        case .media:

            return signage?.isAnyScreenLive == true ? .green : nil
        case .timers:
            return controls.timers.timers.contains(where: \.isLive) ? .green : nil
        case .tracking:
            return controls.timers.snapshot(id: ServiceTrackingTimers.id(.item, .remaining))?.isRunning == true ? .green : nil
        case .alerts:
            return controls.state.liveAlert == nil ? nil : .orange
        case .overlays:
            return controls.state.liveOverlays.isEmpty ? nil : .green
        case .combos:

            return nil
        case .confidence:

            return controls.state.liveAlert?.showsOnConfidence == true ? .orange : nil
        case .outputs:

            let outputs = controls.render.outputs
            return outputs.displays.contains { outputs.isLive($0.uuid) } ? .green : nil
        }
    }
}

struct ModuleViewportHeightKey: PreferenceKey, EnvironmentKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension EnvironmentValues {
    var moduleViewportHeight: CGFloat {
        get { self[ModuleViewportHeightKey.self] }
        set { self[ModuleViewportHeightKey.self] = newValue }
    }
}
