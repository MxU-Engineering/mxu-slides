import Foundation

public enum StarterPack: String, CaseIterable, Sendable {
    case cleanGeometric, editorialSerif, boldBlocks, digital

    public var title: String {
        switch self {
        case .cleanGeometric: "Clean Geometric"
        case .editorialSerif: "Editorial Serif"
        case .boldBlocks: "Bold Blocks"
        case .digital: "Digital"
        }
    }

    public var themeID: String { "pack.\(rawValue).theme" }
    public func overlayID(_ item: String) -> String { "pack.\(rawValue).overlay.\(item)" }

    public static let overlayItems = [
        "name", "nameTimed", "scriptureVerse", "point", "ctaLower", "ticker", "verseSide", "pointSide", "cta", "search", "bars",
    ]

    public static let retiredOverlayItems = ["quote", "scripture", "section"]

    struct Look {
        var body: String       
        var display: String    
        var accent: String     
        var accent2: String    
        var ink: String        
        var inkOnAccent: String
        var plate: String      
        var plate2: String     
        var backdrop: String   
        var radius: Double
    }

    var look: Look {
        switch self {
        case .cleanGeometric:
            Look(body: "HelveticaNeue", display: "HelveticaNeue-Bold", accent: "#3B82F6FF", accent2: "#60A5FAFF",
                 ink: "#FFFFFFFF", inkOnAccent: "#FFFFFFFF", plate: "#0F172AF2", plate2: "#1E293BF2",
                 backdrop: "#0B1220FF", radius: 10)
        case .editorialSerif:
            Look(body: "Georgia", display: "Georgia-Bold", accent: "#C8A96AFF", accent2: "#E6D3A3FF",
                 ink: "#F7F3EAFF", inkOnAccent: "#1C1A17FF", plate: "#1C1A17CC", plate2: "#1C1A1700",
                 backdrop: "#14120FFF", radius: 0)
        case .boldBlocks:
            Look(body: "AvenirNext-DemiBold", display: "AvenirNext-Heavy", accent: "#FACC15FF", accent2: "#111111FF",
                 ink: "#FFFFFFFF", inkOnAccent: "#111111FF", plate: "#111111FF", plate2: "#111111FF",
                 backdrop: "#111111FF", radius: 0)
        case .digital:
            Look(body: "Menlo-Regular", display: "Menlo-Bold", accent: "#22D3EEFF", accent2: "#F472B6FF",
                 ink: "#E6FBFFFF", inkOnAccent: "#05080CFF", plate: "#0A0F14E6", plate2: "#0A0F14E6",
                 backdrop: "#05080CFF", radius: 4)
        }
    }

    private func fill(_ hex: String) -> ObjectFill { ObjectFill(fillKind: .solid, colorHex: hex) }
    private func gradient(_ a: String, _ b: String, angle: Double = 0) -> ObjectFill {
        ObjectFill(fillKind: .linearGradient, gradientAngleDegrees: angle,
                   gradientStops: [GradientStop(colorHex: a, position: 0), GradientStop(colorHex: b, position: 1)])
    }

    private func block(
        _ id: String, _ name: String, x: Double, y: Double, w: Double, h: Double,
        fill: ObjectFill? = nil, color: String? = nil, radius: Double? = nil, stroke: ObjectStroke? = nil,
        shadow: ObjectShadow? = nil, skew: Double? = nil, ellipse: Bool = false, maskedBy: String? = nil,
        animationSteps: [AnimationStep]
    ) -> SlideObject {
        let r = radius ?? look.radius
        return SlideObject(
            id: id, objectKind: .shape, name: name, text: "", x: x, y: y, width: w, height: h,
            maskObjectId: maskedBy, maskMode: maskedBy == nil ? nil : .in,
            shapeKind: ellipse ? .ellipse : (r > 0 ? .roundedRectangle : .rectangle), cornerRadius: r,
            fill: fill ?? self.fill(color ?? look.plate), stroke: stroke, shadow: shadow,
            animationSteps: animationSteps.isEmpty ? nil : animationSteps, skewX: skew
        )
    }

    private func matte(_ id: String, x: Double, y: Double, w: Double, h: Double) -> SlideObject {
        SlideObject(id: id, objectKind: .shape, name: "Mask", text: "", x: x, y: y, width: w, height: h,
                    shapeKind: .rectangle, fill: fill("#FFFFFFFF"))
    }

    private func label(
        _ id: String, _ name: String, _ string: String, x: Double, y: Double, w: Double, h: Double,
        size: Double, display: Bool = false, font: String? = nil, color: String? = nil,
        align: TextHorizontalAlignment = .left, valign: TextVerticalAlignment = .middle,
        tracking: Double = 0, uppercase: Bool = false, inset: Double = 24, lineHeight: Double = 1,
        lineFill: TextLineFill? = nil, maskedBy: String? = nil, shrink: Bool = false, page: Bool = false, animationSteps: [AnimationStep]
    ) -> SlideObject {
        SlideObject(
            id: id, objectKind: .text, name: name, text: string, x: x, y: y, width: w, height: h,
            maskObjectId: maskedBy, maskMode: maskedBy == nil ? nil : .in,
            textStyle: TextStyle(
                fontName: font ?? (display ? look.display : look.body), fontSize: size,
                colorHex: color ?? look.ink, tracking: tracking, lineHeightMultiple: lineHeight,
                horizontalAlignment: align, verticalAlignment: valign,
                textTransform: uppercase ? .uppercase : nil,

                autoShrink: shrink ? true : nil,

                pageOnClick: page ? true : nil,
                lineFill: lineFill, insetLeft: inset, insetRight: inset
            ),
            animationSteps: animationSteps.isEmpty ? nil : animationSteps
        )
    }

    private func step(
        _ id: String, _ kind: AnimationKind, _ animation: StepAnimation, _ trigger: AnimationTrigger,
        delay: Double? = nil, duration: Double, ramp: AnimationRamp? = nil, fade: Bool? = nil,
        edge: AnimationEdge? = nil, offsetX: Double? = nil, offsetY: Double? = nil, fromScale: Double? = nil,
        amount: Double? = nil, softEdge: Double? = nil, cursor: Bool? = nil, drawStart: Double? = nil
    ) -> AnimationStep {
        AnimationStep(id: id, kind: kind, animation: animation, trigger: trigger, delaySeconds: delay,
                  durationSeconds: duration, ramp: ramp, withFade: fade, edge: edge, offsetX: offsetX,
                  offsetY: offsetY, fromScale: fromScale, amount: amount, softEdge: softEdge, cursor: cursor,
                  drawStart: drawStart)
    }

    private func plateIn(_ id: String, _ trigger: AnimationTrigger = .withPrevious, delay: Double? = nil, edge: AnimationEdge = .left, big: Bool = false, videoPush: VideoPush? = nil) -> AnimationStep {
        let stretch: Double = big ? 1.3 : 1

        if big {
            var s = step(id, .in, .move, trigger, delay: delay, duration: 0.7, ramp: .out, edge: edge)
            s.videoPush = videoPush
            return s
        }
        switch self {
        case .cleanGeometric: return step(id, .in, .move, trigger, delay: delay, duration: 0.55 * stretch, ramp: .out, fade: true, edge: edge)
        case .editorialSerif: return step(id, .in, .burn, trigger, delay: delay, duration: 1.1 * stretch, ramp: .out, fade: true, amount: 0.7)
        case .boldBlocks: return step(id, .in, .wipe, trigger, delay: delay, duration: 0.45 * stretch, ramp: .out, fade: true, edge: edge, softEdge: big ? 60 : 0)
        case .digital: return step(id, .in, .glitch, trigger, delay: delay, duration: 0.9 * stretch, fade: true, amount: 0.9)
        }
    }

    private func plateOut(_ id: String, _ trigger: AnimationTrigger = .onDismiss, delay: Double? = nil, edge: AnimationEdge = .left, big: Bool = false, videoPush: VideoPush? = nil) -> AnimationStep {
        let stretch: Double = big ? 1.2 : 1

        if big {
            var s = step(id, .out, .move, trigger, delay: delay, duration: 0.6, ramp: .in, edge: edge)
            s.videoPush = videoPush
            return s
        }
        switch self {
        case .cleanGeometric: return step(id, .out, .move, trigger, delay: delay, duration: 0.45 * stretch, ramp: .in, fade: true, edge: edge)
        case .editorialSerif: return step(id, .out, .burn, trigger, delay: delay, duration: 0.9 * stretch, ramp: .in, fade: true, amount: 0.7)
        case .boldBlocks: return step(id, .out, .wipe, trigger, delay: delay, duration: 0.4 * stretch, ramp: .in, fade: true, edge: edge, softEdge: big ? 60 : 0)
        case .digital: return step(id, .out, .glitch, trigger, delay: delay, duration: 0.8 * stretch, fade: true, amount: 0.9)
        }
    }

