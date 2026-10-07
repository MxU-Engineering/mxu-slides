import Foundation
import Testing
import PresenterCore
@testable import PPTXImport

struct PPTXDocumentMapperTests {

    private func deck(
        cx: Double = 12_192_000, cy: Double = 6_858_000, slides: [PPTXSlide]
    ) -> PPTXDeck {
        PPTXDeck(slideWidthEMU: cx, slideHeightEMU: cy, slides: slides)
    }

    private func transform(
        x: Double = 914_400, y: Double = 457_200, cx: Double = 1_828_800, cy: Double = 914_400,
        rot: Double = 0, flipH: Bool = false, flipV: Bool = false
    ) -> PPTXTransform {
        PPTXTransform(offXEMU: x, offYEMU: y, extXEMU: cx, extYEMU: cy,
                      rotation60k: rot, flipH: flipH, flipV: flipV)
    }

    private func run(
        _ text: String, font: String? = "Helvetica", size: Double? = 4000,
        bold: Bool = false, underline: Bool = false, strike: Bool = false,
        color: String? = nil, tracking: Double? = nil
    ) -> PPTXRun {
        PPTXRun(text: text, fontFamily: font, sizeHundredthsPt: size, bold: bold,
                underline: underline, strike: strike, colorHex: color,
                trackingHundredthsPt: tracking)
    }

    private func textShape(
        _ runs: [PPTXRun], anchor: String? = nil, alignment: String? = nil,
        hasNormAutofit: Bool = false, fontScale: Double? = nil,
        transform: PPTXTransform? = nil
    ) -> PPTXShape {
        var body = PPTXTextBody()
        body.anchor = anchor
        body.hasNormAutofit = hasNormAutofit
        body.autofitFontScale = fontScale
        body.paragraphs = [PPTXParagraph(alignment: alignment, runs: runs)]
        return PPTXShape(kind: .shape, name: "Text Box",
                         transform: transform ?? self.transform(), textBody: body)
    }

    private func map(_ deck: PPTXDeck) -> PPTXMappedDocument {
        PPTXDocumentMapper.map(deck, fallbackName: "Deck", sourceID: "test-id")
    }

    @Test func sixteenNineDeckScalesEMUToSceneAndLeavesCanvasNil() {
        let mapped = map(deck(slides: [PPTXSlide(shapes: [textShape([run("Hello")])])]))
        #expect(mapped.presentation.canvasWidth == nil)
        #expect(mapped.presentation.canvasHeight == nil)
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.objectKind == .text)
        #expect(object.x == 144)
        #expect(object.y == 72)
        #expect(object.width == 288)
        #expect(object.height == 144)

