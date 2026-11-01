import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

struct MapItem: Identifiable {
    let id: String
    var rect: CGRect
    var label: String
    var tint: Color

    var screen: PlaceholderScreen?
    var cardName: String?
    var pixelSize: (width: Int, height: Int)
    var movable: Bool
    var resizable: Bool
    var dimmed = false
}

struct MapPicture: View {
    let render: RenderContext
    let bounds: CGSize
    let items: [MapItem]
    let selected: String?
    var mode: OutputPicture.Mode = .grid
    var snapOn = true
    let select: (String) -> Void
    let commit: (String, CGRect) -> Void

    @State private var moveOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero

    private var snap: Double { snapOn ? 8 : 1 }

    private var frame: (width: Int, height: Int) {
        (Int(bounds.width + max(bounds.width * 0.12, 240)), Int(bounds.height + max(bounds.height * 0.12, 240)))
    }

    var body: some View {
        PictureChrome.framed(width: frame.width, height: frame.height) {
            GeometryReader { proxy in
                let size = proxy.size
                ZStack(alignment: .topLeading) {
                    PictureChrome.checkerboard
                    ForEach(items) { item in region(item, in: size) }
                }
                .clipped()
            }
            .aspectRatio(CGFloat(frame.width) / CGFloat(max(frame.height, 1)), contentMode: .fit)
            .frame(maxHeight: 420)
        }
    }

    private func liveRect(_ item: MapItem) -> CGRect {
        guard item.id == selected else { return item.rect }
        let w = item.resizable ? snapped(item.rect.width + resizeOffset.width, min: 8) : item.rect.width
        let h = item.resizable ? snapped(item.rect.height + resizeOffset.height, min: 8) : item.rect.height
        let x = item.movable ? snapped(item.rect.minX + moveOffset.width, min: 0) : item.rect.minX
        let y = item.movable ? snapped(item.rect.minY + moveOffset.height, min: 0) : item.rect.minY
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func snapped(_ value: Double, min lower: Double) -> Double {
        Swift.max((value / snap).rounded() * snap, lower)
    }

    @ViewBuilder
    private func region(_ item: MapItem, in size: CGSize) -> some View {
        let isSelected = item.id == selected
        let scale = size.width / CGFloat(max(frame.width, 1))
        let rect = liveRect(item).applying(CGAffineTransform(scaleX: scale, y: scale))
        ZStack(alignment: .topLeading) {
            if mode == .content, let screen = item.screen {
                PlaceholderScreenPreview(screen: screen, compositor: render.compositor)
            } else if let cardName = item.cardName {
                OutputTestCard(name: cardName, width: item.pixelSize.width, height: item.pixelSize.height, tint: item.tint)
            } else {
                Rectangle().fill(item.tint.opacity(0.18))
            }

            if !item.dimmed {
                Text(item.label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .padding(3)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
                    .lineLimit(1)
            }
        }
        .frame(width: max(rect.width, 8), height: max(rect.height, 8))
        .clipped()
        .opacity(item.dimmed ? 0.45 : 1)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(item.tint, lineWidth: isSelected ? 1.5 : 1))
        .overlay(alignment: .bottomTrailing) {
            if isSelected, item.resizable {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .overlay(Rectangle().strokeBorder(item.tint, lineWidth: 1))
                    .offset(x: 4, y: 4)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                resizeOffset = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                            }
                            .onEnded { _ in finish(item) }
                    )
            }
        }
        .offset(x: rect.minX, y: rect.minY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard isSelected, item.movable else { return }
                    moveOffset = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                }
                .onEnded { _ in if isSelected, item.movable { finish(item) } }
        )
        .onTapGesture { if !isSelected { select(item.id) } }
        .zIndex(isSelected ? 1 : 0)
    }

    private func finish(_ item: MapItem) {
        let rect = liveRect(item)
        moveOffset = .zero
        resizeOffset = .zero
        if rect != item.rect { commit(item.id, rect) }
    }
}

struct ScreenMapEditor: View {
    let render: RenderContext
    let outputs: OutputManager
    let openScreen: (UUID) -> Void

    @State private var selected: UUID?
    @State private var mode: OutputPicture.Mode = .grid
    @State private var snap = true
    @State private var name = ""

