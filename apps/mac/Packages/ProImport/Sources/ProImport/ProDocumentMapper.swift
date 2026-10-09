import AppKit
import Foundation
import PresenterCore

public typealias ProMediaWant = MediaWant

public struct ProMappedDocument: Sendable {
    public var presentation: Presentation
    public var mediaWants: [ProMediaWant]
    public var warnings: [String]

    public var groupHotKeys: [String: String] = [:]
}

public enum ProDocumentMapper {

    public static func map(
        _ doc: RVData_Presentation,
        fallbackName: String,
        timerIDsByProUUID: [String: String] = [:],
        timerIDsByName: [String: String] = [:]
    ) -> ProMappedDocument {
        var state = MapState()

        let name = doc.name.isEmpty ? fallbackName : doc.name

        let arrangementGroupIDs = Set(doc.arrangements.flatMap { arrangement in
            arrangement.groupIdentifiers.map { $0.string.lowercased() }
        })
        var sections: [PresentationSection] = []
        var groupOfCue: [String: String] = [:]
        var groupHotKeys: [String: String] = [:]
        for cueGroup in doc.cueGroups {
            let groupID = cueGroup.group.uuid.string.lowercased()
            if cueGroup.group.name.isEmpty, !arrangementGroupIDs.contains(groupID) { continue }
            sections.append(PresentationSection(
                id: groupID,
                name: cueGroup.group.name,
                colorHex: cueGroup.group.hasColor ? hexColor(cueGroup.group.color) : nil
            ))

            if cueGroup.group.hasHotKey, !cueGroup.group.name.isEmpty,
               let letter = hotKeyLetter(cueGroup.group.hotKey.code) {
                let key = GroupPalette.normalizedName(cueGroup.group.name)
                if groupHotKeys[key] == nil { groupHotKeys[key] = letter }
            }
            for cueID in cueGroup.cueIdentifiers {
                groupOfCue[cueID.string.lowercased()] = groupID
            }
        }

        let docTransition = doc.hasTransition
            ? transition(from: doc.transition, state: &state) : nil

        let cueByID = Dictionary(doc.cues.map { ($0.uuid.string.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var orderedCueIDs: [String] = []
        var seenCueIDs = Set<String>()
        for cueGroup in doc.cueGroups {
            for id in cueGroup.cueIdentifiers where seenCueIDs.insert(id.string.lowercased()).inserted {
                orderedCueIDs.append(id.string.lowercased())
            }
        }
        for cue in doc.cues where seenCueIDs.insert(cue.uuid.string.lowercased()).inserted {
            orderedCueIDs.append(cue.uuid.string.lowercased())
        }

        var slides: [Slide] = []
        var canvas: (width: Int, height: Int)?
        for cueID in orderedCueIDs {
            guard let cue = cueByID[cueID],
                  let slide = mapCue(
                    cue, groupOfCue: groupOfCue, timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName,
                    docTransition: docTransition, canvas: &canvas, state: &state
                  )
            else { continue }
            slides.append(slide)
        }
        if slides.isEmpty {
            slides = [Slide(id: UUID().uuidString, name: "", objects: [])]
        }

        sections = enforceContiguity(sections: &slides, mapped: sections, state: &state)

        let referenced = Set(slides.compactMap(\.sectionId))
        sections.removeAll { !referenced.contains($0.id) }

        var arrangements: [Arrangement] = []
        for arrangement in doc.arrangements {
            let ids = arrangement.groupIdentifiers.map { $0.string.lowercased() }
            let known = ids.filter { id in sections.contains { $0.id == id } }
            if known.count < ids.count {
                state.warn("arrangement \"\(arrangement.name)\" referenced \(ids.count - known.count) missing group(s)")
            }
            guard !known.isEmpty else { continue }
            arrangements.append(Arrangement(
                id: arrangement.uuid.string.lowercased(),
                name: arrangement.name,
                sectionIds: known
            ))
        }
        let selectedArrangement = doc.selectedArrangement.string.lowercased()
        let defaultArrangementId = arrangements.first { $0.id == selectedArrangement }?.id

        let originalKey = keyName(doc.hasMusic && doc.music.hasOriginal ? doc.music.original : nil)
            ?? normalizedKeyName(doc.hasMusic ? doc.music.originalMusicKey : "")
            ?? normalizedKeyName(doc.musicKey)
        let userKey = keyName(doc.hasMusic && doc.music.hasUser ? doc.music.user : nil)
            ?? normalizedKeyName(doc.hasMusic ? doc.music.userMusicKey : "")
        let musicKey = originalKey ?? userKey
        let displayKey = userKey == musicKey ? nil : userKey

        var ccli: CCLIInfo?
        if doc.hasCcli {
            let c = doc.ccli
            var info = CCLIInfo()
            if c.songNumber > 0 { info.songNumber = Int(c.songNumber) }
            if !c.songTitle.isEmpty { info.songTitle = c.songTitle }
            if !c.author.isEmpty { info.author = c.author }
            if !c.publisher.isEmpty { info.publisher = c.publisher }
            if c.copyrightYear > 0 { info.copyrightYear = Int(c.copyrightYear) }
            if info != CCLIInfo() { ccli = info }
        }

        var presentation = Presentation(
            id: doc.uuid.string.isEmpty ? UUID().uuidString : doc.uuid.string.lowercased(),
            name: name,
            presentationKind: .deck,
            themeId: "",
            slides: slides,
            canvasWidth: canvas.flatMap { $0 == (1920, 1080) ? nil : $0.width },
            canvasHeight: canvas.flatMap { $0 == (1920, 1080) ? nil : $0.height },
            sections: sections.isEmpty ? nil : sections,
            arrangements: arrangements.isEmpty ? nil : arrangements,
            defaultArrangementId: defaultArrangementId,
            ccli: ccli,
            musicKey: musicKey,
            displayKey: displayKey,

            origin: PresentationOrigin(.proPresenter, at: nil)
        )

        if case .slideShowDuration(let duration)? = doc.slideShow, duration > 0 {
            presentation.autoAdvance = AutoAdvance(delaySeconds: duration, loopToStart: true)
        }

        if doc.hasBackground, doc.background.isEnabled {
            switch doc.background.fill {
            case .color(let color)?:
                presentation.backgroundFill = ObjectFill(fillKind: .solid, colorHex: hexColor(color))
            case .gradient(let gradient)?:
                let stops = gradient.stops.map {
                    GradientStop(colorHex: hexColor($0.color), position: $0.position)
                }
                presentation.backgroundFill = ObjectFill(
                    fillKind: .linearGradient,
                    gradientAngleDegrees: gradient.angle,
                    gradientStops: stops
                )
            case nil:
                break
            }
        }
        return ProMappedDocument(
            presentation: presentation, mediaWants: state.wants,
            warnings: state.warnings, groupHotKeys: groupHotKeys)
    }

    public static func replacingMediaIDs(_ presentation: Presentation, with map: [String: String]) -> Presentation {
        var result = presentation

        func remap(_ id: String?) -> String? {
            guard let id, id.hasPrefix(placeholderPrefix) else { return id }
            return map[id]
        }
        func remap(_ cueMedia: CueMedia?) -> CueMedia? {
            guard var media = cueMedia else { return nil }
            guard let mapped = remap(media.mediaId) else { return nil }
            media.mediaId = mapped
            return media
        }
        func remap(_ fill: ObjectFill?) -> ObjectFill? {
            guard var fill else { return nil }
            if fill.mediaId != nil, remap(fill.mediaId) == nil { return nil }
            fill.mediaId = remap(fill.mediaId)
            return fill
        }

        result.background = remap(result.background)
        result.sections = result.sections.map { sections in
            sections.map { section in
                var section = section
                section.background = remap(section.background)
                return section
            }
        }
        result.slides = result.slides.map { slide in
            var slide = slide
            slide.background = remap(slide.background)

            slide.actions = slide.actions.map { actions in
                actions.compactMap { action in
                    var action = action
                    if let id = action.audioItemId, id.hasPrefix(placeholderPrefix) {
                        guard let mapped = map[id] else { return nil }
                        action.audioItemId = mapped
                    }
                    if let id = action.mediaId, id.hasPrefix(placeholderPrefix) {
                        guard let mapped = map[id] else { return nil }
                        action.mediaId = mapped
                    }
                    return action
                }
            }
            if slide.actions?.isEmpty == true { slide.actions = nil }
            slide.objects = slide.objects.compactMap { object in
                var object = object
                let fillLostItsMedia = object.fill?.fillKind == .media
                    && object.fill?.mediaId?.hasPrefix(placeholderPrefix) == true
                    && remap(object.fill?.mediaId) == nil
                object.fill = remap(object.fill)
                if var style = object.textStyle {
                    style.fill = remap(style.fill)
                    object.textStyle = style
                }

                if fillLostItsMedia, object.stroke == nil,
                   object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                return object
            }
            return slide
        }
        return result
    }

    public static let placeholderPrefix = "pro-media://"

    struct MapState {
        var wants: [ProMediaWant] = []
        var warnings: [String] = []
        var wantByUUID: [String: String] = [:]

        var inputBook = ProInputPlanBook()

        mutating func warn(_ message: String) {
            if !warnings.contains(message) { warnings.append(message) }
        }

        mutating func want(
            for media: RVData_Media, classification: MediaClassification? = nil
        ) -> String {
            let uuid = media.uuid.string.lowercased()
            if let existing = wantByUUID[uuid] {

                if let classification,
                   let index = wants.firstIndex(where: { $0.placeholderID == existing }),
                   wants[index].classification == nil {
                    wants[index].classification = classification
                }
                return existing
            }
            let placeholder = ProDocumentMapper.placeholderPrefix + (uuid.isEmpty ? UUID().uuidString : uuid)

            var absolute: String?
            if case .absoluteString(let string)? = media.url.storage, !string.isEmpty {
                absolute = URL(string: string)?.path
            }
            var relative: String?
            if case .local(let local)? = media.url.relativeFilePath, !local.path.isEmpty {
                relative = local.path
            } else if case .relativePath(let path)? = media.url.storage, !path.isEmpty {
                relative = path
            }
            var want = ProMediaWant(placeholderID: placeholder, absolutePath: absolute, relativePath: relative)
            want.classification = classification

            if case .video(let video)? = media.typeProperties, video.hasTransport {
                let transport = video.transport
                if transport.inPoint > 0 { want.inPoint = transport.inPoint }
                let out = transport.outPoint > 0 ? transport.outPoint : transport.endPoint
                if out > 0 { want.outPoint = out }
                if transport.playRate > 0, transport.playRate != 1 { want.playRate = transport.playRate }
                let fade = max(
                    transport.shouldFadeIn ? transport.fadeInDuration : 0,
                    transport.shouldFadeOut ? transport.fadeOutDuration : 0
                )
                if fade > 0 { want.fadeSeconds = fade }
            }

            if ProDocumentMapper.mediaLoops(media) { want.loops = true }
            wants.append(want)
            if !uuid.isEmpty { wantByUUID[uuid] = placeholder }
            return placeholder
        }
    }

    private static func mapCue(
        _ cue: RVData_Cue,
        groupOfCue: [String: String],
        timerIDsByProUUID: [String: String],
        timerIDsByName: [String: String] = [:],
        docTransition: Transition? = nil,
        canvas: inout (width: Int, height: Int)?,
        state: inout MapState
    ) -> Slide? {
        var slideAction: RVData_Action.SlideType?
        var cueMedia: CueMedia?
        var cueActionTransition: Transition?
        var slideActions: [SlideAction] = []
        var flattened: [String] = []

        for action in cue.actions {
            switch action.actionTypeData {
            case .slide(let slide):
                slideAction = slide
            case .media(let media):
                let element = media.element

                if case .audio(let audio)? = element.typeProperties {
                    var fire = SlideAction(id: UUID().uuidString, kind: .fireAudio)
                    fire.audioItemId = state.want(for: element)

                    if action.delayTime > 0 { fire.delaySeconds = action.delayTime }
                    if audio.hasTransport {
                        switch audio.transport.playbackBehavior {
                        case .loop, .loopForCount, .loopForTime: fire.audioRepeat = true
                        default: break
                        }
                    }
                    slideActions.append(fire)
                    continue
                }
                let loops = mediaLoops(element)
                let isVideo: Bool
                if case .video = element.typeProperties { isVideo = true } else { isVideo = false }

                let placeholder = state.want(
                    for: element,
                    classification: media.layerType == .background ? .background : .foreground
                )
                if !isVideo {
                    var fire = SlideAction(id: UUID().uuidString, kind: .fireMedia)
                    fire.mediaId = placeholder
                    if action.delayTime > 0 { fire.delaySeconds = action.delayTime }
                    slideActions.append(fire)
                    continue
                }

                let layer: CueMediaLayer = media.layerType == .background ? .loopingVideos : .videos
                cueMedia = CueMedia(mediaId: placeholder, layer: layer, loops: loops)
            case .transition(let t) where t.hasTransition:

                cueActionTransition = transition(from: t.transition, state: &state)
            case .none:
                continue
            default:

                if let steps = ProWorkspaceMapper.mapActionSteps(
                    action, context: "cue \"\(cue.name)\"",
                    timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName, state: &state
                ) {
                    slideActions.append(contentsOf: steps)
                } else {
                    let label = action.label.text.isEmpty ? action.name : action.label.text
                    flattened.append(label.isEmpty ? describeActionKind(action) : label)
                }
            }
        }

        let videoEndAnchored: Bool? = cueMedia?.layer == .videos ? true : nil
        var autoAdvance: AutoAdvance?
        switch (cue.completionTargetType, cue.completionActionType) {
        case (.none, _):
            break
        case (.next, .afterTime):
            autoAdvance = AutoAdvance(delaySeconds: max(cue.completionTime, 0), afterPlayback: videoEndAnchored)
        case (.first, .afterTime):
            autoAdvance = AutoAdvance(delaySeconds: max(cue.completionTime, 0), loopToStart: true, afterPlayback: videoEndAnchored)
        case (.next, .afterAction):
            autoAdvance = AutoAdvance(delaySeconds: 0, afterPlayback: true)
        case (.first, .afterAction):
            autoAdvance = AutoAdvance(delaySeconds: 0, loopToStart: true, afterPlayback: true)
        default:
            flattened.append("go to next timer")
        }

        guard let slideType = slideAction else {

            if cueMedia != nil || !slideActions.isEmpty {
                return Slide(id: cue.uuid.string.lowercased(), name: cue.name, objects: [],
                             background: cueMedia, sectionId: groupOfCue[cue.uuid.string.lowercased()],
                             actions: slideActions.isEmpty ? nil : slideActions,
                             autoAdvance: autoAdvance,
                             transition: cueActionTransition ?? docTransition)
            }
            state.warn("cue \"\(cue.name)\" had no slide content and was skipped")
            return nil
        }

        let slideTransition = cueActionTransition
            ?? (slideType.presentation.hasTransition
                ? transition(from: slideType.presentation.transition, state: &state)
                : docTransition)

        let base = slideType.presentation.baseSlide
        if canvas == nil, base.hasSize, base.size.width > 0 {
            canvas = (Int(base.size.width), Int(base.size.height))
        }

        var objects: [SlideObject] = []
        if base.drawsBackgroundColor, base.hasBackgroundColor {
            objects.append(SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: "Background Color", text: "",
                x: 0, y: 0,
                width: Double(canvas?.width ?? 1920), height: Double(canvas?.height ?? 1080),
                fill: ObjectFill(fillKind: .solid, colorHex: hexColor(base.backgroundColor))
            ))
        }

        var stepWarnings: [String] = []
        for wrapped in base.elements.reversed() {
            var mapped = mapElement(wrapped.element, state: &state)

            if var link = ProWorkspaceMapper.textLink(
                for: wrapped, timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, state: &state
            ) {
                if link.source == .videoCountdown {

                    link.showsVideoName = false
                }
                if mapped == nil {
                    mapped = ProWorkspaceMapper.emptyTextPlaceholder(wrapped.element, state: &state)
                }
                mapped?.objectKind = .text
                mapped?.textLink = link
            }
            guard var object = mapped else { continue }
            if wrapped.element.hidden { object.hidden = true }

            let steps = ProAnimationMapper.steps(for: wrapped, objectID: object.id, text: object.text, warnings: &stepWarnings)
            if !steps.isEmpty { object.animationSteps = steps }
            if let visibility = ProWorkspaceMapper.visibility(
                for: wrapped, timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, state: &state
            ) {
                object.visibilityMatch = visibility.match
                object.visibilityConditions = visibility.conditions
            }
            if object.hidden != true {
                warnOnNearFullBleed(
                    object,
                    canvas: CGSize(
                        width: Double(canvas?.width ?? 1920),
                        height: Double(canvas?.height ?? 1080)
                    ),
                    state: &state
                )
            }
            objects.append(object)
        }

        var notes: [String] = []
        if slideType.presentation.hasNotes,
           let text = attributedString(fromRTF: slideType.presentation.notes.rtfData)?.string,
           !text.isEmpty {
            notes.append(text)
        }
        if !flattened.isEmpty {
            notes.append("Flattened ProPresenter actions: \(flattened.joined(separator: ", "))")
        }
        for warning in stepWarnings {
            state.warn(warning)
            notes.append("ProPresenter \(warning)")
        }

        AnimationImportSupport.rigidifyMoves(&objects, canvas: CGSize(
            width: Double(canvas?.width ?? 1920), height: Double(canvas?.height ?? 1080)
        ))
        return Slide(
            id: cue.uuid.string.lowercased(),
            name: cue.name,
            objects: objects,
            background: cueMedia,
            sectionId: groupOfCue[cue.uuid.string.lowercased()],
            actions: slideActions.isEmpty ? nil : slideActions,
            notes: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            autoAdvance: autoAdvance,
            transition: slideTransition,
            animationOrder: ProAnimationMapper.animationOrder(base.elementBuildOrder, objects: objects)
        )
    }

    static func transition(from rv: RVData_Transition, state: inout MapState) -> Transition? {
        guard rv.hasEffect || rv.duration > 0 else { return nil }
        let name = rv.effect.name.trimmingCharacters(in: .whitespaces)
        let lowered = name.lowercased()
        let duration = rv.duration > 0 ? rv.duration : nil
        if lowered.isEmpty || lowered == "none" || lowered == "cut" {
            return Transition(transitionKind: .cut)
        }
        if lowered.contains("blur") {
            return Transition(transitionKind: .blurDissolve, durationSeconds: duration)
        }
        if lowered.contains("dissolve") {
            return Transition(transitionKind: .dissolve, durationSeconds: duration)
        }
        if lowered.contains("fade") {
            return Transition(transitionKind: .fadeBlack, durationSeconds: duration)
        }
        state.warn("transition \"\(name)\" has no MxU equivalent — imported as a dissolve")
        return Transition(transitionKind: .dissolve, durationSeconds: duration)
    }

    static func describeActionKind(_ action: RVData_Action) -> String {
        switch action.actionTypeData {
        case .transition: return "transition"
        case .effects: return "effects"
        case .timer: return "timer"
        case .clear, .clearGroup_p: return "clear"
        case .stage: return "stage layout"
        case .prop: return "prop"
        case .mask: return "mask"
        case .message: return "message"
        case .communication: return "device control"
        case .audienceLook: return "look"
        case .macro: return "macro"
        case .audioInput: return "audio input"
        case .transportControl: return "transport"
        default: return "action"
        }
    }

    private static func enforceContiguity(
        sections slides: inout [Slide],
        mapped: [PresentationSection],
        state: inout MapState
    ) -> [PresentationSection] {
        var result = mapped
        var completedRuns = Set<String>()  
        var runOriginal: String?           
        var runAssigned: String?           

        for index in slides.indices {
            guard let original = slides[index].sectionId else {
                if let previous = runOriginal { completedRuns.insert(previous) }
                runOriginal = nil
                runAssigned = nil
                continue
            }
            if original != runOriginal {
                if let previous = runOriginal { completedRuns.insert(previous) }
                runOriginal = original
                if completedRuns.contains(original), let source = result.first(where: { $0.id == original }) {
                    let clone = PresentationSection(id: UUID().uuidString, name: source.name, colorHex: source.colorHex)
                    result.append(clone)
                    runAssigned = clone.id
                    state.warn("group \"\(source.name)\" was split — its slides were not contiguous")
                } else {
                    runAssigned = original
                }
            }
            slides[index].sectionId = runAssigned
        }
        return result
    }

    static func mapElement(_ element: RVData_Graphics.Element, state: inout MapState) -> SlideObject? {
        let bounds = element.bounds
        let frame: (x: Double?, y: Double?, w: Double?, h: Double?) = element.hasBounds
            ? (bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height)
            : (nil, nil, nil, nil)

        let rotation = (-element.rotation).truncatingRemainder(dividingBy: 360)
        let opacity = normalizedOpacity(element.opacity)

        let attributed = element.hasText ? attributedString(fromRTF: element.text.rtfData) : nil

        var text = attributed?.string ?? ""
        if text.unicodeScalars.allSatisfy(Self.invisibleScalars.contains) { text = "" }

        if !text.isEmpty, !hasEnabledInkFill(element) || lineFillEnabled(element) {
            return textObject(element, text: text, attributed: attributed, frame: frame, rotation: rotation, opacity: opacity, state: &state)
        }

        let shape = shapeKind(of: element.path)
        let elementIsMedia = if case .media? = element.fill.fillType { true } else { false }

        var object = SlideObject(
            id: elementID(element), objectKind: .shape,
            name: elementName(
                element,
                fallback: !text.isEmpty ? "Text" : elementIsMedia ? "Media" : "Shape"),
            text: text,
            x: frame.x, y: frame.y, width: frame.w, height: frame.h,
            rotationDegrees: rotation == 0 ? nil : rotation,
            opacity: opacity == 1 ? nil : opacity,
            textStyle: text.isEmpty ? nil : textStyle(for: element, attributed: attributed, state: &state),
            shapeKind: shape.kind == .rectangle && shape.cornerRadius == nil ? nil : shape.kind,
            cornerRadius: shape.cornerRadius,
            pathData: shape.pathData,

            fill: lineFillEnabled(element) ? nil : objectFill(element, state: &state)
        )
        if element.hasStroke, element.stroke.enable {
            object.stroke = ObjectStroke(colorHex: hexColor(element.stroke.color), width: element.stroke.width)
        }
        if element.hasShadow, element.shadow.enable {
            object.shadow = objectShadow(element.shadow)
        }

        if !text.isEmpty, let attributed {
            let runs = styleRuns(
                from: attributed,
                rtfData: element.hasText ? element.text.rtfData : nil
            )
            if !runs.isEmpty { object.styleRuns = runs }
        }

        if case .media(let media)? = element.fill.fillType {
            let mapped = mapMediaEffects(of: media, context: "\"\(object.name)\"", state: &state)
            if let effects = mapped.effects { object.effects = effects }
            if mapped.alphaFactor != 1 {
                object.opacity = (object.opacity ?? 1) * mapped.alphaFactor
            }
            let flips = mediaFlips(of: media)
            if flips.horizontal || flips.vertical {
                if shape.kind == .rectangle, shape.cornerRadius == nil, text.isEmpty {
                    object.flipHorizontal = flips.horizontal ? true : nil
                    object.flipVertical = flips.vertical ? true : nil
                } else {
                    state.warn("\"\(object.name)\": its media fill was flipped in ProPresenter — fills have no flip yet, the media imported unflipped")
                }
            }
        }

        let fillIsInk = object.fill.map { $0.fillKind != FillKind.none } ?? false
        if !fillIsInk, object.stroke == nil, text.isEmpty {
            return nil
        }
        return object
    }

    private static func warnOnNearFullBleed(
        _ object: SlideObject,
        canvas: CGSize,
        state: inout MapState
    ) {
        guard let x = object.x, let y = object.y,
              let width = object.width, let height = object.height
        else { return }
        var frame = CGRect(x: x, y: y, width: width, height: height)
        if let degrees = object.rotationDegrees, degrees.truncatingRemainder(dividingBy: 360) != 0 {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let radians = degrees * .pi / 180
            let halfW = abs(frame.width / 2 * cos(radians)) + abs(frame.height / 2 * sin(radians))
            let halfH = abs(frame.width / 2 * sin(radians)) + abs(frame.height / 2 * cos(radians))
            frame = CGRect(x: center.x - halfW, y: center.y - halfH, width: halfW * 2, height: halfH * 2)
        }
        let gaps = [
            max(0, frame.minX), max(0, frame.minY),
            max(0, canvas.width - frame.maxX), max(0, canvas.height - frame.maxY),
        ]
        let worst = gaps.max() ?? 0

        guard worst <= 0.5, worst >= 0.01 else { return }
        state.warn(String(
            format: "\"%@\" misses the canvas edge by %.2f — a hairline of whatever is behind it may show",
            object.name, worst
        ))
    }

    private static func textObject(
        _ element: RVData_Graphics.Element,
        text: String,
        attributed: NSAttributedString?,
        frame: (x: Double?, y: Double?, w: Double?, h: Double?),
        rotation: Double,
        opacity: Double,
        state: inout MapState
    ) -> SlideObject {
        var style = textStyle(for: element, attributed: attributed, state: &state)

        if element.hasText, element.text.hasChordPro, element.text.chordPro.enabled {
            var chordStyle = style ?? TextStyle()
            chordStyle.showChords = true
            chordStyle.chordNotation = chordNotation(element.text.chordPro.notation)
            if element.text.chordPro.hasColor {
                chordStyle.chordColorHex = hexColor(element.text.chordPro.color)
            }
            style = chordStyle
        }
        var object = SlideObject(
            id: elementID(element), objectKind: .text, name: elementName(element, fallback: "Text"),
            text: text,
            x: frame.x, y: frame.y, width: frame.w, height: frame.h,
            rotationDegrees: rotation == 0 ? nil : rotation,
            opacity: opacity == 1 ? nil : opacity,
            textStyle: style
        )
        let chords = chordPlacements(element, plainText: text)
        if !chords.isEmpty { object.chords = chords }

        if let attributed {
            let runs = styleRuns(
                from: attributed,
                rtfData: element.hasText ? element.text.rtfData : nil
            )
            if !runs.isEmpty { object.styleRuns = runs }
        }
        return object
    }

    static func styleRuns(from attributed: NSAttributedString, rtfData: Data? = nil) -> [TextStyleRun] {
        guard attributed.length > 0 else { return [] }
        let text = attributed.string as NSString
        var lineRanges: [NSRange] = []
        var position = 0
        while position < text.length {
            let lineRange = text.lineRange(for: NSRange(location: position, length: 0))
            lineRanges.append(lineRange)
            position = NSMaxRange(lineRange)
        }

        func content(of lineRange: NSRange) -> NSRange {
            var content = lineRange
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A {
                content.length -= 1
            }
            return content
        }

        func span(_ overlap: NSRange, in content: NSRange, line: String) -> (column: Int, length: Int)? {
            func characters(toUTF16 offset: Int) -> Int {
                let clamped = min(max(0, offset), line.utf16.count)
                let utf16Index = line.utf16.index(line.utf16.startIndex, offsetBy: clamped)
                return String.Index(utf16Index, within: line)
                    .map { line.distance(from: line.startIndex, to: $0) } ?? line.count
            }
            let column = characters(toUTF16: overlap.location - content.location)
            let end = characters(toUTF16: overlap.location + overlap.length - content.location)
            guard end > column else { return nil }
            return (column, end - column)
        }

        var runs: [TextStyleRun] = []
        func collect(_ key: NSAttributedString.Key, into assign: (inout TextStyleRun) -> Void) {
            attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                guard let style = value as? Int, style != 0 else { return }
                for (lineIndex, lineRange) in lineRanges.enumerated() {
                    let content = content(of: lineRange)
                    let overlap = NSIntersectionRange(content, range)
                    guard overlap.length > 0 else { continue }
                    let line = text.substring(with: content)
                    guard let (column, length) = span(overlap, in: content, line: line) else { continue }
                    var run = TextStyleRun(line: lineIndex, column: column, length: length)
                    assign(&run)
                    runs.append(run)
                }
            }
        }
        collect(.underlineStyle) { $0.underline = true }
        collect(.strikethroughStyle) { $0.strikethrough = true }

        let rtfText = rtfData.map { String(decoding: $0, as: UTF8.self) }
        for (lineIndex, lineRange) in lineRanges.enumerated() {
            let content = content(of: lineRange)
            guard content.length > 0 else { continue }
            let line = text.substring(with: content)
            let leading = attributed.attributes(at: content.location, effectiveRange: nil)
            let leadingFont = leading[.font] as? NSFont
            let leadingColor = (leading[.foregroundColor] as? NSColor).map(hexColor)
            let leadingKern = (leading[.kern] as? NSNumber)?.doubleValue ?? 0
            attributed.enumerateAttributes(in: content) { attrs, range, _ in

                let fragment = text.substring(with: range)
                guard !fragment.unicodeScalars.allSatisfy(Self.invisibleScalars.contains) else { return }
                guard let (column, length) = span(range, in: content, line: line) else { return }

                var run = TextStyleRun(line: lineIndex, column: column, length: length)
                if let font = attrs[.font] as? NSFont {
                    if let base = leadingFont, Double(font.pointSize) != Double(base.pointSize) {
                        run.fontSize = Double(font.pointSize)
                    }
                    if font.fontName != leadingFont?.fontName,
                       rtfText?.contains("\(font.fontName);") == true {
                        run.fontName = font.fontName
                    }
                }
                if let color = (attrs[.foregroundColor] as? NSColor).map(hexColor),
                   color != leadingColor {
                    run.colorHex = color
                }
                let kern = (attrs[.kern] as? NSNumber)?.doubleValue ?? 0
                if kern != leadingKern { run.tracking = kern }
                if let background = attrs[.backgroundColor] as? NSColor {
                    run.highlightColorHex = hexColor(background)
                }
                if run != TextStyleRun(line: lineIndex, column: column, length: length) {
                    runs.append(run)
                }
            }
        }
        return runs.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    static func chordPlacements(_ element: RVData_Graphics.Element, plainText: String) -> [ChordPlacement] {
        guard element.hasText else { return [] }
        let runs = element.text.attributes.customAttributes.compactMap { attr -> (offset: Int, symbol: String)? in
            guard case .chord(let symbol)? = attr.attribute,
                  !symbol.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return (Int(attr.range.start), symbol.trimmingCharacters(in: .whitespaces))
        }
        guard !runs.isEmpty else { return [] }

        let lines = plainText.components(separatedBy: "\n")
        var lineStartUTF16: [Int] = []
        var running = 0
        for line in lines {
            lineStartUTF16.append(running)
            running += line.utf16.count + 1  
        }
        return runs.map { run in
            let lineIndex = (lineStartUTF16.lastIndex { $0 <= run.offset }) ?? 0
            let line = lines[lineIndex]
            let within = min(max(0, run.offset - lineStartUTF16[lineIndex]), line.utf16.count)
            let utf16Index = line.utf16.index(line.utf16.startIndex, offsetBy: within)
            let column = String.Index(utf16Index, within: line)
                .map { line.distance(from: line.startIndex, to: $0) } ?? line.count
            return ChordPlacement(line: lineIndex, column: column, symbol: run.symbol)
        }
        .sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    static func chordNotation(_ notation: RVData_Graphics.Text.ChordPro.Notation) -> ChordNotation? {
        switch notation {
        case .chords: return nil  
        case .numbers: return .numbers
        case .numerals: return .numerals
        case .doReMi: return .doReMi
        case .UNRECOGNIZED: return nil
        }
    }

    static func keyName(_ scale: RVData_MusicKeyScale?) -> String? {
        guard let scale else { return nil }
        let names: [RVData_MusicKeyScale.MusicKey: String] = [
            .aFlat: "Ab", .a: "A", .aSharp: "A#",
            .bFlat: "Bb", .b: "B", .bSharp: "B#",
            .cFlat: "Cb", .c: "C", .cSharp: "C#",
            .dFlat: "Db", .d: "D", .dSharp: "D#",
            .eFlat: "Eb", .e: "E", .eSharp: "E#",
            .fFlat: "Fb", .f: "F", .fSharp: "F#",
            .gFlat: "Gb", .g: "G", .gSharp: "G#",
        ]
        guard let name = names[scale.musicKey] else { return nil }
        return scale.musicScale == .minor ? name + "m" : name
    }

    static func normalizedKeyName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, ChordMath.parseKey(trimmed) != nil else { return nil }
        return trimmed
    }

    private static func hasEnabledInkFill(_ element: RVData_Graphics.Element) -> Bool {
        guard element.hasFill, element.fill.enable else { return false }
        switch element.fill.fillType {
        case .color(let color)?: return color.alpha > 0
        case .gradient?: return true
        default: return false
        }
    }

    private static func lineFillEnabled(_ element: RVData_Graphics.Element) -> Bool {
        guard case .textLineMask(let mask)? = element.mask else { return false }
        return mask.enabled
    }

    static func textStyle(
        for element: RVData_Graphics.Element,
        attributed: NSAttributedString?,
        state: inout MapState
    ) -> TextStyle? {
        let attrs = element.text.attributes
        var style = TextStyle()

        if attrs.hasFont, !attrs.font.name.isEmpty { style.fontName = attrs.font.name }
        if attrs.hasFont, attrs.font.size > 0 { style.fontSize = attrs.font.size }
        if case .textSolidFill(let color)? = attrs.fill { style.colorHex = hexColor(color) }
        if attrs.kerning != 0 { style.tracking = attrs.kerning }
        if attrs.hasParagraphStyle {
            switch attrs.paragraphStyle.alignment {
            case .left, .natural: style.horizontalAlignment = .left
            case .right: style.horizontalAlignment = .right
            case .center: style.horizontalAlignment = .center
            case .justified, .UNRECOGNIZED: break
            }
            let multiple = attrs.paragraphStyle.lineHeightMultiple
            if multiple > 0, multiple != 1 { style.lineHeightMultiple = multiple }

            let paragraph = attrs.paragraphStyle
            let firstLineDelta = paragraph.firstLineHeadIndent - paragraph.headIndent
            if firstLineDelta != 0 { style.firstLineIndent = firstLineDelta }
            if paragraph.headIndent != 0 { style.leftIndent = paragraph.headIndent }
            if paragraph.tailIndent < 0 {

                style.rightIndent = -paragraph.tailIndent
            } else if paragraph.tailIndent > 0 {
                state.warn("absolute right-edge indent (\(paragraph.tailIndent)) is not supported — the line width follows the box")
            }
            if paragraph.paragraphSpacing > 0 { style.paragraphSpacing = paragraph.paragraphSpacing }
            if paragraph.paragraphSpacingBefore > 0 {
                state.warn("space-before-paragraph (\(paragraph.paragraphSpacingBefore)) is not supported — only space after carries")
            }
        }

        if element.hasText, element.text.hasMargins {
            let margins = element.text.margins
            if margins.top != 0 { style.insetTop = margins.top }
            if margins.left != 0 { style.insetLeft = margins.left }
            if margins.bottom != 0 { style.insetBottom = margins.bottom }
            if margins.right != 0 { style.insetRight = margins.right }
        }

        switch element.text.verticalAlignment {
        case .top: style.verticalAlignment = .top
        case .middle: style.verticalAlignment = .middle
        case .bottom, .UNRECOGNIZED: style.verticalAlignment = .bottom
        }
        if attrs.capitalization == .allCaps { style.textTransform = .uppercase }

        if attrs.hasUnderlineStyle, attrs.underlineStyle.style != .none { style.underline = true }
        if attrs.hasStrikethroughStyle, attrs.strikethroughStyle.style != .none { style.strikethrough = true }
        switch element.text.scaleBehavior {
        case .scaleFontDown, .scaleFontUpDown: style.autoShrink = true
        default: break
        }
        if attrs.strokeWidth > 0 {
            style.outline = ObjectStroke(colorHex: hexColor(attrs.strokeColor), width: attrs.strokeWidth)
        }
        if element.hasShadow, element.shadow.enable {
            style.shadow = objectShadow(element.shadow)
        }
        if case .mediaFill(let mediaFill)? = attrs.fill {
            var fill = ObjectFill(fillKind: .media)
            fill.mediaId = state.want(for: mediaFill.media)
            style.fill = fill
        }

        if case .textLineMask(let mask)? = element.mask, mask.enabled,
           let fill = objectFill(element, state: &state),
           fill.fillKind == .solid || fill.fillKind == .linearGradient {
            let widthMode: TextLineFillWidthMode? = switch mask.maskStyle {
            case .fullWidth, .UNRECOGNIZED: nil  
            case .lineWidth: .lineWidth
            case .maxLineWidth: .maxLineWidth
            }
            style.lineFill = TextLineFill(
                fill: fill,
                widthMode: widthMode,
                verticalPadding: mask.heightOffset == 0 ? nil : mask.heightOffset,
                horizontalPadding: mask.widthOffset == 0 ? nil : mask.widthOffset,
                verticalOffset: mask.verticalOffset == 0 ? nil : mask.verticalOffset,
                horizontalOffset: mask.horizontalOffset == 0 ? nil : mask.horizontalOffset
            )
        }
        if let attributed {
            style.lineStyles = lineOverrides(
                attributed, baseSize: style.fontSize, baseColorHex: style.colorHex,
                baseFontName: style.fontName,
                baseFirstLineIndent: style.firstLineIndent,
                baseLeftIndent: style.leftIndent,
                baseRightIndent: style.rightIndent,
                rtfData: element.hasText ? element.text.rtfData : nil
            )
        }
        return style == TextStyle() ? nil : style
    }

    private static func lineOverrides(
        _ attributed: NSAttributedString,
        baseSize: Double?,
        baseColorHex: String?,
        baseFontName: String? = nil,
        baseFirstLineIndent: Double?,
        baseLeftIndent: Double?,
        baseRightIndent: Double?,
        rtfData: Data? = nil
    ) -> [LineStyleOverride]? {
        var overrides: [LineStyleOverride] = []
        let lines = attributed.string.components(separatedBy: "\n")
        let rtfText = rtfData.map { String(decoding: $0, as: UTF8.self) }

        var lineFonts: [Int: String] = [:]
        var scan = 0
        for (index, line) in lines.enumerated() {
            defer { scan += line.count + 1 }
            guard !line.isEmpty, scan < attributed.length else { continue }
            if let font = attributed.attributes(at: scan, effectiveRange: nil)[.font] as? NSFont {
                lineFonts[index] = font.fontName
            }
        }
        let referenceFont: String? = {
            let distinct = Set(lineFonts.values)
            guard distinct.count > 1 else { return nil }
            if let base = baseFontName, distinct.contains(base) { return base }
            var counts: [String: Int] = [:]
            for name in lineFonts.values { counts[name, default: 0] += 1 }
            return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }()

        var location = 0
        for (index, line) in lines.enumerated() {
            defer { location += line.count + 1 }
            guard !line.isEmpty, location < attributed.length else { continue }
            let attrs = attributed.attributes(at: location, effectiveRange: nil)
            var override = LineStyleOverride(lineIndex: index)
            if let font = attrs[.font] as? NSFont, let base = baseSize, Double(font.pointSize) != base {
                override.fontSize = Double(font.pointSize)
            }

            if let reference = referenceFont, let name = lineFonts[index],
               name != reference,
               rtfText?.contains("\(name);") == true {
                override.fontName = name
            }
            if let color = attrs[.foregroundColor] as? NSColor {
                let hex = hexColor(color)
                if let base = baseColorHex, hex != base { override.colorHex = hex }
            }
            if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {

                let first = Double(paragraph.firstLineHeadIndent - paragraph.headIndent)
                if first != (baseFirstLineIndent ?? 0) { override.firstLineIndent = first }
                let left = Double(paragraph.headIndent)
                if left != (baseLeftIndent ?? 0) { override.leftIndent = left }
                if paragraph.tailIndent <= 0 {
                    let right = Double(-paragraph.tailIndent)
                    if right != (baseRightIndent ?? 0) { override.rightIndent = right }
                }
            }
            if override != LineStyleOverride(lineIndex: index) {
                overrides.append(override)
            }
        }
        return overrides.isEmpty ? nil : overrides
    }

    private struct MappedShape {
        var kind: ShapeKind
        var cornerRadius: Double?
        var pathData: String?
    }

    private static func shapeKind(of path: RVData_Graphics.Path) -> MappedShape {
        switch path.shape.type {
        case .rectangle, .unknown:
            if case .roundedRectangle(let rounded)? = path.shape.additionalData, rounded.roundness > 0 {
                return MappedShape(kind: .roundedRectangle, cornerRadius: rounded.roundness)
            }

            if path.points.isEmpty || isUnitRectangle(path) {
                return MappedShape(kind: .rectangle)
            }
            return MappedShape(kind: .path, pathData: svgPath(path))
        case .ellipse:
            return MappedShape(kind: .ellipse)
        default:
            return MappedShape(kind: .path, pathData: svgPath(path))
        }
    }

    private static func isUnitRectangle(_ path: RVData_Graphics.Path) -> Bool {
        guard path.closed, path.points.count == 4 else { return false }
        let corners: Set<[Double]> = [[0, 0], [1, 0], [1, 1], [0, 1]]
        for point in path.points {
            guard !point.curved,
                  corners.contains([point.point.x.rounded(), point.point.y.rounded()]),
                  point.q0 == point.point || !point.hasQ0,
                  point.q1 == point.point || !point.hasQ1
            else { return false }
        }
        return true
    }

    private static func svgPath(_ path: RVData_Graphics.Path) -> String? {
        let points = path.points
        guard points.count >= 2 else { return nil }
        func fmt(_ value: Double) -> String {
            String(format: "%.4f", min(max(value, -4), 4))
        }
        func coord(_ point: RVData_Graphics.Point) -> String { "\(fmt(point.x)) \(fmt(point.y))" }

        var commands = ["M \(coord(points[0].point))"]
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let c1 = previous.hasQ1 ? previous.q1 : previous.point
            let c2 = current.hasQ0 ? current.q0 : current.point
            commands.append("C \(coord(c1)) \(coord(c2)) \(coord(current.point))")
        }
        if path.closed, let first = points.first, let last = points.last {
            let c1 = last.hasQ1 ? last.q1 : last.point
            let c2 = first.hasQ0 ? first.q0 : first.point
            commands.append("C \(coord(c1)) \(coord(c2)) \(coord(first.point))")
            commands.append("Z")
        }
        return commands.joined(separator: " ")
    }

    private static func objectFill(_ element: RVData_Graphics.Element, state: inout MapState) -> ObjectFill? {
        guard element.hasFill else { return nil }
        switch element.fill.fillType {

        case .color(let color)? where element.fill.enable:
            guard color.alpha > 0 else { return ObjectFill(fillKind: .none) }
            return ObjectFill(fillKind: .solid, colorHex: hexColor(color))
        case .gradient(let gradient)? where element.fill.enable:
            let stops = gradient.stops.map {
                GradientStop(colorHex: hexColor($0.color), position: $0.position)
            }
            return ObjectFill(fillKind: .linearGradient, gradientAngleDegrees: gradient.angle, gradientStops: stops)
        case .media(let media)?:

            if case .liveVideo(let live)? = media.typeProperties {
                let device = live.liveVideo.videoDevice
                let scale = live.hasDrawing ? scaleMode(live.drawing.scaleBehavior) : nil
                if state.inputBook.isEnabled {
                    return ObjectFill(
                        fillKind: .media,
                        mediaScaleMode: scale,
                        liveInputId: state.inputBook.id(for: device)
                    )
                }
                let mapped = ProInputPlanBook.device(device)
                return ObjectFill(
                    fillKind: .media,
                    mediaScaleMode: scale,
                    captureSourceKind: mapped.kind,
                    captureSourceId: mapped.sourceId
                )
            }
            let elementSize = element.hasBounds
                ? CGSize(width: element.bounds.size.width, height: element.bounds.size.height) : nil
            let custom = customSourceRect(of: media, elementSize: elementSize)
            return ObjectFill(
                fillKind: .media,
                mediaId: state.want(for: media),
                mediaScaleMode: scaleMode(scaleBehavior(of: media)) ?? (custom != nil ? .stretch : nil),
                mediaSourceRect: mediaSourceRect(of: media) ?? custom,
                loops: mediaLoops(media) ? true : nil
            )
        default:
            return ObjectFill(fillKind: .none)
        }
    }

    static func scaleBehavior(of media: RVData_Media) -> RVData_Media.ScaleBehavior {
        switch media.typeProperties {
        case .image(let image)?: return image.drawing.scaleBehavior
        case .video(let video)?: return video.drawing.scaleBehavior
        default: return .fit
        }
    }

    static func scaleMode(_ behavior: RVData_Media.ScaleBehavior) -> MediaScaleMode? {
        switch behavior {
        case .fit: return .fit
        case .stretch: return .stretch
        case .fill: return nil  
        default: return nil
        }
    }

    static func drawing(of media: RVData_Media) -> RVData_Media.DrawingProperties? {
        switch media.typeProperties {
        case .image(let image)?: return image.hasDrawing ? image.drawing : nil
        case .video(let video)?: return video.hasDrawing ? video.drawing : nil
        default: return nil
        }
    }

    static func mediaFlips(of media: RVData_Media) -> (horizontal: Bool, vertical: Bool) {
        guard let drawing = drawing(of: media) else { return (false, false) }
        return (drawing.flippedHorizontally, drawing.flippedVertically)
    }

    static func customSourceRect(of media: RVData_Media, elementSize: CGSize?) -> MediaSourceRect? {
        guard let drawing = drawing(of: media), let elementSize,
              drawing.scaleBehavior == .custom, drawing.hasCustomImageBounds
        else { return nil }
        let bounds = drawing.customImageBounds
        guard bounds.size.width > 0, bounds.size.height > 0,
              elementSize.width > 0, elementSize.height > 0
        else { return nil }
        let x = max(0, (0 - bounds.origin.x) / bounds.size.width)
        let y = max(0, (0 - bounds.origin.y) / bounds.size.height)
        let maxX = min(1, (elementSize.width - bounds.origin.x) / bounds.size.width)
        let maxY = min(1, (elementSize.height - bounds.origin.y) / bounds.size.height)
        let width = maxX - x
        let height = maxY - y
        guard width > 0, height > 0,
              x.isFinite, y.isFinite, width.isFinite, height.isFinite
        else { return nil }
        if x == 0, y == 0, width == 1, height == 1 { return nil }
        return MediaSourceRect(x: x, y: y, width: width, height: height)
    }

    static func mapMediaEffects(
        of media: RVData_Media, context: String, state: inout MapState
    ) -> (effects: [Effect]?, alphaFactor: Double) {
        guard let drawing = drawing(of: media), !drawing.effects.isEmpty else { return (nil, 1) }
        var chain: [Effect] = []
        var alpha = 1.0
        for effect in drawing.effects where effect.enabled {
            func variable(_ name: String) -> Double? {
                for candidate in effect.variables where candidate.name == name {
                    switch candidate.type {
                    case .int(let value)?: return Double(value.value)
                    case .float(let value)?: return Double(value.value)
                    case .double(let value)?: return value.value
                    default: return nil
                    }
                }
                return nil
            }
            switch effect.name.lowercased() {
            case "adjust color":
                var mapped = Effect(effectKind: .colorAdjust)
                mapped.brightness = variable("brightness") ?? 0
                mapped.contrast = (variable("contrast") ?? 1) - 1
                mapped.saturation = variable("saturation") ?? 1
                mapped.hue = variable("hue") ?? 0
                let neutral = mapped.brightness == 0 && mapped.contrast == 0
                    && mapped.saturation == 1 && mapped.hue == 0
                if !neutral { chain.append(mapped) }
            case "adjust alpha":
                alpha *= min(max(variable("amount") ?? 1, 0), 1)
            case "blur":
                var mapped = Effect(effectKind: .blur)
                mapped.radius = variable("amount") ?? variable("radius") ?? 0
                if (mapped.radius ?? 0) > 0 { chain.append(mapped) }
            default:
                state.warn("\(context): effect \"\(effect.name)\" has no MxU equivalent and was dropped")
            }
        }
        return (chain.isEmpty ? nil : chain, alpha)
    }

    static func mediaSourceRect(of media: RVData_Media) -> MediaSourceRect? {
        guard let drawing = drawing(of: media), drawing.cropEnable, drawing.hasNaturalSize else { return nil }
        let size = drawing.naturalSize
        guard size.width > 0, size.height > 0 else { return nil }

        let insets = drawing.cropInsets
        let x = insets.left / size.width
        let y = insets.top / size.height
        let width = (size.width - insets.left - insets.right) / size.width
        let height = (size.height - insets.top - insets.bottom) / size.height
        guard width > 0, height > 0, x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        if x == 0, y == 0, width == 1, height == 1 { return nil }
        return MediaSourceRect(x: x, y: y, width: width, height: height)
    }

    static func mediaLoops(_ media: RVData_Media) -> Bool {
        guard case .video(let video)? = media.typeProperties else { return false }
        switch video.transport.playbackBehavior {
        case .loop, .loopForCount, .loopForTime: return true
        default: return false
        }
    }

    static let invisibleScalars = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}"))

