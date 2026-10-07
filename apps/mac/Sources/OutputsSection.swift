import OutputEngine
import RenderEngine
import SwiftUI

struct OutputsSection: View {
    let render: RenderContext
    let outputs: OutputManager
    let screen: PlaceholderScreen

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
        OutputLayout.classify(
            slices: slices,
            hasBlends: { hasBlends($0) },
            hasPlacement: { outputs.placement(forSlice: $0) != nil }
        )
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
        if kind == .single || kind == .ledWall { return slices.first }
        if case .output(let id) = selection,
           let hit = slices.first(where: { $0.id == id }) {
            return hit
        }
        if case .seam = selection { return nil }
        return kind == .mirror ? slices.first : extras.first
    }

    private var selectedSeam: (leading: OutputSliceState, trailing: OutputSliceState)? {
        guard case .seam(let a, let b) = selection else { return nil }
        return seams.first { $0.leading.id == a && $0.trailing.id == b }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if kind != .ledWall { tileDiagram }
            if kind == .ledWall, let slice = selectedOutput { frameDiagram(slice) }
            if kind == .custom, let slice = selectedOutput,
               outputs.placement(forSlice: slice.id) != nil
                   || !carrySiblings(of: slice).isEmpty {
                frameDiagram(slice)
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
                        .help("Remove this output — its carry and corrections go with it")
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
                    Text("Outputs \(outputCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            if kind == .edgeBlend || kind == .grouped || kind == .ledWall {
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
            Toggle(
                "Sync Test",
                isOn: Binding(
                    get: { outputs.syncTestScreens.contains(screen.id) },
                    set: { outputs.setSyncTest($0, forScreen: screen.id) }
                )
            )
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            .help("Play the metronome sync pattern on this screen to check its picture against its sound")
        }
    }

    private var pickerKinds: [OutputLayoutKind] {
        kind == .custom
            ? OutputLayoutKind.allCases
            : [.single, .mirror, .grouped, .edgeBlend, .ledWall]
    }

    private var kindHelp: String {
        switch kind {
        case .single: "One output carries the whole canvas."
        case .mirror: "Every output shows the whole canvas — same picture on each."
        case .grouped: "Outputs tile the canvas edge to edge — a video wall with hard seams."
        case .edgeBlend: "Outputs overlap and ramp into each other — click a seam to tune its blend."
        case .ledWall: "Wall-native pixels landing at exact coordinates inside the processor's frame — 1:1, never scaled."
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
            return kind == .mirror ? "Main" : "Full Canvas"
        }
        return slice.name ?? "Output"
    }

    private func backingSummary(_ slice: OutputSliceState) -> String {
        if let display = outputs.placeholderDevices[slice.id] {
            return outputs.placeholderDeviceNames[slice.id]
                ?? outputs.displays.first { $0.uuid == display }?.name
                ?? "Display"
        }
        if NDIScreenOutputs.shared.isCarrying(slice.id) { return "NDI" }
        if let backing = DeckLinkScreenOutputs.shared.backing(for: slice.id) {
            return backing.deviceName
        }
        return "Unconfigured"
    }

    private var customControls: some View {
        HStack {
            Button("Add Output") {
                outputs.addSlice(
                    toScreen: screen.id, name: "Output \(slices.count + 1)")
            }
            .font(.caption)
            .help("A new output starts full-region — shrink its Region to place it")
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
        if kind == .ledWall || kind == .custom {
            placementFields(slice)
        }
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

    @ViewBuilder
    private func placementFields(_ slice: OutputSliceState) -> some View {
        let placement = outputs.placement(forSlice: slice.id)
        HStack(spacing: 6) {
            if kind == .custom {
                Toggle(
                    "Place in frame",
                    isOn: Binding(
                        get: { placement != nil },
                        set: { on in
                            if on {
                                let info = outputs.sliceInfo(for: slice.id)
                                outputs.setPlacement(
                                    OutputPlacement(
                                        frameWidth: 1920, frameHeight: 1080,
                                        x: 0, y: 0,
                                        width: Double(min(info?.width ?? 1920, 1920)),
                                        height: Double(min(info?.height ?? 1080, 1080))
                                    ),
                                    forSlice: slice.id)
                            } else {
                                outputs.setPlacement(nil, forSlice: slice.id)
                            }
                            DeckLinkScreenOutputs.shared.refreshCarry(
                                for: slice.id, render: render)
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("Land this output's content at exact pixels inside the carry's frame instead of filling it — the LED-processor contract")
            }
            if let placement {
                Text("Frame")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                placementField(Double(placement.frameWidth), step: 8) { value in
                    update(placement, slice.id) { $0.frameWidth = max(Int(value), 8) }
                }
                placementField(Double(placement.frameHeight), step: 8) { value in
                    update(placement, slice.id) { $0.frameHeight = max(Int(value), 8) }
                }
                Text("Position")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                placementField(placement.x, step: 8) { value in
                    update(placement, slice.id) { $0.x = value }
                }
                placementField(placement.y, step: 8) { value in
                    update(placement, slice.id) { $0.y = value }
                }
                Text("Size")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                placementField(placement.width, step: 8) { value in
                    update(placement, slice.id) { $0.width = max(value, 8) }
                }
                placementField(placement.height, step: 8) { value in
                    update(placement, slice.id) { $0.height = max(value, 8) }
                }
                Text("px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help("Where this output's pixels sit inside the signal the processor reads — Frame is the wire's full size, Position/Size the crop your processor is configured for")
    }

    private func update(
        _ placement: OutputPlacement, _ sliceID: UUID,
        _ mutate: (inout OutputPlacement) -> Void
    ) {
        var value = placement
        mutate(&value)
        outputs.setPlacement(value, forSlice: sliceID)

        DeckLinkScreenOutputs.shared.refreshCarry(for: sliceID, render: render)
    }

    private func placementField(
        _ value: Double, step: Double, commit: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            TextField(
                "0",
                text: Binding(
                    get: { String(format: "%.0f", value) },
                    set: { commit(Double($0) ?? 0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.mini)
            .frame(width: 46)
            .multilineTextAlignment(.trailing)
            .font(.caption.monospacedDigit())
            Stepper(
                "",
                onIncrement: { commit((value / step).rounded(.down) * step + step) },
                onDecrement: { commit(max(0, (value / step).rounded(.up) * step - step)) }
            )
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    private func carrySiblings(of slice: OutputSliceState) -> [UUID] {
        if let display = outputs.placeholderDevices[slice.id] {
            return outputs.placeholderDevices
                .filter { $0.value == display && $0.key != slice.id }
                .keys.sorted { $0.uuidString < $1.uuidString }
        }
        if let backing = DeckLinkScreenOutputs.shared.backing(for: slice.id) {
            return DeckLinkScreenOutputs.shared
                .members(onDevice: backing.devicePersistentID)
                .filter { $0 != slice.id }
        }
        return []
    }

    private func packedLabel(_ sliceID: UUID) -> String {
        guard let info = outputs.sliceInfo(for: sliceID) else { return "Output" }
        let screenName = outputs.placeholderScreens
            .first { $0.id == info.screenID }?.name ?? "Screen"
        return info.name.map { "\(screenName) — \($0)" } ?? screenName
    }

    private func frameDiagram(_ slice: OutputSliceState) -> some View {
        let placement = outputs.placement(forSlice: slice.id)
        let members = [slice.id] + carrySiblings(of: slice)
        return GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle.standard(CornerStandard.element)
                    .fill(Color.black.opacity(0.35))
                ForEach(members, id: \.self) { member in
                    let unit = outputs.placement(forSlice: member)?.unitRect
                        ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    let isSelected = member == slice.id
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(
                            isSelected ? Color.green : Color.cyan.opacity(0.8),
                            lineWidth: isSelected ? 1.5 : 1
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill((isSelected ? Color.green : Color.cyan).opacity(0.14))
                        )
                        .overlay(alignment: .topLeading) {
                            Text(packedLabel(member))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(isSelected ? Color.green : Color.cyan)
                                .padding(2)
                                .lineLimit(1)
                        }
                        .frame(
                            width: max(unit.width * size.width, 8),
                            height: max(unit.height * size.height, 8)
                        )
                        .offset(x: unit.minX * size.width, y: unit.minY * size.height)
                }
            }
        }
        .aspectRatio(
            CGFloat(placement?.frameWidth ?? 16) / CGFloat(max(placement?.frameHeight ?? 9, 1)),
            contentMode: .fit
        )
        .frame(maxHeight: 110)
        .help("The signal the carry sends: the frame at wire size, every packed output's pixels landing 1:1 inside it — right-click a claimed display/DeckLink card and Add Alongside to pack more")
    }
}
