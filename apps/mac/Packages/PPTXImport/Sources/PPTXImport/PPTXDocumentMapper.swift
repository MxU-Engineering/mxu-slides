import AppKit
import Foundation
import PresenterCore

struct PPTXMappedDocument: Sendable {
    var presentation: Presentation
    var mediaWants: [MediaWant]
    var warnings: [String]

    var missingFonts: [String]

    var bakes: [TextureBake]
}

enum TextureBakeKind: Sendable, Equatable {

    case texture(sourcePath: String, alpha: Double, scaleX: Double, scaleY: Double, tiled: Bool)

    case pattern(preset: String, foregroundHex: String, backgroundHex: String)
}

struct TextureBake: Sendable, Equatable {
    var placeholderID: String
    var kind: TextureBakeKind

    var k: Double
}

enum PPTXDocumentMapper {

    static let placeholderPrefix = "pptx-media://"

    struct MapState {
        var wants: [MediaWant] = []
        var bakes: [TextureBake] = []
        var warnings: [String] = []
        var missingFonts: [String] = []
        var wantByPath: [String: String] = [:]
        var nextWantIndex = 1
        var fontNameCache: [String: String] = [:]

        mutating func bake(_ bake: (String) -> TextureBake) -> String {
            let placeholder = PPTXDocumentMapper.placeholderPrefix + String(nextWantIndex)
            nextWantIndex += 1
            bakes.append(bake(placeholder))
            return placeholder
        }

        mutating func warn(_ message: String) {
            if !warnings.contains(message) { warnings.append(message) }
        }

        mutating func want(forPath path: String) -> String {
            if let existing = wantByPath[path] { return existing }
            let placeholder = PPTXDocumentMapper.placeholderPrefix + String(nextWantIndex)
            nextWantIndex += 1
            wants.append(MediaWant(placeholderID: placeholder, absolutePath: path, relativePath: nil))
            wantByPath[path] = placeholder
            return placeholder
        }
    }

    static func map(_ deck: PPTXDeck, fallbackName: String, sourceID: String) -> PPTXMappedDocument {
        var state = MapState()
        for warning in deck.warnings { state.warn(warning) }

        let heightEMU = deck.slideHeightEMU > 0 ? deck.slideHeightEMU : 6_858_000
        let k = 1080 / (heightEMU / 12700)
        func scene(_ emu: Double) -> Double { emu * 1080 / heightEMU }
        let canvasWidth = Int(scene(deck.slideWidthEMU).rounded())
        let canvasHeight = 1080

        var slides: [Slide] = []
        for pptxSlide in deck.slides {
            slides.append(mapSlide(
                pptxSlide, scene: scene, k: k,
                canvasWidth: Double(canvasWidth), canvasHeight: Double(canvasHeight),
                state: &state))
        }
        if slides.isEmpty {
            slides = [Slide(id: UUID().uuidString, name: "", objects: [])]
        }

        var sections: [PresentationSection] = []
        for section in deck.sections {
            let valid = section.slideIndexes.filter { slides.indices.contains($0) }
            guard !valid.isEmpty else { continue }
            sections.append(PresentationSection(id: section.id, name: section.name))
            for index in valid { slides[index].sectionId = section.id }
        }

        var presentationBackgroundFill: ObjectFill?
        let slideFills = slides.map(\.backgroundFill)
        if let first = slideFills.first ?? nil, slideFills.allSatisfy({ $0 == first }) {
            presentationBackgroundFill = first
            for index in slides.indices { slides[index].backgroundFill = nil }
        }

        let presentation = Presentation(
            id: sourceID,
            name: fallbackName,
            presentationKind: .deck,
            themeId: "",
            slides: slides,
            canvasWidth: (canvasWidth, canvasHeight) == (1920, 1080) ? nil : canvasWidth,
            canvasHeight: (canvasWidth, canvasHeight) == (1920, 1080) ? nil : canvasHeight,
            backgroundFill: presentationBackgroundFill,
            sections: sections.isEmpty ? nil : sections
        )
        return PPTXMappedDocument(
            presentation: presentation, mediaWants: state.wants,
            warnings: state.warnings, missingFonts: state.missingFonts,
            bakes: state.bakes)
    }

