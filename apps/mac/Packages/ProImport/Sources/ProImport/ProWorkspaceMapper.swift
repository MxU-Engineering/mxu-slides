import Foundation
import PresenterCore

public struct ProMappedTheme: Sendable {
    public var theme: Theme
    public var mediaWants: [ProMediaWant]
    public var warnings: [String]
}

public struct ProMappedOverlay: Sendable {
    public var overlay: Overlay
    public var mediaWants: [ProMediaWant]
    public var warnings: [String]
}

public struct ProMappedAlert: Sendable {
    public var preset: AlertPreset

    public var templateThemeName: String?
    public var templateSlideName: String?
    public var warnings: [String]
}

public struct ProMappedLayout: Sendable {
    public var layout: ConfidenceLayout
    public var mediaWants: [ProMediaWant]
    public var warnings: [String]
}

public struct ProMappedCombo: Sendable {
    public var combo: ActionCombo
    public var mediaWants: [ProMediaWant]
    public var warnings: [String]
}

public struct ProInputPlanBook: Sendable, Equatable {

    public private(set) var plans: [ProInputPlan] = []
    private var idsByKey: [String: String] = [:]

    private var workspaceIDs: [String] = []

    public private(set) var isEnabled = false

    public init() {}

    public mutating func seed(_ existing: [ProInputSeed]) {
        isEnabled = true
        for input in existing {
            for key in Self.keys(name: input.name, sourceId: input.sourceId)
            where idsByKey[key] == nil {
                idsByKey[key] = input.id
            }
        }
    }

    mutating func registerWorkspaceInput(
        uuid: String, name: String, device: RVData_Media.VideoDevice
    ) {
        isEnabled = true
        let id = id(
            for: device,
            preferredID: uuid.isEmpty ? nil : uuid.lowercased(),
            fallbackName: name
        )
        workspaceIDs.append(id)
    }

    mutating func id(
        for device: RVData_Media.VideoDevice,
        preferredID: String? = nil,
        fallbackName: String = ""
    ) -> String {
        isEnabled = true
        let mapped = Self.device(device)
        var name = fallbackName.isEmpty ? device.name : fallbackName
        if name.isEmpty { name = "Video Input" }
        let keys = Self.keys(name: name, sourceId: mapped.sourceId)
        if let existing = keys.compactMap({ idsByKey[$0] }).first { return existing }
        let id = preferredID ?? UUID().uuidString
        plans.append(ProInputPlan(
            newID: id, name: name, kind: mapped.kind, sourceId: mapped.sourceId
        ))
        for key in keys { idsByKey[key] = id }
        return id
    }

    func workspaceInputID(at index: Int) -> String? {
        workspaceIDs.indices.contains(index) ? workspaceIDs[index] : nil
    }

    static func device(
        _ device: RVData_Media.VideoDevice
    ) -> (kind: CaptureSourceKind, sourceId: String?) {
        let kind: CaptureSourceKind = device.type == .ndi ? .ndi : .camera
        let sourceId = kind == .ndi
            ? (device.name.isEmpty ? device.uniqueID : device.name)
            : device.uniqueID
        return (kind, sourceId.isEmpty ? nil : sourceId)
    }

    private static func keys(name: String, sourceId: String?) -> [String] {
        var keys: [String] = []
        if let sourceId, !sourceId.isEmpty { keys.append("device:" + sourceId.lowercased()) }
        if !name.isEmpty { keys.append("name:" + name.lowercased()) }
        return keys
    }
}

public enum ProWorkspaceMapper {

