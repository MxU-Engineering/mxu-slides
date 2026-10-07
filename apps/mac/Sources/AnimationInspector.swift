import AppKit
import PresenterCore
import SlideScene
import SwiftUI

extension AnimationKind {
    var displayName: String {
        switch self {
        case .in: "In"
        case .out: "Out"
        case .emphasis: "Emphasis"
        case .morph: "Morph"
        }
    }

    var glyph: String {
        switch self {
        case .in: "arrow.down.right.circle"
        case .out: "arrow.up.right.circle"
        case .emphasis: "sparkle"
        case .morph: "arrow.triangle.swap"
        }
    }
}

extension StepAnimation {
    var displayName: String {
        switch self {
        case .fade: "Fade"
        case .move: "Move"
        case .scale: "Scale"
        case .wipe: "Wipe"
        case .blur: "Blur"
        case .burn: "Burn"
        case .glitch: "Glitch"
        case .draw: "Draw"
        case .type: "Type"
        case .pulse: "Pulse"
        case .color: "Color"
        }
    }

    static let inOut: [StepAnimation] = [.fade, .move, .scale, .wipe, .blur, .burn, .glitch, .draw, .type]
    static let emphasis: [StepAnimation] = [.pulse, .color, .scale, .move, .fade]

    static func choices(for kind: AnimationKind) -> [StepAnimation] {
        kind == .emphasis ? emphasis : inOut
    }
}

extension AnimationTrigger {
    var displayName: String {
        switch self {
        case .onClick: "On Click"
        case .withPrevious: "With Previous"
        case .afterPrevious: "After Previous"
        case .onDismiss: "On Exit"
        }
    }

    var shortName: String {
        switch self {
        case .onClick: "Click"
        case .withPrevious: "With"
        case .afterPrevious: "After"
        case .onDismiss: "Final"
        }
    }
}

extension AnimationRamp {
    var displayName: String {
        switch self {
        case .none: "None"
        case .in: "In"
        case .out: "Out"
        case .both: "Both"
        }
    }
}

extension AnimationEdge {
    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

struct AnimationTab: View {
    let model: SlideEditorModel

    var body: some View {

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    AnimationGallery(model: model)
                    Divider()
                    AnimationSequenceList(model: model)
                    if let stepID = model.selectedAnimationStepID, model.animationStep(id: stepID) != nil {
                        Divider()
                        AnimationStepStrip(model: model, stepID: stepID)
                            .id("animationStepStrip")
                    }
                }
            }
            .coordinateSpace(name: "animationSequence")
            .onChange(of: model.selectedAnimationStepID) { _, selected in

                guard selected != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("animationStepStrip", anchor: .bottom)
                }
            }
        }
    }
}

enum AnimationGalleryTab: String, CaseIterable, Identifiable {
    case bringIn, takeOut, emphasize, change
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bringIn: "Bring In"
        case .takeOut: "Take Out"
        case .emphasize: "Emphasize"
        case .change: "Change"
        }
    }
    var kind: AnimationKind {
        switch self {
        case .bringIn: .in
        case .takeOut: .out
        case .emphasize: .emphasis
        case .change: .morph
        }
    }
    var tiles: [StepAnimation] {
        switch self {
        case .bringIn, .takeOut: [.fade, .move, .scale, .wipe, .blur, .burn, .glitch, .draw, .type]
        case .emphasize: [.pulse, .color, .scale, .move, .fade]
        case .change: [.fade, .blur, .burn, .glitch]
        }
    }
    static func tileTitle(_ animation: StepAnimation, in tab: AnimationGalleryTab) -> String {
        switch (tab, animation) {
        case (.change, .fade): "Move & restyle"
        case (.change, .blur): "Change with blur"
        case (.change, .burn): "Change with burn"
        case (.change, .glitch): "Change with glitch"
        case (_, .move): "Slide"
        case (_, .scale): tab == .emphasize ? "Grow & settle" : "Grow"
        case (_, .fade): tab == .emphasize ? "Dim" : "Fade"
        case (_, .move) where tab == .emphasize: "Nudge"
        default: animation.displayName
        }
    }
}

