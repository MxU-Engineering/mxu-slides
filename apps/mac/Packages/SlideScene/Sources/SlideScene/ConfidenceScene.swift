import CoreGraphics
import Foundation
import PresenterCore
import RenderEngine

public struct CueAlert: Sendable, Equatable {
    public var id: String
    public var message: String
    public var behavior: AlertBehavior
    public var target: AlertTarget

    public var layer: LayerKind?

    public var theme: Theme?

    public init(
        id: String = UUID().uuidString,
        message: String,
        behavior: AlertBehavior,
        target: AlertTarget = .confidence,
        theme: Theme? = nil,
        layer: LayerKind? = nil
    ) {
        self.id = id
        self.message = message
        self.behavior = behavior
        self.target = target
        self.theme = theme
        self.layer = layer
    }

    public var showsOnConfidence: Bool { target != .audience }

    public var showsOnAudience: Bool { target != .confidence }
}

public struct TimerWarning: Codable, Sendable, Equatable, Identifiable {
    public var remainingSeconds: TimeInterval

    public var colorHex: String

    public var id: String { "\(remainingSeconds)-\(colorHex)" }

    public init(remainingSeconds: TimeInterval, colorHex: String) {
        self.remainingSeconds = remainingSeconds
        self.colorHex = colorHex
    }

    public static let amberHex = "#FFB826FF"
    public static let redHex = "#FF4739FF"
    public static let defaults = [
        TimerWarning(remainingSeconds: 30, colorHex: amberHex),
        TimerWarning(remainingSeconds: 0, colorHex: redHex),
    ]
}

public struct TimerSnapshot: Sendable, Equatable, Identifiable {
    public enum Mode: Sendable, Equatable {

        case countdown

        case countdownToTime

        case countUp
    }

    public enum Urgency: Sendable, Equatable {
        case normal
        case warning
        case overrun
    }

    public func remaining(at date: Date) -> TimeInterval? {
        switch mode {
        case .countdown, .countdownToTime:
            return value(at: date)
        case .countUp:
            guard durationSeconds > 0 else { return nil }
            return durationSeconds - elapsed(at: date)
        }
    }

    public var isIdle: Bool {
        !isRunning && banked == 0 && durationSeconds == 0 && (mode != .countdownToTime || targetTime == nil)
    }

    public func activeWarning(at date: Date) -> TimerWarning? {
        guard !isIdle, let remaining = remaining(at: date) else { return nil }
        return warnings
            .filter { $0.remainingSeconds >= remaining }
            .min { $0.remainingSeconds < $1.remainingSeconds }
    }

    public func urgency(at date: Date) -> Urgency {
        guard let warning = activeWarning(at: date) else { return .normal }
        return warning.remainingSeconds <= 0 ? .overrun : .warning
    }

    public static let warningThreshold: TimeInterval = 30

    public var id: String
    public var name: String
    public var mode: Mode
    public var isRunning: Bool

    public var runningSince: Date?

    public var banked: TimeInterval

    public var durationSeconds: TimeInterval

    public var targetTime: Date?

    public var armedAt: Date?

    public var warnings: [TimerWarning]

    public init(
        id: String = UUID().uuidString,
        name: String,
        mode: Mode,
        isRunning: Bool = false,
        runningSince: Date? = nil,
        banked: TimeInterval = 0,
        durationSeconds: TimeInterval = 0,
        targetTime: Date? = nil,
        armedAt: Date? = nil,
        warnings: [TimerWarning] = TimerWarning.defaults
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.isRunning = isRunning
        self.runningSince = runningSince
        self.banked = banked
        self.durationSeconds = durationSeconds
        self.targetTime = targetTime
        self.armedAt = armedAt
        self.warnings = warnings
    }

    public var isLive: Bool {
        isRunning || mode == .countdownToTime
    }

    public func elapsed(at date: Date) -> TimeInterval {
        banked + (isRunning ? max(0, date.timeIntervalSince(runningSince ?? date)) : 0)
    }

    public func value(at date: Date) -> TimeInterval {
        switch mode {
        case .countUp: elapsed(at: date)
        case .countdown: durationSeconds - elapsed(at: date)
        case .countdownToTime: (targetTime ?? date).timeIntervalSince(date)
        }
    }

    public func displayString(at date: Date) -> String {
        Self.timecode(displayValue(at: date))
    }

    public func displayValue(at date: Date) -> TimeInterval {
        value(at: date).rounded(.towardZero)
    }

    public func displayString(at date: Date, format: TimerTextFormat?, pattern: String? = nil) -> String {
        Self.text(value(at: date), format: format, pattern: pattern)
    }