    static func replacingMediaIDs(_ presentation: Presentation, with map: [String: String]) -> Presentation {
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

    private static func mapSlide(
        _ slide: PPTXSlide, scene: (Double) -> Double, k: Double,
        canvasWidth: Double, canvasHeight: Double, state: inout MapState
    ) -> Slide {
        var objects: [SlideObject] = []
        var backgroundFill: ObjectFill?

        func backdropObject(_ mediaId: String) -> SlideObject {
            SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: "Background", text: "",
                x: 0, y: 0, width: canvasWidth, height: canvasHeight,
                fill: ObjectFill(
                    fillKind: .media, mediaId: mediaId, mediaScaleMode: .stretch))
        }
        switch slide.backgroundFill {
        case .solid?, .gradient?:
            backgroundFill = objectFill(slide.backgroundFill, state: &state)
        case .blip(let path)?:
            objects.append(backdropObject(state.want(forPath: path)))
        case .blipTiled(let path, let alpha, let sx, let sy, let tiled)?:

            let placeholder = state.bake { id in
                TextureBake(
                    placeholderID: id,
                    kind: .texture(sourcePath: path, alpha: alpha, scaleX: sx, scaleY: sy, tiled: tiled),
                    k: k)
            }
            objects.append(backdropObject(placeholder))
        case .pattern(let preset, let fg, let bg)?:
            if TextureBaker.structuralPatterns.contains(preset) {

                let placeholder = state.bake { id in
                    TextureBake(
                        placeholderID: id,
                        kind: .pattern(preset: preset, foregroundHex: fg, backgroundHex: bg),
                        k: k)
                }
                objects.append(backdropObject(placeholder))
            } else {
                state.warn("pattern fills are approximated as a blend of their two colors")
                backgroundFill = ObjectFill(fillKind: .solid, colorHex: rgba(Self.patternBlend(preset, fg, bg)))
            }
        case PPTXFill.noFill?, nil:
            break
        }

        var actions: [SlideAction] = []
        var objectIDsByShape: [Int: String] = [:]
        for shape in slide.shapes {

            if shape.kind == .picture, shape.mediaKind == .audio {
                guard let path = shape.mediaPath else { continue }
                state.warn("slide audio imported as a play action (the speaker icon is not drawn)")
                var fire = SlideAction(id: UUID().uuidString, kind: .fireAudio)
                fire.audioItemId = state.want(forPath: path)
                actions.append(fire)
                continue
            }
            if let object = mapShape(shape, scene: scene, k: k, state: &state) {
                objects.append(object)
                if let shapeID = shape.shapeID { objectIDsByShape[shapeID] = object.id }
            }
        }

        let animationSteps = PPTXAnimationMapper.apply(slide.animationSteps, objectIDs: objectIDsByShape, objects: &objects)

        AnimationImportSupport.rigidifyMoves(&objects, canvas: CGSize(width: canvasWidth, height: canvasHeight))
        var notes = slide.notes
        for warning in animationSteps.warnings {
            state.warn(warning)
            notes = (notes.map { $0 + "\n" } ?? "") + "PowerPoint \(warning)"
        }

        var transition: Transition?
        var autoAdvance: AutoAdvance?
        if let pptxTransition = slide.transition {
            if let kind = pptxTransition.kind {
                switch kind {
                case "fade":
                    transition = Transition(
                        transitionKind: pptxTransition.throughBlack ? .fadeBlack : .dissolve,
                        durationSeconds: pptxTransition.durationSeconds)
                default:
                    state.warn("transition \"\(kind)\" has no MxU equivalent — shown as a dissolve")
                    transition = Transition(transitionKind: .dissolve, durationSeconds: pptxTransition.durationSeconds)
                }
            }
            if let ms = pptxTransition.advanceAfterMs {
                autoAdvance = AutoAdvance(delaySeconds: max(ms / 1000, 0))
            }
        }

        return Slide(
            id: UUID().uuidString,
            name: slide.name ?? "",
            objects: objects,
            backgroundFill: backgroundFill,
            actions: actions.isEmpty ? nil : actions,
            notes: notes,
            autoAdvance: autoAdvance,
            transition: transition,
            animationOrder: animationSteps.animationOrder
        )
    }