    private func textIn(_ id: String, _ trigger: AnimationTrigger = .afterPrevious, delay: Double? = nil, rise: Double = 28, edge: AnimationEdge = .left) -> AnimationStep {
        let lag: Double? = trigger == .afterPrevious ? max(delay ?? 0, -0.05) : delay
        switch self {
        case .cleanGeometric: return step(id, .in, .move, trigger, delay: lag, duration: 0.5, ramp: .out, fade: true, offsetX: 0, offsetY: rise)
        case .editorialSerif: return step(id, .in, .fade, trigger, delay: lag, duration: 0.9, ramp: .out)
        case .boldBlocks: return step(id, .in, .wipe, trigger, delay: lag, duration: 0.4, ramp: .out, edge: edge, softEdge: 0)
        case .digital: return step(id, .in, .glitch, trigger, delay: lag, duration: 0.9, amount: 0.85)
        }
    }

    private func textOut(_ id: String, _ trigger: AnimationTrigger = .onClick, delay: Double? = nil, toward: AnimationEdge = .bottom, distance: Double = 28) -> AnimationStep {
        let (dx, dy): (Double, Double) = switch toward {
        case .bottom: (0, distance)
        case .top: (0, -distance)
        case .left: (-distance, 0)
        case .right: (distance, 0)
        }
        switch self {
        case .cleanGeometric: return step(id, .out, .move, trigger, delay: delay, duration: 0.4, ramp: .in, fade: true, offsetX: dx, offsetY: dy)
        case .editorialSerif: return step(id, .out, .fade, trigger, delay: delay, duration: 0.7, ramp: .in)
        case .boldBlocks: return step(id, .out, .wipe, trigger, delay: delay, duration: 0.3, ramp: .in, edge: toward, softEdge: 0)
        case .digital: return step(id, .out, .glitch, trigger, delay: delay, duration: 0.7, amount: 0.85)
        }
    }

    private func ruleIn(_ id: String, _ trigger: AnimationTrigger = .afterPrevious, delay: Double? = -0.2, edge: AnimationEdge = .left, duration: Double = 0.5) -> AnimationStep {
        step(id, .in, .wipe, trigger, delay: delay, duration: duration, ramp: .out, edge: edge, softEdge: 0)
    }

    private func ruleOut(_ id: String, _ trigger: AnimationTrigger = .withPrevious, delay: Double? = nil, edge: AnimationEdge = .left) -> AnimationStep {
        step(id, .out, .wipe, trigger, delay: delay, duration: 0.35, ramp: .in, edge: edge, softEdge: 0)
    }

    private func popIn(_ id: String, _ trigger: AnimationTrigger = .afterPrevious, delay: Double? = -0.2, duration: Double = 0.45, from: Double = 0.4) -> AnimationStep {
        step(id, .in, .scale, trigger, delay: delay, duration: duration, ramp: .out, fade: true, fromScale: from)
    }

    private func popOut(_ id: String, _ trigger: AnimationTrigger = .withPrevious, delay: Double? = nil) -> AnimationStep {
        step(id, .out, .scale, trigger, delay: delay, duration: 0.35, ramp: .in, fade: true, fromScale: 0.6)
    }

    private func drawIn(_ id: String, _ trigger: AnimationTrigger = .withPrevious, delay: Double? = nil, duration: Double = 1.2) -> AnimationStep {
        step(id, .in, .draw, trigger, delay: delay, duration: duration, drawStart: 0)
    }

    private func typeIn(_ id: String, _ trigger: AnimationTrigger = .afterPrevious, delay: Double? = -0.1, duration: Double = 1.6) -> AnimationStep {
        step(id, .in, .type, trigger, delay: delay, duration: duration, cursor: true)
    }

    private func fadeIn(_ id: String, _ trigger: AnimationTrigger = .afterPrevious, delay: Double? = -0.1, duration: Double = 0.4) -> AnimationStep {
        step(id, .in, .fade, trigger, delay: delay, duration: duration, ramp: .out)
    }

    private func fadeOut(_ id: String, _ trigger: AnimationTrigger = .withPrevious, delay: Double? = nil, duration: Double = 0.4) -> AnimationStep {
        step(id, .out, .fade, trigger, delay: delay, duration: duration, ramp: .in)
    }

