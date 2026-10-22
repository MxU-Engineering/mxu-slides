import RenderEngine
import SlideScene
import SwiftUI

struct ClearChip: View {
    let controls: ServiceControls

    @State private var open = false

    @AppStorage(ClearAllScope.skipsKey) private var storedSkips: String?
    @AppStorage(ClearAllScope.legacyIncludesAudioKey) private var legacyIncludesAudio: Bool?
    @AppStorage(ClearAllScope.sweepsTracksKey) private var sweepsTracks = false

    private var skips: Set<ShowFunction> {
        ClearAllScope.skips(stored: storedSkips, legacyIncludesAudio: legacyIncludesAudio, sweepsTracks: sweepsTracks)
    }

    var body: some View {
        let anyContent = controls.hasClearAllContent(sweeping: ClearAllScope.swept(skips: skips))
        Button {
            open = true
        } label: {
            HStack(spacing: 5) {
                Glyph(kind: .clear, size: 12)

                Text("Clear")
                    .font(.system(size: 10, weight: .medium))
                    .fixedSize()
            }
            .foregroundStyle(anyContent ? Color.green : .secondary)
            .headerItemLabel()
        }
        .buttonStyle(.plain)

        .headerItemBackground(tint: anyContent ? .green : nil)
        .help("Clear — everything at once, one function, or one layer. Right-click to choose what Clear All clears.")

        .contextMenu { ClearAllChecklistMenu() }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popup
        }
    }

    private var popup: some View {
        VStack(alignment: .leading, spacing: 8) {
            clearAllButton
            sectionLabel("Functions")
                .padding(.top, 4)
            HStack(spacing: 6) {
                functionButton(.slides)
                functionButton(.media)
                functionButton(.overlays)
            }

            HStack(spacing: 6) {
                functionButton(.audio)
                functionButton(.alerts)
                functionButton(.inputs)
            }

            HStack(spacing: 6) {
                functionButton(.tracks)
            }
            sectionLabel("Layers")
                .padding(.top, 4)

            ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                layerButton(layer)
            }
        }
        .padding(12)
        .frame(width: 252)
    }

    private var clearAllButton: some View {
        let anyContent = controls.hasClearAllContent(sweeping: ClearAllScope.swept(skips: skips))
        return VStack(alignment: .leading, spacing: 4) {
            clearAllPlate(anyContent: anyContent)

            if !skips.isEmpty {
                Text("Leaves \(ShowFunction.allCases.filter(skips.contains).map(\.displayName).formatted(.list(type: .and))) up · right-click to change")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contextMenu { ClearAllChecklistMenu() }
    }

    private func clearAllPlate(anyContent: Bool) -> some View {
        Button {
            controls.clearAll()
            open = false
        } label: {
            Text("Clear All")
                .font(.caption.weight(.medium))
                .foregroundStyle(anyContent ? Color.green : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            anyContent ? Color.green.opacity(0.10) : Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    anyContent ? Color.green.opacity(0.4) : Color.separator.opacity(0.5),
                    lineWidth: 1
                )
        )
        .help("Clear every function the checklist ticks (right-click to change)")
    }

    private func functionButton(_ function: ShowFunction) -> some View {
        let live = controls.hasContent(function: function)
        return Button {
            controls.clear(function: function)
        } label: {
            Text(function.displayName)
                .font(.caption.weight(live ? .medium : .regular))
                .foregroundStyle(live ? Color.green : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            live ? Color.green.opacity(0.10) : Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    live ? Color.green.opacity(0.4) : Color.separator.opacity(0.5),
                    lineWidth: 1
                )
        )

        .help("Clear Function: \(function.displayName)")
    }

    private func layerButton(_ layer: LayerKind) -> some View {
        let live = controls.hasContent(layer: layer)
        return Button {
            controls.clear(layer: layer)
        } label: {
            Text(layer.displayName)
                .font(.caption.weight(live ? .medium : .regular))
                .foregroundStyle(live ? Color.green : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            live ? Color.green.opacity(0.10) : Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    live ? Color.green.opacity(0.4) : Color.separator.opacity(0.5),
                    lineWidth: 1
                )
        )
        .help("Clear Layer: sweep \(layer.displayName) — green means live")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

struct ClearAllChecklistMenu: View {
    @AppStorage(ClearAllScope.skipsKey) private var storedSkips: String?
    @AppStorage(ClearAllScope.legacyIncludesAudioKey) private var legacyIncludesAudio: Bool?
    @AppStorage(ClearAllScope.sweepsTracksKey) private var sweepsTracks = false

    var body: some View {
        let skips = ClearAllScope.skips(stored: storedSkips, legacyIncludesAudio: legacyIncludesAudio, sweepsTracks: sweepsTracks)
        Text("Clear All clears")
        ForEach(ShowFunction.allCases, id: \.self) { function in
            Toggle(function.displayName, isOn: Binding(
                get: { !skips.contains(function) },
                set: { ClearAllScope.set(function, swept: $0) }
            ))
        }
    }
}

struct ClearAllChecklist: View {
    @AppStorage(ClearAllScope.skipsKey) private var storedSkips: String?
    @AppStorage(ClearAllScope.legacyIncludesAudioKey) private var legacyIncludesAudio: Bool?
    @AppStorage(ClearAllScope.sweepsTracksKey) private var sweepsTracks = false

    var body: some View {
        let skips = ClearAllScope.skips(stored: storedSkips, legacyIncludesAudio: legacyIncludesAudio, sweepsTracks: sweepsTracks)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 6) {
            ForEach(ShowFunction.allCases, id: \.self) { function in
                Toggle(function.displayName, isOn: Binding(
                    get: { !skips.contains(function) },
                    set: { ClearAllScope.set(function, swept: $0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
        }
    }
}
