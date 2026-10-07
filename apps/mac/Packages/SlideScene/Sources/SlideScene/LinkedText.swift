import Foundation
import PresenterCore
import RenderEngine

public enum LinkedText {

    public static func resolve(_ link: TextLink, info: ConfidenceInfo, at date: Date) -> String? {

        if let name = link.sourceObjectName, !name.isEmpty,
           [.currentSlide, .nextSlide, .lastSlide].contains(link.source) {
            let slide: ConfidenceInfo.SlideText? = switch link.source {
            case .currentSlide: info.current
            case .nextSlide: info.next
            case .lastSlide: info.last
            default: nil
            }
            let match = slide?.objectTexts?.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            return nonEmpty(match?.text)
        }
        switch link.source {
        case .currentSlide: return nonEmpty(info.current?.body)
        case .nextSlide:

            return nonEmpty((slideText(for: link, in: info) ?? info.next)?.body)
        case .lastSlide: return nonEmpty(info.last?.body)
        case .clock: return clockString(date, format: link.clockFormat)
        case .timer:
            return timer(for: link, in: info)?
                .displayString(at: date, format: link.timerFormat, pattern: link.timerPattern)
        case .videoCountdown:

            guard let video = info.videoCountdown(forLayer: link.videoLayer),
                  video.duration > 0 else { return nil }

            let timecode = TimerSnapshot.text(
                video.remaining(at: date), format: link.timerFormat, pattern: link.timerPattern
            )
            return link.showsVideoName == false ? timecode : "\(video.name)  \(timecode)"
        case .slidePosition:
            guard let position = info.slidePosition else { return nil }
            return "\(position.index) of \(position.total)"
        case .currentServiceItem: return nonEmpty(info.currentItemName)
        case .nextServiceItem: return nonEmpty(info.nextItemName)
        case .currentGroup: return nonEmpty(info.currentGroupName)
        case .currentPresentation: return nonEmpty(info.currentPresentationName)

        case .nextServiceTitle: return nonEmpty(info.nextServiceTitle)
        case .stageMessage:

            guard let alert = info.alert, alert.showsOnConfidence, info.alertVisible else { return nil }

            return nonEmpty(resolvedAlertMessage(alert.message, info: info, at: date))
        }
    }

    public static func resolvedObjects(
        _ objects: [SlideObject], info: ConfidenceInfo, at date: Date,
        reading: (TextLink) -> TextLink = { $0 }
    ) -> [SlideObject] {
        objects.map { object in
            guard let stored = object.textLink else { return object }
            let link = reading(stored)
            var resolved = object
            resolved.text = resolve(link, info: info, at: date) ?? ""

            let named = (link.sourceObjectName?.isEmpty == false)
            if let slide = slideText(for: link, in: info) {
                var chords = named ? [] : slide.chords
                if let maxLines = link.maxLines, maxLines > 0 {
                    let lines = resolved.text.components(separatedBy: "\n")
                    if lines.count > maxLines {
                        resolved.text = lines.prefix(maxLines).joined(separator: "\n")
                    }
                    chords = chords.filter { $0.line < maxLines }
                }

                chords = ChordMath.displayPlacements(
                    chords,
                    musicKey: slide.musicKey, displayKey: slide.displayKey,
                    notation: object.textStyle?.chordNotation ?? .chords
                )
                resolved.chords = chords.isEmpty ? nil : chords
            }
            if let ink = warningColorHex(for: link, info: info, at: date) {
                var style = resolved.textStyle ?? TextStyle()
                style.colorHex = ink
                resolved.textStyle = style
            }
            return resolved
        }
    }

    static func slideText(for link: TextLink, in info: ConfidenceInfo) -> ConfidenceInfo.SlideText? {
        switch link.source {
        case .currentSlide: info.current
        case .nextSlide: link.includeSteps == true ? (info.nextStep ?? info.next) : info.next
        case .lastSlide: info.last
        default: nil
        }
    }

    public static func warningColorHex(
        for link: TextLink, info: ConfidenceInfo, at date: Date
    ) -> String? {
        guard link.usesWarningColor != false else { return nil }
        switch link.source {
        case .timer:
            return timer(for: link, in: info)?.activeWarning(at: date)?.colorHex
        case .videoCountdown:
            guard let video = info.videoCountdown(forLayer: link.videoLayer),
                  video.duration > 0 else { return nil }
            return video.remaining(at: date) <= TimerSnapshot.warningThreshold
                ? TimerWarning.amberHex : nil
        default:
            return nil
        }
    }

    public static func authoringSources(current: TextSourceKind?) -> [TextSourceKind] {
        TextSourceKind.allCases.filter { $0 != .nextServiceTitle || $0 == current }
    }

    public static func isTimeVarying(_ link: TextLink) -> Bool {
        switch link.source {
        case .clock, .timer, .videoCountdown:
            return true
        case .currentSlide, .nextSlide, .lastSlide, .slidePosition,
             .currentServiceItem, .nextServiceItem, .stageMessage, .currentGroup,
             .currentPresentation, .nextServiceTitle:
            return false
        }
    }

