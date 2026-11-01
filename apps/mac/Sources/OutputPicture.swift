import OutputEngine
import RenderEngine
import SwiftUI

enum OutputCarry {

    enum Key: Hashable {
        case display(DisplayUUID)
        case deckLink(Int64)
    }

    @MainActor
    static func key(of sliceID: UUID, outputs: OutputManager) -> Key? {
        if let display = outputs.placeholderDevices[sliceID] { return .display(display) }
        if let backing = DeckLinkScreenOutputs.shared.backing(for: sliceID) {
            return .deckLink(backing.devicePersistentID)
        }
        return nil
    }

    @MainActor
    static func members(of key: Key, outputs: OutputManager) -> [UUID] {
        switch key {
        case .display(let display):
            return outputs.placeholderDevices.filter { $0.value == display }
                .keys.sorted { $0.uuidString < $1.uuidString }
        case .deckLink(let device):
            return DeckLinkScreenOutputs.shared.members(onDevice: device)
        }
    }

    @MainActor
    static func siblings(of sliceID: UUID, outputs: OutputManager) -> [UUID] {
        guard let key = key(of: sliceID, outputs: outputs) else { return [] }
        return members(of: key, outputs: outputs).filter { $0 != sliceID }
    }

    @MainActor
    static func screenIDs(of members: [UUID], outputs: OutputManager) -> [UUID] {
        var seen: [UUID] = []
        for member in members {
            if let id = outputs.sliceInfo(for: member)?.screenID, !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    @MainActor
    static func groups(outputs: OutputManager) -> [(key: Key, members: [UUID])] {
        var keys: [Key] = []
        for screen in outputs.placeholderScreens {
            for slice in outputs.slices(forScreen: screen.id) {
                if let key = key(of: slice.id, outputs: outputs), !keys.contains(key) { keys.append(key) }
            }
        }
        return keys.map { ($0, members(of: $0, outputs: outputs)) }
            .filter { screenIDs(of: $0.members, outputs: outputs).count > 1 }
    }

    @MainActor
    static func name(of key: Key, outputs: OutputManager) -> String {
        switch key {
        case .display(let display):
            return outputs.displays.first { $0.uuid == display }?.name
                ?? members(of: key, outputs: outputs).compactMap { outputs.placeholderDeviceNames[$0] }.first
                ?? "Display"
        case .deckLink:
            return members(of: key, outputs: outputs)
                .compactMap { DeckLinkScreenOutputs.shared.backing(for: $0)?.deviceName }.first ?? "DeckLink"
        }
    }

    static func kindWord(_ key: Key) -> String {
        switch key {
        case .display: "Display"
        case .deckLink: "DeckLink"
        }
    }

    @MainActor
    static func label(_ sliceID: UUID, outputs: OutputManager) -> String {
        guard let info = outputs.sliceInfo(for: sliceID) else { return "Slice" }
        let screenName = outputs.placeholderScreens
            .first { $0.id == info.screenID }?.name ?? "Screen"
        return info.name.map { "\(screenName) — \($0)" } ?? screenName
    }

    @MainActor
    static func frameSize(of key: Key, outputs: OutputManager) -> (width: Int, height: Int) {
        switch key {
        case .display(let display):
            if let snapshot = outputs.displays.first(where: { $0.uuid == display }) {
                return pixelSize(of: snapshot)
            }
        case .deckLink:
            let members = members(of: key, outputs: outputs)
            if let mode = members.compactMap({ DeckLinkScreenOutputs.shared.backing(for: $0)?.mode }).first {
                return (mode.width, mode.height)
            }
        }
        if let frame = members(of: key, outputs: outputs)
            .compactMap({ outputs.placement(forSlice: $0) }).first {
            return (frame.frameWidth, frame.frameHeight)
        }
        return (1920, 1080)
    }

    @MainActor
    static func frameSize(for sliceID: UUID, outputs: OutputManager) -> (width: Int, height: Int) {
        if let key = key(of: sliceID, outputs: outputs) { return frameSize(of: key, outputs: outputs) }
        let info = outputs.sliceInfo(for: sliceID)
        return (info?.width ?? 1920, info?.height ?? 1080)
    }

    static func pixelSize(of display: DisplaySnapshot) -> (width: Int, height: Int) {
        if let mode = CGDisplayCopyDisplayMode(display.displayID), mode.pixelWidth > 0 {
            return (mode.pixelWidth, mode.pixelHeight)
        }
        return (Int(display.frame.width), Int(display.frame.height))
    }

    @MainActor
    static func join(_ sliceID: UUID, _ key: Key, outputs: OutputManager, render: RenderContext) {
        let holders = members(of: key, outputs: outputs).filter { $0 != sliceID }
        let frame = frameSize(of: key, outputs: outputs)
        NDIScreenOutputs.shared.disable(screenID: sliceID)
        for holder in holders where outputs.placement(forSlice: holder) == nil {
            outputs.seedPlacement(forSlice: holder, frameWidth: frame.width, frameHeight: frame.height)
        }
        outputs.seedPlacement(
            forSlice: sliceID, frameWidth: frame.width, frameHeight: frame.height,
            siblings: holders.compactMap { outputs.placement(forSlice: $0) })
        switch key {
        case .display(let display):
            DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
            outputs.assignPlaceholderDevice(
                placeholderID: sliceID, displayUUID: display,
                displayName: outputs.displays.first { $0.uuid == display }?.name, exclusive: false)
        case .deckLink(let id):
            guard let device = DeckLinkDeviceCatalog.shared.devices.first(where: { $0.persistentID == id })
            else { return }
            DeckLinkScreenOutputs.shared.enable(
                screenID: sliceID, device: device, keying: .off, joining: true, render: render)
        }
    }

    @MainActor
    static func release(_ sliceID: UUID, outputs: OutputManager, render: RenderContext) {
        NDIScreenOutputs.shared.disable(screenID: sliceID)
        DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
        outputs.assignPlaceholderDevice(placeholderID: sliceID, displayUUID: nil)
        outputs.setPlacement(nil, forSlice: sliceID)
    }
}

struct OutputPicture: View {
    enum Mode: Hashable { case content, grid }

    let render: RenderContext
    let outputs: OutputManager
    let sliceID: UUID

    let selectSlice: (UUID) -> Void
    var mode: Mode = .content
    var snapOn = true
    var showsHeader = true

    @State private var moveOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero

    private static let rulerWidth = 22.0
    private static let rulerHeight = 14.0

    private var snap: Double { snapOn ? 8 : 1 }
    private var placement: OutputPlacement? { outputs.placement(forSlice: sliceID) }
    private var frame: (width: Int, height: Int) {
        if let placement { return (placement.frameWidth, placement.frameHeight) }
        return OutputCarry.frameSize(for: sliceID, outputs: outputs)
    }
    private var members: [UUID] { [sliceID] + OutputCarry.siblings(of: sliceID, outputs: outputs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 8) {
                    Text("What \(carryName) sends")
                        .font(.caption.weight(.semibold))
                    Text("\(String(frame.width)) × \(String(frame.height)) · drag \(OutputCarry.label(sliceID, outputs: outputs)) where the processor reads it")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: Self.rulerWidth, height: Self.rulerHeight)
                    topRuler
                }
                HStack(spacing: 0) {
                    leftRuler
                    picture
                }
            }
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
            HStack(spacing: 12) {
                Text("Processor reads \(String(frame.width)) × \(String(frame.height))")
                Text(members.count == 1 ? "1 slice" : "\(members.count) slices")
                if members.count > 1 {
                    Text(overlaps ? "overlapping" : "no overlap")
                        .foregroundStyle(overlaps ? Color.orange : Color.secondary)
                }
                Spacer()
                Text("checkerboard = pixels nothing lands on")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var picture: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                checkerboard
                ForEach(members, id: \.self) { member in
                    region(member, in: size)
                }
            }
            .clipped()
        }
        .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
        .frame(maxHeight: 420)
    }

    private var checkerboard: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))
            let step = 10.0
            var path = Path()
            var y = 0.0
            var row = 0
            while y < size.height {
                var x = row.isMultiple(of: 2) ? 0.0 : step
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: step, height: step))
                    x += step * 2
                }
                y += step
                row += 1
            }
            context.fill(path, with: .color(Color(white: 0.11)))
        }
    }

    private var topRuler: some View {
        Canvas { context, size in
            for step in 0...8 {
                let x = size.width * Double(step) / 8
                let major = step.isMultiple(of: 2)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: x, y: size.height)); $0.addLine(to: CGPoint(x: x, y: size.height - (major ? 6 : 3))) },
                    with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                if major, step < 8 {
                    context.draw(
                        Text(String(frame.width * step / 8)).font(.system(size: 8)).foregroundStyle(.secondary),
                        at: CGPoint(x: x + 3, y: 4), anchor: .topLeading)
                }
            }
        }
        .frame(height: Self.rulerHeight)
    }

    private var leftRuler: some View {
        Canvas { context, size in
            for step in 0...8 {
                let y = size.height * Double(step) / 8
                let major = step.isMultiple(of: 2)
                context.stroke(
                    Path { $0.move(to: CGPoint(x: size.width, y: y)); $0.addLine(to: CGPoint(x: size.width - (major ? 6 : 3), y: y)) },
                    with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                if major, step < 8 {
                    context.draw(
                        Text(String(frame.height * step / 8)).font(.system(size: 7)).foregroundStyle(.secondary),
                        at: CGPoint(x: 1, y: y + 2), anchor: .topLeading)
                }
            }
        }
        .frame(width: Self.rulerWidth)
    }

    private var carryName: String {
        if let key = OutputCarry.key(of: sliceID, outputs: outputs) {
            return OutputCarry.name(of: key, outputs: outputs)
        }
        if NDIScreenOutputs.shared.isCarrying(sliceID) { return "NDI" }
        return "the output"
    }

    private var overlaps: Bool {
        let rects = members.map { unitRect($0) }
        for (index, rect) in rects.enumerated() {
            for other in rects[(index + 1)...] where rect.intersection(other).width > 0.001
                && rect.intersection(other).height > 0.001 {
                return true
            }
        }
        return false
    }

    private func unitRect(_ member: UUID) -> CGRect {
        outputs.placement(forSlice: member)?.unitRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func liveRect() -> CGRect {
        guard let placement else {
            return CGRect(x: 0, y: 0, width: Double(frame.width), height: Double(frame.height))
        }
        let w = snapped(placement.width + resizeOffset.width, min: 8, max: Double(frame.width) - placement.x)
        let h = snapped(placement.height + resizeOffset.height, min: 8, max: Double(frame.height) - placement.y)
        let x = snapped(placement.x + moveOffset.width, min: 0, max: Double(frame.width) - w)
        let y = snapped(placement.y + moveOffset.height, min: 0, max: Double(frame.height) - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func snapped(_ value: Double, min lower: Double, max upper: Double) -> Double {
        Swift.min(Swift.max((value / snap).rounded() * snap, lower), Swift.max(upper, lower))
    }

    @ViewBuilder
    private func region(_ member: UUID, in size: CGSize) -> some View {
        let isSelected = member == sliceID
        let scale = size.width / CGFloat(max(frame.width, 1))
        let rect: CGRect = isSelected
            ? liveRect().applying(CGAffineTransform(scaleX: scale, y: scale))
            : CGRect(
                x: unitRect(member).minX * size.width, y: unitRect(member).minY * size.height,
                width: unitRect(member).width * size.width, height: unitRect(member).height * size.height)
        let tint = isSelected ? Color.green : Color.cyan
        ZStack(alignment: .topLeading) {
            if let info = outputs.sliceInfo(for: member),
               let screen = outputs.placeholderScreens.first(where: { $0.id == info.screenID }) {
                if mode == .grid {
                    OutputTestCard(
                        name: OutputCarry.label(member, outputs: outputs),
                        width: info.width, height: info.height, tint: tint)
                } else {
                    PlaceholderScreenPreview(
                        screen: screen, compositor: render.compositor,
                        sourceRect: info.sourceRect == Compositor.fullSourceRect ? nil : info.sourceRect)
                }
            }
            Text(regionLabel(member))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
                .padding(3)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
                .lineLimit(1)
        }
        .frame(width: max(rect.width, 8), height: max(rect.height, 8))
        .clipped()
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint, lineWidth: isSelected ? 1.5 : 1))
        .overlay(alignment: .bottomTrailing) {
            if isSelected, placement != nil {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .overlay(Rectangle().strokeBorder(tint, lineWidth: 1))
                    .offset(x: 4, y: 4)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                resizeOffset = CGSize(
                                    width: value.translation.width / scale,
                                    height: value.translation.height / scale)
                            }
                            .onEnded { _ in commit() }
                    )
                    .help("Drag to resize — the slice's pixels scale to the new size; 1:1 is its own canvas size")
            }
        }
        .offset(x: rect.minX, y: rect.minY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard isSelected, placement != nil else { return }
                    moveOffset = CGSize(
                        width: value.translation.width / scale,
                        height: value.translation.height / scale)
                }
                .onEnded { _ in if isSelected { commit() } }
        )
        .onTapGesture {
            if !isSelected { selectSlice(member) }
        }
        .help(isSelected ? "Drag to move; the fields below nudge by 8 px" : "Click to select \(regionLabel(member))")
    }

    private func regionLabel(_ member: UUID) -> String {
        guard let info = outputs.sliceInfo(for: member) else { return "Slice" }
        let rect = unitRect(member)
        let isOneToOne = outputs.placement(forSlice: member).map {
            Int($0.width) == info.width && Int($0.height) == info.height
        } ?? false
        var parts = [OutputCarry.label(member, outputs: outputs)]
        parts.append("\(Int((rect.width * Double(frame.width)).rounded()))×\(Int((rect.height * Double(frame.height)).rounded()))")
        if isOneToOne { parts.append("1:1") }
        return parts.joined(separator: " · ")
    }

    private func commit() {
        guard var next = placement else { return }
        let rect = liveRect()
        next.x = rect.minX
        next.y = rect.minY
        next.width = rect.width
        next.height = rect.height
        moveOffset = .zero
        resizeOffset = .zero
        outputs.setPlacement(next, forSlice: sliceID)

        DeckLinkScreenOutputs.shared.refreshCarry(for: sliceID, render: render)
    }
}

