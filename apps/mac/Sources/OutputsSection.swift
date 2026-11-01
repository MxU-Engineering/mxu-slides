import OutputEngine
import RenderEngine
import SwiftUI

struct OutputsSection: View {
    let render: RenderContext
    let outputs: OutputManager
    let screen: PlaceholderScreen
    let openScreen: (UUID) -> Void

    private enum Selection: Equatable {
        case output(UUID)
        case seam(leading: UUID, trailing: UUID)
    }

    @State private var selection: Selection?
    @State private var tab: OutputPanelTab = .output

    private var slices: [OutputSliceState] {
        outputs.slices(forScreen: screen.id)
    }

    private var extras: [OutputSliceState] {
        (outputs.screenSlices[screen.id] ?? [])
            .sorted { $0.sourceRect.minX < $1.sourceRect.minX }
    }

    private var kind: OutputLayoutKind {
        OutputLayout.classify(slices: slices, hasBlends: { hasBlends($0) })
    }

    private func hasBlends(_ sliceID: UUID) -> Bool {
        let adjustments = outputs.adjustments(forScreen: sliceID)
        return adjustments.blendLeft != nil || adjustments.blendRight != nil
            || adjustments.blendTop != nil || adjustments.blendBottom != nil
    }

    private var seams: [(leading: OutputSliceState, trailing: OutputSliceState)] {
        guard kind == .edgeBlend, extras.count >= 2 else { return [] }
        return (0..<(extras.count - 1)).map { (extras[$0], extras[$0 + 1]) }
    }

    private var selectedOutput: OutputSliceState? {
        if kind == .single { return slices.first }
        if case .output(let id) = selection,
           let hit = slices.first(where: { $0.id == id }) {
            return hit
        }
        if case .seam = selection { return nil }
        return kind == .mirror ? slices.first : extras.first
    }

    private func showsPicture(_ slice: OutputSliceState) -> Bool {
        outputs.placement(forSlice: slice.id) != nil
            || !OutputCarry.siblings(of: slice.id, outputs: outputs).isEmpty
    }

