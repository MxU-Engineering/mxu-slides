import RenderEngine
import SlideScene
import SwiftUI

struct ClearChip: View {
    let controls: ServiceControls

    @State private var open = false

    var body: some View {
        let anyContent = controls.hasAnyClearableContent
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (anyContent ? Color.green : .primary)
                    .opacity(anyContent ? 0.1 : 0.06),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Clear — everything at once, one function, or one layer")
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
                functionButton(.slides, key: "1")
                functionButton(.media, key: "2")
                functionButton(.overlays, key: "3")
            }
            HStack(spacing: 6) {
                functionButton(.audio, key: "4")
                functionButton(.alerts, key: "5")
                functionButton(.signage, key: "6")
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
        let anyContent = controls.hasAnyClearableContent
        return Button {
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
        .help("Clear every function (⌥⌘0)")
    }

    private func functionButton(_ function: ShowFunction, key: Character) -> some View {
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

        .help("Clear Function: \(function.displayName) (⌥⌘\(key))")
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