struct AnimationGallery: View {
    let model: SlideEditorModel
    @State private var tab: AnimationGalleryTab = .bringIn

    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 110), spacing: 6)]

    private func galleryTab(for kind: AnimationKind) -> AnimationGalleryTab {
        switch kind {
        case .in: .bringIn
        case .out: .takeOut
        case .emphasis: .emphasize
        case .morph: .change
        }
    }

    private var replacing: (id: String, step: AnimationStep, entry: AnimationSequence.Entry)? {
        guard let id = model.selectedAnimationStepID, let (_, step) = model.animationStep(id: id),
              let entry = model.stepEntries.first(where: { $0.step.id == id }) else { return nil }
        return (id, step, entry)
    }

    var body: some View {
        let target = model.stepTarget
        let replacing = replacing
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(replacing == nil ? "Effects" : "Effect")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if replacing == nil {

                    if case .ranges = target {
                        Menu("Generate") {
                            Button("One Step per Line") { generate(.line) }
                            Button("One Step per Word") { generate(.word) }
                        }
                        .controlSize(.small)
                        .disabled(tab == .change)
                        .help(tab == .change
                            ? "Change works on whole objects — pick Bring In, Take Out, or Emphasize to generate steps"
                            : "Expand the text selection into explicit steps: each line or word arrives on its own click")
                    }
                    AnimationPresetsMenu(model: model)
                        .controlSize(.small)
                }
                if replacing != nil {
                    Button("Add Another Effect") { model.selectedAnimationStepID = nil }
                        .controlSize(.small)
                        .help("Back to adding effects to the selection")
                }
            }
            Picker("", selection: $tab) {
                ForEach(AnimationGalleryTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            .onAppear {
                if let replacing { tab = galleryTab(for: replacing.step.kind) }
            }
            .onChange(of: model.selectedAnimationStepID) { _, _ in
                if let replacing = self.replacing { tab = galleryTab(for: replacing.step.kind) }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(tab.tiles, id: \.self) { animation in
                    let isCurrent = replacing.map { $0.step.kind == tab.kind && Self.matches($0.step, animation, in: tab) } ?? false
                    BuildTile(
                        title: AnimationGalleryTab.tileTitle(animation, in: tab),
                        kind: tab.kind, animation: animation,
                        enabled: replacing != nil
                            ? (tab != .change || replacing?.entry.step.ranges?.isEmpty ?? true)
                            : (tab == .change ? { if case .objects? = target { true } else { false } }() : target != nil),
                        current: isCurrent
                    ) {
                        if let replacing {
                            model.replaceStepEffect(replacing.id, kind: tab.kind, animation: animation)
                        } else {

                            model.quickAdd(
                                kind: tab.kind, animation: animation,
                                appendToLast: NSApp.currentEvent?.modifierFlags.contains(.option) == true
                            )
                        }
                    }
                }
            }
            Text(replacing.map { "Changing: \(model.stepTargetLabel($0.entry)) · \(model.animationSentence($0.step)). Click another effect to swap it." }
                 ?? (model.stepAddArmed
                        ? (target == nil
                            ? "Select an object in the Objects panel, then pick its effect here."
                            : (model.stepAddSlot == nil ? "Pick an effect. It starts a new click." : "Pick an effect. It joins the group you chose."))
                        : targetLine(target)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(replacing == nil ? 2 : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .onAppear { syncTab() }
        .onChange(of: model.selectedAnimationStepID) { _, _ in syncTab() }
    }

    private func generate(_ generator: AnimationRanges.Generator) {
        guard tab != .change else { return }
        model.generateAnimationSteps(
            by: generator, kind: tab.kind,
            animation: tab == .emphasize ? .pulse : .fade, trigger: .onClick
        )
    }

    private func syncTab() {
        guard let step = replacing?.step else { return }
        tab = switch step.kind {
        case .in: .bringIn
        case .out: .takeOut
        case .emphasis: .emphasize
        case .morph: .change
        }
    }

    private static func matches(_ step: AnimationStep, _ animation: StepAnimation, in tab: AnimationGalleryTab) -> Bool {
        if tab == .change {
            let blend: StepAnimation = [.blur, .burn, .glitch].contains(step.animation) ? step.animation : .fade
            return blend == animation
        }
        return step.animation == animation
    }

    private func targetLine(_ target: SlideEditorModel.StepTarget?) -> String {
        switch target {
        case .ranges(let objectID, let ranges)?:
            let text = ranges.map { AnimationRanges.text(of: $0, in: model.object(id: objectID)?.text ?? "") }.joined(separator: " … ")
            return "Click an effect to add it to “\(text.count > 24 ? String(text.prefix(24)) + "…" : text)”. ⌥-click joins the last step."
        case .objects(let ids)? where ids.count > 1:
            return "Click an effect to add it to the \(ids.count) selected objects (they play together)"
        case .objects(let ids)?:
            let object = ids.first.flatMap { model.object(id: $0) }
            let name = object.map { $0.name.isEmpty ? $0.objectKind.rawValue.capitalized : $0.name } ?? "object"

            if let scroll = object?.textStyle?.scroll, scroll.speed > 0 {
                return "\(name) rolls (\((scroll.axis ?? .up).rawValue) scroll, set in Object › Scroll). Effects here play on top."
            }
            return "Click an effect to add it to \(name)"
        case nil:
            return "Select an object on the canvas (or text while editing it) to animate it"
        }
    }
}

struct AnimationPresetsMenu: View {
    let model: SlideEditorModel
    @State private var namePrompt = false
    @State private var nameDraft = ""

    private var canApply: Bool {
        if case .objects? = model.stepTarget { return true }
        return false
    }

    var body: some View {
        Menu("Presets") {
            Menu("Recommended") {
                ForEach(AnimationPreset.recommendedGroups) { group in
                    if group.presets.count == 1, let only = group.presets.first {
                        items(only, builtIn: true, title: group.name)
                    } else {
                        Menu(group.name) {
                            ForEach(group.presets) { preset in items(preset, builtIn: true) }
                        }
                    }
                }
            }
            let saved = model.appModel.animationPresetBoard.presets
            if !saved.isEmpty { Divider() }
            ForEach(saved) { preset in items(preset, builtIn: false) }
            Divider()
            Button("Save as Preset…") { namePrompt = true }
                .disabled(model.animationPresetRecipe == nil)
        }
        .disabled(!canApply)
        .help(canApply ? "Apply an animation recipe to the selected objects (several stagger in selection order)"
                       : "Select objects to use a preset (text selections take effects from the gallery)")
        .alert("New Animation Preset", isPresented: $namePrompt) {
            TextField("Name", text: $nameDraft)
            Button("Save") {
                let name = nameDraft.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let recipe = model.animationPresetRecipe {
                    model.appModel.saveAnimationPreset(name: name, steps: recipe.steps, scroll: recipe.scroll, tilt: recipe.tilt)
                }
                nameDraft = ""
            }
            Button("Cancel", role: .cancel) { nameDraft = "" }
        }
    }

    @ViewBuilder
    private func items(_ preset: AnimationPreset, builtIn: Bool, title: String? = nil) -> some View {
        Menu(title ?? preset.name) {
            Button("Apply") { model.applyAnimationPreset(preset, mode: .replace) }
            Button("Add") { model.applyAnimationPreset(preset, mode: .add) }

            if let stepIn = preset.steps.first(where: { $0.kind == .in }) {
                Button("Set as Default In") { model.appModel.setAnimationDefault(in: stepIn) }
            }
            if let stepOut = preset.steps.first(where: { $0.kind == .out }) {
                Button("Set as Default Out") { model.appModel.setAnimationDefault(out: stepOut) }
            }
            if !builtIn {
                Button("Save Over") {
                    if let recipe = model.animationPresetRecipe {
                        model.appModel.overwriteAnimationPreset(id: preset.id, steps: recipe.steps, scroll: recipe.scroll, tilt: recipe.tilt)
                    }
                }
                .disabled(model.animationPresetRecipe == nil)
                Divider()
                Button("Delete", role: .destructive) { model.appModel.deleteAnimationPreset(id: preset.id) }
            }
        }
    }
}

struct BuildTile: View {
    let title: String
    let kind: AnimationKind
    let animation: StepAnimation
    let enabled: Bool
    var current = false
    let add: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.sRGB, white: 0.5).opacity(current ? 0.22 : 0.12))
                    if current {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                    TilePreview(kind: kind, animation: animation, playing: hovering)
                        .padding(8)
                }
                .frame(height: 44)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(!enabled ? "Select an object first" : current ? "The current effect" : "\(title). Hover to preview, click to use.")
    }
}

