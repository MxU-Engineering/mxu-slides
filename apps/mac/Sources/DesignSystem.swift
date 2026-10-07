import AppKit
import SwiftUI

enum CornerStandard {

    static let base: CGFloat = 26

    static let element: CGFloat = 8

    static func nested(inset: CGFloat, within container: CGFloat = base) -> CGFloat {
        max(0, container - inset)
    }

    static func cardHugging(inset: CGFloat) -> CGFloat {
        max(element, panel - inset)
    }
}

extension RoundedRectangle {

    static func standard(_ radius: CGFloat = CornerStandard.base) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
    }
}

struct QuietMenuChip<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)

        .fixedSize(horizontal: false, vertical: true)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

struct CommittedTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal

    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var commitToken = 0

    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title
        self._text = text
        self.axis = axis
    }

    var body: some View {
        TextField(title, text: $draft, axis: axis)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in

                if !focused { draft = newValue }
            }
            .onChange(of: draft) { _, newValue in
                guard newValue != text else { return }
                commitToken += 1
                let token = commitToken
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard token == commitToken else { return }
                    commit()
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused {
                    commitToken += 1
                    commit()
                }
            }
            .onDisappear {
                commitToken += 1
                commit()
            }
    }

    private func commit() {
        if text != draft { text = draft }
    }
}

struct ChipPicker<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option, label in
                let selected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(label)
                        .font(.system(size: 10, weight: selected ? .medium : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(
                    selected ? Color.primary.opacity(0.08) : .clear,
                    in: Capsule()
                )
                .overlay {
                    if selected {
                        Capsule().strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    }
                }
            }
        }
    }
}

struct ToolbarCluster<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {

        HStack(spacing: 2) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

struct IconChipStrip<ID: Hashable>: View {
    struct Item {
        let id: ID
        let systemImage: String
        let title: String
    }

    let items: [Item]
    let isOn: (ID) -> Bool
    let toggle: (ID) -> Void
    var isEnabled: (ID) -> Bool = { _ in true }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let on = isOn(item.id)
                let enabled = isEnabled(item.id)
                Button {
                    toggle(item.id)
                } label: {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .frame(width: 22, height: 20)
                        .contentShape(RoundedRectangle.standard(CornerStandard.element))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .foregroundStyle(on ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(
                    on ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay {
                    if on {
                        RoundedRectangle.standard(CornerStandard.element).strokeBorder(
                            Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    }
                }
                .help(item.title)
                .accessibilityLabel(item.title)
            }
        }
    }
}

struct PanelHeightGrip: View {
    @Binding var height: Double
    var range: ClosedRange<Double> = 170 ... 620

    @State private var hovering = false
    @State private var dragStartHeight: Double?

    var body: some View {
        ZStack {
            Color.clear
            if hovering || dragStartHeight != nil {
                Capsule()
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 28, height: 3)
            }
        }
        .frame(height: 10)
        .contentShape(Rectangle().inset(by: -3))
        .onHover { inside in
            hovering = inside
            guard dragStartHeight == nil else { return }
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    dragStartHeight = start
                    height = min(
                        max(start - value.translation.height, range.lowerBound),
                        range.upperBound
                    )
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    if !hovering { NSCursor.pop() }
                }
        )
    }
}

struct PanelWidthGrip: View {

    static let minPanelWidth: Double = 330

    @Binding var width: Double
    var range: ClosedRange<Double> = minPanelWidth ... 520

    @State private var hovering = false
    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            Color.clear
            if hovering || dragStartWidth != nil {
                Capsule()
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 3, height: 28)
            }
        }
        .frame(width: 10)
        .contentShape(Rectangle().inset(by: -3))
        .onHover { inside in
            hovering = inside

            guard dragStartWidth == nil else { return }
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    dragStartWidth = start
                    width = min(
                        max(start - value.translation.width, range.lowerBound),
                        range.upperBound
                    )
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    if !hovering { NSCursor.pop() }
                }
        )
    }
}

struct BoundedSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var onScrubPhase: ((Bool) -> Void)?

    var stacked = false

    @State private var live: Double?

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) { track; readout }
            }
        } else {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption)
                    .frame(width: 70, alignment: .leading)
                    .lineLimit(1)
                track
                readout
            }
        }
    }

    private var track: some View {
            Slider(
                value: Binding(
                    get: { live ?? value },
                    set: { raw in
                        let snapped = step > 0 ? (raw / step).rounded() * step : raw
                        let next = min(max(snapped, range.lowerBound), range.upperBound)
                        if live == nil { onScrubPhase?(true) }
                        live = next
                        value = next 
                    }
                ),
                in: range
            ) { editing in
                if !editing {
                    onScrubPhase?(false) 
                    if let live { value = live } 
                    live = nil
                }
            }
            .controlSize(.small)
    }

    private var readout: some View {
            TextField(
                label,
                value: Binding(
                    get: { live ?? value },
                    set: { raw in
                        let snapped = step > 0 ? (raw / step).rounded() * step : raw
                        value = min(max(snapped, range.lowerBound), range.upperBound)
                    }
                ),
                format: .number.grouping(.never)
                    .precision(.fractionLength(step >= 1 ? 0 ... 0 : 0 ... 2))
            )
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(width: 42)
    }
}