struct OutputTestCard: View {
    let name: String
    let width: Int
    let height: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(tint.opacity(0.16)))
            var grid = Path()
            let columns = 8
            let rows = max(2, Int((Double(columns) * size.height / max(size.width, 1)).rounded()))
            for step in 1..<columns {
                let x = size.width * Double(step) / Double(columns)
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for step in 1..<rows {
                let y = size.height * Double(step) / Double(rows)
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(tint.opacity(0.3)), lineWidth: 0.5)
            var marks = Path()
            marks.move(to: .zero); marks.addLine(to: CGPoint(x: size.width, y: size.height))
            marks.move(to: CGPoint(x: size.width, y: 0)); marks.addLine(to: CGPoint(x: 0, y: size.height))
            let radius = min(size.width, size.height) * 0.38
            marks.addEllipse(in: CGRect(
                x: size.width / 2 - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2))
            context.stroke(marks, with: .color(tint.opacity(0.55)), lineWidth: 1)
        }
        .overlay {
            VStack(spacing: 1) {
                Text(name)
                    .font(.system(size: 15, weight: .bold))
                Text("\(String(width)) × \(String(height))")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .shadow(color: .black.opacity(0.8), radius: 3)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .padding(8)
        }
    }
}

struct PlacementFields: View {
    let render: RenderContext
    let outputs: OutputManager
    let sliceID: UUID

    var body: some View {
        if let placement = outputs.placement(forSlice: sliceID) {
            HStack(spacing: 6) {
                Text("At")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                field(placement.x) { value in update(placement) { $0.x = value } }
                field(placement.y) { value in update(placement) { $0.y = value } }
                Text("Size")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                field(placement.width) { value in update(placement) { $0.width = max(value, 8) } }
                field(placement.height) { value in update(placement) { $0.height = max(value, 8) } }
                Text("px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help("Where this slice's pixels sit inside the \(placement.frameWidth)×\(placement.frameHeight) the output sends — the crop your processor is configured for")
        }
    }

    private func update(_ placement: OutputPlacement, _ mutate: (inout OutputPlacement) -> Void) {
        var value = placement
        mutate(&value)
        outputs.setPlacement(value, forSlice: sliceID)

        DeckLinkScreenOutputs.shared.refreshCarry(for: sliceID, render: render)
    }

    private func field(_ value: Double, commit: @escaping (Double) -> Void) -> some View {
        let step = 8.0
        return HStack(spacing: 0) {
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
}