    public static func themeID(named name: String) -> String {
        "pro7-theme-" + name.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func mapTheme(_ doc: RVData_Template.Document, name: String) -> ProMappedTheme {
        var state = ProDocumentMapper.MapState()
        var slides: [Slide] = []

        for templateSlide in doc.slides {
            let base = templateSlide.baseSlide
            var objects: [SlideObject] = []
            if base.drawsBackgroundColor, base.hasBackgroundColor {
                objects.append(SlideObject(
                    id: UUID().uuidString, objectKind: .shape, name: "Background Color", text: "",
                    x: 0, y: 0, width: 1920, height: 1080,
                    fill: ObjectFill(fillKind: .solid, colorHex: ProDocumentMapper.hexColor(base.backgroundColor))
                ))
            }

            for action in templateSlide.actions {
                guard case .media(let media)? = action.actionTypeData else { continue }
                let element = media.element
                if case .audio? = element.typeProperties { continue }
                let size = base.hasSize ? base.size : nil
                objects.append(SlideObject(
                    id: UUID().uuidString, objectKind: .shape, name: "Background", text: "",
                    x: 0, y: 0, width: size?.width ?? 1920, height: size?.height ?? 1080,
                    fill: ObjectFill(
                        fillKind: .media,
                        mediaId: state.want(for: element, classification: .background),
                        mediaScaleMode: .fill)
                ))
            }

            for element in base.elements.reversed() {
                if var object = ProDocumentMapper.mapElement(element.element, state: &state) {
                    if element.element.hidden { object.hidden = true }
                    objects.append(object)
                } else if var placeholder = emptyTextPlaceholder(element.element, state: &state) {

                    if element.element.hidden { placeholder.hidden = true }
                    objects.append(placeholder)
                }
            }
            slides.append(Slide(
                id: base.uuid.string.isEmpty ? UUID().uuidString : base.uuid.string.lowercased(),
                name: templateSlide.name.isEmpty ? "Theme Slide" : templateSlide.name,
                objects: objects
            ))
        }

        let firstStyle = slides.lazy.flatMap(\.objects).compactMap(\.textStyle).first
        let theme = Theme(
            id: themeID(named: name),
            name: name,
            fontFamily: firstStyle?.fontName ?? "Helvetica Neue",
            fontSize: firstStyle?.fontSize ?? 96,
            textColorHex: firstStyle?.colorHex ?? "#FFFFFFFF",
            backgroundColorHex: "#000000FF",
            slides: slides.isEmpty ? nil : slides
        )
        return ProMappedTheme(theme: theme, mediaWants: state.wants, warnings: state.warnings)
    }

    static func emptyTextPlaceholder(_ element: RVData_Graphics.Element, state: inout ProDocumentMapper.MapState) -> SlideObject? {
        guard element.hasText else { return nil }
        var object = SlideObject(
            id: element.uuid.string.isEmpty ? UUID().uuidString : element.uuid.string.lowercased(),
            objectKind: .text,
            name: element.name.isEmpty ? "Text Placeholder" : element.name,
            text: ""
        )
        if element.hasBounds {
            object.x = element.bounds.origin.x
            object.y = element.bounds.origin.y
            object.width = element.bounds.size.width
            object.height = element.bounds.size.height
        }
        object.textStyle = ProDocumentMapper.textStyle(for: element, attributed: nil, state: &state)
        return object
    }

    public static func mapProps(_ doc: RVData_PropDocument) -> [ProMappedOverlay] {
        doc.cues.compactMap { cue in
            var state = ProDocumentMapper.MapState()
            var slide: RVData_Slide?
            for action in cue.actions {
                if case .slide(let slideType)? = action.actionTypeData,
                   case .prop(let propSlide)? = slideType.slide {
                    slide = propSlide.baseSlide
                    break
                }
            }
            guard let base = slide else { return nil }
            var objects: [SlideObject] = []

            for element in base.elements.reversed() {
                if var object = ProDocumentMapper.mapElement(element.element, state: &state) {
                    if element.element.hidden { object.hidden = true }
                    objects.append(object)
                }
            }
            let overlay = Overlay(
                id: cue.uuid.string.isEmpty ? UUID().uuidString : cue.uuid.string.lowercased(),
                name: cue.name.isEmpty ? "Prop" : cue.name,
                objects: objects,
                folder: "ProPresenter Import"
            )
            return ProMappedOverlay(overlay: overlay, mediaWants: state.wants, warnings: state.warnings)
        }
    }

    public static func mapMessages(_ doc: RVData_MessageDocument) -> [ProMappedAlert] {
        doc.messages.map { message in
            var warnings: [String] = []
            var text = message.messageText

            for token in message.tokens {
                let name: String
                switch token.tokenType {
                case .text(let t)?: name = t.name
                case .timer(let t)?: name = t.name
                case .clock?:
                    name = "clock"
                    warnings.append("message \"\(message.title)\": clock token becomes a fill-at-fire slot")
                case .none:
                    continue
                }
                let uuid = token.uuid.string
                if !uuid.isEmpty {
                    text = text.replacingOccurrences(
                        of: "${\(uuid)}", with: "{\(name)}",
                        options: [.caseInsensitive]
                    )
                }
                if !text.localizedCaseInsensitiveContains("{\(name)}") {
                    text += text.isEmpty ? "{\(name)}" : " {\(name)}"
                }
            }
            if message.timeToRemove > 0 {
                warnings.append("message \"\(message.title)\": auto-clear after \(Int(message.timeToRemove))s is not supported — the alert clears manually")
            }

            let hasTemplate = !message.template.name.isEmpty
            let preset = AlertPreset(
                id: message.uuid.string.isEmpty ? UUID().uuidString : message.uuid.string.lowercased(),
                name: message.title.isEmpty ? "Message" : message.title,
                message: text,
                behavior: .persist,

                target: hasTemplate ? .both : nil
            )
            return ProMappedAlert(
                preset: preset,
                templateThemeName: hasTemplate ? message.template.name : nil,
                templateSlideName: message.template.slideName.isEmpty ? nil : message.template.slideName,
                warnings: warnings
            )
        }
    }

    public struct ProMappedTrigger: Sendable {
        public var trigger: ScheduleTrigger
        public var warnings: [String]
    }

    public static func mapCalendar(
        _ doc: RVData_Calendar,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:],
        calendar: Calendar = .current
    ) -> [ProMappedTrigger] {
        doc.events.map { event in
            var state = ProDocumentMapper.MapState()
            let name = event.name.isEmpty ? "Calendar Event" : event.name
            let context = "calendar event \"\(name)\""
            let date = Date(timeIntervalSince1970: TimeInterval(event.date.seconds))
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)

            var wall = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if let second = parts.second, second > 0 {
                wall += String(format: ":%02d", second)
            }
            var condition: ScheduleCondition
            if event.recurrenceDays.isEmpty {
                condition = ScheduleCondition(
                    id: UUID().uuidString, kind: .oneTime,
                    date: String(
                        format: "%04d-%02d-%02dT%@",
                        parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1, wall)
                )
            } else {
                condition = ScheduleCondition(
                    id: UUID().uuidString, kind: .weekly,
                    days: event.recurrenceDays.map(\.rawValue).filter { (1 ... 7).contains($0) },
                    timeOfDay: wall
                )
            }

            var enabledUntil: String?
            if event.recurrenceLimitDate.seconds > 0 {
                let limit = Date(timeIntervalSince1970: TimeInterval(event.recurrenceLimitDate.seconds))
                let limitParts = calendar.dateComponents([.year, .month, .day], from: limit)
                enabledUntil = String(
                    format: "%04d-%02d-%02dT23:59:59",
                    limitParts.year ?? 2000, limitParts.month ?? 1, limitParts.day ?? 1)
            }

            if !event.recurrenceExcludedDates.isEmpty, condition.kind == .weekly {
                var weekly = condition
                weekly.excludedDates = event.recurrenceExcludedDates.map { stamp in
                    let parts = calendar.dateComponents(
                        [.year, .month, .day],
                        from: Date(timeIntervalSince1970: TimeInterval(stamp.seconds)))
                    return String(
                        format: "%04d-%02d-%02d",
                        parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
                }
                condition = weekly
            }

            var actions: [SlideAction] = []
            for proAction in event.actions {
                if let steps = mapActionSteps(
                    proAction, context: context,
                    timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName, state: &state
                ) {
                    actions.append(contentsOf: steps)
                } else {
                    state.warn("\(context): \(ProDocumentMapper.describeActionKind(proAction)) steps have no Scheduler equivalent yet")
                }
            }

            if actions.isEmpty, event.hasAction {
                switch event.action.actionType {
                case .macro(let macro)?:
                    var step = SlideAction(id: UUID().uuidString, kind: .fireCombo)
                    step.comboId = macro.identification.parameterUuid.string.lowercased()
                    actions.append(step)
                case .playlist?:
                    state.warn("\(context): a fire-playlist calendar action has no Scheduler read yet")
                case nil:
                    break
                }
            }

            let trigger = ScheduleTrigger(
                id: event.uuid.string.isEmpty ? UUID().uuidString : event.uuid.string.lowercased(),
                name: name,
                conditions: [condition],
                actions: actions,
                enabledUntil: enabledUntil
            )
            return ProMappedTrigger(trigger: trigger, warnings: state.warnings)
        }
    }