    public static func ticksSubSecond(_ link: TextLink) -> Bool {
        switch link.source {
        case .timer, .videoCountdown:
            return link.timerPattern.map(TimerPattern.hasFraction) == true
        case .clock, .currentSlide, .nextSlide, .lastSlide, .slidePosition,
             .currentServiceItem, .nextServiceItem, .stageMessage, .currentGroup,
             .currentPresentation, .nextServiceTitle:
            return false
        }
    }

    public static let subSecondTickInterval: TimeInterval = 1.0 / 30

    public static let previewDate = Date(timeIntervalSince1970: 1_784_800_000)

    public static let previewInfo = ConfidenceInfo(
        current: .init(
            body: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
            chords: [
                ChordPlacement(line: 0, column: 0, symbol: "G"),
                ChordPlacement(line: 0, column: 24, symbol: "C"),
                ChordPlacement(line: 0, column: 30, symbol: "G"),
                ChordPlacement(line: 1, column: 5, symbol: "Em"),
                ChordPlacement(line: 1, column: 13, symbol: "D"),
            ],
            musicKey: "G"
        ),
        next: .init(
            body: "I once was lost, but now am found\nWas blind, but now I see",
            chords: [
                ChordPlacement(line: 0, column: 0, symbol: "G"),
                ChordPlacement(line: 0, column: 17, symbol: "G/B"),
                ChordPlacement(line: 1, column: 0, symbol: "C"),
                ChordPlacement(line: 1, column: 19, symbol: "G"),
            ],
            musicKey: "G"
        ),
        last: .init(body: "'Twas grace that taught my heart to fear\nAnd grace my fears relieved"),
        alert: CueAlert(message: "Mics hot after this song", behavior: .persist, target: .confidence),
        alertVisible: true,

        timers: [TimerSnapshot(name: "Sermon", mode: .countdown, banked: 753.58, durationSeconds: 1800)],
        videoCountdown: VideoCountdown(
            name: "Announcements", duration: 300, position: 180,
            anchoredAt: Date(timeIntervalSince1970: 1_784_800_000), isPlaying: false
        ),

        videoCountdowns: [
            LayerKind.videos.rawValue: VideoCountdown(
                name: "Announcements", duration: 300, position: 180,
                anchoredAt: Date(timeIntervalSince1970: 1_784_800_000), isPlaying: false
            ),
            LayerKind.loopingVideos.rawValue: VideoCountdown(
                name: "Background Loop", duration: 240, position: 60,
                anchoredAt: Date(timeIntervalSince1970: 1_784_800_000), isPlaying: false
            ),
            LayerKind.slide.rawValue: VideoCountdown(
                name: "Slide Video", duration: 90, position: 35,
                anchoredAt: Date(timeIntervalSince1970: 1_784_800_000), isPlaying: false
            ),
            LayerKind.overlays.rawValue: VideoCountdown(
                name: "Overlay Video", duration: 60, position: 20,
                anchoredAt: Date(timeIntervalSince1970: 1_784_800_000), isPlaying: false
            ),
        ],
        slidePosition: .init(index: 3, total: 12),
        currentItemName: "Amazing Grace",
        currentGroupName: "Verse 1",
        nextItemName: "Welcome & Announcements",
        currentPresentationName: "Amazing Grace",
        nextServiceTitle: "Sunday Gathering"
    )

    public static func previewObjects(_ objects: [SlideObject]) -> [SlideObject] {
        resolvedObjects(objects, info: previewInfo, at: previewDate, reading: previewLink)
    }

    public static func sampleText(for link: TextLink) -> String {
        resolve(previewLink(link), info: previewInfo, at: previewDate) ?? ""
    }

    private static func previewLink(_ link: TextLink) -> TextLink {
        var sampled = link
        sampled.timerId = nil
        return sampled
    }

    public static func resolvedAlertMessage(
        _ message: String, info: ConfidenceInfo, at date: Date
    ) -> String {
        guard message.contains("{") else { return message }
        var values: [String: String] = [:]
        for name in AlertTokens.tokenNames(in: message) {
            if let timer = info.timers.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                values[name] = timer.displayString(at: date)
            } else {

                values[name] = "{\(name)}"
            }
        }
        return AlertTokens.compose(template: message, values: values)
    }

    public static func alertMessageHasTimerToken(
        _ message: String, timers: [TimerSnapshot]
    ) -> Bool {
        guard message.contains("{") else { return false }
        return AlertTokens.tokenNames(in: message).contains { name in
            timers.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    static func timer(for link: TextLink, in info: ConfidenceInfo) -> TimerSnapshot? {
        if let id = link.timerId, !id.isEmpty {

            return info.timers.first { $0.id == id }
        }
        return ConfidenceSceneBuilder.primaryTimer(info.timers)
    }

    private static let formatters = Locked<[String: DateFormatter]>([:])

    static func clockString(_ date: Date, format: String?) -> String {
        guard let format, !format.isEmpty else {
            return ConfidenceSceneBuilder.clockString(date)
        }
        return formatters.withLock { cache in
            let formatter: DateFormatter
            if let cached = cache[format] {
                formatter = cached
            } else {
                formatter = DateFormatter()
                formatter.dateFormat = format
                cache[format] = formatter
            }
            return formatter.string(from: date)
        }
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