    public static func text(_ seconds: TimeInterval, format: TimerTextFormat?, pattern: String?) -> String {
        if let pattern, !pattern.isEmpty {
            return TimerPattern.text(seconds, pattern: pattern)
        } else {
            return text(seconds, format: format ?? .digits)
        }
    }

    public static func text(_ seconds: TimeInterval, format: TimerTextFormat) -> String {
        switch format {
        case .digits: return timecode(seconds)
        case .abbreviated: return units(seconds, labels: ("d", "h", "m", "s"), spaced: false)
        case .words: return units(seconds, labels: ("day", "hour", "minute", "second"), spaced: true)
        }
    }

    private static func units(
        _ seconds: TimeInterval, labels: (String, String, String, String), spaced: Bool
    ) -> String {
        let total = Int(seconds.rounded(.towardZero))
        let magnitude = abs(total)
        let parts: [(Int, String)] = [
            (magnitude / 86400, labels.0), ((magnitude / 3600) % 24, labels.1),
            ((magnitude / 60) % 60, labels.2), (magnitude % 60, labels.3),
        ]
        var started = false
        var words: [String] = []
        for (index, (count, label)) in parts.enumerated() {
            let last = index == parts.count - 1
            guard started || count > 0 || last else { continue }
            started = true
            let unit = spaced ? " \(label)\(count == 1 ? "" : "s")" : label
            words.append("\(count)\(unit)")
        }
        let sign = total < 0 ? "-" : ""
        return sign + words.joined(separator: " ")
    }

    public func progress(at date: Date) -> Double? {
        switch mode {
        case .countUp, .countdown:
            guard durationSeconds > 0 else { return nil }
            return min(1, max(0, elapsed(at: date) / durationSeconds))
        case .countdownToTime:
            guard let armedAt, let targetTime else { return nil }
            let span = targetTime.timeIntervalSince(armedAt)
            guard span > 0 else { return 1 }
            return min(1, max(0, date.timeIntervalSince(armedAt) / span))
        }
    }

    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.towardZero))
        let magnitude = abs(total)
        let sign = seconds < 0 && magnitude > 0 ? "-" : ""
        if magnitude >= 3600 {
            return String(
                format: "%@%d:%02d:%02d",
                sign, magnitude / 3600, (magnitude / 60) % 60, magnitude % 60
            )
        }
        return String(format: "%@%d:%02d", sign, magnitude / 60, magnitude % 60)
    }
}

public struct VideoCountdown: Sendable, Equatable {
    public var name: String
    public var duration: Double

    public var position: Double
    public var anchoredAt: Date
    public var isPlaying: Bool

    public init(
        name: String, duration: Double, position: Double,
        anchoredAt: Date, isPlaying: Bool
    ) {
        self.name = name
        self.duration = duration
        self.position = position
        self.anchoredAt = anchoredAt
        self.isPlaying = isPlaying
    }

    public func remaining(at date: Date) -> Double {
        let advance = isPlaying ? max(0, date.timeIntervalSince(anchoredAt)) : 0
        return max(0, duration - (position + advance))
    }
}

public struct ConfidenceInfo: Sendable, Equatable {

    public struct SlideText: Sendable, Equatable {
        public var body: String

        public var chords: [ChordPlacement]

        public var musicKey: String?
        public var displayKey: String?

        public var stepIndex: Int?

        public var stepCount: Int?

        public var objectTexts: [ObjectText]?

        public struct ObjectText: Sendable, Equatable {
            public var name: String
            public var text: String

            public init(name: String, text: String) {
                self.name = name
                self.text = text
            }
        }

        public init(
            body: String,
            chords: [ChordPlacement] = [],
            musicKey: String? = nil,
            displayKey: String? = nil,
            stepIndex: Int? = nil,
            stepCount: Int? = nil,
            objectTexts: [ObjectText]? = nil
        ) {
            self.body = body
            self.chords = chords
            self.musicKey = musicKey
            self.displayKey = displayKey
            self.stepIndex = stepIndex
            self.stepCount = stepCount
            self.objectTexts = objectTexts
        }
    }

    public struct SlidePosition: Sendable, Equatable {
        public var index: Int
        public var total: Int

        public init(index: Int, total: Int) {
            self.index = index
            self.total = total
        }
    }

    public var current: SlideText?
    public var next: SlideText?

    public var nextStep: SlideText?

    public var last: SlideText?
    public var alert: CueAlert?

    public var alertVisible: Bool
    public var timers: [TimerSnapshot]

    public var videoCountdown: VideoCountdown?

    public var videoCountdowns: [String: VideoCountdown]