    public static func mapStageLayouts(
        _ doc: RVData_Stage.Document,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:],
        inputs: inout ProInputPlanBook
    ) -> [ProMappedLayout] {
        doc.layouts.map { layout in
            var state = ProDocumentMapper.MapState()
            state.inputBook = inputs
            defer { inputs = state.inputBook }
            let base = layout.slide
            var objects: [SlideObject] = []

            for element in base.elements.reversed() {
                var object = ProDocumentMapper.mapElement(element.element, state: &state)
                if let link = textLink(
                    for: element,
                    timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName,
                    state: &state
                ) {

                    if object == nil {
                        object = emptyTextPlaceholder(element.element, state: &state)
                    }
                    object?.objectKind = .text
                    object?.textLink = link
                }

                if let visibility = visibility(
                    for: element,
                    timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName,
                    state: &state
                ) {

                    if object == nil {
                        object = emptyTextPlaceholder(element.element, state: &state)
                    }
                    object?.visibilityMatch = visibility.match
                    object?.visibilityConditions = visibility.conditions
                }
                if element.element.hidden { object?.hidden = true }
                if let object { objects.append(object) }
            }

            var canvas: (Int, Int)?
            if base.hasSize, base.size.width > 0 {
                canvas = (Int(base.size.width), Int(base.size.height))
            }
            let confidenceLayout = ConfidenceLayout(
                id: layout.uuid.string.isEmpty ? UUID().uuidString : layout.uuid.string.lowercased(),
                name: layout.name.isEmpty ? "Stage Layout" : layout.name,
                objects: objects,
                folder: "ProPresenter Import",
                canvasWidth: canvas.flatMap { $0 == (1920, 1080) ? nil : $0.0 },
                canvasHeight: canvas.flatMap { $0 == (1920, 1080) ? nil : $0.1 }
            )
            return ProMappedLayout(layout: confidenceLayout, mediaWants: state.wants, warnings: state.warnings)
        }
    }

    public static func mapStageLayouts(
        _ doc: RVData_Stage.Document,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:]
    ) -> [ProMappedLayout] {
        var book = ProInputPlanBook()
        return mapStageLayouts(
            doc, timerIDsByProUUID: timerIDsByProUUID,
            timerIDsByName: timerIDsByName, inputs: &book
        )
    }

    static func textLink(
        for element: RVData_Slide.Element,
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String],
        state: inout ProDocumentMapper.MapState
    ) -> TextLink? {
        for dataLink in element.dataLinks {
            switch dataLink.propertyType {
            case .slideText(let slideText)?:
                return TextLink(source: slideText.sourceSlide == .nextSlide ? .nextSlide : .currentSlide)
            case .timerText(let timer)?:
                var link = TextLink(source: .timer)
                let uuid = timer.timerUuid.string.lowercased()
                if let mapped = timerIDsByProUUID[uuid] ?? timerIDsByName[timer.timerName.lowercased()] {
                    link.timerId = mapped
                } else if !timer.timerName.isEmpty {
                    state.warn("timer \"\(timer.timerName)\" was not imported — the linked box follows \(AutomaticTimer.phrase)")
                }
                return link
            case .clockText(let clock)?:
                var link = TextLink(source: .clock)
                link.clockFormat = clock.format.militaryTimeEnabled ? "H:mm" : "h:mm a"
                return link
            case .videoCountdown?:
                return TextLink(source: .videoCountdown)
            case .stageMessage?:
                return TextLink(source: .stageMessage)
            case .slideCount?:
                return TextLink(source: .slidePosition)
            case .groupName?:

                return TextLink(source: .currentGroup)
            case .playlistItem(let item)?:

                switch item.playlistItemSource {
                case .current: return TextLink(source: .currentServiceItem)
                case .next: return TextLink(source: .nextServiceItem)
                default:
                    state.warn("a playlist-item link (\(caseName(of: item.playlistItemSource))) has no MxU source yet and imported as static text")
                    return nil
                }
            case .presentation?:

                return TextLink(source: .currentPresentation)
            case .presentationNotes?:
                state.warn("a \"notes\" link has no MxU source yet and imported as static text")
                return nil
            case .visibilityLink?:

                continue
            case .some(let other):
                state.warn("a data link (\(caseName(of: other))) has no MxU source yet and imported as static text")
                return nil
            case .none:
                continue
            }
        }
        return nil
    }

    private static func caseName(of value: Any) -> String {
        Mirror(reflecting: value).children.first?.label ?? String(describing: value)
    }

    static func visibility(
        for element: RVData_Slide.Element,
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String],
        state: inout ProDocumentMapper.MapState
    ) -> (match: VisibilityMatch?, conditions: [VisibilityCondition])? {
        for dataLink in element.dataLinks {
            guard case .visibilityLink(let link)? = dataLink.propertyType else { continue }
            guard !link.conditions.isEmpty else { return nil }
            let match: VisibilityMatch? = switch link.visibilityCriterion {
            case .all, .UNRECOGNIZED: nil  
            case .any: .any
            case .none: VisibilityMatch.none
            }

            func timeState(_ raw: Int) -> VisibilityConditionState? {
                switch raw {
                case 0: .hasTimeRemaining
                case 1: .hasExpired
                case 2: .isRunning
                case 3: .isNotRunning
                default: nil  
                }
            }

            var conditions: [VisibilityCondition] = []
            for condition in link.conditions {
                switch condition.conditionType {
                case .timerVisibility(let timer)?:
                    guard let mappedState = timeState(timer.visibilityCriterion.rawValue) else {
                        state.warn("a visibility condition uses an unsupported timer state and was dropped")
                        continue
                    }
                    var mapped = VisibilityCondition(conditionKind: .timer, state: mappedState)
                    let uuid = timer.timerUuid.string.lowercased()
                    if let id = timerIDsByProUUID[uuid] ?? timerIDsByName[timer.timerName.lowercased()] {
                        mapped.timerId = id
                    } else if !timer.timerName.isEmpty {
                        state.warn("a visibility condition watches timer \"\(timer.timerName)\", which wasn't imported — it follows \(AutomaticTimer.phrase)")
                    }
                    conditions.append(mapped)
                case .videoCountdownVisibility(let video)?:
                    guard let mappedState = timeState(video.visibilityCriterion.rawValue) else {
                        state.warn("a video-countdown visibility condition uses a looping state, which has no MxU read — dropped")
                        continue
                    }
                    conditions.append(VisibilityCondition(conditionKind: .videoCountdown, state: mappedState))
                case .audioCountdownVisibility(let audio)?:
                    guard let mappedState = timeState(audio.visibilityCriterion.rawValue) else {
                        state.warn("an audio visibility condition uses a looping state, which has no MxU read — dropped")
                        continue
                    }
                    conditions.append(VisibilityCondition(conditionKind: .audioPlayback, state: mappedState))
                case .elementVisibility(let other)?:
                    var mapped = VisibilityCondition(
                        conditionKind: .objectText,
                        state: other.visibilityCriterion == .hasNoText ? .hasNoText : .hasText
                    )
                    let uuid = other.otherElementUuid.string.lowercased()
                    if !uuid.isEmpty { mapped.objectId = uuid }
                    conditions.append(mapped)
                case .captureSessionVisibility(let capture)?:
                    conditions.append(VisibilityCondition(
                        conditionKind: .capture,
                        state: capture.visibilityCriterion == .inactive ? .isInactive : .isActive
                    ))
                case .videoInputVisibility(let input)?:

                    var mapped = VisibilityCondition(
                        conditionKind: .liveInput,
                        state: input.visibilityCriterion == .inactive ? .isInactive : .isActive
                    )
                    if let id = state.inputBook.workspaceInputID(at: Int(input.videoInputIndex)) {
                        mapped.liveInputId = id
                    } else {
                        state.warn("a video-input visibility condition imported — pick the MxU input on the object")
                    }
                    conditions.append(mapped)
                case .none:
                    continue
                }
            }
            guard !conditions.isEmpty else { return nil }
            return (match, conditions)
        }
        return nil
    }

    public static func mapMacros(
        _ doc: RVData_MacrosDocument,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:],
        inputs: inout ProInputPlanBook
    ) -> [ProMappedCombo] {

        (doc.macros + doc.macroCollections.flatMap(\.macros)).compactMap { macro in

            guard !macro.actions.isEmpty else { return nil }
            return mapMacro(
                macro, timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, inputs: &inputs
            )
        }
    }

    public static func mapMacros(
        _ doc: RVData_MacrosDocument,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:]
    ) -> [ProMappedCombo] {
        var book = ProInputPlanBook()
        return mapMacros(
            doc, timerIDsByProUUID: timerIDsByProUUID,
            timerIDsByName: timerIDsByName, inputs: &book
        )
    }

    private static func mapMacro(
        _ macro: RVData_MacrosDocument.Macro,
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String],
        inputs: inout ProInputPlanBook
    ) -> ProMappedCombo {
        var state = ProDocumentMapper.MapState()
        state.inputBook = inputs
        defer { inputs = state.inputBook }
        var actions: [SlideAction] = []
        for proAction in macro.actions {
            if let steps = mapActionSteps(
                proAction, context: "macro \"\(macro.name)\"",
                timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, state: &state
            ) {
                actions.append(contentsOf: steps)
            } else if case .slide? = proAction.actionTypeData {
                state.warn("macro \"\(macro.name)\": an inline slide step has no combo equivalent")
            } else {
                state.warn("macro \"\(macro.name)\": \(ProDocumentMapper.describeActionKind(proAction)) steps have no combo equivalent yet")
            }
        }
        let combo = ActionCombo(
            id: macro.uuid.string.isEmpty ? UUID().uuidString : macro.uuid.string.lowercased(),
            name: macro.name.isEmpty ? "Macro" : macro.name,
            actions: actions,
            colorHex: macro.hasColor ? ProDocumentMapper.hexColor(macro.color) : nil
        )
        return ProMappedCombo(combo: combo, mediaWants: state.wants, warnings: state.warnings)
    }

    static func mapActionSteps(
        _ proAction: RVData_Action,
        context: String,
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String] = [:],
        state: inout ProDocumentMapper.MapState
    ) -> [SlideAction]? {
            var actions: [SlideAction] = []

            func action(_ kind: SlideActionKind) -> SlideAction {
                SlideAction(id: UUID().uuidString, kind: kind)
            }

                switch proAction.actionTypeData {
                case .media(let media)?:
                    let element = media.element
                    switch element.typeProperties {
                    case .image?, .video?:
                        var fire = action(.fireMedia)
                        fire.mediaId = state.want(for: element)
                        actions.append(fire)
                    case .liveVideo(let live)?:

                        var fire = action(.fireLiveInput)
                        let device = live.liveVideo.videoDevice
                        let mapped = ProInputPlanBook.device(device)
                        if state.inputBook.isEnabled {

                            fire.liveInputId = state.inputBook.id(for: device)
                            if mapped.sourceId == nil {
                                state.warn("\(context): its video-input step named no device — assign one to the imported input in Settings › Audio/Video Inputs")
                            }
                        } else {
                            fire.inputSourceKind = mapped.kind
                            fire.inputSourceId = mapped.sourceId
                            if fire.inputSourceId == nil {
                                state.warn("\(context): its video-input step named no device — pick the source on the imported combo")
                            }
                        }
                        actions.append(fire)
                    default:
                        state.warn("\(context): an audio/web media step has no combo equivalent yet")
                    }
                case .clear(let clear)?:
                    switch clear.targetLayer {
                    case .all:
                        actions.append(action(.clearAll))
                    case .slide:
                        var step = action(.clearLayer); step.layer = "slide"; actions.append(step)
                    case .background:
                        for layer in ["loopingVideos", "stillGraphics", "videos"] {
                            var step = action(.clearLayer); step.layer = layer; actions.append(step)
                        }
                    case .prop:
                        var step = action(.clearLayer); step.layer = "overlays"; actions.append(step)
                    case .messages:
                        var step = action(.clearLayer); step.layer = "alerts"; actions.append(step)
                    case .liveVideo:
                        var step = action(.clearLayer); step.layer = "videoInput"; actions.append(step)
                    case .audio:

                        actions.append(action(.clearAudio))
                    default:
                        state.warn("\(context): clear \(clear.targetLayer) has no MxU layer equivalent")
                    }
                case .timer(let timer)?:

                    let name = timer.timerIdentification.parameterName
                    let timerID = timerIDsByProUUID[timerActionUUID(timer).lowercased()]
                        ?? timerIDsByName[name.lowercased()]
                    if timerID == nil {

                        state.warn("\(context): its timer step\(name.isEmpty ? "" : " (\"\(name)\")") didn't match an imported timer — pick one on the action")
                    }
                    func timerStep(_ kind: SlideActionKind) {
                        var step = action(kind); step.timerId = timerID; actions.append(step)
                    }

                    if timer.hasTimerConfiguration,
                       let mode = timerPlanMode(timer.timerConfiguration) {
                        var configure = action(.timerConfigure)
                        configure.timerId = timerID
                        switch mode {
                        case .countdown(let seconds):
                            configure.timerMode = .countdown
                            configure.timerDurationSeconds = seconds
                        case .countdownToTime(let hour, let minute):
                            configure.timerMode = .countdownToTime
                            configure.timerHour = hour
                            configure.timerMinute = minute
                        case .countUp(let limitSeconds):
                            configure.timerMode = .countUp
                            configure.timerDurationSeconds = limitSeconds
                        }
                        actions.append(configure)
                    }
                    switch timer.actionType {
                    case .actionStart: timerStep(.timerStart)
                    case .actionStop: timerStep(.timerPause)
                    case .actionReset: timerStep(.timerReset)
                    case .actionResetAndStart: timerStep(.timerReset); timerStep(.timerStart)
                    case .actionStopAndReset: timerStep(.timerPause); timerStep(.timerReset)
                    default:
                        state.warn("\(context): unsupported timer action")
                    }
                case .stage(let stage)?:

                    for assignment in stage.stageScreenAssignments {
                        var step = action(.setConfidenceLayout)
                        step.confidenceLayoutId = assignment.layout.parameterUuid.string.lowercased()
                        actions.append(step)
                    }
                    if stage.stageScreenAssignments.count > 1 {
                        state.warn("\(context): Pro7 set different stage layouts per screen; MxU applies each to ALL confidence screens — keep the last step or re-scope after import")
                    }
                case .message(let message)?:
                    var step = action(.fireAlert)
                    step.alertId = message.messageIdentificaton.parameterUuid.string.lowercased()
                    actions.append(step)
                case .macro(let inner)?:
                    var step = action(.fireCombo)
                    step.comboId = inner.identification.parameterUuid.string.lowercased()
                    actions.append(step)
                case .presentationDocument(let document)?:
                    var step = action(.firePresentation)
                    step.presentationId = document.identification.parameterUuid.string.lowercased()
                    actions.append(step)
                case .prop(let prop)?:

                    let overlayID = prop.identification.parameterUuid.string.lowercased()
                    if case .clear? = prop.triggerType {
                        var step = action(.dismissOverlay)
                        step.overlayId = overlayID.isEmpty ? nil : overlayID
                        actions.append(step)
                    } else {
                        var step = action(.fireOverlay)
                        step.overlayId = overlayID
                        actions.append(step)
                    }
                case .playlistItem(let playlist)?:

                    var step = action(.fireAudioPlaylist)
                    step.playlistId = playlist.playlistUuid.string.lowercased()

                    if !playlist.itemUuid.string.isEmpty {
                        step.audioEntryId = playlist.itemUuid.string.lowercased()
                    }
                    actions.append(step)
                case .audienceLook(let look)?:

                    var step = action(.switchOutputPreset)
                    step.presetId = look.identification.parameterUuid.string.lowercased()
                    actions.append(step)
                case .communication(let communication)?:

                    guard case .midiCommand(let midi)? = communication.commandTypeData else {
                        return nil
                    }
                    var step = action(.midiOut)
                    step.midiKind = .noteOn
                    step.midiChannel = min(Int(midi.channel) + 1, 16)
                    step.midiNumber = Int(midi.note)
                    step.midiValue = midi.state == .off ? 0 : Int(midi.intensity)
                    actions.append(step)
                case .none:
                    return []
                default:
                    return nil
                }

            if proAction.delayTime > 0 {
                for index in actions.indices {
                    actions[index].delaySeconds = proAction.delayTime
                }
            }
            return actions
    }

    private static func timerActionUUID(_ timer: RVData_Action.TimerType) -> String {
        timer.timerIdentification.parameterUuid.string
    }

    public static func replacingMediaIDs(_ combo: ActionCombo, with map: [String: String]) -> ActionCombo {
        var combo = combo
        combo.actions = combo.actions.compactMap { step in
            guard let mediaId = step.mediaId, mediaId.hasPrefix(ProDocumentMapper.placeholderPrefix) else { return step }
            guard let mapped = map[mediaId] else { return nil }
            var step = step
            step.mediaId = mapped
            return step
        }
        return combo
    }

    public static func mapScreens(
        _ workspace: RVData_ProPresenterWorkspace
    ) -> (plan: ProScreenPlan, warnings: [String]) {
        var warnings: [String] = []
        let screens = workspace.proScreens.compactMap { screen -> ProScreenPlan.Screen? in
            var width = 1920
            var height = 1080
            var correction: ProScreenPlan.OutputCorrection?
            var slices: [ProScreenPlan.Slice] = []
            let name = screen.name.isEmpty ? "Screen" : screen.name
            switch screen.arrangement {
            case .arrangementSingle(let single)?:
                if let output = single.screens.first {
                    if output.hasBounds, output.bounds.size.width > 0 {
                        width = Int(output.bounds.size.width)
                        height = Int(output.bounds.size.height)
                    }
                    correction = outputCorrection(of: output, screenName: name, warnings: &warnings)
                }
            case .arrangementCombined(let combined)?:

                if let size = spanCanvasSize(of: combined.screens) {
                    width = size.width
                    height = size.height
                }
                slices = spanSlices(
                    of: combined.screens, edgeBlends: [],
                    canvasWidth: width, canvasHeight: height,
                    screenName: name, warnings: &warnings)
            case .arrangementEdgeBlend(let blend)?:
                if let size = spanCanvasSize(of: blend.screens) {
                    width = size.width
                    height = size.height
                }
                slices = spanSlices(
                    of: blend.screens, edgeBlends: blend.edgeBlends,
                    canvasWidth: width, canvasHeight: height,
                    screenName: name, warnings: &warnings)
            case .none:
                break
            }
            return ProScreenPlan.Screen(
                proUUID: screen.uuid.string.lowercased(),
                name: name,
                isConfidence: screen.screenType == .stage,
                width: width,
                height: height,
                correction: correction,
                slices: slices
            )
        }
        let assignments = workspace.stageLayoutMappings.map {
            ProScreenPlan.StageAssignment(
                screenProUUID: $0.screen.parameterUuid.string.lowercased(),
                layoutID: $0.layout.parameterUuid.string.lowercased()
            )
        }
        let masks = mapMasks(workspace, warnings: &warnings)
        return (
            ProScreenPlan(screens: screens, stageAssignments: assignments, masks: masks),
            warnings
        )
    }

    private static func mapMasks(
        _ workspace: RVData_ProPresenterWorkspace, warnings: inout [String]
    ) -> [ProScreenPlan.MaskPlan] {
        workspace.masks.compactMap { mask -> ProScreenPlan.MaskPlan? in
            let slide = mask.baseSlide
            let name = mask.name.isEmpty ? "Mask" : mask.name
            let canvasWidth = slide.hasSize && slide.size.width > 0 ? slide.size.width : 1920
            let canvasHeight = slide.hasSize && slide.size.height > 0 ? slide.size.height : 1080
            var state = ProDocumentMapper.MapState()
            var shapes: [ProScreenPlan.MaskShape] = []
            for wrapped in slide.elements {
                guard let object = ProDocumentMapper.mapElement(
                    wrapped.element, state: &state)
                else { continue }
                guard object.objectKind == .shape else {
                    warnings.append(
                        "mask \"\(name)\": a \(object.objectKind.rawValue) element has no mask reading and was dropped")
                    continue
                }
                shapes.append(ProScreenPlan.MaskShape(
                    x: (object.x ?? 0) / canvasWidth,
                    y: (object.y ?? 0) / canvasHeight,
                    width: (object.width ?? 0) / canvasWidth,
                    height: (object.height ?? 0) / canvasHeight,
                    shapeKind: (object.shapeKind ?? .rectangle).rawValue,
                    cornerRadius: object.cornerRadius ?? 0,
                    pathData: object.pathData
                ))
            }
            guard !shapes.isEmpty else {
                warnings.append("mask \"\(name)\": no readable shapes — dropped")
                return nil
            }
            return ProScreenPlan.MaskPlan(
                proUUID: slide.uuid.string.lowercased(), name: name, shapes: shapes)
        }
    }

    private static func spanSlices(
        of outputs: [RVData_Screen], edgeBlends: [RVData_EdgeBlend],
        canvasWidth: Int, canvasHeight: Int,
        screenName: String, warnings: inout [String]
    ) -> [ProScreenPlan.Slice] {
        let union = spanCanvasSize(of: outputs)
        let origin: (x: Double, y: Double) = {
            let rects = outputs.filter { $0.hasBounds && $0.bounds.size.width > 0 }
            let x = rects.map(\.bounds.origin.x).min() ?? 0
            let y = rects.map(\.bounds.origin.y).min() ?? 0
            return (x, y)
        }()

        var edges: [String: [(edge: RVData_EdgeBlend.Screen.Edge, entry: RVData_EdgeBlend.Screen)]] = [:]
        for blend in edgeBlends {
            var entries: [RVData_EdgeBlend.Screen] = []
            if blend.hasFirstScreen { entries.append(blend.firstScreen) }
            if blend.hasSecondScreen { entries.append(blend.secondScreen) }
            if blend.hasLeftScreen { entries.append(blend.leftScreen) }
            if blend.hasRightScreen { entries.append(blend.rightScreen) }
            if blend.hasTopScreen { entries.append(blend.topScreen) }
            if blend.hasBottomScreen { entries.append(blend.bottomScreen) }
            for entry in entries where entry.edge != .unknown {
                edges[entry.uuid.string.lowercased(), default: []]
                    .append((entry.edge, entry))
            }
        }
        return outputs.enumerated().map { index, output in
            let rect: (x: Double, y: Double, w: Double, h: Double)
            if output.hasSubscreenUnitRect, output.subscreenUnitRect.size.width > 0 {
                let unit = output.subscreenUnitRect
                rect = (unit.origin.x, unit.origin.y, unit.size.width, unit.size.height)
            } else if output.hasBounds, output.bounds.size.width > 0, let union {
                rect = (
                    (output.bounds.origin.x - origin.x) / Double(union.width),
                    (output.bounds.origin.y - origin.y) / Double(union.height),
                    output.bounds.size.width / Double(union.width),
                    output.bounds.size.height / Double(union.height)
                )
            } else {
                rect = (0, 0, 1, 1)
            }
            var slice = ProScreenPlan.Slice(
                proUUID: output.uuid.string.lowercased(),
                name: output.name.isEmpty ? "Output \(index + 1)" : output.name,
                x: rect.x, y: rect.y, width: rect.w, height: rect.h,
                correction: outputCorrection(
                    of: output, screenName: screenName, warnings: &warnings)
            )
            let sliceWidthPixels = max(rect.w * Double(canvasWidth), 1)
            let sliceHeightPixels = max(rect.h * Double(canvasHeight), 1)
            for (edge, entry) in edges[slice.proUUID] ?? [] {
                let axisPixels = (edge == .left || edge == .right)
                    ? sliceWidthPixels : sliceHeightPixels
                let width = entry.radius > 1
                    ? entry.radius / axisPixels
                    : entry.radius
                guard width > 0 else { continue }
                let modeExponent: Double = switch entry.mode {
                case .linear: 1
                case .quadratic: 2
                case .cubic: 3
                default: 2.2
                }
                let curve = entry.gamma > 0 ? entry.gamma : modeExponent

                let intensity = entry.intensity > 0 && entry.intensity < 1
                    ? entry.intensity : nil
                let compensation = output.hasBlendCompensation
                    ? output.blendCompensation.blackLevel : 0
                let lift = max(min(max(entry.blackLevel, 0), 1), min(max(compensation, 0), 1))
                let plan = ProScreenPlan.EdgeBlendPlan(
                    width: min(max(width, 0), 1), curve: curve,
                    intensity: intensity, blackLift: lift > 0 ? lift : nil)
                switch edge {
                case .left: slice.blendLeft = plan
                case .right: slice.blendRight = plan
                case .top: slice.blendTop = plan
                case .bottom: slice.blendBottom = plan
                default: break
                }
            }
            return slice
        }
    }

    private static func spanCanvasSize(of outputs: [RVData_Screen]) -> (width: Int, height: Int)? {
        let rects = outputs.filter { $0.hasBounds && $0.bounds.size.width > 0 }.map {
            CGRect(
                x: $0.bounds.origin.x, y: $0.bounds.origin.y,
                width: $0.bounds.size.width, height: $0.bounds.size.height
            )
        }
        guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else {
            return nil
        }
        return (Int(union.width), Int(union.height))
    }

    private static func outputCorrection(
        of output: RVData_Screen, screenName: String, warnings: inout [String]
    ) -> ProScreenPlan.OutputCorrection? {
        var correction = ProScreenPlan.OutputCorrection()
        if output.cornerPinningEnabled, output.hasCornerValues {
            func offset(_ point: RVData_Graphics.Point) -> ProScreenPlan.OutputCorrection.Offset? {
                (point.x == 0 && point.y == 0) ? nil
                    : ProScreenPlan.OutputCorrection.Offset(x: point.x, y: point.y)
            }
            correction.topLeft = offset(output.cornerValues.topLeft)
            correction.topRight = offset(output.cornerValues.topRight)
            correction.bottomLeft = offset(output.cornerValues.bottomLeft)
            correction.bottomRight = offset(output.cornerValues.bottomRight)
        }
        if output.colorEnabled, output.hasColorAdjustment {
            let adjustment = output.colorAdjustment
            correction.brightness = adjustment.brightness
            correction.contrast = adjustment.contrast
            correction.gamma = adjustment.gamma
            correction.blackLevel = adjustment.blackLevel
            correction.redLevel = adjustment.redLevel
            correction.greenLevel = adjustment.greenLevel
            correction.blueLevel = adjustment.blueLevel
        }
        correction.gamma += output.gamma
        correction.blackLevel += output.blackLevel
        correction.rotationDegrees = output.rotation
        return correction.isNeutral ? nil : correction
    }

    public static func mapLooks(_ workspace: RVData_ProPresenterWorkspace) -> (looks: [ProLookPlan], liveLookUUID: String?, warnings: [String]) {
        var warnings: [String] = []
        let looks = workspace.audienceLooks.map { look in
            ProLookPlan(
                proUUID: look.uuid.string.lowercased(),
                name: look.name.isEmpty ? "Look" : look.name,
                screenLooks: look.screenLooks.map { screenLook in
                    var layers: [String] = []
                    if screenLook.liveVideoEnabled { layers.append("videoInput") }
                    if screenLook.presentationBackgroundEnabled {
                        layers.append("loopingVideos")
                    }
                    if screenLook.presentationForegroundEnabled {
                        layers.append(contentsOf: ["slide", "videos", "stillGraphics"])
                    }
                    if screenLook.propsLayerEnabled || screenLook.propsEnabled { layers.append("overlays") }
                    if screenLook.messagesLayerEnabled { layers.append("alerts") }
                    if screenLook.announcementsEnabled {
                        warnings.append("look \"\(look.name)\": the announcements layer has no MxU room layer — Digital Signage routes per-screen in Screen Configuration — and was dropped")
                    }
                    return ProLookPlan.ScreenLook(
                        proScreenUUID: screenLook.proScreenUuid.string.lowercased(),
                        enabledLayers: layers,

                        slideThemeName: screenLook.hasTemplateDocumentFilePath
                            ? templateThemeName(screenLook.templateDocumentFilePath)
                            : nil,

                        maskProUUID: screenLook.hasMaskUuid
                            && !screenLook.maskUuid.string.isEmpty
                            ? screenLook.maskUuid.string.lowercased() : nil
                    )
                }
            )
        }
        var liveUUID: String?
        if workspace.hasLiveAudienceLook {
            let original = workspace.liveAudienceLook.originalLookUuid.string.lowercased()
            liveUUID = original.isEmpty ? workspace.liveAudienceLook.uuid.string.lowercased() : original
        }
        return (looks, liveUUID, warnings)
    }

    static func templateThemeName(_ url: RVData_URL) -> String? {
        var path: String?
        if case .absoluteString(let string)? = url.storage, !string.isEmpty {
            path = URL(string: string)?.path ?? string
        }
        if path == nil, case .local(let local)? = url.relativeFilePath, !local.path.isEmpty {
            path = local.path
        }
        if path == nil, case .relativePath(let relative)? = url.storage, !relative.isEmpty {
            path = relative
        }
        guard let path, !path.isEmpty else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let last = components.last else { return nil }

        if last == "Theme", components.count >= 2 {
            return components[components.count - 2]
        }
        return last
    }

    public static func mapCommunicationDevices(_ data: Data) -> (devices: [MIDIDevice], warnings: [String]) {
        struct Entry: Decodable {
            var name: String?
            var id: String?
            var reconnect: Bool?
            var parser: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return ([], ["CommunicationDevices was not readable and was skipped"])
        }
        var devices: [MIDIDevice] = []
        var warnings: [String] = []
        for entry in entries {
            let name = (entry.name?.isEmpty == false) ? entry.name! : "MIDI Device"
            guard let parserData = entry.parser.flatMap({ Data(base64Encoded: $0) }),
                  let xml = String(data: parserData, encoding: .utf16)
            else {
                warnings.append("device \"\(name)\": its parser payload was not readable and was skipped")
                continue
            }
            guard xml.contains("RVProtocolParserMIDI") else {
                warnings.append("device \"\(name)\": \(protocolName(inParserXML: xml)) devices have no MxU equivalent yet")
                continue
            }
            var device = MIDIDevice(
                id: entry.id.map { $0.lowercased() } ?? UUID().uuidString,
                name: name
            )
            let sources = endpointNames(attribute: "sources", inXML: xml)
            let destinations = endpointNames(attribute: "destinations", inXML: xml)
            device.sourceNames = sources.isEmpty ? nil : sources
            device.destinationNames = destinations.isEmpty ? nil : destinations

            switch (sources.isEmpty, destinations.isEmpty) {
            case (false, true): device.direction = .input
            case (true, false): device.direction = .output
            default: device.direction = nil
            }
            device.autoReconnect = entry.reconnect == true ? true : nil
            devices.append(device)
        }
        return (devices, warnings)
    }

    private static func protocolName(inParserXML xml: String) -> String {
        guard let range = xml.range(of: #"RVProtocolParser([A-Za-z0-9]+)"#, options: .regularExpression)
        else { return "this protocol's" }
        return String(xml[range].dropFirst("RVProtocolParser".count))
    }

    private static func endpointNames(attribute: String, inXML xml: String) -> [String] {
        guard let range = xml.range(
            of: attribute + #"="([^"]*)""#, options: .regularExpression
        ) else { return [] }
        let value = xml[range].dropFirst(attribute.count + 2).dropLast()
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func mapTimers(
        _ doc: RVData_TimersDocument, existing: [ProTimerSeed] = []
    ) -> [ProTimerPlan] {

        var existingIDsByName: [String: String] = [:]
        for seed in existing where existingIDsByName[seed.name.lowercased()] == nil {
            existingIDsByName[seed.name.lowercased()] = seed.id
        }
        return doc.timers.compactMap { timer in
            guard let mode = timerPlanMode(timer.configuration) else { return nil }
            let name = timer.name.isEmpty ? "Timer" : timer.name
            return ProTimerPlan(
                proUUID: timer.uuid.string.lowercased(),
                newID: existingIDsByName[name.lowercased()] ?? UUID().uuidString,
                name: name,
                mode: mode
            )
        }
    }

    static func timerPlanMode(_ configuration: RVData_Timer.Configuration) -> ProTimerPlan.Mode? {
        switch configuration.timerType {
        case .countdown(let countdown)?:
            return .countdown(seconds: countdown.duration)
        case .countdownToTime(let toTime)?:
            let seconds = Int(toTime.timeOfDay)
            var hour = (seconds / 3600) % 24
            if toTime.period == .pm, hour < 12 { hour += 12 }
            if toTime.period == .am, hour == 12 { hour = 0 }
            return .countdownToTime(hour: hour, minute: (seconds % 3600) / 60)
        case .elapsedTime(let elapsed)?:
            return .countUp(limitSeconds: elapsed.hasEndTime_p ? max(0, elapsed.endTime - elapsed.startTime) : 0)
        case .none:
            return nil
        }
    }
}