struct AngleDialRow: View {
    let label: String

    @Binding var value: Double
    var range: ClosedRange<Double> = -360 ... 360
    var onScrubPhase: ((Bool) -> Void)?

    @State private var live: Double?
    @State private var dragging = false

    private static let diameter: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)
            dial
            Spacer(minLength: 4)
            TextField(
                label,
                value: Binding(
                    get: { live ?? value },
                    set: { raw in value = min(max(raw, range.lowerBound), range.upperBound) }
                ),
                format: .number.grouping(.never).precision(.fractionLength(0 ... 0))
            )
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(width: 42)
            Text("°")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var dial: some View {
        let d = Self.diameter
        let angle = Angle(degrees: live ?? value)
        return ZStack {
            Circle()
                .fill(Color.primary.opacity(dragging ? 0.10 : 0.06))
            Circle()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)

            Rectangle()
                .fill(.tertiary)
                .frame(width: 1, height: 3)
                .offset(y: -(d / 2 - 3))

            Capsule()
                .fill(.primary)
                .frame(width: 2, height: d / 2 - 5)
                .offset(y: -(d / 4 - 2))
                .rotationEffect(angle)
            Circle()
                .fill(.primary)
                .frame(width: 4, height: 4)
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .help("Drag to rotate · ⇧ snaps to 15°")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    if !dragging {
                        dragging = true
                        onScrubPhase?(true)
                    }
                    let dx = gesture.location.x - d / 2
                    let dy = gesture.location.y - d / 2

                    var degrees = atan2(dx, -dy) * 180 / .pi
                    let snap: Double = NSEvent.modifierFlags.contains(.shift) ? 15 : 1
                    degrees = (degrees / snap).rounded() * snap
                    if degrees == -180 { degrees = 180 }
                    let next = min(max(degrees, range.lowerBound), range.upperBound)
                    if next != live {
                        live = next
                        value = next 
                    }
                }
                .onEnded { _ in
                    onScrubPhase?(false)
                    if let live { value = live } 
                    live = nil
                    dragging = false
                }
        )
    }
}

struct ScrubbableNumberField: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>?
    var step: Double = 1

    var onScrubPhase: ((Bool) -> Void)?

    var stacked = false

    @State private var live: Double?
    @State private var scrubOrigin: Double?

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 3) {
                scrubLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                valueField(width: nil)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
            }
        } else {
            HStack {
                scrubLabel
                Spacer()
                valueField(width: 72)
            }
        }
    }

    private var scrubLabel: some View {
        Text(label)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(scrubGesture)
    }

    @ViewBuilder
    private func valueField(width: CGFloat?) -> some View {
        if let live {
            Text(live, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .trailing)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        } else {
            TextField(
                label, value: clampedBinding,
                format: .number.grouping(.never).precision(.fractionLength(0...1))
            )
            .labelsHidden()

            .multilineTextAlignment(width == nil ? .leading : .trailing)
            .frame(width: width)
        }
    }

    private var clampedBinding: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in value = clamp(newValue) }
        )
    }

    private func clamp(_ raw: Double) -> Double {
        guard let range else { return raw }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if scrubOrigin == nil {
                    scrubOrigin = value
                    onScrubPhase?(true)
                }

                let fine = NSEvent.modifierFlags.contains(.option)
                let increment = fine ? step / 10 : step
                let ticks = gesture.translation.width / 2
                let raw = (scrubOrigin ?? value) + Double(ticks) * increment
                let quantized = (raw / increment).rounded() * increment
                let next = clamp(quantized)
                if next != live {
                    live = next
                    value = next 
                }
            }
            .onEnded { _ in
                onScrubPhase?(false) 
                if let live { value = live } 
                live = nil
                scrubOrigin = nil
            }
    }
}

extension Color {
    private static func dynamic(
        dark: (Double, Double, Double), light: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }

    static let basePlane = dynamic(
        dark: (31 / 255.0, 31 / 255.0, 30 / 255.0), light: (0.957, 0.953, 0.941)
    )

    static let cardSurface = dynamic(
        dark: (38 / 255.0, 38 / 255.0, 38 / 255.0), light: (1.0, 1.0, 1.0)
    )
}

private final class ToolTipNSView: NSView {
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}

private struct ToolTipBacking: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ToolTipNSView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {

        if view.toolTip != text { view.toolTip = text }
    }
}

extension View {

    func reliableHelp(_ text: String) -> some View {
        overlay(ToolTipBacking(text: text))
    }
}
