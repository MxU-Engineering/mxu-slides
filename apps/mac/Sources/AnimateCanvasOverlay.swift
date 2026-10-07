import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct AnimateCanvasOverlay: View {
    let model: SlideEditorModel

    @State private var galleryObjectID: GalleryAnchor?

    private struct GalleryAnchor: Identifiable, Equatable {
        var id: String
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = model.canvasSize.width > 0 ? proxy.size.width / model.canvasSize.width : 1
            ZStack(alignment: .topLeading) {
                ForEach(badges, id: \.objectID) { badge in
                    badgeView(badge, scale: scale)
                }
                if let chipID = chipObjectID, let frame = viewFrame(chipID, scale: scale) {
                    chip(for: chipID, frame: frame)
                }
            }
        }
    }

    private struct Badge {
        var objectID: String
        var click: Int
        var frame: CGRect
    }

    private var badges: [Badge] {
        model.timelineLayout.rows.compactMap { row in
            guard let first = row.blocks.first(where: {
                if case .click = $0.group { return true }
                return false
            }), case .click(let n) = first.group,
                let object = model.object(id: row.objectID)
            else { return nil }
            return Badge(objectID: row.objectID, click: n, frame: model.displayFrame(for: object))
        }
    }

    private func badgeView(_ badge: Badge, scale: CGFloat) -> some View {
        Button {

            model.timelineFocusColumn = .click(badge.click)
            model.setSelection([badge.objectID])
        } label: {
            Text("\(badge.click + 1)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .position(
            x: badge.frame.minX * scale - 12,
            y: badge.frame.minY * scale + 9
        )
        .help("Arrives on Click \(badge.click + 1) — click to focus that column")
    }

    private var chipObjectID: String? {
        if let hovered = model.canvasHoveredObjectID { return hovered }
        if model.selectedObjectIDs.count == 1 { return model.selectedObjectIDs.first }
        return nil
    }

    private func viewFrame(_ objectID: String, scale: CGFloat) -> CGRect? {
        guard let object = model.object(id: objectID) else { return nil }
        let frame = model.displayFrame(for: object)
        return CGRect(
            x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale
        )
    }

    private func chip(for objectID: String, frame: CGRect) -> some View {
        Button {
            model.setSelection([objectID])
            galleryObjectID = GalleryAnchor(id: objectID)
        } label: {
            Label("Animate", systemImage: "sparkles")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .position(x: frame.maxX - 34, y: max(frame.minY - 12, 10))
        .popover(item: Binding(
            get: { galleryObjectID },
            set: { galleryObjectID = $0 }
        ), arrowEdge: .trailing) { anchor in
            AnimateGalleryPopover(model: model, objectID: anchor.id)
        }
        .help("Add an animation to this object")
    }
}

struct AnimateGalleryPopover: View {
    let model: SlideEditorModel
    let objectID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                AnimationGallery(model: model)
            }
            .frame(width: 340, height: 240)
            if let (stepObjectID, step) = selectedStep, stepObjectID == objectID {
                Divider()
                stepRows(step)
            }
        }
        .padding(12)
        .onAppear {
            model.setSelection([objectID])
            model.selectQuickAddResult = true
        }
        .onDisappear {
            model.selectQuickAddResult = false
        }
    }

    private var selectedStep: (String, AnimationStep)? {
        guard let id = model.selectedAnimationStepID else { return nil }
        return model.animationStep(id: id)
    }

    @ViewBuilder
    private func stepRows(_ step: AnimationStep) -> some View {
        let timeline = model.timelineLayout
        if step.kind == .in {
            HStack(spacing: 6) {
                Text("Starts from")
                    .foregroundStyle(.secondary)
                Menu(startsFromLabel(step)) {
                    ForEach([AnimationEdge.left, .right, .top, .bottom], id: \.self) { edge in
                        Button("Off \(edge.displayName.lowercased())") {
                            model.updateAnimationStep(step.id) {
                                if $0.animation != .move && $0.animation != .wipe {
                                    $0.animation = .move
                                }
                                $0.edge = edge
                                $0.fromObject = nil
                            }
                        }
                    }
                }
                .fixedSize()
                Button("Drag to Place…") {

                    model.setInCustomStart(step.id, enabled: true)
                    dismiss()
                }
                .controlSize(.small)
                .help("Drag the dashed outline on the canvas to set where it enters from — off-frame is just an outline parked outside the slide edge")
            }
            .font(.caption)
        }
        HStack(spacing: 6) {
            Text("Lands on")
                .foregroundStyle(.secondary)
            Menu(landsOnLabel(step, in: timeline)) {
                ForEach(Array(timeline.columns.enumerated()), id: \.offset) { _, column in
                    Button(columnName(column.group)) {
                        model.moveTimelineStep(
                            step.id, into: slot(for: column.group), atOffset: step.delaySeconds ?? 0
                        )
                    }
                }
                Button("New Click") {
                    model.moveTimelineStep(step.id, into: .click(timeline.columns.count), atOffset: 0)
                }
            }
            .fixedSize()
            Text("speed")
                .foregroundStyle(.secondary)
            Menu(String(format: "%.1fs", step.durationSeconds)) {
                ForEach([SlideEditorModel.AnimationSpeed.quick, .normal, .slow], id: \.self) { speed in
                    if let seconds = speed.seconds {
                        Button(speed.rawValue.capitalized + String(format: " · %.1fs", seconds)) {
                            model.resizeTimelineStep(step.id, duration: seconds)
                        }
                    }
                }
            }
            .fixedSize()
        }
        .font(.caption)
    }

    private func startsFromLabel(_ step: AnimationStep) -> String {
        if step.fromObject != nil { return "Where you placed it" }
        if let edge = step.edge { return "Off \(edge.displayName.lowercased())" }
        return "In place"
    }

    private func landsOnLabel(_ step: AnimationStep, in timeline: AnimationTimelineLayout.Timeline) -> String {
        guard let block = timeline.rows
            .flatMap(\.blocks)
            .first(where: { $0.stepID == step.id })
        else { return "—" }
        return columnName(block.group)
    }

    private func columnName(_ group: SceneAnimationGroup) -> String {
        switch group {
        case .auto: "With Slide"
        case .click(let n): "Click \(n + 1)"
        case .exit: "Final"
        }
    }

    private func slot(for group: SceneAnimationGroup) -> AnimationSequence.GroupSlot {
        switch group {
        case .auto: .auto
        case .click(let n): .click(n)
        case .exit: .exit
        }
    }
}