    static func normalizedOpacity(_ raw: Double) -> Double {
        let scaled = raw > 1 ? raw / 100 : raw
        return min(max(scaled, 0), 1)
    }

    private static func objectShadow(_ shadow: RVData_Graphics.Shadow) -> ObjectShadow {

        let radians = shadow.angle * .pi / 180
        var color = shadow.color
        color.alpha = Float(Double(color.alpha) * (shadow.opacity == 0 ? 1 : normalizedOpacity(shadow.opacity)))
        return ObjectShadow(
            colorHex: hexColor(color),
            blurRadius: shadow.radius,
            offsetX: (cos(radians) * shadow.offset).rounded(toPlaces: 2),
            offsetY: (-sin(radians) * shadow.offset).rounded(toPlaces: 2)
        )
    }

    static func hotKeyLetter(_ code: RVData_KeyCode) -> String? {
        let raw = code.rawValue
        guard (1 ... 26).contains(raw), let scalar = UnicodeScalar(96 + raw) else { return nil }
        return String(Character(scalar))
    }

    static func hexColor(_ color: RVData_Color) -> String {
        func channel(_ value: Float) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X%02X",
            channel(color.red), channel(color.green), channel(color.blue), channel(color.alpha)
        )
    }

    private static func hexColor(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X%02X",
            channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent), channel(rgb.alphaComponent)
        )
    }

    private static func elementID(_ element: RVData_Graphics.Element) -> String {
        element.uuid.string.isEmpty ? UUID().uuidString : element.uuid.string.lowercased()
    }

    private static func elementName(_ element: RVData_Graphics.Element, fallback: String) -> String {
        element.name.isEmpty ? fallback : element.name
    }

    static func attributedString(fromRTF data: Data) -> NSAttributedString? {
        guard !data.isEmpty else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
