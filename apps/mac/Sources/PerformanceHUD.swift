import MediaEngine
import PresenterCore
import SwiftUI

struct PerformanceHUD: View {
    let render: RenderContext
    let media: MediaTransportController

    private struct Sample {
        var date = Date()
        var pulls = 0
        var perPlayer: [String: PlaybackStats] = [:]
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let fps: Double
        let droppedTotal: Int
        let droppedPerSecond: Double
        let seam: Int
    }

    @State private var previous = Sample()
    @State private var rows: [Row] = []
    @State private var pullRate = 0.0
    @State private var transition: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("PERFORMANCE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "render %.0f/s", pullRate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(pullRate < 55 && pullRate > 0 ? .orange : .secondary)
            }
            if let transition {
                Text("transition: \(transition)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.cyan)
            }
            if rows.isEmpty {
                Text("no videos playing")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(maxWidth: 110, alignment: .leading)
                    Text(String(format: "%.1ffps", row.fps))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(row.fps < 24 ? .orange : .secondary)
                    Text("drops \(row.droppedTotal)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(row.droppedPerSecond > 0.5 ? Color.red : Color.secondary)
                    if row.droppedPerSecond > 0.01 {
                        Text(String(format: "+%.0f/s", row.droppedPerSecond))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                    if row.seam > 0 {
                        Text("seam \(row.seam)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle.standard(CornerStandard.element))
        .task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func sample() {
        let now = Date()
        let elapsed = now.timeIntervalSince(previous.date)
        let telemetry = render.transitions.telemetry(at: now)
        transition = telemetry.transition
        if elapsed > 0.1 {
            pullRate = Double(telemetry.pulls - previous.pulls) / elapsed
        }
        var current: [String: PlaybackStats] = [:]
        var next: [Row] = []
        for row in media.rows {
            let id = row.candidate.mediaID
            guard let stats = render.media.stats(for: id) else { continue }
            current[id] = stats
            let last = previous.perPlayer[id]
            let displayedDelta = stats.framesDisplayed - (last?.framesDisplayed ?? stats.framesDisplayed)
            let droppedDelta = stats.framesDropped - (last?.framesDropped ?? stats.framesDropped)
            next.append(Row(
                id: id,
                name: row.name,
                fps: elapsed > 0.1 ? Double(displayedDelta) / elapsed : 0,
                droppedTotal: stats.framesDropped,
                droppedPerSecond: elapsed > 0.1 ? Double(droppedDelta) / elapsed : 0,
                seam: stats.framesDroppedAtSeam
            ))
        }
        rows = next
        previous = Sample(date: now, pulls: telemetry.pulls, perPlayer: current)
    }
}

struct TransitionChip: View {
    let glyph: GlyphKind
    let kindKey: String
    let durationKey: String
    var fallbackKind = ""
    var fallbackDuration = 0.5

    @State private var open = false
    @State private var kindRaw = ""
    @State private var duration = 0.5

    private var kindName: String {
        switch TransitionKind(rawValue: kindRaw) {
        case .dissolve: "Dissolve"
        case .fadeBlack: "Fade Black"
        case .fadeWhite: "Fade White"
        case .fadeColor: "Fade Color"
        case .blurDissolve: "Blur Dslv"
        case .filmBurn: "Film Burn"
        case .cut, nil: "Cut"
        }
    }

    var showSlider = true

    var body: some View {
        HStack(spacing: 5) {
            Button {
                reload()
                open = true
            } label: {
                Glyph(kind: glyph, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(kindName)\(kindRaw.isEmpty ? "" : String(format: " %.2gs", duration)) — this layer's default; items with their own always win")
            if showSlider, !kindRaw.isEmpty {
                Slider(value: storedDuration, in: 0 ... 5)
                    .controlSize(.mini)
                    .tint(Color.primary.opacity(0.2))
                    .frame(width: 56)
            }
        }
        .onAppear(perform: reload)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {

                Picker("Transition", selection: storedKind) {
                    Text("Cut").tag("")
                    Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                    Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                    Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                    Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !kindRaw.isEmpty {
                    BoundedSliderRow(
                        label: "Duration", value: storedDuration, range: 0 ... 5, step: 0.05
                    )
                }
            }
            .padding(12)
            .frame(width: 220)
        }
    }

    private var storedKind: Binding<String> {
        Binding(
            get: { kindRaw },
            set: { v in
                kindRaw = v
                UserDefaults.standard.set(v, forKey: kindKey)
            }
        )
    }

    private var storedDuration: Binding<Double> {
        Binding(
            get: { duration },
            set: { v in
                duration = v
                UserDefaults.standard.set(v, forKey: durationKey)
            }
        )
    }

    private func reload() {
        kindRaw = UserDefaults.standard.string(forKey: kindKey) ?? fallbackKind
        let stored = UserDefaults.standard.double(forKey: durationKey)
        duration = stored > 0 ? stored : fallbackDuration
    }
}
