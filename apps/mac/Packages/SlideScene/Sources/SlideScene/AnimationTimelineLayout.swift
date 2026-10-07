import Foundation
import PresenterCore
import RenderEngine

public enum AnimationTimelineLayout {

    public struct Column: Equatable, Sendable {
        public var group: SceneAnimationGroup
        public var start: Double
        public var duration: Double
        public var displayDuration: Double

        public init(group: SceneAnimationGroup, start: Double, duration: Double, displayDuration: Double) {
            self.group = group
            self.start = start
            self.duration = duration
            self.displayDuration = displayDuration
        }
    }

    public struct Block: Equatable, Sendable {
        public var stepID: String
        public var objectID: String
        public var kind: AnimationKind
        public var group: SceneAnimationGroup
        public var startOffset: Double
        public var duration: Double

        public var rampIn: Bool

        public var rampOut: Bool

        public var linked: Bool
        public var ranged: Bool

        public init(
            stepID: String, objectID: String, kind: AnimationKind, group: SceneAnimationGroup,
            startOffset: Double, duration: Double, rampIn: Bool, rampOut: Bool,
            linked: Bool, ranged: Bool
        ) {
            self.stepID = stepID
            self.objectID = objectID
            self.kind = kind
            self.group = group
            self.startOffset = startOffset
            self.duration = duration
            self.rampIn = rampIn
            self.rampOut = rampOut
            self.linked = linked
            self.ranged = ranged
        }
    }

    public struct Row: Equatable, Sendable {
        public var objectID: String
        public var blocks: [Block]
        public var presenceStart: Double?
        public var presenceEnd: Double?

        public init(objectID: String, blocks: [Block], presenceStart: Double? = nil, presenceEnd: Double? = nil) {
            self.objectID = objectID
            self.blocks = blocks
            self.presenceStart = presenceStart
            self.presenceEnd = presenceEnd
        }
    }

    public struct Timeline: Equatable, Sendable {
        public var columns: [Column]

        public var rows: [Row]

        public var clickTimes: [Double]
        public var dismissAt: Double
        public var duration: Double

        public init(columns: [Column], rows: [Row], clickTimes: [Double], dismissAt: Double, duration: Double) {
            self.columns = columns
            self.rows = rows
            self.clickTimes = clickTimes
            self.dismissAt = dismissAt
            self.duration = duration
        }
    }

    public static let minimumColumnSeconds = 0.6

    public static func timeline(objects: [SlideObject], order: [String]?) -> Timeline {
        let groups = AnimationSequence.groups(objects: objects, order: order)
        let preview = AnimationSequence.previewTimeline(objects: objects, order: order)
        let allSteps = AnimationSequence.sceneSteps(objects: objects, order: order)
            .values.flatMap { $0 }

        var columns: [Column] = []
        func column(_ group: SceneAnimationGroup, start: Double) {
            let duration = AnimationTimeline.groupDuration(group, in: allSteps)
            columns.append(Column(
                group: group, start: start, duration: duration,

                displayDuration: duration > 0 ? duration : minimumColumnSeconds
            ))
        }
        column(.auto, start: 0)
        for (index, time) in preview.clicks.enumerated() {
            column(.click(index), start: time)
        }
        column(.exit, start: preview.dismissAt)

        let entries = AnimationSequence.orderedEntries(objects: objects, order: order)
        let scheduled = AnimationSequence.sceneSteps(objects: objects, order: order)
        var blocksByObject: [String: [Block]] = [:]
        for entry in entries {
            guard let scene = scheduled[entry.objectID]?.first(where: { $0.id == entry.step.id })
            else { continue }
            let ramp = scene.ramp
            blocksByObject[entry.objectID, default: []].append(Block(
                stepID: entry.step.id,
                objectID: entry.objectID,
                kind: entry.step.kind,
                group: scene.group,
                startOffset: scene.startOffset,
                duration: scene.duration,
                rampIn: ramp == .easeIn || ramp == .easeInOut,
                rampOut: ramp == .easeOut || ramp == .easeInOut,
                linked: entry.step.trigger == .afterPrevious,
                ranged: !(entry.step.ranges?.isEmpty ?? true)
            ))
        }

        var rows: [Row] = []
        for object in objects where object.hidden != true {
            let blocks = blocksByObject[object.id] ?? []
            var presenceStart: Double?
            var presenceEnd: Double?

            let whole = blocks.filter { !$0.ranged }
            if let firstIn = whole.first(where: { $0.kind == .in }) {
                presenceStart = start(of: firstIn, preview: preview)
            }
            if let lastOut = whole.last(where: { $0.kind == .out }) {
                presenceEnd = start(of: lastOut, preview: preview).map { $0 + lastOut.duration }
            }
            rows.append(Row(
                objectID: object.id, blocks: blocks,
                presenceStart: presenceStart, presenceEnd: presenceEnd
            ))
        }

        return Timeline(
            columns: columns, rows: rows,
            clickTimes: preview.clicks,
            dismissAt: preview.dismissAt,
            duration: preview.duration
        )
    }

    static func start(
        of block: Block, preview: (clicks: [Double], dismissAt: Double, duration: Double)
    ) -> Double? {
        switch block.group {
        case .auto: return block.startOffset
        case .click(let n):
            return preview.clicks.indices.contains(n) ? preview.clicks[n] + block.startOffset : nil
        case .exit: return preview.dismissAt + block.startOffset
        }
    }

    public static func morphMoves(_ step: AnimationStep, object: SlideObject?) -> Bool {
        guard step.kind == .morph, let to = step.toObject else { return false }
        guard let object else { return false }
        func d(_ a: Double?, _ b: Double?) -> Bool { (a ?? 0) != (b ?? 0) }
        return d(to.x, object.x) || d(to.y, object.y)
            || d(to.width, object.width) || d(to.height, object.height)
            || d(to.rotationDegrees, object.rotationDegrees)
            || d(to.tilt, object.tilt) || d(to.swing, object.swing)
            || d(to.skewX, object.skewX) || d(to.skewY, object.skewY)
            || d(to.keystoneTop, object.keystoneTop) || d(to.keystoneBottom, object.keystoneBottom)
    }
}