    private var map: ScreenMap { outputs.screenMap ?? ScreenMap() }
    private var audience: [PlaceholderScreen] {
        outputs.placeholderScreens.filter { outputs.role(forScreen: $0.id) != .confidence }
    }
    private var mapped: [PlaceholderScreen] { audience.filter { map.rect(for: $0.id) != nil } }
    private var offMap: [PlaceholderScreen] { audience.filter { map.rect(for: $0.id) == nil } }
    private var current: PlaceholderScreen? {
        mapped.first { $0.id == selected } ?? mapped.first
    }

    @MainActor
    static func add(to outputs: OutputManager) {
        let screens = outputs.placeholderScreens
            .filter { outputs.role(forScreen: $0.id) != .confidence }
            .map { (id: $0.id, width: $0.width, height: $0.height) }
        outputs.setScreenMap(.sideBySide(screens))
    }

    var body: some View {
        let bounds = map.bounds
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 220)
                    .onSubmit { var next = map; next.name = name; outputs.setScreenMap(next) }
                Text("Screen Map · \(String(Int(bounds.maxX))) × \(String(Int(bounds.maxY))) · where every audience screen sits")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Identify All") { outputs.identify(screens: mapped.map(\.id)) }
                    .controlSize(.small)
                Toggle("Alignment Grid", isOn: Binding(
                    get: { !mapped.isEmpty && mapped.allSatisfy { outputs.testPatternScreens.contains($0.id) } },
                    set: { on in for screen in mapped { outputs.setTestPattern(on, forScreen: screen.id) } }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text("Content").tag(OutputPicture.Mode.content)
                    Text("Grid").tag(OutputPicture.Mode.grid)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .help("Content: the live room, each screen's canvas in place. Grid: a named test card per screen")
                Toggle("Snap 8 px", isOn: $snap)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                Text(mapped.count == 1 ? "1 screen on the map" : "\(mapped.count) screens on the map")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                MapPicture(
                    render: render, bounds: bounds.size, items: items, selected: current?.id.uuidString,
                    mode: mode, snapOn: snap,
                    select: { selected = UUID(uuidString: $0) },
                    commit: { id, rect in
                        if let uuid = UUID(uuidString: id) { place(uuid, rect) }
                    })
                if let current { inspector(current) }
            }
            if !offMap.isEmpty { offMapRow }
            Text("Drag a screen to where it sits · the map grows to fit · a screen's size changes on its own page · a removed screen keeps its output and its dots, it just can't be placed on · confidence screens never go on the map")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .task(id: map.name) { name = map.name }
    }

    private var items: [MapItem] {
        mapped.compactMap { screen in
            guard let rect = map.rect(for: screen.id) else { return nil }
            let isSelected = screen.id == current?.id
            return MapItem(
                id: screen.id.uuidString, rect: rect,
                label: "\(screen.name) · \(String(screen.width))×\(String(screen.height)) · → \(carry(screen))",
                tint: isSelected ? .green : .cyan, screen: screen, cardName: screen.name,
                pixelSize: (screen.width, screen.height), movable: true, resizable: false)
        }
    }

    private func carry(_ screen: PlaceholderScreen) -> String {
        if let key = OutputCarry.key(of: screen.id, outputs: outputs) { return OutputCarry.name(of: key, outputs: outputs) }
        if NDIScreenOutputs.shared.isCarrying(screen.id) { return "NDI" }
        return "no output"
    }

    private func place(_ id: UUID, _ rect: CGRect?) {
        var next = map
        next.place(id, at: rect)
        outputs.setScreenMap(next)
    }

