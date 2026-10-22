import PresenterCore
import SlideScene
import SwiftUI

struct PresentationResolutionSheet: View {
    let model: AppModel
    let target: Target

    struct Target: Identifiable {
        let ids: [String]
        var id: String { ids.joined(separator: ",") }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var choice = ""
    @State private var widthText = ""
    @State private var heightText = ""

    private var custom: (width: Int, height: Int)? {
        if let width = Int(widthText), let height = Int(heightText), width > 0, height > 0 {
            (width, height)
        } else {
            nil
        }
    }

    private var chosen: (width: Int, height: Int)? {
        if let preset = SlideSceneBuilder.canvasPresets.first(where: { $0.label == choice }) {
            (preset.width, preset.height)
        } else {
            custom
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.ids.count == 1 ? "Resolution" : "Resolution for \(target.ids.count) Presentations")
                .font(.headline)
            Picker("Resolution", selection: $choice) {
                ForEach(SlideSceneBuilder.canvasPresets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
                Text("Custom…").tag("custom")
            }
            .labelsHidden()
            if choice == "custom" {
                HStack {
                    TextField("Width", text: $widthText)
                        .textFieldStyle(.roundedBorder)
                    Text("×")
                    TextField("Height", text: $heightText)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("Every slide designs at this resolution. Objects keep their positions; screens of another shape fit it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    if let chosen {
                        model.setCanvasSize(of: target.ids, width: chosen.width, height: chosen.height)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear(perform: start)
    }

    private func start() {
        let size = SlideSceneBuilder.canvasSize(for: target.ids.first.flatMap(model.presentation))
        let width = Int(size.width)
        let height = Int(size.height)
        widthText = String(width)
        heightText = String(height)
        choice = SlideSceneBuilder.canvasPresets.first { $0.width == width && $0.height == height }?.label ?? "custom"
    }
}