struct TilePreview: View {
    let kind: AnimationKind
    let animation: StepAnimation
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in

            let t = playing ? (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)) / 1.6 : 0.42

            let raw = min(t / 0.7, 1)
            let p = raw * raw * (3 - 2 * raw)
            let r = kind == .out ? 1 - p : p 
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let box = RoundedRectangle(cornerRadius: 3, style: .continuous)
                Group {
                    switch (kind, animation) {
                    case (.morph, _):

                        let side = h * (0.6 + 0.4 * p)
                        RoundedRectangle(cornerRadius: side / 2 * p + 2, style: .continuous)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: side, height: side)
                            .position(x: w * (0.25 + 0.5 * p), y: h / 2)
                            .blur(radius: animation == .blur ? 3 * sin(p * .pi) : 0)
                            .offset(x: animation == .glitch ? CGFloat(sin(p * 40)) * 2 * sin(p * .pi) : 0)
                            .overlay(animation == .burn ? Color.orange.opacity(0.5 * sin(p * .pi)).blendMode(.screen).clipShape(RoundedRectangle(cornerRadius: side / 2 * p + 2)).frame(width: side, height: side).position(x: w * (0.25 + 0.5 * p), y: h / 2) : nil)
                    case (.emphasis, .pulse), (.emphasis, .scale):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .scaleEffect(1 + 0.15 * sin(p * .pi))
                            .position(x: w / 2, y: h / 2)
                    case (.emphasis, .color):
                        box.fill(Color.accentColor.opacity(0.75))
                            .overlay(box.fill(Color.yellow.opacity(sin(p * .pi))))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .position(x: w / 2, y: h / 2)
                    case (.emphasis, .move):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .position(x: w / 2, y: h / 2 - 5 * sin(p * .pi))
                    case (.emphasis, _):
                        box.fill(Color.accentColor.opacity(0.9 - 0.5 * sin(p * .pi)))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .position(x: w / 2, y: h / 2)
                    case (_, .fade):
                        box.fill(Color.accentColor.opacity(0.9 * r))
                            .frame(width: w * 0.6, height: h * 0.7).position(x: w / 2, y: h / 2)
                    case (_, .move):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .position(x: w / 2 - (1 - r) * w, y: h / 2)
                    case (_, .scale):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .scaleEffect(0.5 + 0.5 * r).opacity(0.3 + 0.7 * r)
                            .position(x: w / 2, y: h / 2)
                    case (_, .wipe):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .mask(Rectangle().frame(width: w * 0.6 * r).frame(width: w * 0.6, alignment: .leading))
                            .position(x: w / 2, y: h / 2)
                    case (_, .blur):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .blur(radius: 6 * (1 - r)).opacity(0.2 + 0.8 * r)
                            .position(x: w / 2, y: h / 2)
                    case (_, .burn):
                        box.fill(Color.accentColor.opacity(0.75))
                            .overlay(box.fill(Color.orange.opacity(1 - r)).blendMode(.screen))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .opacity(min(1, r * 2.5))
                            .position(x: w / 2, y: h / 2)
                    case (_, .glitch):
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7)
                            .offset(x: CGFloat(sin(p * 60)) * 4 * (1 - r))
                            .opacity(r < 0.08 ? 0 : 1)
                            .position(x: w / 2, y: h / 2)
                    case (_, .draw):
                        box.trim(from: 0, to: r)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .frame(width: w * 0.6, height: h * 0.7)
                            .position(x: w / 2, y: h / 2)
                    case (_, .type):
                        HStack(spacing: 2) {
                            ForEach(0..<6, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.accentColor.opacity(Double(i) < r * 6 ? 0.9 : 0))
                                    .frame(width: 5, height: 9)
                            }
                        }
                        .position(x: w / 2, y: h / 2)
                    default:
                        box.fill(Color.accentColor.opacity(0.75))
                            .frame(width: w * 0.6, height: h * 0.7).position(x: w / 2, y: h / 2)
                    }
                }
            }
        }
        .clipped()
    }
}