    public func videoCountdown(forLayer layer: String?) -> VideoCountdown? {
        guard let layer, !layer.isEmpty else { return videoCountdown }
        return videoCountdowns[layer]
    }

    public var slidePosition: SlidePosition?

    public var currentItemName: String?

    public var currentGroupName: String?
    public var nextItemName: String?

    public var currentPresentationName: String?

    public var nextServiceTitle: String?

    public var audioCountdown: VideoCountdown?

    public var activeLiveInputIds: [String]

    public var connectedLiveInputIds: [String]

    public var captureActive: Bool

    public init(
        current: SlideText? = nil,
        next: SlideText? = nil,
        last: SlideText? = nil,
        alert: CueAlert? = nil,
        alertVisible: Bool = true,
        timers: [TimerSnapshot] = [],
        videoCountdown: VideoCountdown? = nil,
        videoCountdowns: [String: VideoCountdown] = [:],
        slidePosition: SlidePosition? = nil,
        currentItemName: String? = nil,
        currentGroupName: String? = nil,
        nextItemName: String? = nil,
        currentPresentationName: String? = nil,
        nextServiceTitle: String? = nil,
        audioCountdown: VideoCountdown? = nil,
        activeLiveInputIds: [String] = [],
        connectedLiveInputIds: [String] = [],
        captureActive: Bool = false
    ) {
        self.current = current
        self.next = next
        self.last = last
        self.alert = alert
        self.alertVisible = alertVisible
        self.timers = timers
        self.videoCountdown = videoCountdown
        self.videoCountdowns = videoCountdowns
        self.slidePosition = slidePosition
        self.currentItemName = currentItemName
        self.currentGroupName = currentGroupName
        self.nextItemName = nextItemName
        self.currentPresentationName = currentPresentationName
        self.nextServiceTitle = nextServiceTitle
        self.audioCountdown = audioCountdown
        self.activeLiveInputIds = activeLiveInputIds
        self.connectedLiveInputIds = connectedLiveInputIds
        self.captureActive = captureActive
    }
}

public enum ConfidenceSceneBuilder {

    public static let amber = SceneColor(red: 1.0, green: 0.72, blue: 0.15)

    public static let builtInLayout: ConfidenceLayout = {
        var layout = ConfidenceLayout.defaultTemplate(name: "Built-in Layout")
        layout.id = "built-in"
        return layout
    }()

    public static func scene(info: ConfidenceInfo, at date: Date) -> RenderScene {
        scene(layout: builtInLayout, info: info, at: date)
    }

    public static func scene(
        layout: ConfidenceLayout,
        info: ConfidenceInfo,
        at date: Date
    ) -> RenderScene {
        let canvasSize = CGSize(
            width: layout.canvasWidth.map(Double.init) ?? SlideSceneBuilder.canvasSize.width,
            height: layout.canvasHeight.map(Double.init) ?? SlideSceneBuilder.canvasSize.height
        )
        var scene = RenderScene(canvasSize: canvasSize)
        let resolved = LinkedText.resolvedObjects(layout.objects, info: info, at: date)

        let objects = resolved.filter {
            VisibilityRules.isShown($0, among: resolved, info: info, at: date)
        }
        let wiring = SlideSceneBuilder.maskWiring(for: objects)
        for object in objects {

            for item in SlideSceneBuilder.renderItems(
                for: object, theme: nil, in: canvasSize,
                baseID: "confidence-\(layout.id)-\(object.id)",
                maskedBy: wiring.maskedBy[object.id],
                matteGroup: wiring.mattes.contains(object.id) ? object.id : nil
            ) {
                scene.addItem(item, to: .slide)
            }
        }

        if let alert = info.alert, alert.showsOnConfidence, info.alertVisible,
           !layout.hasStageMessageObject {
            for item in AlertSceneBuilder.bannerItems(
                for: alert, canvasSize: canvasSize, info: info, at: date
            ) {
                scene.addItem(item, to: .alerts)
            }
        }
        return scene
    }

    static func primaryTimer(_ timers: [TimerSnapshot]) -> TimerSnapshot? {
        timers.first(where: \.isLive) ?? timers.first
    }

    public static func lyricText(for slide: Slide) -> String {
        lyricObjects(of: slide)
            .map(\.text)
            .joined(separator: "\n")
    }

    static func lyricObjects(of slide: Slide) -> [SlideObject] {
        slide.objects.filter {
            $0.objectKind == .text && (!$0.text.isEmpty || $0.chords?.isEmpty == false)
        }
    }

    public static func hasLyricContent(_ slide: Slide) -> Bool {
        !lyricObjects(of: slide).isEmpty
    }

