import OutputEngine
import RenderEngine
import SwiftUI

enum OutputPanelTab: String, CaseIterable {
    case output
    case color
    case cornerPin
    case blend

    var label: String {
        switch self {
        case .output: "Output"
        case .color: "Color"
        case .cornerPin: "Corner Pin"
        case .blend: "Blend"
        }
    }
}

struct OutputColorPanel: View {
    let outputs: OutputManager
    let sliceID: UUID

    private var adjustments: OutputAdjustments {
        outputs.adjustments(forScreen: sliceID)
    }

    private func update(_ mutate: (inout OutputAdjustments) -> Void) {
        var value = adjustments
        mutate(&value)
        outputs.setAdjustments(value, forScreen: sliceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            slider("Brightness", \.brightness, range: -1...1)
            slider("Contrast", \.contrast, range: -1...1)
            slider("Gamma", \.gamma, range: -1...1)
            slider("Black Level", \.blackLevel, range: 0...1)
            slider("Red", \.redLevel, range: -1...1)
            slider("Green", \.greenLevel, range: -1...1)
            slider("Blue", \.blueLevel, range: -1...1)
            HStack {
                Spacer()
                Button("Reset Color") {
                    update { value in
                        value.brightness = nil
                        value.contrast = nil
                        value.gamma = nil
                        value.blackLevel = nil
                        value.redLevel = nil
                        value.greenLevel = nil
                        value.blueLevel = nil
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled([
                    adjustments.brightness, adjustments.contrast, adjustments.gamma,
                    adjustments.blackLevel, adjustments.redLevel, adjustments.greenLevel,
                    adjustments.blueLevel,
                ].allSatisfy { ($0 ?? 0) == 0 })
            }
        }
    }

    private func slider(
        _ label: String, _ keyPath: WritableKeyPath<OutputAdjustments, Double?>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Slider(
                value: Binding(
                    get: { adjustments[keyPath: keyPath] ?? 0 },
                    set: { newValue in
                        update { $0[keyPath: keyPath] = newValue == 0 ? nil : newValue }
                    }
                ),
                in: range
            )
            .controlSize(.mini)
            Text(String(format: "%+.2f", adjustments[keyPath: keyPath] ?? 0))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

struct OutputCornerPinPanel: View {
    let outputs: OutputManager
    let sliceID: UUID

    private var adjustments: OutputAdjustments {
        outputs.adjustments(forScreen: sliceID)
    }

    private func update(_ mutate: (inout OutputAdjustments) -> Void) {
        var value = adjustments
        mutate(&value)
        outputs.setAdjustments(value, forScreen: sliceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    corner("TL", \.topLeft)
                    corner("TR", \.topRight)
                }
                GridRow {
                    corner("BL", \.bottomLeft)
                    corner("BR", \.bottomRight)
                }
            }
            Text("Pixel offsets from each corner — content warps to fit, outside stays black.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Text("Rotation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { adjustments.rotationDegrees ?? 0 },
                        set: { newValue in
                            update { $0.rotationDegrees = newValue == 0 ? nil : newValue }
                        }
                    ),
                    in: -180...180
                )
                .controlSize(.mini)
                Text(String(format: "%.0f°", adjustments.rotationDegrees ?? 0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("Reset Pin") {
                    update { value in
                        value.topLeft = nil
                        value.topRight = nil
                        value.bottomLeft = nil
                        value.bottomRight = nil
                        value.rotationDegrees = nil
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    private func corner(
        _ label: String, _ keyPath: WritableKeyPath<OutputAdjustments, CGPoint?>
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            offsetField(value: adjustments[keyPath: keyPath]?.x ?? 0) { newX in
                update { adjust in
                    var point = adjust[keyPath: keyPath] ?? .zero
                    point.x = newX
                    adjust[keyPath: keyPath] = point == .zero ? nil : point
                }
            }
            offsetField(value: adjustments[keyPath: keyPath]?.y ?? 0) { newY in
                update { adjust in
                    var point = adjust[keyPath: keyPath] ?? .zero
                    point.y = newY
                    adjust[keyPath: keyPath] = point == .zero ? nil : point
                }
            }
        }
    }

    private func offsetField(value: CGFloat, commit: @escaping (CGFloat) -> Void) -> some View {
        TextField(
            "0",
            text: Binding(
                get: { value == 0 ? "0" : String(format: "%.0f", value) },
                set: { commit(CGFloat(Double($0) ?? 0)) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.mini)
        .frame(width: 46)
        .multilineTextAlignment(.trailing)
        .font(.caption.monospacedDigit())
    }
}

struct SeamBlendPanel: View {
    let outputs: OutputManager
    let screen: PlaceholderScreen
    let leading: OutputSliceState
    let trailing: OutputSliceState

    let setOverlap: (Double) -> Void

    private var overlap: Double {
        max(leading.sourceRect.maxX - trailing.sourceRect.minX, 0)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SeamGraph(outputs: outputs, leading: leading, trailing: trailing)
                .frame(width: 220)
            knobs
        }
    }

    private var knobs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Width")
                    .font(.caption)
                    .frame(width: 68, alignment: .leading)
                Slider(
                    value: Binding(get: { overlap }, set: { setOverlap($0) }),
                    in: 0.01...0.15
                )
                .controlSize(.small)
                Text("\(Int((overlap * Double(screen.width)).rounded())) px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            .help("How much of the canvas both projectors share at this seam — the ramps on both sides stay matched")
            HStack(alignment: .top, spacing: 16) {
                sideColumn(
                    title: leading.name ?? "Left", sliceID: leading.id, edge: \.blendRight)
                Divider()
                sideColumn(
                    title: trailing.name ?? "Right", sliceID: trailing.id, edge: \.blendLeft)
            }
            Text("Depth backs the ramp off when the overlap's light overshoots; Lift raises blacks OUTSIDE the overlap so dark scenes don't show a bright seam band.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sideColumn(
        title: String, sliceID: UUID,
        edge: WritableKeyPath<OutputAdjustments, OutputEdgeBlend?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
            let blend = outputs.adjustments(forScreen: sliceID)[keyPath: edge]
            HStack(spacing: 8) {
                Text("Curve")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                rampButton(sliceID, edge, current: blend?.curve, value: 1.0,
                           help: "Linear — even falloff")
                rampButton(sliceID, edge, current: blend?.curve, value: 2.2,
                           help: "Natural — matches projector gamma")
                rampButton(sliceID, edge, current: blend?.curve, value: 3.2,
                           help: "Steep — holds bright longer, drops fast at the seam")
            }
            trim("Depth", value: blend?.intensity ?? 1, range: 0...1) { newValue in
                write(sliceID, edge) { $0.intensity = newValue >= 1 ? nil : newValue }
            }
            trim("Lift", value: blend?.blackLift ?? 0, range: 0...0.25) { newValue in
                write(sliceID, edge) { $0.blackLift = newValue <= 0 ? nil : newValue }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rampButton(
        _ sliceID: UUID,
        _ edge: WritableKeyPath<OutputAdjustments, OutputEdgeBlend?>,
        current: Double?, value: Double, help: String
    ) -> some View {
        let selected = abs((current ?? 2.2) - value) < 0.15
        return Button {
            write(sliceID, edge) { $0.curve = value }
        } label: {
            RampShape(exponent: value)
                .stroke(
                    selected ? Color.white : Color.secondary,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                )
                .frame(width: 20, height: 13)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func trim(
        _ label: String, value: Double, range: ClosedRange<Double>,
        commit: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { value }, set: commit), in: range)
                .controlSize(.mini)
            Text(String(format: "%.2f", value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func write(
        _ sliceID: UUID,
        _ edge: WritableKeyPath<OutputAdjustments, OutputEdgeBlend?>,
        _ mutate: (inout OutputEdgeBlend) -> Void
    ) {
        var adjustments = outputs.adjustments(forScreen: sliceID)
        var blend = adjustments[keyPath: edge]
            ?? OutputEdgeBlend(width: max(overlap, 0.01))
        mutate(&blend)
        adjustments[keyPath: edge] = blend
        outputs.setAdjustments(adjustments, forScreen: sliceID)
    }
}

struct RampShape: Shape {
    var exponent: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 16
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for index in 1...steps {
            let t = Double(index) / Double(steps)

            let light = pow(1 - t, 1 / max(exponent, 0.1))
            path.addLine(to: CGPoint(
                x: rect.minX + rect.width * t,
                y: rect.minY + rect.height * (1 - light)
            ))
        }
        return path
    }
}

struct SeamGraph: View {
    let outputs: OutputManager
    let leading: OutputSliceState
    let trailing: OutputSliceState

    var body: some View {
        let left = outputs.adjustments(forScreen: leading.id).blendRight
        let right = outputs.adjustments(forScreen: trailing.id).blendLeft
        Canvas { context, size in
            let steps = 48
            func leftLight(_ t: Double) -> Double {
                guard let left else { return 1 }
                let ramp = pow(1 - t, max(left.curve, 0.1))
                return 1 - (left.intensity ?? 1) * (1 - ramp)
                    + (left.blackLift ?? 0) * ramp
            }
            func rightLight(_ t: Double) -> Double {
                guard let right else { return 0 }
                let ramp = pow(t, max(right.curve, 0.1))
                return 1 - (right.intensity ?? 1) * (1 - ramp)
                    + (right.blackLift ?? 0) * ramp
            }
            func plot(_ values: [Double]) -> Path {
                var path = Path()
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: size.width * Double(index) / Double(values.count - 1),

                        y: size.height * (1 - min(value, 1.2) / 1.2)
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }
            let ts = (0...steps).map { Double($0) / Double(steps) }
            let lefts = ts.map(leftLight)
            let rights = ts.map { 1 - rightLight(1 - $0) >= 0 ? rightLight($0) : rightLight($0) }
            let sums = zip(lefts, rights).map { min($0 + $1, 1.2) }

            let targetY = size.height * (1 - 1 / 1.2)
            var target = Path()
            target.move(to: CGPoint(x: 0, y: targetY))
            target.addLine(to: CGPoint(x: size.width, y: targetY))
            context.stroke(
                target, with: .color(.secondary.opacity(0.5)),
                style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
            )
            context.stroke(
                plot(lefts), with: .color(.purple.opacity(0.9)), lineWidth: 1.2)
            context.stroke(
                plot(rights), with: .color(.cyan.opacity(0.9)), lineWidth: 1.2)
            context.stroke(plot(sums), with: .color(.green), lineWidth: 2)
        }
        .frame(height: 92)
        .background(
            Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            Text("SUM — flat = seamless")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.green)
                .padding(4)
        }
        .help("Both projectors' light across the overlap and their sum — tune Width, Curve, and Depth until the green line reads flat")
    }
}

struct OutputEdgesPanel: View {
    let outputs: OutputManager
    let sliceID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            edgeRow("Left", \.blendLeft)
            edgeRow("Right", \.blendRight)
            edgeRow("Top", \.blendTop)
            edgeRow("Bottom", \.blendBottom)
            Text("Width is the ramp's reach into this output; γ steepens the falloff (≈2.2 matches projector gamma).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func edgeRow(
        _ label: String, _ keyPath: WritableKeyPath<OutputAdjustments, OutputEdgeBlend?>
    ) -> some View {
        let blend = outputs.adjustments(forScreen: sliceID)[keyPath: keyPath]
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { blend != nil },
                set: { on in
                    var adjustments = outputs.adjustments(forScreen: sliceID)
                    adjustments[keyPath: keyPath] = on ? OutputEdgeBlend(width: 0.15) : nil
                    outputs.setAdjustments(adjustments, forScreen: sliceID)
                }
            )) {
                Text(label)
                    .font(.caption2)
                    .frame(width: 44, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            if let blend {
                Slider(
                    value: Binding(
                        get: { blend.width },
                        set: { newValue in
                            var adjustments = outputs.adjustments(forScreen: sliceID)
                            adjustments[keyPath: keyPath]?.width = newValue
                            outputs.setAdjustments(adjustments, forScreen: sliceID)
                        }
                    ),
                    in: 0.01...0.5
                )
                .controlSize(.mini)
                Stepper(
                    value: Binding(
                        get: { blend.curve },
                        set: { newValue in
                            var adjustments = outputs.adjustments(forScreen: sliceID)
                            adjustments[keyPath: keyPath]?.curve = newValue
                            outputs.setAdjustments(adjustments, forScreen: sliceID)
                        }
                    ),
                    in: 0.5...4, step: 0.1
                ) {
                    Text(String(format: "γ %.1f", blend.curve))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .controlSize(.mini)
            } else {
                Spacer()
            }
        }
    }
}