    @ViewBuilder
    private func inspector(_ screen: PlaceholderScreen) -> some View {
        let rect = map.rect(for: screen.id) ?? .zero
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name).font(.headline)
                Text("\(String(screen.width)) × \(String(screen.height)) · on \(carry(screen))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("X").font(.caption2).foregroundStyle(.secondary)
                PixelField(value: rect.minX) { place(screen.id, CGRect(x: max(0, $0), y: rect.minY, width: rect.width, height: rect.height)) }
                Text("Y").font(.caption2).foregroundStyle(.secondary)
                PixelField(value: rect.minY) { place(screen.id, CGRect(x: rect.minX, y: max(0, $0), width: rect.width, height: rect.height)) }
            }
            Text("Where it sits in the room. Its size is the screen's own canvas and changes on the screen's page.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Identify") { outputs.identify(screens: [screen.id]) }
                Button("Open \(screen.name) →") { openScreen(screen.id) }
                    .buttonStyle(.link)
            }
            .controlSize(.small)
            Button("Remove from map", role: .destructive) {
                place(screen.id, nil)
                selected = nil
            }
            .controlSize(.small)
            .help("Off the map it keeps its output and its dots; presets just can't place layers on it")
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle.standard(CornerStandard.element).fill(Color.primary.opacity(0.03)))
    }

    private var offMapRow: some View {
        HStack(spacing: 12) {
            Text("OFF THE MAP")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            ForEach(offMap) { screen in
                HStack(spacing: 6) {
                    Text(screen.name).font(.caption.weight(.medium))
                    Text("\(String(screen.width))×\(String(screen.height)) · \(carry(screen)) · gets layers by its dots only")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button("Add to map") {
                        place(screen.id, map.nextSeat(width: screen.width, height: screen.height))
                        selected = screen.id
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(10)
        .overlay(RoundedRectangle.standard(CornerStandard.element).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(Color.separator.opacity(0.6)))
    }
}

struct PresetPlacementsEditor: View {
    let render: RenderContext
    let outputs: OutputManager
    let presets: OutputPresetsController
    let presetID: String

    @State private var layer: String = LayerKind.slide.rawValue
    @State private var selectedIndex: Int?
    @State private var mode: OutputPicture.Mode = .grid
    @State private var snap = true
    @State private var expanded = true

    private var map: ScreenMap { outputs.screenMap ?? ScreenMap() }
    private var placements: [LayerPlacement] { presets.placements(presetID: presetID, layer: layer) }
    private var layerName: String {
        LayerKind(rawValue: layer)?.displayName ?? presets.customLayers(presetID: presetID).first { $0.id == layer }?.name ?? layer
    }
    private var mapped: [PlaceholderScreen] {
        outputs.placeholderScreens.filter { outputs.role(forScreen: $0.id) != .confidence && map.rect(for: $0.id) != nil }
    }

    private var chosen: [CGRect] {
        mapped.compactMap { screen in
            let enabled = presets.enabledLayers(presetID: presetID, targetId: screen.id.uuidString)
            return (enabled?.contains(layer) ?? true) ? map.rect(for: screen.id) : nil
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Layer", selection: $layer) {
                        ForEach(LayerKind.allCases, id: \.rawValue) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }

                        ForEach(presets.customLayers(presetID: presetID)) { custom in
                            Text(custom.name).tag(custom.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .onChange(of: layer) { _, _ in selectedIndex = nil }
                    Picker("", selection: $mode) {
                        Text("Content").tag(OutputPicture.Mode.content)
                        Text("Grid").tag(OutputPicture.Mode.grid)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    Toggle("Snap 8 px", isOn: $snap)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    Spacer()
                    Text(placements.isEmpty ? "\(layerName) follows its dots" : "\(layerName) · \(placements.count) placement\(placements.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(placements.isEmpty ? Color.secondary : Color.yellow)
                }
                HStack(alignment: .top, spacing: 10) {
                    MapPicture(
                        render: render, bounds: map.bounds.size, items: items,
                        selected: selectedIndex.map { "p\($0)" }, mode: mode, snapOn: snap,
                        select: { id in
                            if id.hasPrefix("p") { selectedIndex = Int(id.dropFirst()) }
                        },
                        commit: { id, rect in
                            guard id.hasPrefix("p"), let index = Int(id.dropFirst()) else { return }
                            update(index) { $0.x = rect.minX; $0.y = rect.minY; $0.width = rect.width; $0.height = rect.height }
                        })
                    sidebar
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text("Screen Map").font(.headline)
                Text("advanced · place a layer anywhere on the map, in as many places as you need")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var items: [MapItem] {
        let screens = mapped.compactMap { screen -> MapItem? in
            guard let rect = map.rect(for: screen.id) else { return nil }
            return MapItem(
                id: screen.id.uuidString, rect: rect, label: "\(screen.name) · \(String(screen.width))×\(String(screen.height))",
                tint: .cyan, screen: screen, cardName: screen.name,
                pixelSize: (screen.width, screen.height), movable: false, resizable: false, dimmed: true)
        }
        let placed = placements.enumerated().map { index, placement in
            MapItem(
                id: "p\(index)", rect: CGRect(x: placement.x, y: placement.y, width: placement.width, height: placement.height),
                label: "\(index + 1) · \(layerName) · \(String(Int(placement.width)))×\(String(Int(placement.height))) at \(String(Int(placement.x))),\(String(Int(placement.y))) · \(placement.scale == .fill ? "Fill" : "Fit")",
                tint: .yellow, screen: nil, cardName: nil,
                pixelSize: (Int(placement.width), Int(placement.height)), movable: true, resizable: true)
        }
        return screens + placed
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("One per screen") { set(ScreenMapResolver.onePerScreen(chosen)) }
                    .help("A placement filling each screen whose dot is on — the same whole picture on each")
                Button("Across chosen") { set(ScreenMapResolver.acrossScreens(chosen)) }
                    .help("One placement across every screen whose dot is on — one picture spanning them")
            }
            .controlSize(.small)
            Text("PLACEMENTS OF \(layerName.uppercased())")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                placementRow(index, placement)
            }
            HStack(spacing: 6) {
                Button("Add placement") {
                    let seat = chosen.first ?? map.bounds
                    add(LayerPlacement(layerId: layer, x: seat.minX, y: seat.minY, width: seat.width, height: seat.height, scale: nil))
                }
                .buttonStyle(.borderedProminent)
                Button("Duplicate") {
                    if let index = selectedIndex, index < placements.count {
                        var copy = placements[index]
                        copy.x += 64
                        copy.y += 64
                        add(copy)
                    }
                }
                .disabled(selectedIndex == nil)
                .help("A sister copy of the selected placement, offset so you can see it — drag it where it goes")
            }
            .controlSize(.small)
            Text("A screen shows whatever part of a placement falls on it. Remove every placement and the layer goes back to its dots.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 250)
    }

    @ViewBuilder
    private func placementRow(_ index: Int, _ placement: LayerPlacement) -> some View {
        let isSelected = index == selectedIndex
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(index + 1) · \(String(Int(placement.width)))×\(String(Int(placement.height))) at \(String(Int(placement.x))),\(String(Int(placement.y)))")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("", selection: Binding(
                    get: { placement.scale == .fill ? MediaScaleMode.fill : MediaScaleMode.fit },
                    set: { value in update(index) { $0.scale = value == .fill ? .fill : nil } }
                )) {
                    Text("Fit").tag(MediaScaleMode.fit)
                    Text("Fill").tag(MediaScaleMode.fill)
                }
                .pickerStyle(.menu)
                .controlSize(.mini)
                .fixedSize()
                Button(role: .destructive) {
                    remove(index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
            if isSelected {
                HStack(spacing: 4) {
                    PixelField(value: placement.x) { v in update(index) { $0.x = max(0, v) } }
                    PixelField(value: placement.y) { v in update(index) { $0.y = max(0, v) } }
                    PixelField(value: placement.width) { v in update(index) { $0.width = max(8, v) } }
                    PixelField(value: placement.height) { v in update(index) { $0.height = max(8, v) } }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle.standard(4).fill(isSelected ? Color.yellow.opacity(0.1) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle.standard(4).strokeBorder(isSelected ? Color.yellow : Color.separator.opacity(0.5), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedIndex = index }
    }

    private func set(_ seats: [MapPlacement]) {
        presets.setPlacements(
            seats.map { LayerPlacement(layerId: layer, x: $0.rect.minX, y: $0.rect.minY, width: $0.rect.width, height: $0.rect.height, scale: $0.fill ? .fill : nil) },
            presetID: presetID, layer: layer)
        selectedIndex = seats.isEmpty ? nil : 0
    }

    private func add(_ placement: LayerPlacement) {
        let next = placements + [placement]
        presets.setPlacements(next, presetID: presetID, layer: layer)
        selectedIndex = next.count - 1
    }

    private func remove(_ index: Int) {
        var next = placements
        guard index < next.count else { return }
        next.remove(at: index)
        presets.setPlacements(next, presetID: presetID, layer: layer)
        selectedIndex = nil
    }

    private func update(_ index: Int, _ mutate: (inout LayerPlacement) -> Void) {
        var next = placements
        guard index < next.count else { return }
        mutate(&next[index])
        presets.setPlacements(next, presetID: presetID, layer: layer)
    }
}