    static func opposite(_ edge: AnimationEdge) -> AnimationEdge {
        switch edge {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    private var kickerTracking: Double { self == .editorialSerif ? 8 : self == .digital ? 4 : 6 }

    public func makeTheme() -> Theme {
        let look = look

        var slides: [Slide] = []
        func fromOverlay(_ overlay: Overlay, _ item: String, _ name: String, primary: String, fullScreen: Bool = false, folder: String? = nil) -> Slide {
            themeSlide(item, name, Self.promotingPrimaryText(overlay.objects, primaryID: primary),
                       order: overlay.animationOrder ?? [], fullScreen: fullScreen, folder: folder)
        }
        slides.append(contentsOf: [
            lyricsSlide(), pointsSlide(), sectionTitleSlide(), verseSlide(), pointSlide(), quoteSlide(),
            fromOverlay(callToAction(base: "\(themeID).ctaFull", layout: .full), "ctaFull", "Call to Action", primary: "\(themeID).ctaFull.head", fullScreen: true),

            simplifiedThird("lowerDefault", "Lower Third",
                            pointLowerThird(base: "\(themeID).lowerDefault"),
                            primary: "\(themeID).lowerDefault.text",
                            dropping: ["\(themeID).lowerDefault.tag", "\(themeID).lowerDefault.kicker"],
                            folder: "Lower Thirds"),
            fromOverlay(lyricsLowerThird(base: "\(themeID).lyricsLower"), "lyricsLower", "Lyrics (Lower Third)", primary: "\(themeID).lyricsLower.text", folder: "Lower Thirds"),
            fromOverlay(namePlate(timed: false, base: "\(themeID).name"), "name", "Name + Title", primary: "\(themeID).name.name", folder: "Lower Thirds"),
            fromOverlay(verseLowerThird(base: "\(themeID).verseLower"), "verseLower", "Verse + Reference (Lower Third)", primary: "\(themeID).verseLower.verse", folder: "Lower Thirds"),
            fromOverlay(pointLowerThird(base: "\(themeID).pointLower"), "pointLower", "Point (Lower Third)", primary: "\(themeID).pointLower.text", folder: "Lower Thirds"),
            fromOverlay(callToAction(base: "\(themeID).ctaLower", layout: .lowerThird), "ctaLower", "Call to Action (Lower Third)", primary: "\(themeID).ctaLower.head", folder: "Lower Thirds"),
            simplifiedThird("sideDefault", "Side Third",
                            pointSideThird(base: "\(themeID).sideDefault"),
                            primary: "\(themeID).sideDefault.text",
                            dropping: ["\(themeID).sideDefault.kicker"],
                            folder: "Side Thirds"),
            fromOverlay(lyricsSideThird(base: "\(themeID).lyricsSide"), "lyricsSide", "Lyrics (Side Third)", primary: "\(themeID).lyricsSide.text", folder: "Side Thirds"),
            fromOverlay(pointSideThird(base: "\(themeID).pointSide"), "pointSide", "Point (Side Third)", primary: "\(themeID).pointSide.text", folder: "Side Thirds"),
            fromOverlay(verseSideThird(base: "\(themeID).verseSide"), "verseSide", "Verse + Reference (Side Third)", primary: "\(themeID).verseSide.verse", folder: "Side Thirds"),
            fromOverlay(callToAction(base: "\(themeID).ctaSide", layout: .sideThird), "ctaSide", "Call to Action (Side Third)", primary: "\(themeID).ctaSide.head", folder: "Side Thirds"),
        ])
        return Theme(id: themeID, name: title, fontFamily: look.body, fontSize: 72, textColorHex: look.ink,
                     backgroundColorHex: look.backdrop, slides: slides)
    }

    public static func isGenericPlaceholder(_ slide: Slide) -> Bool {
        let names: Set<String> = ["Lyrics", "Bible", "Announcements", "Sermon Points"]
        return names.contains(slide.name) && slide.folder == nil && slide.objects.count == 1
            && slide.objects[0].objectKind == .text && slide.objects[0].name == "Text Placeholder"
            && slide.objects[0].text == "Sample \(slide.name)"
    }

    public func pagingThirds(_ slides: [Slide]) -> [Slide] {
        slides.map { slide in
            guard slide.id.hasPrefix("\(themeID)."), ["Lower Thirds", "Side Thirds"].contains(slide.folder ?? ""),
                  let index = slide.objects.firstIndex(where: { $0.objectKind == .text })
            else { return slide }
            var result = slide
            var style = result.objects[index].textStyle ?? TextStyle()
            style.autoShrink = true
            style.pageOnClick = true
            result.objects[index].textStyle = style
            return result
        }
    }

    public func addingLyricsDesigns(to slides: [Slide]) -> [Slide] {
        var result = slides
        let designs = (makeTheme().slides ?? []).filter { $0.id.hasPrefix("\(themeID).lyrics") }
        for design in designs
        where !result.contains(where: { $0.name.caseInsensitiveCompare(design.name) == .orderedSame }) {
            if let folder = design.folder, folder != "Full Slide",
               let last = result.lastIndex(where: { $0.folder == folder }) {
                result.insert(design, at: last + 1)
            } else if design.folder == "Full Slide" {
                result.insert(design, at: 0)
            } else {
                result.append(design)
            }
        }
        return result
    }

    public var retiredThemeIDs: [String] {
        ["pack.\(rawValue).theme.lowerThird", "pack.\(rawValue).theme.sideThird"]
    }

    private func simplifiedThird(
        _ item: String, _ name: String, _ overlay: Overlay,
        primary: String, dropping: Set<String>, folder: String
    ) -> Slide {
        let kept = overlay.objects.filter { !dropping.contains($0.id) }
        let droppedSteps = Set(
            overlay.objects.filter { dropping.contains($0.id) }
                .flatMap { ($0.animationSteps ?? []).map(\.id) }
        )
        let objects = Self.promotingPrimaryText(kept, primaryID: primary).map { object -> SlideObject in

            guard object.id == primary else { return object }
            var adjusted = object
            adjusted.animationSteps = (object.animationSteps ?? []).map { step in
                guard step.kind == .in else { return step }
                var chained = step
                chained.trigger = .afterPrevious
                chained.delaySeconds = -0.05
                return chained
            }
            return adjusted
        }
        var slide = Slide(id: "\(themeID).\(item)", name: name, objects: objects)
        slide.animationOrder = (overlay.animationOrder ?? []).filter { !droppedSteps.contains($0) }
        slide.folder = folder
        return slide
    }

    static func promotingPrimaryText(_ objects: [SlideObject], primaryID: String) -> [SlideObject] {
        guard let primaryIndex = objects.firstIndex(where: { $0.id == primaryID }),
              let firstTextIndex = objects.firstIndex(where: { $0.objectKind == .text }),
              firstTextIndex < primaryIndex
        else { return objects }
        var result = objects
        let primary = result.remove(at: primaryIndex)
        result.insert(primary, at: firstTextIndex)
        return result
    }

    private func themeSlide(_ item: String, _ name: String, _ objects: [SlideObject], order: [String], fullScreen: Bool, folder: String? = nil) -> Slide {
        var slide = Slide(id: "\(themeID).\(item)", name: name, objects: objects,
                          backgroundFill: fullScreen ? fill(look.backdrop) : nil)
        slide.animationOrder = order
        slide.folder = folder ?? (fullScreen ? "Full Slide" : nil)
        return slide
    }

    private static let sampleLyrics = "Amazing grace, how sweet the sound\nThat saved a wretch like me\nI once was lost, but now am found\nWas blind, but now I see"

    private func lyricsSlide() -> Slide {
        let b = "\(themeID).lyrics"
        let look = look
        let bold = self == .boldBlocks
        let textIn = textIn("\(b).text.in", .withPrevious, delay: 0, rise: 40), textOut = textOut("\(b).text.out")
        let ruleIn = ruleIn("\(b).rule.in", delay: -0.2, edge: .left), ruleOut = ruleOut("\(b).rule.out", .withPrevious, edge: .left)
        let objects = [

            label("\(b).text", "Lyrics", Self.sampleLyrics, x: bold ? 100 : 160, y: 160, w: bold ? 1720 : 1600, h: 700,
                  size: bold ? 64 : 84, display: true, font: self == .editorialSerif ? "Georgia" : nil, align: .center,
                  tracking: bold ? 2 : 0, uppercase: bold, inset: 0, lineHeight: 1.22, animationSteps: [textIn, textOut]),
            block("\(b).rule", "Rule", x: 880, y: 900, w: 160, h: bold ? 10 : 4, color: look.accent, radius: 0,
                  skew: bold ? -12 : nil, animationSteps: [ruleIn, ruleOut]),
        ]
        return themeSlide("lyrics", "Lyrics", objects, order: [textIn.id, ruleIn.id, textOut.id, ruleOut.id], fullScreen: true)
    }

    private func lyricsLowerThird(base b: String) -> Overlay {
        let look = look
        let bold = self == .boldBlocks

        let bandIn = plateIn("\(b).band.in", edge: .bottom, big: true), bandOut = plateOut("\(b).band.out", .afterPrevious, delay: -0.05, edge: .bottom, big: true)
        let barIn = ruleIn("\(b).bar.in", delay: -0.3, edge: .top, duration: 0.6), barOut = ruleOut("\(b).bar.out", edge: .top)
        let textIn = textIn("\(b).text.in", delay: -0.3, rise: 30), textOut = textOut("\(b).text.out")
        let objects = [
            block("\(b).band", "Band", x: 0, y: 720, w: 1920, h: 280, fill: gradient(look.plate2, look.plate, angle: 90), radius: 0, animationSteps: [bandIn, bandOut]),
            block("\(b).bar", "Bar", x: 160, y: 760, w: bold ? 18 : 8, h: 200, color: look.accent, radius: 0, skew: bold ? -12 : nil, animationSteps: [barIn, barOut]),
            label("\(b).text", "Lyrics", Self.sampleLyrics, x: 210, y: 750, w: 1550, h: 220, size: 46,
                  display: bold, font: self == .editorialSerif ? "Georgia" : nil, uppercase: bold, inset: 0, lineHeight: 1.15, shrink: true, page: true,
                  animationSteps: [textIn, textOut]),
        ]
        return Overlay(id: b, name: "Lyrics (Lower Third)", objects: objects,
                       animationOrder: [bandIn.id, barIn.id, textIn.id, textOut.id, bandOut.id, barOut.id])
    }

    private func lyricsSideThird(base b: String) -> Overlay {
        let look = look
        let bold = self == .boldBlocks
        let push = VideoPush(zoom: 1.05, backdrop: true)
        let panelIn = plateIn("\(b).panel.in", edge: .right, big: true, videoPush: push), panelOut = plateOut("\(b).panel.out", .afterPrevious, delay: -0.05, edge: .right, big: true, videoPush: push)
        let barIn = ruleIn("\(b).bar.in", delay: -0.3, edge: .top, duration: 0.9), barOut = ruleOut("\(b).bar.out", edge: .top)
        let textIn = textIn("\(b).text.in", delay: -0.3, rise: 40), textOut = textOut("\(b).text.out", toward: .right)
        let objects = [
            block("\(b).panel", "Panel", x: 1280, y: 0, w: 640, h: 1080, fill: gradient(look.plate2, look.plate, angle: 0), radius: 0, animationSteps: [panelIn, panelOut]),
            block("\(b).bar", "Bar", x: 1280, y: 0, w: bold ? 18 : 6, h: 1080, color: look.accent, radius: 0, animationSteps: [barIn, barOut]),
            label("\(b).text", "Lyrics", Self.sampleLyrics, x: 1340, y: 220, w: 520, h: 640, size: 44,
                  display: bold, font: self == .editorialSerif ? "Georgia" : nil, valign: .top, uppercase: bold, inset: 0, lineHeight: 1.2, shrink: true, page: true,
                  animationSteps: [textIn, textOut]),
        ]
        return Overlay(id: b, name: "Lyrics (Side Third)", objects: objects,
                       animationOrder: [panelIn.id, barIn.id, textIn.id, textOut.id, panelOut.id, barOut.id])
    }

    private func pointsSlide() -> Slide {
        let b = "\(themeID).points"
        let look = look
        let points = SlideObject(
            id: "\(b).text", objectKind: .text, name: "Points",
            text: "First point\nSecond point\nThird point",
            x: 200, y: 220, width: 1520, height: 640,
            textStyle: TextStyle(fontName: look.body, fontSize: 80, colorHex: look.ink, lineHeightMultiple: 1.25,
                                 horizontalAlignment: .left, verticalAlignment: .middle,
                                 lineFill: self == .boldBlocks ? TextLineFill(fill: fill(look.accent), widthMode: .lineWidth, verticalPadding: 4, horizontalPadding: 24) : nil),
            animationSteps: (0..<3).map { line in
                var s = textIn("\(b).in\(line)", .onClick, delay: nil, rise: 36)
                s.ranges = [AnimationRange(line: line, column: 0, length: 12)]
                return s
            }
        )
        let kicker = label("\(b).kicker", "Kicker", "Today's message", x: 200, y: 140, w: 1520, h: 60,
                           size: 30, color: look.accent, tracking: kickerTracking, uppercase: true, inset: 0,
                           animationSteps: [textIn("\(b).kicker.in", .withPrevious, delay: 0)])
        let rule = block("\(b).rule", "Rule", x: 224, y: 205, w: 160, h: 4, color: look.accent, radius: 0,
                         animationSteps: [ruleIn("\(b).rule.in", .afterPrevious, delay: -0.2)])
        return themeSlide("points", "Points", [kicker, rule, points],
                          order: [kicker.animationSteps![0].id, rule.animationSteps![0].id] + points.animationSteps!.map(\.id), fullScreen: true)
    }

    private func sectionTitleSlide() -> Slide {
        let b = "\(themeID).section"
        let look = look
        let kicker = label("\(b).kicker", "Kicker", "Part one", x: 160, y: 340, w: 1600, h: 60,
                           size: 32, color: look.accent, align: .center, tracking: kickerTracking, uppercase: true,
                           animationSteps: [textIn("\(b).kicker.in", .withPrevious, delay: 0), textOut("\(b).kicker.out", .withPrevious)])
        let title = label("\(b).text", "Section Title", "Section Title", x: 160, y: 400, w: 1600, h: 260,
                          size: 140, display: true, color: self == .boldBlocks ? look.inkOnAccent : look.ink, align: .center,
                          tracking: self == .boldBlocks ? 4 : 0, uppercase: self == .boldBlocks,
                          animationSteps: [textIn("\(b).in"), textOut("\(b).out")])
        let leftRule = block("\(b).rule", "Rule Left", x: 560, y: 690, w: 380, h: 4, color: look.accent, radius: 0,
                             animationSteps: [ruleIn("\(b).rule.in", edge: .right), ruleOut("\(b).rule.out", edge: .right)])
        let rightRule = block("\(b).rule2", "Rule Right", x: 980, y: 690, w: 380, h: 4, color: look.accent, radius: 0,
                              animationSteps: [ruleIn("\(b).rule2.in", .withPrevious, delay: 0, edge: .left), ruleOut("\(b).rule2.out", edge: .left)])
        var objects = [kicker, title, leftRule, rightRule]
        var order = [kicker.animationSteps![0].id, title.animationSteps![0].id, leftRule.animationSteps![0].id, rightRule.animationSteps![0].id,
                     title.animationSteps![1].id, kicker.animationSteps![1].id, leftRule.animationSteps![1].id, rightRule.animationSteps![1].id]
        if self == .boldBlocks {

            let blockIn = plateIn("\(b).block.in"), blockOut = plateOut("\(b).block.out", .afterPrevious, delay: -0.2)
            objects.insert(block("\(b).block", "Block", x: 260, y: 420, w: 1400, h: 220, color: look.accent, skew: -12, animationSteps: [blockIn, blockOut]), at: 0)
            objects[1].animationSteps![0].trigger = .afterPrevious
            order.insert(blockIn.id, at: 0); order.append(blockOut.id)
        }
        return themeSlide("section", "Section Title", objects, order: order, fullScreen: true)
    }

    private func verseSlide() -> Slide {
        let b = "\(themeID).verse"
        let look = look
        let editorial = self == .editorialSerif
        let barIn = ruleIn("\(b).bar.in", .withPrevious, delay: nil, edge: .top, duration: 0.7), barOut = ruleOut("\(b).bar.out", edge: .top)
        let verseIn = textIn("\(b).verse.in", delay: -0.35, rise: 40), verseOut = textOut("\(b).verse.out")
        let ruleIn = ruleIn("\(b).rule.in", delay: -0.15), ruleOut = ruleOut("\(b).rule.out", edge: .left)
        let refIn = textIn("\(b).ref.in", .withPrevious, delay: 0.1), refOut = textOut("\(b).ref.out", .withPrevious)
        let objects = [
            block("\(b).bar", "Bar", x: 200, y: 300, w: self == .boldBlocks ? 22 : 8, h: 480, color: look.accent, radius: 0, skew: self == .boldBlocks ? -12 : nil, animationSteps: [barIn, barOut]),
            label("\(b).verse", "Verse", "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.",
                  x: 260, y: 280, w: 1460, h: 440, size: 64, font: editorial ? "Georgia-Italic" : look.body, valign: .top, inset: 0, lineHeight: 1.15, animationSteps: [verseIn, verseOut]),
            block("\(b).rule", "Rule", x: 260, y: 760, w: 140, h: 4, color: look.accent, radius: 0, animationSteps: [ruleIn, ruleOut]),
            label("\(b).ref", "Reference", "John 3:16 (ESV)", x: 260, y: 780, w: 1460, h: 60, size: 34, display: true,
                  color: look.accent, tracking: kickerTracking - 2, uppercase: !editorial, inset: 0, animationSteps: [refIn, refOut]),
        ]
        return themeSlide("verse", "Verse + Reference", objects,
                          order: [barIn.id, verseIn.id, ruleIn.id, refIn.id, verseOut.id, refOut.id, ruleOut.id, barOut.id], fullScreen: true)
    }

    private func pointSlide() -> Slide {
        let b = "\(themeID).point"
        let look = look
        let kickIn = textIn("\(b).kicker.in", .withPrevious, delay: 0), kickOut = textOut("\(b).kicker.out", .withPrevious)
        let ruleIn = ruleIn("\(b).rule.in", delay: -0.2, duration: 0.6), ruleOut = ruleOut("\(b).rule.out", edge: .left)
        let textIn = textIn("\(b).text.in", delay: -0.3, rise: 48), textOut = textOut("\(b).text.out")
        let objects = [
            label("\(b).kicker", "Kicker", "Point 1", x: 200, y: 260, w: 1520, h: 60, size: 34, color: look.accent, tracking: kickerTracking, uppercase: true, inset: 0, animationSteps: [kickIn, kickOut]),
            block("\(b).rule", "Rule", x: 200, y: 330, w: 220, h: self == .boldBlocks ? 12 : 5, color: look.accent, radius: 0, animationSteps: [ruleIn, ruleOut]),
            label("\(b).text", "Point", "Faith is not the absence of fear — it is trust that outlasts it.",
                  x: 200, y: 360, w: 1520, h: 460, size: 92, display: true, valign: .top, tracking: self == .boldBlocks ? 2 : 0, uppercase: self == .boldBlocks, inset: 0, lineHeight: 1.08,
                  lineFill: self == .boldBlocks ? TextLineFill(fill: fill(look.accent), widthMode: .lineWidth, verticalPadding: 2, horizontalPadding: 28) : nil,
                  animationSteps: [textIn, textOut]),
        ]
        return themeSlide("point", "Point", objects, order: [kickIn.id, ruleIn.id, textIn.id, textOut.id, kickOut.id, ruleOut.id], fullScreen: true)
    }

    private func quoteSlide() -> Slide {
        let b = "\(themeID).quote"
        let look = look
        let bold = self == .boldBlocks
        let chipIn = popIn("\(b).chip.in", .withPrevious, delay: nil, duration: 0.5, from: 0.4), chipOut = popOut("\(b).chip.out", .withPrevious)
        let markIn = popIn("\(b).mark.in", .afterPrevious, delay: -0.05, duration: 0.6, from: 0.4), markOut = popOut("\(b).mark.out", .afterPrevious, delay: -0.15)
        let frameIn = drawIn("\(b).frame.in", .withPrevious, delay: 0.1, duration: 1.3), frameOut = fadeOut("\(b).frame.out", .withPrevious, duration: 0.5)
        let bodyIn = textIn("\(b).body.in", delay: -0.7, rise: 40), bodyOut = textOut("\(b).body.out")
        let ruleIn = ruleIn("\(b).rule.in", delay: -0.2), ruleOut = ruleOut("\(b).rule.out", edge: .left)
        let sourceIn = textIn("\(b).source.in", .withPrevious, delay: 0.15), sourceOut = textOut("\(b).source.out", .withPrevious)
        let markFont = self == .editorialSerif ? "Georgia-Bold" : bold ? "AvenirNext-Heavy" : look.display
        var objects = [
            block("\(b).frame", "Frame", x: 300, y: 250, w: 1320, h: 580, fill: bold ? fill(look.plate) : fill("#00000000"),
                  radius: self == .cleanGeometric ? 14 : 0, stroke: ObjectStroke(colorHex: look.accent, width: bold ? 10 : 3),
                  skew: bold ? -6 : nil, animationSteps: [frameIn, frameOut]),

            block("\(b).chip", "Mark Chip", x: 250, y: 150, w: 220, h: 220, color: bold ? look.accent2 : look.backdrop, radius: self == .cleanGeometric ? 20 : 0,
                  skew: bold ? -6 : nil, animationSteps: [chipIn, chipOut]),
            label("\(b).mark", "Quote Mark", "“", x: 250, y: 130, w: 220, h: 280, size: 300, font: markFont, color: look.accent, align: .center, inset: 0, animationSteps: [markIn, markOut]),
            label("\(b).body", "Quote", "The quote goes here — long enough to wrap onto a second line, and it should still breathe.",
                  x: 400, y: 330, w: 1120, h: 340, size: 56, font: self == .editorialSerif ? "Georgia-Italic" : look.body,
                  align: bold ? .left : .center, inset: 0, lineHeight: 1.15, animationSteps: [bodyIn, bodyOut]),
            block("\(b).rule", "Rule", x: bold ? 400 : 880, y: 700, w: 160, h: 4, color: look.accent, radius: 0, animationSteps: [ruleIn, ruleOut]),
            label("\(b).source", "Source", "Attribution", x: 400, y: 716, w: 1120, h: 60, size: 30, color: look.accent,
                  align: bold ? .left : .center, tracking: kickerTracking, uppercase: self != .editorialSerif, inset: 0, animationSteps: [sourceIn, sourceOut]),
        ]
        var order = [chipIn.id, markIn.id, frameIn.id, bodyIn.id, ruleIn.id, sourceIn.id, bodyOut.id, sourceOut.id, ruleOut.id, frameOut.id, markOut.id, chipOut.id]
        if self == .digital {
            let shadowIn = popIn("\(b).mark2.in", .withPrevious, delay: 0.05, duration: 0.6, from: 0.4), shadowOut = popOut("\(b).mark2.out", .withPrevious)
            objects.insert(label("\(b).mark2", "Quote Mark Shadow", "“", x: 262, y: 138, w: 220, h: 280, size: 300, font: markFont, color: look.accent2, align: .center, inset: 0,
                                 animationSteps: [shadowIn, shadowOut]), at: 2)
            order.insert(shadowIn.id, at: 2); order.append(shadowOut.id)
        }
        return themeSlide("quote", "Quote", objects, order: order, fullScreen: true)
    }

    public func makeOverlays() -> [Overlay] {
        func group(_ overlay: Overlay, _ folder: String) -> Overlay {
            var o = overlay
            o.folder = "\(title)/\(folder)"
            return o
        }
        return [
            group(namePlate(timed: false, base: overlayID("name")), "Lower Thirds"),
            group(namePlate(timed: true, base: overlayID("nameTimed")), "Lower Thirds"),
            group(verseLowerThird(base: overlayID("scriptureVerse")), "Lower Thirds"),
            group(pointLowerThird(base: overlayID("point")), "Lower Thirds"),
            group(callToAction(base: overlayID("ctaLower"), layout: .lowerThird), "Lower Thirds"),
            group(ticker(), "Lower Thirds"),
            group(verseSideThird(base: overlayID("verseSide")), "Side Thirds"),
            group(pointSideThird(base: overlayID("pointSide")), "Side Thirds"),
            group(callToAction(base: overlayID("cta"), layout: .sideThird), "Side Thirds"),
            group(searchCard(), "Full Screen"),
            group(cinematicBars(), "Full Screen"),
        ]
    }

    private func namePlate(timed: Bool, base b: String) -> Overlay {
        let look = look
        var objects: [SlideObject] = []
        var order: [String] = []

        let outTrigger: AnimationTrigger = timed ? .afterPrevious : .onClick
        let outDelay: Double? = timed ? 6 : nil

        switch self {
        case .cleanGeometric:
            let accentIn = plateIn("\(b).accent.in"), accentOut = plateOut("\(b).accent.out", .afterPrevious, delay: -0.2)
            let plateIn = step("\(b).plate.in", .in, .wipe, .afterPrevious, delay: -0.3, duration: 0.5, ramp: .out, edge: .left, softEdge: 40)
            let plateOut = step("\(b).plate.out", .out, .wipe, .withPrevious, delay: 0.05, duration: 0.4, ramp: .in, edge: .left, softEdge: 40)
            let nameIn = textIn("\(b).name.in", delay: -0.15, rise: 90), nameOut = textOut("\(b).name.out", outTrigger, delay: outDelay, distance: 90)
            let ruleIn = ruleIn("\(b).rule.in", delay: -0.35, duration: 0.45), ruleOut = ruleOut("\(b).rule.out", edge: .left)
            let titleIn = textIn("\(b).title.in", .withPrevious, delay: 0.1, rise: -60), titleOut = textOut("\(b).title.out", .withPrevious, distance: 60)
            objects = [
                block("\(b).plate", "Plate", x: 160, y: 820, w: 960, h: 170, fill: gradient(look.plate, look.plate2, angle: 0), radius: 0, animationSteps: [plateIn, plateOut]),
                block("\(b).accent", "Accent Bar", x: 120, y: 820, w: 40, h: 170, color: look.accent, radius: 0, animationSteps: [accentIn, accentOut]),
                matte("\(b).mask.name", x: 160, y: 812, w: 960, h: 98),
                label("\(b).name", "Name", "Full Name", x: 160, y: 824, w: 960, h: 84, size: 60, display: true, inset: 40, maskedBy: "\(b).mask.name", shrink: true, page: true, animationSteps: [nameIn, nameOut]),
                block("\(b).rule", "Rule", x: 200, y: 910, w: 300, h: 4, color: look.accent2, radius: 0, animationSteps: [ruleIn, ruleOut]),
                matte("\(b).mask.title", x: 160, y: 914, w: 960, h: 80),
                label("\(b).title", "Title", "Title or role", x: 160, y: 920, w: 960, h: 60, size: 32, color: look.accent2, tracking: 2, inset: 40, maskedBy: "\(b).mask.title", animationSteps: [titleIn, titleOut]),
            ]
            order = [accentIn.id, plateIn.id, nameIn.id, ruleIn.id, titleIn.id, nameOut.id, titleOut.id, ruleOut.id, plateOut.id, accentOut.id]

        case .editorialSerif:
            let bandIn = plateIn("\(b).band.in"), bandOut = plateOut("\(b).band.out", .afterPrevious, delay: -0.3)
            let topIn = ruleIn("\(b).top.in", delay: -0.7, duration: 0.8), topOut = ruleOut("\(b).top.out")
            let nameIn = textIn("\(b).name.in"), nameOut = textOut("\(b).name.out", outTrigger, delay: outDelay)
            let titleIn = textIn("\(b).title.in", .withPrevious, delay: 0.2), titleOut = textOut("\(b).title.out", .withPrevious)
            let bottomIn = ruleIn("\(b).bottom.in", .withPrevious, delay: 0.1, duration: 0.8), bottomOut = ruleOut("\(b).bottom.out", edge: .left)
            objects = [
                block("\(b).band", "Band", x: 0, y: 800, w: 1300, h: 220, fill: gradient(look.plate, look.plate2, angle: 0), radius: 0, animationSteps: [bandIn, bandOut]),
                block("\(b).top", "Hairline", x: 140, y: 828, w: 720, h: 2, color: look.accent, radius: 0, animationSteps: [topIn, topOut]),
                label("\(b).name", "Name", "Full Name", x: 140, y: 840, w: 1000, h: 92, size: 66, display: true, inset: 0, shrink: true, page: true, animationSteps: [nameIn, nameOut]),
                label("\(b).title", "Title", "Title or role", x: 140, y: 930, w: 1000, h: 50, size: 28, color: look.accent, tracking: kickerTracking, uppercase: true, inset: 0, animationSteps: [titleIn, titleOut]),
                block("\(b).bottom", "Hairline", x: 140, y: 992, w: 220, h: 2, color: look.accent, radius: 0, animationSteps: [bottomIn, bottomOut]),
            ]
            order = [bandIn.id, topIn.id, nameIn.id, titleIn.id, bottomIn.id, nameOut.id, titleOut.id, topOut.id, bottomOut.id, bandOut.id]

        case .boldBlocks:
            let yellowIn = plateIn("\(b).yellow.in"), yellowOut = plateOut("\(b).yellow.out", .afterPrevious, delay: -0.2)
            let nameIn = textIn("\(b).name.in"), nameOut = textOut("\(b).name.out", outTrigger, delay: outDelay)
            let blackIn = plateIn("\(b).black.in", .withPrevious, delay: 0.1), blackOut = plateOut("\(b).black.out", .withPrevious, delay: 0.05)
            let titleIn = textIn("\(b).title.in"), titleOut = textOut("\(b).title.out", .withPrevious)
            let chipIn = popIn("\(b).chip.in", delay: -0.1, duration: 0.35, from: 0), chipOut = popOut("\(b).chip.out")
            objects = [
                block("\(b).yellow", "Yellow Block", x: 120, y: 800, w: 820, h: 140, color: look.accent, skew: -12, animationSteps: [yellowIn, yellowOut]),
                label("\(b).name", "Name", "Full Name", x: 150, y: 800, w: 790, h: 140, size: 72, display: true, color: look.inkOnAccent, tracking: 2, uppercase: true, inset: 40, shrink: true, page: true, animationSteps: [nameIn, nameOut]),
                block("\(b).black", "Black Block", x: 200, y: 940, w: 680, h: 64, color: look.accent2, skew: -12, animationSteps: [blackIn, blackOut]),
                label("\(b).title", "Title", "Title or role", x: 230, y: 940, w: 650, h: 64, size: 30, color: look.ink, tracking: 5, uppercase: true, inset: 40, animationSteps: [titleIn, titleOut]),
                block("\(b).chip", "Chip", x: 94, y: 940, w: 64, h: 64, color: look.accent, skew: -12, animationSteps: [chipIn, chipOut]),
            ]
            order = [yellowIn.id, nameIn.id, blackIn.id, titleIn.id, chipIn.id, nameOut.id, titleOut.id, chipOut.id, blackOut.id, yellowOut.id]

        case .digital:
            let plateIn = plateIn("\(b).plate.in"), plateOut = plateOut("\(b).plate.out", .afterPrevious, delay: -0.3)
            let lbIn = popIn("\(b).lb.in", .afterPrevious, delay: -0.05, duration: 0.5, from: 0.2), lbOut = popOut("\(b).lb.out")
            let rbIn = popIn("\(b).rb.in", .withPrevious, delay: 0, duration: 0.5, from: 0.2), rbOut = popOut("\(b).rb.out")
            let kickIn = typeIn("\(b).kicker.in", delay: -0.3, duration: 0.8), kickOut = textOut("\(b).kicker.out", .withPrevious)
            let nameIn = textIn("\(b).name.in", delay: -0.3), nameOut = textOut("\(b).name.out", outTrigger, delay: outDelay)
            let bandIn = ruleIn("\(b).band.in", delay: -0.5, duration: 0.6), bandOut = ruleOut("\(b).band.out")
            let titleIn = textIn("\(b).title.in", .withPrevious, delay: 0.15), titleOut = textOut("\(b).title.out", .withPrevious)
            objects = [
                block("\(b).plate", "Plate", x: 120, y: 810, w: 960, h: 190, color: look.plate, stroke: ObjectStroke(colorHex: look.accent, width: 1.5), animationSteps: [plateIn, plateOut]),
                label("\(b).lb", "Bracket", "[", x: 96, y: 800, w: 90, h: 210, size: 150, display: true, color: look.accent, align: .center, inset: 0, animationSteps: [lbIn, lbOut]),
                label("\(b).rb", "Bracket", "]", x: 1014, y: 800, w: 90, h: 210, size: 150, display: true, color: look.accent, align: .center, inset: 0, animationSteps: [rbIn, rbOut]),
                label("\(b).kicker", "Kicker", "// speaker", x: 160, y: 822, w: 800, h: 40, size: 22, color: look.accent2, tracking: 4, inset: 0, animationSteps: [kickIn, kickOut]),
                label("\(b).name", "Name", "Full Name", x: 160, y: 858, w: 880, h: 80, size: 58, display: true, inset: 0, shrink: true, page: true, animationSteps: [nameIn, nameOut]),
                block("\(b).band", "Band", x: 160, y: 942, w: 760, h: 36, fill: gradient(look.accent, look.accent2, angle: 0), radius: 0, animationSteps: [bandIn, bandOut]),
                label("\(b).title", "Title", "Title or role", x: 160, y: 942, w: 760, h: 36, size: 22, color: look.inkOnAccent, tracking: 3, uppercase: true, inset: 16, animationSteps: [titleIn, titleOut]),
            ]
            order = [plateIn.id, lbIn.id, rbIn.id, kickIn.id, nameIn.id, bandIn.id, titleIn.id, nameOut.id, titleOut.id, kickOut.id, bandOut.id, lbOut.id, rbOut.id, plateOut.id]
        }
        return Overlay(id: b, name: timed ? "Name + Title (timed)" : "Name + Title", objects: objects, animationOrder: order)
    }

    private func verseLowerThird(base b: String) -> Overlay {
        let look = look
        let editorial = self == .editorialSerif
        let bold = self == .boldBlocks
        let bandIn = plateIn("\(b).band.in", edge: .bottom, big: true), bandOut = plateOut("\(b).band.out", .afterPrevious, delay: -0.25, edge: .bottom, big: true)
        let barIn = ruleIn("\(b).bar.in", delay: -0.3, edge: .top, duration: 0.6), barOut = ruleOut("\(b).bar.out", edge: .top)
        let verseIn = textIn("\(b).verse.in", delay: -0.3, rise: 30), verseOut = textOut("\(b).verse.out")

        let refPlateIn = editorial ? ruleIn("\(b).refplate.in", delay: 0.05, duration: 0.5) : plateIn("\(b).refplate.in", .afterPrevious, delay: -0.1, edge: .right)

        let refPlateOut = editorial ? ruleOut("\(b).refplate.out", .afterPrevious, delay: -0.05) : plateOut("\(b).refplate.out", .afterPrevious, delay: -0.05, edge: .right)
        let refIn = textIn("\(b).ref.in"), refOut = textOut("\(b).ref.out", .withPrevious)
        let objects = [
            block("\(b).band", "Band", x: 0, y: 720, w: 1920, h: 280, fill: gradient(look.plate2, look.plate, angle: 90), radius: 0, animationSteps: [bandIn, bandOut]),
            block("\(b).bar", "Bar", x: 160, y: 760, w: bold ? 18 : 8, h: 130, color: look.accent, radius: 0, skew: bold ? -12 : nil, animationSteps: [barIn, barOut]),
            label("\(b).verse", "Verse", "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.",
                  x: 210, y: 750, w: 1500, h: 150, size: 42, font: editorial ? "Georgia-Italic" : look.body, inset: 0, lineHeight: 1.12, shrink: true, page: true, animationSteps: [verseIn, verseOut]),

            block("\(b).refplate", editorial ? "Hairline" : "Reference Plate", x: 1380, y: editorial ? 972 : 914, w: 380, h: editorial ? 2 : 56,
                  color: look.accent, radius: self == .cleanGeometric ? 28 : 0, skew: bold ? -12 : nil, animationSteps: [refPlateIn, refPlateOut]),
            label("\(b).ref", "Reference", "John 3:16 (ESV)", x: 1380, y: 914, w: 380, h: 56, size: 26, display: true,
                  color: editorial ? look.accent : look.inkOnAccent, align: editorial ? .right : .center, tracking: kickerTracking - 2, uppercase: !editorial,
                  inset: editorial ? 0 : 24, animationSteps: [refIn, refOut]),
        ]
        return Overlay(id: b, name: "Verse + Reference", objects: objects,
                       animationOrder: [bandIn.id, barIn.id, verseIn.id, refPlateIn.id, refIn.id, verseOut.id, refOut.id, refPlateOut.id, barOut.id, bandOut.id])
    }

    private func pointLowerThird(base b: String) -> Overlay {
        let look = look
        let bold = self == .boldBlocks

        let bandIn = plateIn("\(b).band.in", edge: .bottom, big: true), bandOut = plateOut("\(b).band.out", .afterPrevious, delay: -0.05, edge: .bottom, big: true)
        let tagIn = popIn("\(b).tag.in", delay: 0, from: 0.6), tagOut = popOut("\(b).tag.out")
        let kickIn = textIn("\(b).kicker.in", .withPrevious, delay: 0.05), kickOut = textOut("\(b).kicker.out", .withPrevious)
        let textIn = textIn("\(b).text.in", delay: -0.2, rise: 36), textOut = textOut("\(b).text.out")
        let objects = [
            block("\(b).band", "Band", x: 0, y: 760, w: 1920, h: 240, fill: gradient(look.plate2, look.plate, angle: 90), radius: 0, animationSteps: [bandIn, bandOut]),
            block("\(b).tag", "Tag", x: 160, y: 792, w: 200, h: 48, color: look.accent, radius: self == .cleanGeometric ? 24 : 0, skew: bold ? -12 : nil, animationSteps: [tagIn, tagOut]),
            label("\(b).kicker", "Kicker", "Point 1", x: 160, y: 792, w: 200, h: 48, size: 22, display: true, color: look.inkOnAccent, align: .center, tracking: 3, uppercase: true, inset: 0, animationSteps: [kickIn, kickOut]),
            label("\(b).text", "Point", "Faith is not the absence of fear — it is trust that outlasts it.",
                  x: 160, y: 850, w: 1600, h: 130, size: 50, display: true, tracking: bold ? 2 : 0, uppercase: bold, inset: 0, lineHeight: 1.08, shrink: true, page: true, animationSteps: [textIn, textOut]),
        ]
        return Overlay(id: b, name: "Point", objects: objects,
                       animationOrder: [bandIn.id, tagIn.id, kickIn.id, textIn.id, textOut.id, kickOut.id, bandOut.id, tagOut.id])
    }

    private func pointSideThird(base b: String) -> Overlay {
        let look = look
        let push = VideoPush(zoom: 1.05, backdrop: true)

        let panelIn = plateIn("\(b).panel.in", edge: .right, big: true, videoPush: push), panelOut = plateOut("\(b).panel.out", .afterPrevious, delay: -0.05, edge: .right, big: true, videoPush: push)
        let barIn = ruleIn("\(b).bar.in", delay: -0.3, edge: .top, duration: 0.9), barOut = ruleOut("\(b).bar.out", edge: .top)
        let kickIn = textIn("\(b).kicker.in", delay: -0.3), kickOut = textOut("\(b).kicker.out", .withPrevious, toward: .right)
        let textIn = textIn("\(b).text.in", .withPrevious, delay: 0.15, rise: 40), textOut = textOut("\(b).text.out", toward: .right)
        let objects = [
            block("\(b).panel", "Panel", x: 1280, y: 0, w: 640, h: 1080, fill: gradient(look.plate2, look.plate, angle: 0), radius: 0, animationSteps: [panelIn, panelOut]),
            block("\(b).bar", "Bar", x: 1280, y: 0, w: self == .boldBlocks ? 18 : 6, h: 1080, color: look.accent, radius: 0, animationSteps: [barIn, barOut]),
            label("\(b).kicker", "Kicker", "Point 1", x: 1340, y: 300, w: 520, h: 50, size: 28, color: look.accent, tracking: kickerTracking, uppercase: true, inset: 0, animationSteps: [kickIn, kickOut]),
            label("\(b).text", "Point", "Faith is not the absence of fear — it is trust that outlasts it.",
                  x: 1340, y: 360, w: 520, h: 440, size: 50, display: true, valign: .top, uppercase: self == .boldBlocks, inset: 0, lineHeight: 1.1, shrink: true, page: true, animationSteps: [textIn, textOut]),
        ]
        return Overlay(id: b, name: "Point (Side Third)", objects: objects,
                       animationOrder: [panelIn.id, barIn.id, kickIn.id, textIn.id, textOut.id, kickOut.id, panelOut.id, barOut.id])
    }

    private func verseSideThird(base b: String) -> Overlay {
        let look = look
        let editorial = self == .editorialSerif
        let push = VideoPush(zoom: 1.05, backdrop: true)

        let panelIn = plateIn("\(b).panel.in", edge: .right, big: true, videoPush: push), panelOut = plateOut("\(b).panel.out", .afterPrevious, delay: -0.05, edge: .right, big: true, videoPush: push)
        let barIn = ruleIn("\(b).bar.in", delay: -0.3, edge: .top, duration: 0.9), barOut = ruleOut("\(b).bar.out", edge: .top)
        let verseIn = textIn("\(b).verse.in", delay: -0.3, rise: 40), verseOut = textOut("\(b).verse.out", toward: .right)

        let ruleIn = ruleIn("\(b).rule.in", delay: -0.15), ruleOut = ruleOut("\(b).rule.out", edge: .right)
        let refIn = textIn("\(b).ref.in", .withPrevious, delay: 0.1), refOut = textOut("\(b).ref.out", .withPrevious, toward: .right)
        let objects = [
            block("\(b).panel", "Panel", x: 1280, y: 0, w: 640, h: 1080, fill: gradient(look.plate2, look.plate, angle: 0), radius: 0, animationSteps: [panelIn, panelOut]),
            block("\(b).bar", "Bar", x: 1280, y: 0, w: self == .boldBlocks ? 18 : 6, h: 1080, color: look.accent, radius: 0, animationSteps: [barIn, barOut]),
            label("\(b).verse", "Verse", "For God so loved the world, that he gave his only Son, that whoever believes in him should not perish but have eternal life.",
                  x: 1340, y: 240, w: 520, h: 520, size: 40, font: editorial ? "Georgia-Italic" : look.body, valign: .top, inset: 0, lineHeight: 1.15, shrink: true, page: true, animationSteps: [verseIn, verseOut]),
            block("\(b).rule", "Rule", x: 1340, y: 780, w: 120, h: 4, color: look.accent, radius: 0, animationSteps: [ruleIn, ruleOut]),
            label("\(b).ref", "Reference", "John 3:16 (ESV)", x: 1340, y: 796, w: 520, h: 50, size: 26, display: true, color: look.accent,
                  tracking: kickerTracking - 2, uppercase: !editorial, inset: 0, animationSteps: [refIn, refOut]),
        ]
        return Overlay(id: b, name: "Verse + Reference (Side Third)", objects: objects,
                       animationOrder: [panelIn.id, barIn.id, verseIn.id, ruleIn.id, refIn.id, verseOut.id, refOut.id, panelOut.id, ruleOut.id, barOut.id])
    }

    enum CardLayout { case full, lowerThird, sideThird }

    private func callToAction(base b: String, layout: CardLayout) -> Overlay {
        let look = look
        let bold = self == .boldBlocks

        let card: (x: Double, y: Double, w: Double, h: Double) = switch layout {
        case .sideThird: (1220, 110, 600, 340)
        case .lowerThird: (120, 780, 1680, 220)
        case .full: (360, 240, 1200, 600)
        }
        let pad: Double = layout == .full ? 72 : 40
        let headSize: Double = layout == .full ? 80 : 44
        let bodySize: Double = layout == .full ? 40 : 28
        let cardEdge: AnimationEdge = layout == .lowerThird ? .bottom : .right
        let away: AnimationEdge = layout == .sideThird ? .top : .bottom
        let stroked = self == .editorialSerif || self == .digital
        var cardIn = stroked
            ? drawIn("\(b).card.in", .withPrevious, duration: 1.2)                 
            : self == .cleanGeometric || layout == .full
                ? step("\(b).card.in", .in, .scale, .withPrevious, duration: 0.55, ramp: .out, fade: true, fromScale: 0.9)
                : plateIn("\(b).card.in", edge: cardEdge)

        var cardOut = self == .cleanGeometric || layout == .full
            ? step("\(b).card.out", .out, .scale, .afterPrevious, delay: -0.05, duration: 0.45, ramp: .in, fade: true, fromScale: 0.9)
            : plateOut("\(b).card.out", .afterPrevious, delay: -0.05, edge: cardEdge)

        if layout == .sideThird {
            cardIn.videoPush = VideoPush(zoom: 1.05, backdrop: true)
            cardOut.videoPush = VideoPush(zoom: 1.05, backdrop: true)
        }
        let dotIn = popIn("\(b).dot.in"), dotOut = popOut("\(b).dot.out")
        let headIn = textIn("\(b).head.in", delay: -0.2), headOut = textOut("\(b).head.out", toward: away)
        let bodyIn = textIn("\(b).body.in", .withPrevious, delay: 0.12), bodyOut = textOut("\(b).body.out", .withPrevious, toward: away)
        let pillIn = popIn("\(b).pill.in", .afterPrevious, delay: -0.15, duration: 0.45, from: 0.7), pillOut = popOut("\(b).pill.out")
        let pillTextIn = textIn("\(b).pilltext.in", .withPrevious, delay: 0.1), pillTextOut = textOut("\(b).pilltext.out", .withPrevious, toward: away)
        let dotSize: Double = layout == .full ? 72 : 56
        let headX = card.x + pad + dotSize + 20
        let bodyY = card.y + pad + (layout == .full ? 110 : 76)
        let pillY = card.y + card.h - pad - 60
        let bodyW = layout == .lowerThird ? card.w - pad * 2 - 360 : card.w - pad * 2
        let pillX = layout == .lowerThird ? card.x + card.w - pad - 260 : card.x + pad
        let objects = [
            block("\(b).card", "Card", x: card.x, y: card.y, w: card.w, h: card.h, fill: bold ? fill(look.plate) : gradient(look.plate, look.plate2, angle: 135),
                  radius: self == .cleanGeometric ? 18 : look.radius,
                  stroke: self == .editorialSerif || self == .digital ? ObjectStroke(colorHex: look.accent, width: self == .digital ? 1.5 : 2) : nil,
                  shadow: self == .cleanGeometric ? ObjectShadow(colorHex: "#00000066", blurRadius: 30, offsetX: 0, offsetY: 12) : nil,
                  skew: bold && layout != .lowerThird ? -6 : nil, animationSteps: [cardIn, cardOut]),
            block("\(b).dot", "Icon", x: card.x + pad, y: card.y + pad, w: dotSize, h: dotSize, color: look.accent, radius: dotSize / 2, ellipse: !bold, animationSteps: [dotIn, dotOut]),
            label("\(b).head", "Heading", "Next Steps", x: headX, y: card.y + pad - 4, w: card.x + card.w - pad - headX, h: dotSize + 8, size: headSize, display: true,
                  tracking: bold ? 2 : 0, uppercase: bold, inset: 0, shrink: layout != .full, page: layout != .full, animationSteps: [headIn, headOut]),
            label("\(b).body", "Body", "Text NEXT to 555-0100 or stop by the Welcome Desk after the service.", x: card.x + pad, y: bodyY, w: bodyW,
                  h: layout == .lowerThird ? 70 : (pillY - bodyY - 16), size: bodySize, valign: .top, inset: 0, lineHeight: 1.1, shrink: layout != .full, page: layout != .full, animationSteps: [bodyIn, bodyOut]),
            block("\(b).pill", "Button", x: pillX, y: layout == .lowerThird ? card.y + (card.h - 60) / 2 : pillY, w: 260, h: 60, color: look.accent,
                  radius: self == .cleanGeometric ? 30 : look.radius, skew: bold ? -12 : nil, animationSteps: [pillIn, pillOut]),
            label("\(b).pilltext", "Button Label", "Text NEXT", x: pillX, y: layout == .lowerThird ? card.y + (card.h - 60) / 2 : pillY, w: 260, h: 60, size: 24, display: true,
                  color: look.inkOnAccent, align: .center, tracking: 2, uppercase: true, inset: 0, animationSteps: [pillTextIn, pillTextOut]),
        ]
        return Overlay(id: b, name: "Call to Action", objects: objects,
                       animationOrder: [cardIn.id, dotIn.id, headIn.id, bodyIn.id, pillIn.id, pillTextIn.id, headOut.id, bodyOut.id, pillTextOut.id, cardOut.id, pillOut.id, dotOut.id])
    }

    private func searchCard() -> Overlay {
        let b = overlayID("search")
        let look = look
        let editorial = self == .editorialSerif

        var fieldIn = drawIn("\(b).field.in", .withPrevious, duration: 1.1)
        var fieldOut = popOut("\(b).field.out", .afterPrevious, delay: -0.15)

        fieldIn.videoPush = VideoPush(mode: .blurBackground, zoom: 1.15)
        fieldOut.videoPush = VideoPush(mode: .blurBackground, zoom: 1.15)
        let glyphIn = popIn("\(b).glyph.in", delay: -0.2), glyphOut = popOut("\(b).glyph.out")
        let queryIn = typeIn("\(b).query.in", duration: 1.8), queryOut = textOut("\(b).query.out")
        let fieldFill: ObjectFill = editorial ? fill("#00000000") : self == .boldBlocks ? fill(look.ink) : fill(look.plate)
        let objects = [
            block("\(b).field", "Field", x: 460, y: 470, w: 1000, h: 120, fill: fieldFill, radius: self == .cleanGeometric ? 60 : look.radius,
                  stroke: ObjectStroke(colorHex: look.accent, width: self == .boldBlocks ? 8 : editorial ? 1.5 : 2),
                  skew: self == .boldBlocks ? -8 : nil, animationSteps: [fieldIn, fieldOut]),
            SlideObject(id: "\(b).glyph", objectKind: .shape, name: "Search Icon", text: "", x: 504, y: 502, width: 56, height: 56,
                        shapeKind: .path, pathData: IconCatalog.search, fill: fill(look.accent), animationSteps: [glyphIn, glyphOut]),
            label("\(b).query", "Query", "how do I find peace?", x: 584, y: 470, w: 840, h: 120, size: 44,
                  color: self == .boldBlocks ? look.inkOnAccent : look.ink, inset: 0, animationSteps: [queryIn, queryOut]),
        ]
        return Overlay(id: b, name: "Search", objects: objects,
                       animationOrder: [fieldIn.id, glyphIn.id, queryIn.id, queryOut.id, glyphOut.id, fieldOut.id])
    }

    private func cinematicBars() -> Overlay {
        let b = overlayID("bars")
        let topIn = step("\(b).top.in", .in, .move, .withPrevious, duration: 3.5, ramp: .both, edge: .top)
        let bottomIn = step("\(b).bottom.in", .in, .move, .withPrevious, duration: 3.5, ramp: .both, edge: .bottom)
        let topOut = step("\(b).top.out", .out, .move, .onDismiss, duration: 3.0, ramp: .both, edge: .top)
        let bottomOut = step("\(b).bottom.out", .out, .move, .withPrevious, duration: 3.0, ramp: .both, edge: .bottom)
        let edgeIn = ruleIn("\(b).edge.in", delay: -1.0, duration: 2.0), edgeOut = ruleOut("\(b).edge.out")
        let edge2In = ruleIn("\(b).edge2.in", .withPrevious, delay: 0, edge: .right, duration: 2.0), edge2Out = ruleOut("\(b).edge2.out", edge: .right)
        let objects = [
            block("\(b).top", "Top Bar", x: 0, y: 0, w: 1920, h: 140, color: "#000000FF", radius: 0, animationSteps: [topIn, topOut]),
            block("\(b).bottom", "Bottom Bar", x: 0, y: 940, w: 1920, h: 140, color: "#000000FF", radius: 0, animationSteps: [bottomIn, bottomOut]),
            block("\(b).edge", "Top Edge", x: 0, y: 138, w: 1920, h: 2, color: look.accent, radius: 0, animationSteps: [edgeIn, edgeOut]),
            block("\(b).edge2", "Bottom Edge", x: 0, y: 940, w: 1920, h: 2, color: look.accent, radius: 0, animationSteps: [edge2In, edge2Out]),
        ]
        return Overlay(id: b, name: "Cinematic Bars", objects: objects,
                       animationOrder: [topIn.id, bottomIn.id, edgeIn.id, edge2In.id, topOut.id, bottomOut.id, edgeOut.id, edge2Out.id])
    }

    private func ticker() -> Overlay {
        let b = overlayID("ticker")
        let look = look
        let plateIn = step("\(b).plate.in", .in, .wipe, .withPrevious, duration: 0.6, ramp: .out, edge: .left, softEdge: 30)
        let plateOut = step("\(b).plate.out", .out, .wipe, .afterPrevious, delay: -0.1, duration: 0.5, ramp: .in, edge: .left, softEdge: 30)
        let tagIn = popIn("\(b).tag.in", delay: 0, from: 0.6), tagOut = popOut("\(b).tag.out")
        let tagTextIn = textIn("\(b).tagtext.in", .withPrevious, delay: 0.05), tagTextOut = textOut("\(b).tagtext.out", .withPrevious)
        let lineIn = fadeIn("\(b).text.in"), lineOut = fadeOut("\(b).text.out", .onDismiss)
        var style = TextStyle(fontName: look.body, fontSize: 38, colorHex: look.ink, horizontalAlignment: .left, verticalAlignment: .middle)
        style.scroll = BlockScroll(axis: .left, speed: 170)
        let line = SlideObject(id: "\(b).text", objectKind: .text, name: "Ticker Text",
                               text: "Welcome — service times, upcoming events and announcements scroll here.   •   Next Steps class Sunday 9am   •   Text NEXT to 555-0100",
                               x: 300, y: 990, width: 1620, height: 80, textStyle: style, animationSteps: [lineIn, lineOut])
        let objects = [
            block("\(b).plate", "Plate", x: 0, y: 990, w: 1920, h: 80, fill: gradient(look.plate, look.plate2, angle: 0), radius: 0, animationSteps: [plateIn, plateOut]),
            line,
            block("\(b).tag", "Tag", x: 0, y: 990, w: 280, h: 80, color: look.accent, radius: 0, skew: self == .boldBlocks ? -12 : nil, animationSteps: [tagIn, tagOut]),
            label("\(b).tagtext", "Tag Text", "Announcements", x: 0, y: 990, w: 280, h: 80, size: 24, display: true, color: look.inkOnAccent, align: .center, tracking: 2, uppercase: true, inset: 0, animationSteps: [tagTextIn, tagTextOut]),
        ]
        return Overlay(id: b, name: "Ticker", objects: objects,
                       animationOrder: [plateIn.id, tagIn.id, tagTextIn.id, lineIn.id, lineOut.id, tagTextOut.id, tagOut.id, plateOut.id])
    }
}