struct AnimationSequenceList: View {
    let model: SlideEditorModel

    @State private var selectionChangedAt = Date.distantPast

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragging: DragState?
    private struct DragState: Equatable {
        var stepID: String
        var location: CGPoint

        var target: String?
    }
    private var dropTarget: String? { dragging?.target }

    private enum Row: Identifiable {
        case header(AnimationSequence.GroupSlot, String)
        case step(AnimationSequence.Entry, AnimationSequence.GroupSlot, Int)

        case add(AnimationSequence.GroupSlot?)
        var id: String {
            switch self {
            case .header(let slot, _): "header-\(slot)"
            case .step(let entry, _, _): entry.step.id
            case .add(let slot): "add-\(String(describing: slot))"
            }
        }
    }

    private var rows: [Row] {
        let groups = model.stepGroups
        var rows: [Row] = []
        if !groups.auto.isEmpty {
            rows.append(.header(.auto, "On fire"))
            rows += groups.auto.enumerated().map { .step($0.element, .auto, $0.offset) }
            rows.append(.add(.auto))
        }
        for (n, entries) in groups.click.enumerated() {
            rows.append(.header(.click(n), "Click \(n + 1)"))
            rows += entries.enumerated().map { .step($0.element, .click(n), $0.offset) }
            rows.append(.add(.click(n)))
        }

        rows.append(.add(nil))
        if !groups.exit.isEmpty {
            rows.append(.header(.exit, "Final"))
            rows += groups.exit.enumerated().map { .step($0.element, .exit, $0.offset) }
            rows.append(.add(.exit))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let warnings = model.stepWarnings
        VStack(spacing: 0) {
            HStack {
                Text("Sequence")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.compositionHasAnimationSteps {
                    Button {
                        if model.animationPreviewPlaying { model.stopAnimationPreview() } else { model.playAnimationPreview() }
                    } label: {
                        Label(model.animationPreviewPlaying ? "Stop" : "Preview", systemImage: model.animationPreviewPlaying ? "stop.fill" : "play.fill")
                    }
                    .controlSize(.small)
                    .help("Play the whole sequence on this canvas (never on glass)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 0) {
                    if !model.compositionHasAnimationSteps {
                        Text("Nothing animates yet. Pick an effect above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    ForEach(rows) { row in
                        Group {
                            switch row {
                            case .header(let slot, let title):
                                headerRow(row, slot: slot, title: title)
                            case .add(let slot):
                                gapRow(row, slot: slot)
                            case .step(let entry, _, _):
                                stepRowView(entry, warning: warnings[entry.step.id])
                            }
                        }
                        .background(GeometryReader { proxy in
                            Color.clear.preference(
                                key: RowFramesKey.self,
                                value: [row.id: proxy.frame(in: .named("animationSequence"))]
                            )
                        })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            .overlay(alignment: .topLeading) {

                if let dragging, let entry = model.stepEntries.first(where: { $0.step.id == dragging.stepID }) {
                    HStack(spacing: 6) {
                        Circle().fill(kindColor(entry.step.kind)).frame(width: 7, height: 7)
                        Text("\(model.stepTargetLabel(entry)) · \(model.animationSentence(entry.step))")
                            .font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .shadow(radius: 4)
                    .position(x: dragging.location.x + 60, y: dragging.location.y)
                    .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
        }
        .onChange(of: model.selectedAnimationStepID) { _, _ in selectionChangedAt = Date() }
    }

    private struct RowFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    private func rowID(at point: CGPoint) -> String? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    private func dragGesture(for stepID: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("animationSequence"))
            .onChanged { value in
                var state = dragging ?? DragState(stepID: stepID, location: value.location, target: nil)
                state.location = value.location
                let hit = rowID(at: value.location)
                state.target = hit == stepID ? nil : hit
                dragging = state
            }
            .onEnded { value in
                defer { dragging = nil }
                guard let target = rowID(at: value.location), target != stepID else { return }
                applyDrop(of: stepID, onto: target)
            }
    }

    private func applyDrop(of stepID: String, onto rowID: String) {
        if rowID.hasPrefix("header-") {
            if let row = rows.first(where: { $0.id == rowID }), case .header(let slot, _) = row {
                dropFirst(stepID, in: slot)
            }
        } else if rowID.hasPrefix("add-") {
            if let row = rows.first(where: { $0.id == rowID }), case .add(let slot) = row {
                dropSeparate(stepID, after: slot)
            }
        } else if let entry = model.stepEntries.first(where: { $0.step.id == rowID }) {
            dropJoining(stepID, after: entry)
        }
    }

    private func headerRow(_ row: Row, slot: AnimationSequence.GroupSlot, title: String) -> some View {
        let targeted = dropTarget == row.id
        return HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.6))
            if targeted {
                Text("— first in this group").font(.system(size: 9)).foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        .padding(.horizontal, 4)
    }

    private func gapIsAlreadyHome(_ slot: AnimationSequence.GroupSlot?, for stepID: String?) -> Bool {
        guard let stepID else { return false }
        let groups = model.stepGroups

        if let n = groups.click.firstIndex(where: { $0.first?.step.id == stepID }) {
            let previous: AnimationSequence.GroupSlot? = n == 0 ? (groups.auto.isEmpty ? nil : .auto) : .click(n - 1)
            return slot == previous || (n == 0 && groups.auto.isEmpty && slot == nil && groups.click.count == 1)
        }
        if groups.exit.first?.step.id == stepID { return slot == .exit || slot == nil }
        return false
    }

    private func gapRow(_ row: Row, slot: AnimationSequence.GroupSlot?) -> some View {
        AddGapRow(
            armed: model.stepAddArmed && model.selectedAnimationStepID == nil && model.stepAddSlot == slot,
            newClick: slot == nil,
            needsObject: model.stepTarget == nil,
            dropTargeted: dropTarget == row.id,
            dropIsHome: dropTarget == row.id && gapIsAlreadyHome(slot, for: dragging?.stepID)
        ) {
            model.armStepAdd(into: slot)
        }
        .padding(.horizontal, 4)
    }

    private func stepRowView(_ entry: AnimationSequence.Entry, warning: String?) -> some View {
        stepRow(entry, warning: warning, dropTargeted: dropTarget == entry.step.id)
            .padding(.horizontal, 4)
            .opacity(dragging?.stepID == entry.step.id ? 0.35 : 1)
            .gesture(dragGesture(for: entry.step.id))
            .contextMenu {
                Button("Preview from Here") { model.previewAnimationStep(entry.step.id) }
                Divider()
                Button("Remove", role: .destructive) { model.removeAnimationStep(entry.step.id) }
            }
    }

    private func flatIndex(after target: String?, moving: String) -> Int {
        let ids = model.stepEntries.map(\.step.id)
        guard let target, let at = ids.firstIndex(of: target) else { return 0 }
        let from = ids.firstIndex(of: moving) ?? Int.max
        return from < at ? at : at + 1
    }

    private func dropJoining(_ id: String, after entry: AnimationSequence.Entry) {
        model.moveAnimationStep(id: id, toFlatIndex: flatIndex(after: entry.step.id, moving: id), trigger: .withPrevious, displaceFollowingToWith: false)
    }

    private func dropFirst(_ id: String, in slot: AnimationSequence.GroupSlot) {
        let groups = model.stepGroups
        let first: AnimationSequence.Entry?
        let trigger: AnimationTrigger
        switch slot {
        case .auto: first = groups.auto.first; trigger = .withPrevious
        case .click(let n): first = groups.click.indices.contains(n) ? groups.click[n].first : nil; trigger = .onClick
        case .newClick: first = nil; trigger = .onClick
        case .exit: first = groups.exit.first; trigger = .onDismiss
        }
        let ids = model.stepEntries.map(\.step.id)
        var at = first.flatMap { ids.firstIndex(of: $0.step.id) } ?? ids.count
        if let from = ids.firstIndex(of: id), from < at { at -= 1 }
        model.moveAnimationStep(id: id, toFlatIndex: at, trigger: trigger, displaceFollowingToWith: trigger != .withPrevious)
    }

    private func dropSeparate(_ id: String, after slot: AnimationSequence.GroupSlot?) {
        let groups = model.stepGroups
        let last: AnimationSequence.Entry?
        var trigger: AnimationTrigger = .onClick
        switch slot {
        case .auto?: last = groups.auto.last
        case .click(let n)?: last = groups.click.indices.contains(n) ? groups.click[n].last : nil
        case .newClick?: last = groups.click.last?.last ?? groups.auto.last
        case .exit?: last = groups.exit.last; trigger = .onDismiss
        case nil: last = groups.click.last?.last ?? groups.auto.last
        }
        model.moveAnimationStep(id: id, toFlatIndex: flatIndex(after: last?.step.id, moving: id), trigger: trigger, displaceFollowingToWith: false)
    }

    private func stepRow(_ entry: AnimationSequence.Entry, warning: String?, dropTargeted: Bool) -> some View {
        let step = entry.step
        return VStack(alignment: .leading, spacing: 1) {
            if dropTargeted {
                Text("plays together with this")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 13)
            }
            HStack(spacing: 6) {
                Circle().fill(kindColor(step.kind)).frame(width: 7, height: 7)
                Text(model.stepTargetLabel(entry))
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                Text("·").foregroundStyle(.tertiary).font(.caption)
                Text(model.animationSentence(step))
                    .font(.caption)
                    .lineLimit(1)
                if let warning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange).help(warning)
                }
                Spacer(minLength: 4)
                Text(model.stepTimingLabel(step))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let warning {
                HStack(spacing: 6) {
                    Text(warning).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    if let fix = model.stepWarningFix(step.id) {
                        Button(fix.label) { fix.apply() }
                            .controlSize(.mini)
                    }
                }
                .padding(.leading, 13)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            dropTargeted ? Color.accentColor.opacity(0.18)
                : model.selectedAnimationStepID == step.id ? Color.accentColor.opacity(0.9) : .clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .foregroundStyle(model.selectedAnimationStepID == step.id && !dropTargeted ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { model.selectAnimationStep(step.id) }
    }

    private func kindColor(_ kind: AnimationKind) -> Color { kind.tint }
}

extension AnimationKind {
    var tint: Color {
        switch self {
        case .in: Color(red: 0.16, green: 0.62, blue: 0.36)
        case .out: Color(red: 0.85, green: 0.47, blue: 0.16)
        case .emphasis: Color(red: 0.55, green: 0.38, blue: 0.85)
        case .morph: Color(red: 0.20, green: 0.55, blue: 0.85)
        }
    }
}

private struct AddGapRow: View {
    let armed: Bool
    let newClick: Bool

    var needsObject = false
    var dropTargeted = false

    var dropIsHome = false
    let arm: () -> Void
    @State private var hovering = false

    var body: some View {
        let show = hovering || armed
        ZStack {

            HStack(spacing: 6) {
                Rectangle()
                    .fill(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(height: dropTargeted ? 2 : 1)
                if dropTargeted {
                    Text(dropIsHome ? "already separate here" : newClick ? "separate, new click" : "separate")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                } else if newClick && !show {
                    Text("new click")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .fixedSize()
                    Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
                }
            }
            if show && !dropTargeted {
                Button(action: arm) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        if armed {

                            Text(needsObject
                                 ? "select an object in the Objects panel"
                                 : (newClick ? "new click: pick an effect above" : "pick an effect above"))
                                .font(.system(size: 9, weight: .medium))
                        } else if newClick {
                            Text("new click").font(.system(size: 9))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(armed ? Color.accentColor.opacity(0.25) : Color(.sRGB, white: 0.35), in: Capsule())
                    .foregroundStyle(armed ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(newClick ? "Add an effect on a new click: pick it above" : "Add an effect to this group: pick it above")
            }
        }

        .frame(height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct AnimationStepStrip: View {
    let model: SlideEditorModel
    let stepID: String
    @State private var more = false

    var body: some View {
        if let (_, step) = model.animationStep(id: stepID),
           let entry = model.stepEntries.first(where: { $0.step.id == stepID }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color(step.kind)).frame(width: 7, height: 7)
                    Text("\(model.stepTargetLabel(entry)) · \(model.animationSentence(step))")
                        .font(.caption).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.previewAnimationStep(stepID) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Preview from this step")
                    Button { model.removeAnimationStep(stepID) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Remove this step")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Plays").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { step.trigger },
                        set: { value in model.updateAnimationStep(stepID) { $0.trigger = value } }
                    )) {
                        Text("Click").tag(AnimationTrigger.onClick)
                        Text("With").tag(AnimationTrigger.withPrevious)
                        Text("After").tag(AnimationTrigger.afterPrevious)
                        Text("Final").tag(AnimationTrigger.onDismiss)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .help("On click · With previous (together) · After previous · On exit")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speed").font(.caption2).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { SlideEditorModel.AnimationSpeed.of(step.durationSeconds) },
                            set: { speed in if let s = speed.seconds { model.updateAnimationStep(stepID) { $0.durationSeconds = s } } }
                        )) {
                            Text("Quick").tag(SlideEditorModel.AnimationSpeed.quick)
                            Text("Normal").tag(SlideEditorModel.AnimationSpeed.normal)
                            Text("Slow").tag(SlideEditorModel.AnimationSpeed.slow)
                            Text("Custom").tag(SlideEditorModel.AnimationSpeed.custom)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        if SlideEditorModel.AnimationSpeed.of(step.durationSeconds) == .custom {
                            ScrubbableNumberField(label: "", value: Binding(
                                get: { step.durationSeconds },
                                set: { v in model.updateAnimationStep(stepID) { $0.durationSeconds = v } }
                            ), range: 0...60, step: 0.1)
                            .frame(width: 56)
                        }
                    }
                }
                if more {
                    AnimationStepEditor(model: model, stepID: stepID)
                        .controlSize(.small)
                        .font(.caption)
                }
                HStack {
                    Button(more ? "Fewer Settings" : "All Settings…") {
                        withAnimation(.easeInOut(duration: 0.15)) { more.toggle() }
                    }
                    .controlSize(.small)
                    Spacer()
                    Button("Done") { model.selectedAnimationStepID = nil }.controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(_ kind: AnimationKind) -> Color {
        switch kind {
        case .in: Color(red: 0.16, green: 0.62, blue: 0.36)
        case .out: Color(red: 0.85, green: 0.47, blue: 0.16)
        case .emphasis: Color(red: 0.55, green: 0.38, blue: 0.85)
        case .morph: Color(red: 0.20, green: 0.55, blue: 0.85)
        }
    }
}

struct AnimationStepEditor: View {
    let model: SlideEditorModel
    let stepID: String

    var body: some View {
        if let (_, step) = model.animationStep(id: stepID) {
            VStack(alignment: .leading, spacing: 6) {
                if step.kind == .morph {

                    if [.blur, .burn, .glitch].contains(step.animation) {
                        number(step.animation == .blur ? "Blend Radius" : "Blend Amount",
                               write(\.amount, default: step.animation == .blur ? 24 : 0.6),
                               range: step.animation == .blur ? 0...200 : 0...1,
                               step: step.animation == .blur ? 1 : 0.05)
                    }
                    if step.toObject == nil {
                        Button("Set End State from Current Look") {
                            if let (objectID, _) = model.animationStep(id: stepID),
                               let baseline = model.morphBaseline(objectID: objectID, before: stepID) {
                                model.updateAnimationStep(stepID) { $0.toObject = baseline }
                            }
                        }
                        .controlSize(.small)
                    }
                }
                if step.kind == .in {
                    Toggle("Where It Enters From", isOn: Binding(
                        get: { step.fromObject != nil },
                        set: { model.setInCustomStart(stepID, enabled: $0) }
                    ))
                    .help("Drag the dashed outline on the canvas to set where it enters from (off-frame, smaller, rotated, another color) instead of the animation's edge or offset. The object's own frame stays where it rests.")
                }

                number("Delay", write(\.delaySeconds, default: 0), range: -60...600, step: 0.1)
                Text(delayHint(step))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Ramp", selection: Binding(
                    get: { step.ramp ?? (step.kind == .in ? .out : step.kind == .out ? .in : .both) }, 
                    set: { ramp in model.updateAnimationStep(stepID) { $0.ramp = ramp } }
                )) {
                    ForEach([AnimationRamp.none, .in, .out, .both], id: \.self) { Text($0.displayName).tag($0) }
                }
                if step.animation != .fade, step.kind != .emphasis, step.kind != .morph {
                    Toggle("With Fade", isOn: write(\.withFade, default: false))
                }
                switch step.kind == .morph ? .fade : step.animation {
                case .move:
                    Picker("From", selection: Binding<String>(
                        get: { step.edge?.rawValue ?? "offset" },
                        set: { value in model.updateAnimationStep(stepID) { $0.edge = AnimationEdge(rawValue: value) } }
                    )) {
                        ForEach([AnimationEdge.left, .right, .top, .bottom], id: \.self) { Text($0.displayName).tag($0.rawValue) }
                        Text("Offset").tag("offset")
                    }
                    if step.edge == nil {
                        number("Offset X", write(\.offsetX, default: 0), range: -4000...4000)
                        number("Offset Y", write(\.offsetY, default: 0), range: -4000...4000)
                    }
                case .scale:
                    number("From Scale", write(\.fromScale, default: 0.95), range: 0...4, step: 0.05)
                case .wipe:
                    Picker("From", selection: write(\.edge, default: .left)) {
                        ForEach([AnimationEdge.left, .right, .top, .bottom], id: \.self) { Text($0.displayName).tag($0) }
                    }
                    number("Soft Edge", write(\.softEdge, default: 0), range: 0...500)
                case .blur:
                    number("Radius", write(\.amount, default: 24), range: 0...200)
                case .burn, .glitch:
                    number("Amount", write(\.amount, default: 0.6), range: 0...1, step: 0.05)
                case .pulse:
                    number("Peak Scale", write(\.amount, default: 1.1), range: 0.5...3, step: 0.05)
                case .type:
                    Toggle("Cursor", isOn: write(\.cursor, default: true))
                    Toggle("Type from the End", isOn: write(\.reverse, default: false))
                case .draw:
                    Picker("Start At", selection: Binding<String>(
                        get: {
                            let v = step.drawStart ?? 0
                            return [0: "tl", 0.25: "tr", 0.5: "br", 0.75: "bl"].first { abs($0.key - v) < 0.001 }?.value ?? "custom"
                        },
                        set: { value in
                            let map = ["tl": 0.0, "tr": 0.25, "br": 0.5, "bl": 0.75]
                            if let v = map[value] { model.updateAnimationStep(stepID) { $0.drawStart = v == 0 ? nil : v } }
                        }
                    )) {
                        Text("Top Left").tag("tl")
                        Text("Top Right").tag("tr")
                        Text("Bottom Right").tag("br")
                        Text("Bottom Left").tag("bl")
                        Text("Custom").tag("custom")
                    }
                    number("Start (0–1)", write(\.drawStart, default: 0), range: 0...1, step: 0.01)
                    Toggle("Counter-clockwise", isOn: write(\.reverse, default: false))
                    Text("Traces the outline around the shape. The fill arrives as it closes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .color:
                    HexColorRow(label: "Color", hex: write(\.colorHex, default: "#FFD54FFF"))
                case .fade:
                    EmptyView()
                }
                if step.ranges?.isEmpty == false {
                    Toggle("Blank Underline While Hidden", isOn: write(\.placeholderUnderline, default: false))
                        .help("Fill-in-the-blank: the hidden word keeps a same-width underline until it arrives")
                }

                if step.ranges?.isEmpty ?? true, step.kind != .emphasis {
                    Divider()
                        .padding(.vertical, 2)
                    HStack {
                        Image(systemName: "video.badge.waveform")
                            .font(.system(size: 10))
                            .foregroundStyle(step.videoPush == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                        Text("Camera Push")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { step.videoPush != nil },
                            set: { on in model.updateAnimationStep(stepID) { $0.videoPush = on ? VideoPush() : nil } }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                    .help("The program video moves into the space this object leaves free, in step with this animation. Put it on the Out too so the picture returns.")
                    if step.videoPush == nil {
                        Text("Slides the program video into the space this object leaves free. Put it on the Out too so the picture returns.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let push = step.videoPush {
                        Picker("Video", selection: pushWrite(\.mode, default: .fill)) {
                            Text("Push (crop in)").tag(VideoPushMode.fill)
                            Text("Push (letterbox)").tag(VideoPushMode.fit)
                            Text("Blur Background").tag(VideoPushMode.blurBackground)
                        }
                        if (push.mode ?? .fill) != .blurBackground {
                            Picker("Video Sits", selection: pushWrite(\.alignment, default: .center)) {
                                Text("Center").tag(VideoPushAlignment.center)
                                Text("Left").tag(VideoPushAlignment.left)
                                Text("Right").tag(VideoPushAlignment.right)
                                Text("Top").tag(VideoPushAlignment.top)
                                Text("Bottom").tag(VideoPushAlignment.bottom)
                            }
                            Toggle("Blurred Video Backdrop", isOn: pushWrite(\.backdrop, default: false))
                                .help("The space behind everything fills with a blurred, zoomed copy of the program video instead of black")
                            number("Margin", pushNumber(\.margin, default: 0), range: 0...400)
                        }
                        number("Extra Zoom", pushNumber(\.zoom, default: 1), range: 1...2, step: 0.05)
                        if (push.mode ?? .fill) == .blurBackground || push.backdrop == true {
                            number("Blur", pushNumber(\.blurRadius, default: 36), range: 0...200)
                        }
                        Text("The preview moves a stand-in video. On glass it moves your live input.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func delayHint(_ step: AnimationStep) -> String {
        let auto = model.stepGroups.auto.contains { $0.step.id == stepID }
        switch step.trigger {
        case .onClick: return "Seconds after the Advance."
        case .onDismiss: return "Seconds after the final click or clear."
        case .withPrevious:
            return auto ? "Nothing before it, so it starts this long after the slide fires. No click needed."
                        : "Seconds after the previous step starts. Negative starts sooner."
        case .afterPrevious:
            return auto ? "Nothing before it, so it starts this long after the slide fires. No click needed."
                        : "Seconds after the previous step ends. Negative overlaps it."
        }
    }

    private func write<T: Equatable>(_ keyPath: WritableKeyPath<AnimationStep, T>) -> Binding<T> {
        Binding(
            get: { model.animationStep(id: stepID)?.step[keyPath: keyPath] ?? AnimationStep.placeholder[keyPath: keyPath] },
            set: { value in model.updateAnimationStep(stepID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func pushWrite<T: Equatable>(_ keyPath: WritableKeyPath<VideoPush, T?>, default fallback: T) -> Binding<T> {
        Binding(
            get: { model.animationStep(id: stepID)?.step.videoPush?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateAnimationStep(stepID) { $0.videoPush?[keyPath: keyPath] = value } }
        )
    }

    private func pushNumber(_ keyPath: WritableKeyPath<VideoPush, Double?>, default fallback: Double) -> Binding<Double> {
        Binding(
            get: { model.animationStep(id: stepID)?.step.videoPush?[keyPath: keyPath] ?? fallback },
            set: { value in model.updateAnimationStep(stepID) { $0.videoPush?[keyPath: keyPath] = value } }
        )
    }

    private func write<T: Equatable>(_ keyPath: WritableKeyPath<AnimationStep, T?>, default fallback: T) -> Binding<T> {
        Binding(
            get: { model.animationStep(id: stepID)?.step[keyPath: keyPath] ?? fallback },
            set: { value in model.updateAnimationStep(stepID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func number(_ label: String, _ binding: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        ScrubbableNumberField(label: label, value: binding, range: range, step: step)
    }
}

extension AnimationStep {

    static let placeholder = AnimationStep(id: "", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)
}

struct AnimationPreviewStrip: View {
    let model: SlideEditorModel

    var body: some View {
        let duration = max(model.animationPreviewDuration, 0.01)
        HStack(spacing: 10) {
            Button {
                if model.animationPreviewPlaying { model.stopAnimationPreview() } else { model.playAnimationPreview() }
            } label: {
                Image(systemName: model.animationPreviewPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(model.animationPreviewPlaying ? "Stop the preview" : "Play the animation on this canvas (never on glass)")
            Slider(
                value: Binding(
                    get: { model.animationPreviewShownTime },
                    set: { model.setAnimationPreviewTime($0) }
                ),
                in: 0...duration
            )
            .controlSize(.small)
            Text(String(format: "%.1f / %.1fs", model.animationPreviewShownTime, duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            if model.animationPreviewTime != nil || model.animationPreviewPlaying {
                Button("Done") { model.stopAnimationPreview() }
                    .controlSize(.small)
                    .help("Leave the preview. The canvas shows everything again.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