    private var selectedSeam: (leading: OutputSliceState, trailing: OutputSliceState)? {
        guard case .seam(let a, let b) = selection else { return nil }
        return seams.first { $0.leading.id == a && $0.trailing.id == b }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let slice = selectedOutput, showsPicture(slice) {
                OutputPicture(
                    render: render, outputs: outputs, sliceID: slice.id,
                    selectSlice: { id in
                        if let info = outputs.sliceInfo(for: id) { openScreen(info.screenID) }
                    })
            } else {
                tileDiagram
            }
            if kind == .custom { customControls }
            selectionPanel
        }
        .onChange(of: screen.id) { _, _ in
            selection = nil
            tab = .output
        }
    }

    @ViewBuilder
    private var selectionPanel: some View {
        panelBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let seam = selectedSeam {
                        Text("Seam · \(seam.leading.name ?? "Left") ↔ \(seam.trailing.name ?? "Right")")
                            .font(.caption.weight(.medium))
                        Text("\(Int((max(seam.leading.sourceRect.maxX - seam.trailing.sourceRect.minX, 0) * Double(screen.width)).rounded())) px overlap")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let slice = selectedOutput {
                        Text(sliceTitle(slice))
                            .font(.caption.weight(.medium))
                        Text(backingSummary(slice))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    tabStrip
                    Spacer()
                    if kind == .custom, case .output(let id) = selection ?? .output(screen.id),
                       id != screen.id {
                        Button(role: .destructive) {
                            releaseCarries(id)
                            outputs.removeSlice(id: id)
                            selection = nil
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .help("Remove this slice — its output and corrections go with it")
                    }
                }
                if tab == .blend, let seam = selectedSeam {
                    SeamBlendPanel(
                        outputs: outputs, screen: screen,
                        leading: seam.leading, trailing: seam.trailing,
                        setOverlap: { setOverlap($0) }
                    )
                } else if let slice = selectedOutput {
                    switch tab {
                    case .output, .blend:
                        outputTab(slice)
                    case .color:
                        OutputColorPanel(outputs: outputs, sliceID: slice.id)
                    case .cornerPin:
                        OutputCornerPinPanel(outputs: outputs, sliceID: slice.id)
                    }
                    if kind == .custom, tab == .output {
                        OutputEdgesPanel(outputs: outputs, sliceID: slice.id)
                    }
                }
            }
        }
    }

    private var availableTabs: [OutputPanelTab] {
        kind == .edgeBlend
            ? [.output, .color, .cornerPin, .blend]
            : [.output, .color, .cornerPin]
    }

    private var tabStrip: some View {
        Picker("", selection: Binding(
            get: { selectedSeam != nil ? .blend : (tab == .blend ? .output : tab) },
            set: { chooseTab($0) }
        )) {
            ForEach(availableTabs, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .fixedSize()
    }

    private func chooseTab(_ newTab: OutputPanelTab) {
        if newTab == .blend {

            let target: (leading: OutputSliceState, trailing: OutputSliceState)?
            if case .output(let id) = selection {
                target = seams.first { $0.leading.id == id || $0.trailing.id == id }
                    ?? seams.first
            } else {
                target = selectedSeam ?? seams.first
            }
            if let target {
                selection = .seam(leading: target.leading.id, trailing: target.trailing.id)
                tab = .blend
            }
            return
        }

        if let seam = selectedSeam {
            selection = .output(seam.leading.id)
        }
        tab = newTab
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { kind }, set: { apply(kind: $0) })) {
                ForEach(pickerKinds, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help(kindHelp)
            Spacer()
            if kind == .mirror || kind == .grouped || kind == .edgeBlend {
                Stepper(
                    value: Binding(get: { outputCount }, set: { setCount($0) }),
                    in: 2...6
                ) {
                    Text("Slices \(outputCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            if kind == .edgeBlend || kind == .grouped || selectedOutput.map(showsPicture) == true {
                Toggle(
                    "Alignment Grid",
                    isOn: Binding(
                        get: { outputs.testPatternScreens.contains(screen.id) },
                        set: { outputs.setTestPattern($0, forScreen: screen.id) }
                    )
                )
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("Show the rigging grid on every output of this screen while aligning")
            }
        }
    }

    private var pickerKinds: [OutputLayoutKind] {
        kind == .custom
            ? OutputLayoutKind.allCases
            : [.single, .mirror, .grouped, .edgeBlend]
    }

    private var kindHelp: String {
        switch kind {
        case .single: "One output carries the whole canvas."
        case .mirror: "Every output shows the whole canvas — same picture on each."
        case .grouped: "Outputs tile the canvas edge to edge — a video wall with hard seams."
        case .edgeBlend: "Outputs overlap and ramp into each other — click a seam to tune its blend."
        case .custom: "Hand-placed regions — anything the named shapes can't express."
        }
    }

    private var outputCount: Int {
        kind == .mirror ? slices.count : max(extras.count, 2)
    }

    private func apply(kind newKind: OutputLayoutKind) {
        guard newKind != kind else { return }
        outputs.applyLayout(
            newKind, outputCount: max(outputCount, 2),
            overlap: 0.06, forScreen: screen.id,
            releasingCarries: releaseCarries
        )
        selection = nil
        tab = .output
    }

    private func setCount(_ count: Int) {
        switch kind {
        case .mirror:
            var current = outputs.screenSlices[screen.id] ?? []
            while current.count + 1 < count {
                outputs.addSlice(
                    toScreen: screen.id, name: "Mirror \(current.count + 2)")
                current = outputs.screenSlices[screen.id] ?? []
            }
            while current.count + 1 > count, let last = current.last {
                releaseCarries(last.id)
                outputs.removeSlice(id: last.id)
                current = outputs.screenSlices[screen.id] ?? []
            }
        case .grouped, .edgeBlend:
            let overlap = seams.first.map {
                max($0.leading.sourceRect.maxX - $0.trailing.sourceRect.minX, 0)
            } ?? 0.06
            outputs.applyLayout(
                kind, outputCount: count, overlap: overlap,
                forScreen: screen.id, releasingCarries: releaseCarries
            )
            selection = nil
        default:
            break
        }
    }

    private func releaseCarries(_ sliceID: UUID) {
        NDIScreenOutputs.shared.disable(screenID: sliceID)
        SyphonScreenOutputs.shared.disable(screenID: sliceID)
        DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
    }

    private func setOverlap(_ value: Double) {
        let tiles = extras
        guard tiles.count >= 2 else { return }
        let rects = OutputLayout.tiles(columns: tiles.count, overlap: value)
        for (index, tile) in tiles.enumerated() {
            outputs.setSliceSourceRect(rects[index], forSlice: tile.id)
            var adjustments = outputs.adjustments(forScreen: tile.id)
            let rampWidth = value / rects[index].width
            if index > 0 {
                var blend = adjustments.blendLeft ?? OutputEdgeBlend(width: rampWidth)
                blend.width = rampWidth
                adjustments.blendLeft = blend
            }
            if index < tiles.count - 1 {
                var blend = adjustments.blendRight ?? OutputEdgeBlend(width: rampWidth)
                blend.width = rampWidth
                adjustments.blendRight = blend
            }
            outputs.setAdjustments(adjustments, forScreen: tile.id)
        }
    }

    private var tileDiagram: some View {
        let members = kind == .mirror || kind == .single
            ? slices : (kind == .custom ? slices : extras)
        return Group {
            if kind == .mirror || kind == .single {
                HStack(spacing: 10) {
                    ForEach(members) { slice in
                        Button {
                            selection = .output(slice.id)
                        } label: {
                            tileFace(slice)
                                .aspectRatio(
                                    CGFloat(screen.width) / CGFloat(max(screen.height, 1)),
                                    contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxHeight: kind == .single ? 200 : 120)
            } else {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack(alignment: .topLeading) {
                        ForEach(members) { slice in
                            regionTile(slice, in: size)
                        }

                        ForEach(Array(seams.enumerated()), id: \.offset) { _, seam in
                            seamBand(seam, in: size)
                        }
                    }
                }
                .aspectRatio(
                    CGFloat(screen.width) / CGFloat(max(screen.height, 1)),
                    contentMode: .fit
                )
                .frame(maxHeight: 150)
            }
        }
    }

    private func regionTile(_ slice: OutputSliceState, in size: CGSize) -> some View {
        let rect = slice.sourceRect
        return Button {
            selection = .output(slice.id)
        } label: {
            tileFace(slice)
                .frame(
                    width: max(rect.width * size.width, 10),
                    height: max(rect.height * size.height, 10)
                )
        }
        .buttonStyle(.plain)
        .offset(x: rect.minX * size.width, y: rect.minY * size.height)
    }

    private func seamBand(
        _ seam: (leading: OutputSliceState, trailing: OutputSliceState), in size: CGSize
    ) -> some View {
        let start = seam.trailing.sourceRect.minX
        let end = seam.leading.sourceRect.maxX
        let width = max(end - start, 0.012)
        let isSelected = selection == .seam(
            leading: seam.leading.id, trailing: seam.trailing.id)
        return Button {
            selection = .seam(leading: seam.leading.id, trailing: seam.trailing.id)
        } label: {
            ZStack {
                LinearGradient(
                    colors: [
                        .clear, Color.black.opacity(0.65), Color.black.opacity(0.65),
                        .clear,
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.white.opacity(0.55))
                    .frame(width: isSelected ? 2.5 : 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: max(width * size.width, 14), height: size.height)
        .offset(x: start * size.width, y: 0)
        .help("The blend seam — click to tune width, curve, depth, and black lift for both sides")
    }

    private func tileFace(_ slice: OutputSliceState) -> some View {
        let isSelected = selection == .output(slice.id)
            || (selection == nil && selectedOutput?.id == slice.id)
        let region = slice.sourceRect == Compositor.fullSourceRect
            ? nil : slice.sourceRect
        return ZStack {

            PlaceholderScreenPreview(
                screen: screen, compositor: render.compositor, sourceRect: region)
            VStack(spacing: 2) {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sliceTitle(slice))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(backingSummary(slice))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(5)
                    .background(
                        Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
            }
            .padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
    }

    private func sliceTitle(_ slice: OutputSliceState) -> String {
        if slice.id == screen.id {
            return kind == .mirror ? "Main" : screen.name
        }
        return slice.name ?? "Slice"
    }

    private func backingSummary(_ slice: OutputSliceState) -> String {
        if let display = outputs.placeholderDevices[slice.id] {
            return outputs.placeholderDeviceNames[slice.id]
                ?? outputs.displays.first { $0.uuid == display }?.name
                ?? "Display"
        }
        if NDIScreenOutputs.shared.isCarrying(slice.id) { return "NDI" }
        if SyphonScreenOutputs.shared.isCarrying(slice.id) { return "Syphon" }
        if let backing = DeckLinkScreenOutputs.shared.backing(for: slice.id) {
            return backing.deviceName
        }
        return "No output"
    }

    private var customControls: some View {
        HStack {
            Button("Add Slice") {
                outputs.addSlice(
                    toScreen: screen.id, name: "Slice \(slices.count + 1)")
            }
            .font(.caption)
            .help("A new slice starts full-region — shrink its Region to place it")
            Spacer()
        }
    }

    @ViewBuilder
    private func outputTab(_ slice: OutputSliceState) -> some View {
        let isDefault = slice.id == screen.id
        if !isDefault, kind == .custom || kind == .mirror {
            HStack(spacing: 8) {
                CommittedTextField(
                    "Name",
                    text: Binding(
                        get: { slice.name ?? "" },
                        set: { outputs.setSliceName($0, forSlice: slice.id) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.mini)
                .frame(width: 110)
                if kind == .custom {
                    regionFields(slice)
                }
                Spacer()
            }
        }
        PlacementFields(render: render, outputs: outputs, sliceID: slice.id)
        OutputSourcePicker(
            render: render, outputs: outputs, screen: screen, sliceID: slice.id)
        delayRow(slice)
    }

    private func panelBox(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle.standard(CornerStandard.element)
                    .fill(Color.primary.opacity(0.03))
            )
    }

    private func delayRow(_ slice: OutputSliceState) -> some View {
        HStack(spacing: 10) {
            DelayField(
                unit: "frames", range: 0 ... OutputManager.maxVideoDelayFrames, step: 1,
                value: outputs.videoDelay(forScreen: slice.id)
            ) { outputs.setVideoDelay($0, forScreen: slice.id) }
            Text("Video held back to line up with slower outputs")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .help("Delays this output — glass and DeckLink/NDI feeds — by whole frames at its rate. Audio outputs have the matching delay in Settings › Audio/Video Inputs.")
    }

    private func regionFields(_ slice: OutputSliceState) -> some View {
        HStack(spacing: 4) {
            Text("Region")
                .font(.caption2)
                .foregroundStyle(.secondary)
            percentField(slice.sourceRect.minX, commit: rect(slice) { $0.origin.x = $1 })
            percentField(slice.sourceRect.minY, commit: rect(slice) { $0.origin.y = $1 })
            Text("·").foregroundStyle(.tertiary)
            percentField(slice.sourceRect.width, commit: rect(slice) { $0.size.width = $1 })
            percentField(slice.sourceRect.height, commit: rect(slice) { $0.size.height = $1 })
            Text("%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("x · y · width · height, as percentages of the canvas")
    }

    private func rect(
        _ slice: OutputSliceState, _ mutate: @escaping (inout CGRect, Double) -> Void
    ) -> (Double) -> Void {
        { value in
            var rect = slice.sourceRect
            mutate(&rect, value)
            outputs.setSliceSourceRect(rect, forSlice: slice.id)
            DeckLinkScreenOutputs.shared.refreshCarry(for: slice.id, render: render)
        }
    }

    private func percentField(
        _ value: Double, commit: @escaping (Double) -> Void
    ) -> some View {
        TextField(
            "0",
            text: Binding(
                get: { String(format: "%.0f", value * 100) },
                set: { commit((Double($0) ?? 0) / 100) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.mini)
        .frame(width: 40)
        .multilineTextAlignment(.trailing)
        .font(.caption.monospacedDigit())
    }
}
