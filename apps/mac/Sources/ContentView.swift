import RenderEngine
import SwiftUI

struct ContentView: View {
    var render: RenderContext
    var presets: OutputPresetsController?

    var body: some View {
        HSplitView {
            layerStackSidebar
                .frame(minWidth: 220, maxWidth: 320)
            canvas
                .frame(minWidth: 480)
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private var layerStackSidebar: some View {
        List {
            Section("Layer stack") {

                ForEach(render.scene.layers.reversed()) { layer in
                    HStack {
                        Toggle(isOn: visibilityBinding(for: layer.id)) {
                            Text(layer.name)
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        if !layer.items.isEmpty {
                            Text("\(layer.items.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Outputs") {
                OutputsPanel(render: render, presets: presets)
            }
            Section("Media soak") {
                soakControls
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var soakControls: some View {
        let soak = render.soak

        switch soak.phase {
        case .idle:
            Button("Start soak test") {
                Task { await soak.start(render: render) }
            }
        case .generating(let what):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(what).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(4)
            Button("Reset") { soak.stop(render: render) }
        case .running:
            Button("Stop soak test") { soak.stop(render: render) }
            if let startedAt = soak.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startedAt))
                    soakStatsRows(elapsed: elapsed)
                }
            }
        }
    }

    private func soakStatsRows(elapsed: Int) -> some View {
        let soak = render.soak
        return VStack(alignment: .leading, spacing: 3) {
            soakStatRow("Elapsed", String(format: "%d:%02d:%02d", elapsed / 3600, elapsed / 60 % 60, elapsed % 60))
            soakStatRow("4K α frames", "\(soak.alphaStats.framesDisplayed)")
            soakStatRow("1080p60 frames", "\(soak.opaqueStats.framesDisplayed)")
            soakStatRow(
                "Dropped",
                "\(soak.alphaStats.framesDropped + soak.opaqueStats.framesDropped)",
                emphasized: soak.alphaStats.framesDropped + soak.opaqueStats.framesDropped > 0
            )
        }
    }

    private func soakStatRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(emphasized ? .red : .primary)
        }
    }

    private var canvas: some View {
        SceneCanvas(render: render)
            .aspectRatio(render.scene.canvasSize, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
    }

    private func visibilityBinding(for layerID: String) -> Binding<Bool> {
        Binding(
            get: {
                !(render.scene.layers.first { $0.id == layerID }?.isHidden ?? false)
            },
            set: { visible in
                guard let index = render.scene.layers.firstIndex(where: { $0.id == layerID }) else {
                    return
                }
                render.scene.layers[index].isHidden = !visible
            }
        )
    }
}