    private static func mapShape(
        _ shape: PPTXShape, scene: (Double) -> Double, k: Double, state: inout MapState
    ) -> SlideObject? {
        let transform = shape.transform
        let frame = (
            x: scene(transform.offXEMU), y: scene(transform.offYEMU),
            w: scene(transform.extXEMU), h: scene(transform.extYEMU)
        )

        let rotation = (transform.rotation60k / 60000).truncatingRemainder(dividingBy: 360)

        switch shape.kind {
        case .picture:
            guard let path = shape.mediaPath else {

                return nil
            }

            let geometry = resolvedGeometry(of: shape, frame: frame, state: &state)

            let opacity = shape.blipAlpha

            let pictureStroke = shape.stroke.map {
                ObjectStroke(colorHex: rgba($0.colorHex), width: $0.widthEMU / 12700 * k, dashKind: $0.dash)
            }
            return SlideObject(
                id: UUID().uuidString, objectKind: .shape, name: shape.name ?? "Picture", text: "",
                x: frame.x, y: frame.y, width: frame.w, height: frame.h,
                rotationDegrees: rotation == 0 ? nil : rotation,
                flipHorizontal: transform.flipH ? true : nil,
                flipVertical: transform.flipV ? true : nil,
                opacity: opacity,
                shapeKind: geometry.kind == .rectangle ? nil : geometry.kind,
                cornerRadius: geometry.cornerRadius,
                pathData: geometry.pathData,

                fill: ObjectFill(
                    fillKind: .media, mediaId: state.want(forPath: path),
                    mediaScaleMode: .stretch,
                    mediaSourceRect: mediaSourceRect(shape.sourceRect)),
                stroke: pictureStroke
            )

        case .shape:
            let text = shape.textBody?.plainText ?? ""
            let fill = objectFill(shape.fill, state: &state)
            let fillIsInk = fill.map { $0.fillKind != .none } ?? false
            let stroke = shape.stroke.map {
                ObjectStroke(colorHex: rgba($0.colorHex), width: $0.widthEMU / 12700 * k, dashKind: $0.dash)
            }
            var textStyle: TextStyle?
            var styleRuns: [TextStyleRun] = []
            if !text.isEmpty, let body = shape.textBody {
                (textStyle, styleRuns) = self.textStyle(for: body, k: k, state: &state)
            }

            if !text.isEmpty, !fillIsInk, stroke == nil {
                var object = SlideObject(
                    id: UUID().uuidString, objectKind: .text, name: shape.name ?? "Text", text: text,
                    x: frame.x, y: frame.y, width: frame.w, height: frame.h,
                    rotationDegrees: rotation == 0 ? nil : rotation,
                    flipHorizontal: transform.flipH ? true : nil,
                    flipVertical: transform.flipV ? true : nil,
                    textStyle: textStyle
                )
                if !styleRuns.isEmpty { object.styleRuns = styleRuns }
                return object
            }

            let geometry = resolvedGeometry(of: shape, frame: frame, state: &state)

            if text.isEmpty, !fillIsInk, stroke == nil { return nil }

            var object = SlideObject(
                id: UUID().uuidString, objectKind: .shape,
                name: shape.name ?? (text.isEmpty ? "Shape" : "Text"), text: text,
                x: frame.x, y: frame.y, width: frame.w, height: frame.h,
                rotationDegrees: rotation == 0 ? nil : rotation,
                flipHorizontal: transform.flipH ? true : nil,
                flipVertical: transform.flipV ? true : nil,
                textStyle: textStyle,
                shapeKind: geometry.kind,
                cornerRadius: geometry.cornerRadius,
                pathData: geometry.pathData,
                fill: fill,
                stroke: stroke
            )
            if !styleRuns.isEmpty { object.styleRuns = styleRuns }
            return object
        }
    }

    private static func resolvedGeometry(
        of shape: PPTXShape, frame: (x: Double, y: Double, w: Double, h: Double), state: inout MapState
    ) -> (kind: ShapeKind, cornerRadius: Double?, pathData: String?) {
        if let custom = shape.customPathData {
            return (.path, nil, custom)
        }
        switch shape.presetGeometry {
        case nil, "rect":
            return (.rectangle, nil, nil)
        case "roundRect":
            return (.roundedRectangle, (shape.roundRectAdjustment ?? 16_667) / 100_000 * min(frame.w, frame.h), nil)
        case "ellipse", "flowChartConnector":

            return (.ellipse, nil, nil)
        case let preset?:
            if let curated = PPTXPresetGeometry.pathData(forPreset: preset) {
                return (.path, nil, curated)
            }
            if preset.hasPrefix("bentConnector") || preset.hasPrefix("curvedConnector") {
                state.warn("connector \"\(preset)\" imported as a straight line")
                return (.path, nil, PPTXPresetGeometry.linePath)
            }

            state.warn("shape \"\(preset)\" approximated as a rectangle")
            return (.rectangle, nil, nil)
        }
    }