        #expect(object.textStyle?.fontSize == 80)
    }

    @Test func fourThreeDeckGetsExplicitCanvasAndKScaledFonts() {
        let mapped = map(deck(cx: 9_144_000, slides: [PPTXSlide(shapes: [textShape([run("Hello")])])]))
        #expect(mapped.presentation.canvasWidth == 1440)
        #expect(mapped.presentation.canvasHeight == 1080)
        #expect(mapped.presentation.slides[0].objects[0].textStyle?.fontSize == 80)
    }

    @Test func rotationConvertsWithoutNegation() {
        let shape = textShape([run("Hello")], transform: transform(rot: 5_400_000))
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.presentation.slides[0].objects[0].rotationDegrees == 90)
    }

    @Test func flipsCarryAndAbsentFlipsStayNil() {
        let flipped = textShape([run("Hello")], transform: transform(flipH: true, flipV: true))
        let plain = textShape([run("There")])
        let mapped = map(deck(slides: [PPTXSlide(shapes: [flipped, plain])]))
        #expect(mapped.presentation.slides[0].objects[0].flipHorizontal == true)
        #expect(mapped.presentation.slides[0].objects[0].flipVertical == true)
        #expect(mapped.presentation.slides[0].objects[1].flipHorizontal == nil)
        #expect(mapped.presentation.slides[0].objects[1].flipVertical == nil)
    }

    @Test func pictureCropBecomesSourceRectWithStretch() {
        var picture = PPTXShape(kind: .picture, name: "Photo", transform: transform())
        picture.mediaPath = "/tmp/extracted/ppt/media/image1.png"
        picture.sourceRect = PPTXSourceRect(l: 25_000, t: 10_000, r: 25_000, b: 10_000)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [picture])]))
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .shape)
        #expect(object.fill?.mediaId?.hasPrefix(PPTXDocumentMapper.placeholderPrefix) == true)
        #expect(object.fill?.mediaScaleMode == .stretch)
        #expect(object.fill?.mediaSourceRect == MediaSourceRect(x: 0.25, y: 0.1, width: 0.5, height: 0.8))
        #expect(mapped.mediaWants.count == 1)
        #expect(mapped.mediaWants[0].absolutePath == "/tmp/extracted/ppt/media/image1.png")
    }

    @Test func uncroppedPictureHasNoSourceRect() {
        var picture = PPTXShape(kind: .picture, name: "Photo", transform: transform())
        picture.mediaPath = "/tmp/extracted/ppt/media/image1.png"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [picture])]))
        #expect(mapped.presentation.slides[0].objects[0].fill?.mediaSourceRect == nil)
        #expect(mapped.presentation.slides[0].objects[0].fill?.mediaScaleMode == .stretch)
    }

    @Test func roundRectCornerRadiusScalesFromAdjustment() {
        var shape = PPTXShape(kind: .shape, name: "Card", transform: transform())
        shape.presetGeometry = "roundRect"
        shape.fill = .solid(colorHex: "FF0000")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.shapeKind == .roundedRectangle)

        #expect(abs((object.cornerRadius ?? 0) - 0.16667 * 144) < 0.01)

        shape.roundRectAdjustment = 50_000
        let explicit = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(explicit.presentation.slides[0].objects[0].cornerRadius == 72)
    }

    @Test func unknownPresetApproximatesAsRectangleWithWarning() {
        var shape = PPTXShape(kind: .shape, name: "Heart", transform: transform())
        shape.presetGeometry = "heart"
        shape.fill = .solid(colorHex: "FF0000")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.presentation.slides[0].objects[0].shapeKind == .rectangle)
        #expect(mapped.warnings.contains { $0.contains("heart") && $0.contains("approximated") })
    }

    @Test func solidFillCarriesHexWithAlpha() {
        var shape = PPTXShape(kind: .shape, name: "Band", transform: transform())
        shape.fill = .solid(colorHex: "1a2b3c")
        shape.stroke = PPTXStroke(colorHex: "00FF00", widthEMU: 25_400)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.fill == ObjectFill(fillKind: .solid, colorHex: "#1A2B3CFF"))

        #expect(object.stroke == ObjectStroke(colorHex: "#00FF00FF", width: 4))
    }

    @Test func inklessEmptyShapeIsDropped() {
        let shape = PPTXShape(kind: .shape, name: "Ghost", transform: transform())
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.presentation.slides[0].objects.isEmpty)
    }

    @Test func gradientFillMapsAngleAndStopUnits() {
        var shape = PPTXShape(kind: .shape, name: "Wash", transform: transform())
        shape.fill = .gradient(PPTXGradient(angle60k: 2_700_000, stops: [
            PPTXGradientStop(position: 0, colorHex: "FF0000FF"),
            PPTXGradientStop(position: 100_000, colorHex: "0000FF80"),
        ]))
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let fill = mapped.presentation.slides[0].objects[0].fill
        #expect(fill == ObjectFill(
            fillKind: .linearGradient,
            gradientAngleDegrees: 45,
            gradientStops: [
                GradientStop(colorHex: "#FF0000FF", position: 0),
                GradientStop(colorHex: "#0000FF80", position: 1),
            ]))
    }

    @Test func gradientBackgroundRidesTheBackdropLayer() {
        var slide = PPTXSlide()
        slide.backgroundFill = .gradient(PPTXGradient(angle60k: 5_400_000, stops: [
            PPTXGradientStop(position: 0, colorHex: "000000FF"),
            PPTXGradientStop(position: 100_000, colorHex: "FFFFFFFF"),
        ]))
        let mapped = map(deck(slides: [slide]))

        #expect(mapped.presentation.slides[0].objects.isEmpty)
        let fill = mapped.presentation.backgroundFill
        #expect(fill?.fillKind == .linearGradient)
        #expect(fill?.gradientAngleDegrees == 90)
        #expect(mapped.presentation.slides[0].background == nil)
    }

    @Test func midLineBoldRunBecomesFontNameRun() throws {
        let shape = textShape([run("Hello "), run("bold", bold: true), run(" world")])
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.textStyle?.fontName == "Helvetica")
        let styleRun = try #require(object.styleRuns?.first)
        #expect(styleRun.line == 0)
        #expect(styleRun.column == 6)
        #expect(styleRun.length == 4)
        #expect(styleRun.fontName == "Helvetica-Bold")
    }

    @Test func partialUnderlineBecomesExactRuns() {
        let shape = textShape([run("ab"), run("cd", underline: true), run("ef")])
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.textStyle?.underline == nil)
        #expect(object.styleRuns == [TextStyleRun(line: 0, column: 2, length: 2, underline: true)])
    }

    @Test func bodyUniformUnderlineRidesTextStyle() {
        let shape = textShape([run("all", underline: true), run(" underlined", underline: true)])
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.textStyle?.underline == true)
        #expect(object.styleRuns == nil)
    }

    @Test func anchorIsAlwaysWritten() {
        let absent = textShape([run("top")])
        let centered = textShape([run("middle")], anchor: "ctr")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [absent, centered])]))

        #expect(mapped.presentation.slides[0].objects[0].textStyle?.verticalAlignment == .top)
        #expect(mapped.presentation.slides[0].objects[1].textStyle?.verticalAlignment == .middle)
    }

    @Test func alignmentMapsAndJustifiedWarns() {
        let centered = textShape([run("mid")], alignment: "ctr")
        let justified = textShape([run("both edges")], alignment: "just")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [centered, justified])]))
        #expect(mapped.presentation.slides[0].objects[0].textStyle?.horizontalAlignment == .center)
        #expect(mapped.presentation.slides[0].objects[1].textStyle?.horizontalAlignment == .left)
        #expect(mapped.warnings.contains { $0.contains("justified") })
    }

    @Test func normAutofitShrinksAndBakesFontScale() {
        let shape = textShape([run("shrunk")], hasNormAutofit: true, fontScale: 62_500)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let style = mapped.presentation.slides[0].objects[0].textStyle
        #expect(style?.autoShrink == true)

        #expect(style?.fontSize == 50)
    }

    @Test func defaultBodyInsetsAreWrittenScaled() {
        let mapped = map(deck(slides: [PPTXSlide(shapes: [textShape([run("Hi")])])]))
        let style = mapped.presentation.slides[0].objects[0].textStyle

        #expect(style?.insetTop == 7.2)
        #expect(style?.insetBottom == 7.2)
        #expect(style?.insetLeft == 14.4)
        #expect(style?.insetRight == 14.4)
    }

    @Test func lineDominantDeltaBecomesLineStyleOverride() {
        var body = PPTXTextBody()
        body.paragraphs = [
            PPTXParagraph(runs: [run("The long base line")]),
            PPTXParagraph(runs: [run("Small line", size: 2000)]),
        ]
        let shape = PPTXShape(kind: .shape, name: "Text", transform: transform(), textBody: body)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.text == "The long base line\nSmall line")
        #expect(object.textStyle?.lineStyles == [LineStyleOverride(lineIndex: 1, fontSize: 40)])
        #expect(object.styleRuns == nil)
    }

    @Test func distinctBackgroundsStayPerSlideWithNoSyntheticRect() {
        var first = PPTXSlide(shapes: [textShape([run("Over")])])
        first.backgroundFill = .solid(colorHex: "112233")
        var second = PPTXSlide()
        second.backgroundFill = .solid(colorHex: "445566")
        let mapped = map(deck(slides: [first, second]))

        #expect(mapped.presentation.backgroundFill == nil)
        #expect(mapped.presentation.slides[0].backgroundFill == ObjectFill(fillKind: .solid, colorHex: "#112233FF"))
        #expect(mapped.presentation.slides[1].backgroundFill == ObjectFill(fillKind: .solid, colorHex: "#445566FF"))
        #expect(mapped.presentation.slides[0].objects.count == 1)
        #expect(mapped.presentation.slides[0].objects[0].objectKind == .text)
    }

    @Test func uniformBackgroundHoistsToPresentation() {
        var first = PPTXSlide()
        first.backgroundFill = .solid(colorHex: "112233")
        var second = PPTXSlide()
        second.backgroundFill = .solid(colorHex: "112233")
        let mapped = map(deck(slides: [first, second]))
        #expect(mapped.presentation.backgroundFill == ObjectFill(fillKind: .solid, colorHex: "#112233FF"))
        #expect(mapped.presentation.slides.allSatisfy { $0.backgroundFill == nil })

        let mixed = map(deck(slides: [first, PPTXSlide()]))
        #expect(mixed.presentation.backgroundFill == nil)
        #expect(mixed.presentation.slides[0].backgroundFill != nil)
    }

    @Test func pictureBackgroundBecomesBottomSlideObject() throws {
        var slide = PPTXSlide()
        slide.backgroundFill = .blip(path: "/tmp/extracted/ppt/media/bg.png")
        let mapped = map(deck(slides: [slide]))
        #expect(mapped.presentation.slides[0].background == nil)
        let backdrop = try #require(mapped.presentation.slides[0].objects.first)
        #expect(backdrop.objectKind == .shape)
        #expect(backdrop.fill?.fillKind == .media)
        #expect(backdrop.fill?.mediaId?.hasPrefix(PPTXDocumentMapper.placeholderPrefix) == true)
        #expect(backdrop.x == 0)
        #expect(backdrop.width == 1920)
        #expect(backdrop.height == 1080)
        #expect(mapped.mediaWants.count == 1)
    }

    @Test func fadeMapsAndPushDegradesToDissolveWithWarning() {
        var fade = PPTXSlide()
        fade.transition = PPTXTransition(kind: "fade", durationSeconds: 0.7)
        var fadeBlack = PPTXSlide()
        fadeBlack.transition = PPTXTransition(kind: "fade", throughBlack: true, durationSeconds: 0.5)
        var push = PPTXSlide()
        push.transition = PPTXTransition(kind: "push", durationSeconds: 0.75, advanceAfterMs: 5000)
        let mapped = map(deck(slides: [fade, fadeBlack, push]))
        #expect(mapped.presentation.slides[0].transition == Transition(transitionKind: .dissolve, durationSeconds: 0.7))
        #expect(mapped.presentation.slides[1].transition == Transition(transitionKind: .fadeBlack, durationSeconds: 0.5))
        #expect(mapped.presentation.slides[2].transition == Transition(transitionKind: .dissolve, durationSeconds: 0.75))
        #expect(mapped.presentation.slides[2].autoAdvance == AutoAdvance(delaySeconds: 5))
        #expect(mapped.warnings.contains { $0.contains("push") && $0.contains("dissolve") })
    }

    @Test func advanceTimeWithoutEffectStillAutoAdvances() {
        var slide = PPTXSlide()
        slide.transition = PPTXTransition(advanceAfterMs: 3000)
        let mapped = map(deck(slides: [slide]))
        #expect(mapped.presentation.slides[0].transition == nil)
        #expect(mapped.presentation.slides[0].autoAdvance == AutoAdvance(delaySeconds: 3))
    }

    @Test func notesCarry() {
        var slide = PPTXSlide()
        slide.notes = "Greet the guest speaker"
        let mapped = map(deck(slides: [slide]))
        #expect(mapped.presentation.slides[0].notes == "Greet the guest speaker")
    }

    @Test func curatedPresetsBecomeExactPaths() {
        var triangle = PPTXShape(kind: .shape, name: "Tri", transform: transform())
        triangle.presetGeometry = "triangle"
        triangle.fill = .solid(colorHex: "FF0000")
        var star = triangle
        star.presetGeometry = "star5"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [triangle, star])]))
        let triangleObject = mapped.presentation.slides[0].objects[0]
        #expect(triangleObject.shapeKind == .path)
        #expect(triangleObject.pathData == "M 0.5000 0.0000 C 0.5000 0.0000 1.0000 1.0000 1.0000 1.0000 C 1.0000 1.0000 0.0000 1.0000 0.0000 1.0000 C 0.0000 1.0000 0.5000 0.0000 0.5000 0.0000 Z")
        let starObject = mapped.presentation.slides[0].objects[1]
        #expect(starObject.shapeKind == .path)
        #expect(starObject.pathData == "M 0.5000 0.0000 C 0.5000 0.0000 0.3820 0.3820 0.3820 0.3820 C 0.3820 0.3820 0.0000 0.3820 0.0000 0.3820 C 0.0000 0.3820 0.3090 0.6180 0.3090 0.6180 C 0.3090 0.6180 0.1910 1.0000 0.1910 1.0000 C 0.1910 1.0000 0.5000 0.7639 0.5000 0.7639 C 0.5000 0.7639 0.8090 1.0000 0.8090 1.0000 C 0.8090 1.0000 0.6910 0.6180 0.6910 0.6180 C 0.6910 0.6180 1.0000 0.3820 1.0000 0.3820 C 1.0000 0.3820 0.6180 0.3820 0.6180 0.3820 C 0.6180 0.3820 0.5000 0.0000 0.5000 0.0000 Z")
        #expect(!mapped.warnings.contains { $0.contains("approximated as a rectangle") })
    }

    @Test func flowChartConnectorIsACircleNotAnApproximation() {
        var shape = PPTXShape(kind: .shape, name: "Node", transform: transform())
        shape.presetGeometry = "flowChartConnector"
        shape.fill = .solid(colorHex: "FF0000")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.presentation.slides[0].objects[0].shapeKind == .ellipse)
        #expect(mapped.warnings.isEmpty)
    }

    @Test func verticalArrowsJoinTheCuratedTable() {
        var up = PPTXShape(kind: .shape, name: "Up", transform: transform())
        up.presetGeometry = "upArrow"
        up.fill = .solid(colorHex: "FF0000")
        var down = up
        down.presetGeometry = "downArrow"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [up, down])]))
        #expect(mapped.presentation.slides[0].objects[0].pathData == "M 0.2500 1.0000 C 0.2500 1.0000 0.2500 0.4000 0.2500 0.4000 C 0.2500 0.4000 0.0000 0.4000 0.0000 0.4000 C 0.0000 0.4000 0.5000 0.0000 0.5000 0.0000 C 0.5000 0.0000 1.0000 0.4000 1.0000 0.4000 C 1.0000 0.4000 0.7500 0.4000 0.7500 0.4000 C 0.7500 0.4000 0.7500 1.0000 0.7500 1.0000 C 0.7500 1.0000 0.2500 1.0000 0.2500 1.0000 Z")
        #expect(mapped.presentation.slides[0].objects[1].pathData == "M 0.2500 0.0000 C 0.2500 0.0000 0.2500 0.6000 0.2500 0.6000 C 0.2500 0.6000 0.0000 0.6000 0.0000 0.6000 C 0.0000 0.6000 0.5000 1.0000 0.5000 1.0000 C 0.5000 1.0000 1.0000 0.6000 1.0000 0.6000 C 1.0000 0.6000 0.7500 0.6000 0.7500 0.6000 C 0.7500 0.6000 0.7500 0.0000 0.7500 0.0000 C 0.7500 0.0000 0.2500 0.0000 0.2500 0.0000 Z")
        #expect(mapped.warnings.isEmpty)
    }

    @Test func missingFontsNeverArmAutoShrink() {
        let missing = map(deck(slides: [PPTXSlide(shapes: [
            textShape([run("Hello", font: "DefinitelyNotInstalledSans")]),
        ])]))
        #expect(missing.presentation.slides[0].objects[0].textStyle?.autoShrink == nil)

        var body = PPTXTextBody()
        body.hasSpAutofit = true
        body.paragraphs = [PPTXParagraph(alignment: nil, runs: [run("Hi")])]
        let resized = map(deck(slides: [PPTXSlide(shapes: [
            PPTXShape(kind: .shape, name: "Text Box", transform: transform(), textBody: body),
        ])]))
        #expect(resized.presentation.slides[0].objects[0].textStyle?.autoShrink == nil)
    }

    @Test func borderedPictureBecomesStrokedMediaShape() {
        var pic = PPTXShape(kind: .picture, name: "P", transform: transform())
        pic.mediaPath = "/tmp/x.png"
        pic.stroke = PPTXStroke(colorHex: "000000FF", widthEMU: 38100, dash: nil)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [pic])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.objectKind == .shape)
        #expect(object.shapeKind == nil)  
        #expect(object.fill?.fillKind == .media)
        #expect(object.stroke == ObjectStroke(colorHex: "#000000FF", width: 6))  
    }

    @Test func blipAlphaImportsAsObjectOpacity() {
        var pic = PPTXShape(kind: .picture, name: "P", transform: transform())
        pic.mediaPath = "/tmp/x.png"
        pic.blipAlpha = 0.4
        let mapped = map(deck(slides: [PPTXSlide(shapes: [pic])]))
        #expect(mapped.presentation.slides[0].objects[0].opacity == 0.4)

        var opaque = PPTXShape(kind: .picture, name: "P", transform: transform())
        opaque.mediaPath = "/tmp/x.png"
        let plain = map(deck(slides: [PPTXSlide(shapes: [opaque])]))
        #expect(plain.presentation.slides[0].objects[0].opacity == nil)
    }

    @Test func missingFontFamiliesCollectDedupedInFirstSeenOrder() {
        let shape = textShape([
            run("One ", font: "DefinitelyNotInstalledSans"),
            run("two ", font: "AlsoAbsentSerif", bold: true),
            run("three", font: "DefinitelyNotInstalledSans", bold: true),
        ])
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.missingFonts == ["DefinitelyNotInstalledSans", "AlsoAbsentSerif"])
        #expect(mapped.warnings.contains { $0.contains("DefinitelyNotInstalledSans") && $0.contains("not installed") })

        let installed = map(deck(slides: [PPTXSlide(shapes: [textShape([run("Hi")])])]))
        #expect(installed.missingFonts.isEmpty)
    }

    @Test func customPathWinsOverPreset() {
        var shape = PPTXShape(kind: .shape, name: "Torn", transform: transform())
        shape.presetGeometry = "star5"
        shape.customPathData = "M 0.0000 0.0000 C 0.0000 0.0000 1.0000 1.0000 1.0000 1.0000"
        shape.fill = .solid(colorHex: "FF0000")
        let mapped = map(deck(slides: [PPTXSlide(shapes: [shape])]))
        #expect(mapped.presentation.slides[0].objects[0].shapeKind == .path)
        #expect(mapped.presentation.slides[0].objects[0].pathData == shape.customPathData)
    }

    @Test func connectorsBecomeStrokedLines() {
        var straight = PPTXShape(kind: .shape, name: "Line", transform: transform())
        straight.presetGeometry = "line"
        straight.stroke = PPTXStroke(colorHex: "FF0000FF", widthEMU: 12_700)
        var bent = straight
        bent.name = "Elbow"
        bent.presetGeometry = "bentConnector3"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [straight, bent])]))
        let objects = mapped.presentation.slides[0].objects
        #expect(objects.count == 2)
        #expect(objects[0].shapeKind == .path)
        #expect(objects[0].pathData == PPTXPresetGeometry.linePath)
        #expect(objects[0].stroke?.colorHex == "#FF0000FF")
        #expect(objects[1].pathData == PPTXPresetGeometry.linePath)
        #expect(mapped.warnings.contains { $0.contains("bentConnector3") && $0.contains("straight line") })
    }

    @Test func pictureWithCustomGeometryBecomesShapeWithMediaFill() {
        var picture = PPTXShape(kind: .picture, name: "Torn Photo", transform: transform())
        picture.mediaPath = "/tmp/extracted/ppt/media/image1.png"
        picture.customPathData = "M 0.0000 0.0000 C 0.0000 0.0000 1.0000 1.0000 1.0000 1.0000"
        picture.sourceRect = PPTXSourceRect(l: 25_000, t: 0, r: 25_000, b: 0)
        let mapped = map(deck(slides: [PPTXSlide(shapes: [picture])]))
        let object = mapped.presentation.slides[0].objects[0]

        #expect(object.objectKind == .shape)
        #expect(object.shapeKind == .path)
        #expect(object.pathData == picture.customPathData)
        #expect(object.mediaId == nil)
        #expect(object.fill?.fillKind == .media)
        #expect(object.fill?.mediaId?.hasPrefix(PPTXDocumentMapper.placeholderPrefix) == true)
        #expect(object.fill?.mediaScaleMode == .stretch)
        #expect(object.fill?.mediaSourceRect == MediaSourceRect(x: 0.25, y: 0, width: 0.5, height: 1))
        #expect(mapped.mediaWants.count == 1)
    }

    @Test func pictureWithEllipsePresetClipsAndUncuratedStaysRectangle() {
        var round = PPTXShape(kind: .picture, name: "Portrait", transform: transform())
        round.mediaPath = "/tmp/a.png"
        round.presetGeometry = "ellipse"
        var heart = PPTXShape(kind: .picture, name: "Valentine", transform: transform())
        heart.mediaPath = "/tmp/b.png"
        heart.presetGeometry = "heart"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [round, heart])]))
        let ellipse = mapped.presentation.slides[0].objects[0]
        #expect(ellipse.objectKind == .shape)
        #expect(ellipse.shapeKind == .ellipse)
        #expect(ellipse.fill?.fillKind == .media)

        let fallback = mapped.presentation.slides[0].objects[1]
        #expect(fallback.objectKind == .shape)
        #expect(fallback.shapeKind == nil)
        #expect(fallback.pathData == nil)
        #expect(fallback.fill?.mediaId != nil)
        #expect(mapped.warnings.contains { $0.contains("heart") && $0.contains("approximated") })
    }

    @Test func audioPictureBecomesFireAudioActionNotAnObject() throws {
        var audio = PPTXShape(kind: .picture, name: "Bell", transform: transform())
        audio.mediaKind = .audio
        audio.mediaPath = "/tmp/extracted/ppt/media/media1.mp3"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [audio])]))
        let slide = mapped.presentation.slides[0]
        #expect(slide.objects.isEmpty)
        let action = try #require(slide.actions?.first)
        #expect(action.kind == .fireAudio)
        let placeholder = try #require(action.audioItemId)
        #expect(placeholder.hasPrefix(PPTXDocumentMapper.placeholderPrefix))
        #expect(mapped.mediaWants.count == 1)
        #expect(mapped.warnings.contains { $0.contains("play action") })

        let resolved = PPTXDocumentMapper.replacingMediaIDs(
            mapped.presentation, with: [placeholder: "audio-1"])
        #expect(resolved.slides[0].actions?.first?.audioItemId == "audio-1")
        let stripped = PPTXDocumentMapper.replacingMediaIDs(mapped.presentation, with: [:])
        #expect(stripped.slides[0].actions == nil)
    }

    @Test func videoPictureBecomesMediaFilledShapeWithWant() {
        var video = PPTXShape(kind: .picture, name: "Clip", transform: transform())
        video.mediaKind = .video
        video.mediaPath = "/tmp/extracted/ppt/media/media1.mp4"
        let mapped = map(deck(slides: [PPTXSlide(shapes: [video])]))
        let object = mapped.presentation.slides[0].objects[0]
        #expect(object.objectKind == .shape)
        #expect(object.fill?.fillKind == .media)
        #expect(mapped.mediaWants.first?.absolutePath == "/tmp/extracted/ppt/media/media1.mp4")
    }

    @Test func sectionsMapWithSlideMembership() {
        let slides = [PPTXSlide(), PPTXSlide(), PPTXSlide()]
        var built = deck(slides: slides)
        built.sections = [
            PPTXSection(id: "aaaa-1", name: "Intro", slideIndexes: [0, 1]),
            PPTXSection(id: "bbbb-2", name: "Empty", slideIndexes: [9]),
            PPTXSection(id: "cccc-3", name: "Close", slideIndexes: [2]),
        ]
        let mapped = map(built)
        #expect(mapped.presentation.sections == [
            PresentationSection(id: "aaaa-1", name: "Intro"),
            PresentationSection(id: "cccc-3", name: "Close"),
        ])
        #expect(mapped.presentation.slides.map(\.sectionId) == ["aaaa-1", "aaaa-1", "cccc-3"])
    }

    @Test func replacingMediaIDsRemapsAndStripsUnresolved() {
        var picture = PPTXShape(kind: .picture, name: "Photo", transform: transform())
        picture.mediaPath = "/tmp/a.png"
        var filled = PPTXShape(kind: .shape, name: "Band", transform: transform())
        filled.fill = .blip(path: "/tmp/b.png")
        var slide = PPTXSlide(shapes: [picture, filled])
        slide.backgroundFill = .blip(path: "/tmp/c.png")
        let mapped = map(deck(slides: [slide]))

        let backdropID = mapped.presentation.slides[0].objects[0].fill!.mediaId!
        let replaced = PPTXDocumentMapper.replacingMediaIDs(
            mapped.presentation, with: [backdropID: "real-media-id"])
        let objects = replaced.slides[0].objects
        #expect(objects.count == 1)
        #expect(objects[0].fill?.mediaId == "real-media-id")
        #expect(replaced.slides[0].background == nil)

        let stripped = PPTXDocumentMapper.replacingMediaIDs(mapped.presentation, with: [:])
        #expect(stripped.slides[0].objects.isEmpty)
    }

    @Test func timingEffectsBecomeAnimationSteps() {
        var title = textShape([run("Hello")])
        title.shapeID = 2
        var body = PPTXTextBody()
        body.paragraphs = [PPTXParagraph(alignment: nil, runs: [run("One")]),
                           PPTXParagraph(alignment: nil, runs: [run("Two")])]
        var points = PPTXShape(kind: .shape, name: "Points", transform: transform(y: 2_000_000), textBody: body)
        points.shapeID = 3
        var slide = PPTXSlide(name: "S", shapes: [title, points])
        slide.animationSteps = [
            PPTXAnimation(shapeID: 2, presetClass: "entr", presetID: 2, presetSubtype: 8, nodeType: "clickEffect", delayMs: 0, durationMs: 750),
            PPTXAnimation(shapeID: 3, presetClass: "entr", presetID: 10, nodeType: "clickEffect", delayMs: 100, durationMs: 500, paragraphStart: 0, paragraphEnd: 0),
            PPTXAnimation(shapeID: 3, presetClass: "entr", presetID: 10, nodeType: "afterEffect", delayMs: 500, durationMs: 500, paragraphStart: 1, paragraphEnd: 1),
            PPTXAnimation(shapeID: 2, presetClass: "emph", presetID: 6, nodeType: "withEffect", durationMs: 1000),
            PPTXAnimation(shapeID: 2, presetClass: "exit", presetID: 58, nodeType: "clickEffect", durationMs: 400),
            PPTXAnimation(shapeID: 99, presetClass: "entr", presetID: 10, nodeType: "clickEffect"), 
        ]
        let mapped = map(deck(slides: [slide]))
        let out = mapped.presentation.slides[0]
        let titleObject = out.objects.first { $0.text == "Hello" }!
        let pointsObject = out.objects.first { $0.text == "One\nTwo" }!

        let t = titleObject.animationSteps ?? []
        #expect(t.count == 3)
        #expect(t[0].kind == .in && t[0].animation == .move && t[0].edge == .left && t[0].trigger == .onClick && t[0].durationSeconds == 0.75)
        #expect(t[1].kind == .emphasis && t[1].animation == .scale && t[1].trigger == .withPrevious)
        #expect(t[2].kind == .out && t[2].animation == .scale && t[2].trigger == .onClick)

        let p = pointsObject.animationSteps ?? []
        #expect(p.count == 2)
        #expect(p[0].ranges == [AnimationRange(line: 0, column: 0, length: 3)] && p[0].delaySeconds == 0.1)
        #expect(p[1].ranges == [AnimationRange(line: 1, column: 0, length: 3)] && p[1].trigger == .afterPrevious && p[1].delaySeconds == nil)

        #expect(out.animationOrder == [t[0].id, p[0].id, p[1].id, t[1].id, t[2].id])

        #expect(mapped.warnings.contains { $0.contains("entrance/exit 58") })
        #expect(out.notes?.contains("PowerPoint animation") == true)

        #expect(out.objects.allSatisfy { object in
            (object.animationSteps ?? []).allSatisfy { $0.trigger != .onDismiss }
        }, "PPTX imports never author exit-group (onDismiss) steps")
    }
}