    public static func lyricChords(for slide: Slide) -> [ChordPlacement] {
        var chords: [ChordPlacement] = []
        var lineOffset = 0
        for object in lyricObjects(of: slide) {
            for chord in object.chords ?? [] {
                chords.append(ChordPlacement(
                    line: chord.line + lineOffset, column: chord.column, symbol: chord.symbol
                ))
            }
            lineOffset += object.text.components(separatedBy: "\n").count
        }
        return chords
    }

    public static func slideText(for slide: Slide, in presentation: Presentation?) -> ConfidenceInfo.SlideText {

        let objectTexts = slide.objects.compactMap { object -> ConfidenceInfo.SlideText.ObjectText? in
            guard !object.name.isEmpty, !object.text.isEmpty else { return nil }
            return .init(name: object.name, text: object.text)
        }
        return ConfidenceInfo.SlideText(
            body: lyricText(for: slide),
            chords: lyricChords(for: slide),
            musicKey: presentation?.musicKey,
            displayKey: presentation?.displayKey,
            objectTexts: objectTexts.isEmpty ? nil : objectTexts
        )
    }

    public static func nextSlide(in upcoming: [Slide], skippingBlanks: Bool) -> Slide? {
        skippingBlanks
            ? upcoming.first(where: hasLyricContent)
            : upcoming.first
    }

    static func clockString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d", twelve, parts.minute ?? 0)
    }
}

public extension ConfidenceLayout {

    var hasStageMessageObject: Bool {
        objects.contains { $0.textLink?.source == .stageMessage }
    }
}

public enum AlertSceneBuilder {

    public static func alertsThemeSlide(in theme: Theme?) -> Slide? {
        theme?.slides?.first { $0.name.caseInsensitiveCompare("Alerts") == .orderedSame }
    }

    public static func audienceItems(
        for alert: CueAlert, canvasSize: CGSize,
        info: ConfidenceInfo? = nil, at date: Date = Date()
    ) -> [RenderItem] {
        guard let theme = alert.theme,
              var template = alertsThemeSlide(in: theme)
        else { return bannerItems(for: alert, canvasSize: canvasSize, info: info, at: date) }

        if let info {
            template.objects = LinkedText.resolvedObjects(template.objects, info: info, at: date)
        }

        let messageText = info.map {
            LinkedText.resolvedAlertMessage(alert.message, info: $0, at: date)
        } ?? alert.message
        let message = SlideObject(
            id: "alert-message", objectKind: .text, name: "Message", text: messageText
        )
        let objects = [message]
        let placeholders = SlideSceneBuilder.placeholderAssignments(for: objects, in: template)
        let stack = SlideSceneBuilder.composedStack(for: objects, in: template)

        let wiring = SlideSceneBuilder.maskWiring(for: stack.map(\.object))

        let steps = AnimationSequence.sceneSteps(objects: stack.map(\.object), order: template.animationOrder)
        return stack.flatMap { entry in
            SlideSceneBuilder.renderItems(
                for: entry.object, theme: theme,
                placeholder: entry.fromTheme ? nil : placeholders[entry.object.id],
                baseID: "alert-\(alert.id)-\(entry.id)",
                maskedBy: wiring.maskedBy[entry.object.id],
                matteGroup: wiring.mattes.contains(entry.object.id) ? entry.object.id : nil,
                animationSteps: steps[entry.object.id] ?? []
            )
        }
    }

    public static func bannerItems(
        for alert: CueAlert, canvasSize: CGSize,
        info: ConfidenceInfo? = nil, at date: Date = Date()
    ) -> [RenderItem] {
        let message = info.map {
            LinkedText.resolvedAlertMessage(alert.message, info: $0, at: date)
        } ?? alert.message
        let height = canvasSize.height * (150.0 / 1080.0)
        let band = CGRect(
            x: 0, y: canvasSize.height - height,
            width: canvasSize.width, height: height
        )
        let inset = canvasSize.width * (40.0 / 1920.0)
        return [
            RenderItem(
                id: "alert-band-\(alert.id)",
                frame: band,
                content: .shape(ShapeStyle(
                    kind: .rectangle,
                    fill: .solid(ConfidenceSceneBuilder.amber)
                ))
            ),
            RenderItem(
                id: "alert-text-\(alert.id)",
                frame: band.insetBy(dx: inset, dy: 0),
                content: .text(StyledText(
                    string: message,
                    fontSize: canvasSize.height * (72.0 / 1080.0),
                    color: .black,
                    alignment: .center,
                    tabularFigures: false,
                    autoShrink: true,
                    minFontSize: canvasSize.height * (24.0 / 1080.0)
                ))
            ),
        ]
    }
}