    private static func objectFill(_ fill: PPTXFill?, state: inout MapState) -> ObjectFill? {
        switch fill {
        case nil:
            return nil
        case .noFill?:
            return ObjectFill(fillKind: .none)
        case .solid(let hex)?:
            return ObjectFill(fillKind: .solid, colorHex: rgba(hex))
        case .gradient(let gradient)?:
            return ObjectFill(
                fillKind: .linearGradient,
                gradientAngleDegrees: gradient.angle60k.map { $0 / 60000 },
                gradientStops: gradient.stops.map {
                    GradientStop(colorHex: rgba($0.colorHex), position: $0.position / 100_000)
                }
            )
        case .blip(let path)?:

            return ObjectFill(fillKind: .media, mediaId: state.want(forPath: path), mediaScaleMode: .stretch)
        case .blipTiled(let path, _, _, _, _)?:

            state.warn("a tiled texture fill on a shape is approximated stretched")
            return ObjectFill(fillKind: .media, mediaId: state.want(forPath: path), mediaScaleMode: .stretch)
        case .pattern(let preset, let fg, let bg)?:

            state.warn("pattern fills are approximated as a blend of their two colors")
            return ObjectFill(fillKind: .solid, colorHex: rgba(Self.patternBlend(preset, fg, bg)))
        }
    }

    static func patternBlend(_ preset: String, _ foreground: String, _ background: String) -> String {
        let coverage: Double
        if preset.hasPrefix("pct"), let percent = Double(preset.dropFirst(3)) {
            coverage = percent / 100
        } else if TextureBaker.structuralPatterns.contains(preset) {
            coverage = 0.15
        } else {
            coverage = 0.5
        }
        return PPTXSlideParser.blend(foreground, background, coverage: coverage)
    }

    private static func mediaSourceRect(_ rect: PPTXSourceRect?) -> MediaSourceRect? {
        guard let rect, !rect.isFullFrame else { return nil }
        return MediaSourceRect(
            x: rect.l / 100_000,
            y: rect.t / 100_000,
            width: 1 - (rect.l + rect.r) / 100_000,
            height: 1 - (rect.t + rect.b) / 100_000
        )
    }

    private static func textStyle(
        for body: PPTXTextBody, k: Double, state: inout MapState
    ) -> (style: TextStyle, runs: [TextStyleRun]) {
        let lines = body.lines
        let allRuns = lines.flatMap(\.runs).filter { !$0.text.isEmpty }
        let base = dominantRun(allRuns)
        let fontScale = body.hasNormAutofit ? (body.autofitFontScale ?? 100_000) / 100_000 : 1

        func scaledSize(_ run: PPTXRun?) -> Double {

            ((run?.sizeHundredthsPt ?? 1800) / 100) * k * fontScale
        }
        func scaledTracking(_ run: PPTXRun?) -> Double? {
            run?.trackingHundredthsPt.map { $0 / 100 * k }
        }

        var style = TextStyle()
        let baseFontName = resolvedFontName(base, inheritedFamily: nil, state: &state)
        let baseFontSize = scaledSize(base)
        let baseColor = base?.colorHex.map(rgba)
        let baseTracking = scaledTracking(base)
        style.fontName = baseFontName
        style.fontSize = baseFontSize
        style.colorHex = baseColor
        if let tracking = baseTracking, tracking != 0 { style.tracking = tracking }

        switch body.anchor {
        case "ctr": style.verticalAlignment = .middle
        case "b": style.verticalAlignment = .bottom
        default: style.verticalAlignment = .top
        }
        style.horizontalAlignment = horizontalAlignment(of: lines, state: &state)

        if body.hasNormAutofit { style.autoShrink = true }

        let insetTop = (body.topInsetEMU ?? 45_720) / 12700 * k
        let insetLeft = (body.leftInsetEMU ?? 91_440) / 12700 * k
        let insetBottom = (body.bottomInsetEMU ?? 45_720) / 12700 * k
        let insetRight = (body.rightInsetEMU ?? 91_440) / 12700 * k
        if insetTop != 0 { style.insetTop = insetTop }
        if insetLeft != 0 { style.insetLeft = insetLeft }
        if insetBottom != 0 { style.insetBottom = insetBottom }
        if insetRight != 0 { style.insetRight = insetRight }

        let uniformUnderline = !allRuns.isEmpty && allRuns.allSatisfy(\.underline)
        let uniformStrike = !allRuns.isEmpty && allRuns.allSatisfy(\.strike)
        if uniformUnderline { style.underline = true }
        if uniformStrike { style.strikethrough = true }

        var overrides: [LineStyleOverride] = []
        var styleRuns: [TextStyleRun] = []
        for (index, line) in lines.enumerated() {
            let lineRuns = line.runs.filter { !$0.text.isEmpty }
            let lineDominant = dominantRun(lineRuns)
            let lineFontName = resolvedFontName(lineDominant, inheritedFamily: base?.fontFamily, state: &state) ?? baseFontName
            let lineFontSize = lineDominant.map { scaledSize($0) } ?? baseFontSize
            let lineColor = lineDominant?.colorHex.map(rgba) ?? baseColor
            let lineTracking = lineDominant.flatMap { scaledTracking($0) } ?? baseTracking

            if lineDominant != nil {
                var override = LineStyleOverride(lineIndex: index)
                if lineFontName != baseFontName { override.fontName = lineFontName }
                if lineFontSize != baseFontSize { override.fontSize = lineFontSize }
                if lineColor != baseColor { override.colorHex = lineColor }
                if lineTracking != baseTracking { override.tracking = lineTracking }
                if override != LineStyleOverride(lineIndex: index) { overrides.append(override) }
            }

            var column = 0
            for run in line.runs {
                let length = run.text.count
                defer { column += length }
                guard length > 0 else { continue }
                var styleRun = TextStyleRun(line: index, column: column, length: length)
                let inherited = lineDominant?.fontFamily ?? base?.fontFamily
                if let runFontName = resolvedFontName(run, inheritedFamily: inherited, state: &state),
                   runFontName != lineFontName {
                    styleRun.fontName = runFontName
                }
                if scaledSize(run) != lineFontSize, run.sizeHundredthsPt != nil {
                    styleRun.fontSize = scaledSize(run)
                }
                if let color = run.colorHex.map(rgba), color != lineColor {
                    styleRun.colorHex = color
                }
                if let tracking = scaledTracking(run), tracking != lineTracking {
                    styleRun.tracking = tracking
                }
                if !uniformUnderline, run.underline { styleRun.underline = true }
                if !uniformStrike, run.strike { styleRun.strikethrough = true }
                if styleRun != TextStyleRun(line: index, column: column, length: length) {
                    styleRuns.append(styleRun)
                }
            }
        }
        if !overrides.isEmpty { style.lineStyles = overrides }

        return (style, styleRuns)
    }

    private static func dominantRun(_ runs: [PPTXRun]) -> PPTXRun? {
        func sameStyle(_ a: PPTXRun, _ b: PPTXRun) -> Bool {
            a.fontFamily == b.fontFamily && a.sizeHundredthsPt == b.sizeHundredthsPt
                && a.bold == b.bold && a.italic == b.italic
                && a.colorHex == b.colorHex && a.trackingHundredthsPt == b.trackingHundredthsPt
        }
        var representatives: [PPTXRun] = []
        var counts: [Int] = []
        for run in runs where !run.text.isEmpty {
            if let index = representatives.firstIndex(where: { sameStyle($0, run) }) {
                counts[index] += run.text.count
            } else {
                representatives.append(run)
                counts.append(run.text.count)
            }
        }
        var best: Int?
        for index in representatives.indices where best.map({ counts[index] > counts[$0] }) ?? true {
            best = index
        }
        return best.map { representatives[$0] }
    }

    private static func horizontalAlignment(of lines: [PPTXTextLine], state: inout MapState) -> TextHorizontalAlignment {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in lines {
            let alignment = line.alignment ?? "l"  
            if counts[alignment] == nil { order.append(alignment) }
            counts[alignment, default: 0] += line.text.count
        }
        let best = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? "l"
        switch best {
        case "ctr": return .center
        case "r": return .right
        case "just":
            state.warn("justified text is not supported — aligned left")
            return .left
        default:
            return .left
        }
    }

    private static func resolvedFontName(
        _ run: PPTXRun?, inheritedFamily: String?, state: inout MapState
    ) -> String? {
        guard let run, let family = run.fontFamily ?? inheritedFamily else { return nil }
        let cacheKey = "\(family)|\(run.bold)|\(run.italic)"
        if let cached = state.fontNameCache[cacheKey] { return cached }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if run.bold { traits.insert(.bold) }
        if run.italic { traits.insert(.italic) }
        var descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) }
        let resolved: String
        if let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family]),
           let name = matched.object(forKey: .name) as? String {
            resolved = name
        } else {
            state.warn("font \"\(family)\" is not installed — imported by name")
            if !state.missingFonts.contains(family) { state.missingFonts.append(family) }
            switch (run.bold, run.italic) {
            case (false, false): resolved = family
            case (true, false): resolved = family + "-Bold"
            case (false, true): resolved = family + "-Italic"
            case (true, true): resolved = family + "-BoldItalic"
            }
        }
        state.fontNameCache[cacheKey] = resolved
        return resolved
    }

    private static func rgba(_ hex: String) -> String {
        let upper = hex.uppercased()
        return upper.count == 8 ? "#\(upper)" : "#\(upper)FF"
    }
}
