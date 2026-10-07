import CoreGraphics
import Foundation

public struct SceneColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = SceneColor(red: 0, green: 0, blue: 0)
    public static let white = SceneColor(red: 1, green: 1, blue: 1)
    public static let clear = SceneColor(red: 0, green: 0, blue: 0, alpha: 0)

    public var linearPremultiplied: SIMD4<Float> {
        let a = Float(alpha)
        return SIMD4(
            Float(Self.srgbToLinear(red)) * a,
            Float(Self.srgbToLinear(green)) * a,
            Float(Self.srgbToLinear(blue)) * a,
            a
        )
    }

    public var linear: SIMD4<Double> {
        SIMD4(Self.srgbToLinear(red), Self.srgbToLinear(green), Self.srgbToLinear(blue), alpha)
    }

    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

public enum LayerKind: String, CaseIterable, Sendable, Hashable {
    case videoInput
    case loopingVideos
    case stillGraphics

    case videos
    case slide
    case overlays

    case alerts

    public var displayName: String {
        switch self {
        case .videoInput: "Video Input"
        case .loopingVideos: "Background Media"
        case .stillGraphics: "Still Graphics"
        case .videos: "Foreground Videos"
        case .slide: "Slide"
        case .overlays: "Overlays"
        case .alerts: "Alerts"
        }
    }
}

public enum SceneTextAlignment: String, Sendable, Hashable {
    case left
    case center
    case right
}

public enum SceneTextVerticalAlignment: String, Sendable, Hashable {
    case top
    case middle
    case bottom
}

public enum SceneTextTransform: String, Sendable, Hashable {
    case none
    case uppercase
}

public struct TextShadow: Hashable, Sendable {
    public var color: SceneColor
    public var blurRadius: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(color: SceneColor, blurRadius: Double, offsetX: Double, offsetY: Double) {
        self.color = color
        self.blurRadius = blurRadius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public struct TextOutline: Hashable, Sendable {
    public var color: SceneColor
    public var width: Double

    public init(color: SceneColor, width: Double) {
        self.color = color
        self.width = width
    }
}

public struct TextLineOverride: Hashable, Sendable {
    public var lineIndex: Int
    public var fontName: String?
    public var fontSize: Double?
    public var color: SceneColor?
    public var tracking: Double?
    public var firstLineIndent: Double?
    public var leftIndent: Double?
    public var rightIndent: Double?

    public init(
        lineIndex: Int,
        fontName: String? = nil,
        fontSize: Double? = nil,
        color: SceneColor? = nil,
        tracking: Double? = nil,
        firstLineIndent: Double? = nil,
        leftIndent: Double? = nil,
        rightIndent: Double? = nil
    ) {
        self.lineIndex = lineIndex
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.tracking = tracking
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
    }
}

public struct TextLineFillStyle: Hashable, Sendable {
    public enum WidthMode: Hashable, Sendable {

        case fullWidth

        case lineWidth

        case maxLineWidth
    }

    public var fill: SceneFill
    public var widthMode: WidthMode

    public var verticalPadding: Double

    public var horizontalPadding: Double

    public var verticalOffset: Double

    public var horizontalOffset: Double

    public var cornerRadius: Double

    public init(
        fill: SceneFill,
        widthMode: WidthMode = .fullWidth,
        verticalPadding: Double = 0,
        horizontalPadding: Double = 0,
        verticalOffset: Double = 0,
        horizontalOffset: Double = 0,
        cornerRadius: Double = 0
    ) {
        self.fill = fill
        self.widthMode = widthMode
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
        self.cornerRadius = cornerRadius
    }
}

public struct ChordRun: Hashable, Sendable {
    public var line: Int
    public var column: Int
    public var symbol: String

    public init(line: Int, column: Int, symbol: String) {
        self.line = line
        self.column = column
        self.symbol = symbol
    }
}

public struct StyleRun: Hashable, Sendable {
    public var line: Int
    public var column: Int
    public var length: Int
    public var underline: Bool?
    public var strikethrough: Bool?
    public var fontName: String?

    public var fontSize: Double?
    public var color: SceneColor?

    public var highlightColor: SceneColor?
    public var tracking: Double?

    public var hidden: Bool?

    public var placeholderUnderline: Bool?

    public var caret: Bool?

    public init(
        line: Int,
        column: Int,
        length: Int,
        underline: Bool? = nil,
        strikethrough: Bool? = nil,
        fontName: String? = nil,
        fontSize: Double? = nil,
        color: SceneColor? = nil,
        highlightColor: SceneColor? = nil,
        tracking: Double? = nil,
        hidden: Bool? = nil,
        placeholderUnderline: Bool? = nil,
        caret: Bool? = nil
    ) {
        self.line = line
        self.column = column
        self.length = length
        self.underline = underline
        self.strikethrough = strikethrough
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.highlightColor = highlightColor
        self.tracking = tracking
        self.hidden = hidden
        self.placeholderUnderline = placeholderUnderline
        self.caret = caret
    }
}

public struct StyledText: Hashable, Sendable {

    public static let defaultMinFontSize: Double = 24

    public var string: String
    public var fontName: String

    public var fontSize: Double
    public var color: SceneColor
    public var alignment: SceneTextAlignment
    public var shadow: TextShadow?

    public var tracking: Double

    public var lineHeightMultiple: Double
    public var verticalAlignment: SceneTextVerticalAlignment
    public var transform: SceneTextTransform

    public var tabularFigures: Bool

    public var autoShrink: Bool

    public var minFontSize: Double

    public var keepLinesWhole: Bool

    public var balancedWrap: Bool

    public var balancedLineInsets: [BalancedLineInset]
    public var outline: TextOutline?
    public var lineOverrides: [TextLineOverride]

    public var fill: SceneFill?

    public var lineFill: TextLineFillStyle?

    public var pathData: String?

    public var tickerSpeed: Double

    public var pathReversed: Bool

    public var pathOffset: Double

    public var tickerRepeat: Int

    public var tickerLeftToRight: Bool

    public var tickerStream: Bool

    public var tickerGap: Double

    public var tickerSeparator: String

    public var wordSpacing: Double

    public var chords: [ChordRun]

    public var chordColor: SceneColor?

    public var insetTop: Double
    public var insetLeft: Double
    public var insetBottom: Double
    public var insetRight: Double

    public var firstLineIndent: Double
    public var leftIndent: Double
    public var rightIndent: Double

    public var paragraphSpacing: Double

    public var underline: Bool

    public var strikethrough: Bool

    public var styleRuns: [StyleRun]

    public var tickerRamp: SceneAnimationRamp

    public var scroll: SceneBlockScroll?

    public init(
        string: String,
        fontName: String = "HelveticaNeue-Bold",
        fontSize: Double,
        color: SceneColor = .white,
        alignment: SceneTextAlignment = .center,
        shadow: TextShadow? = nil,
        tracking: Double = 0,
        lineHeightMultiple: Double = 1,
        verticalAlignment: SceneTextVerticalAlignment = .middle,
        transform: SceneTextTransform = .none,
        tabularFigures: Bool = false,
        autoShrink: Bool = false,
        minFontSize: Double = StyledText.defaultMinFontSize,
        keepLinesWhole: Bool = false,
        balancedWrap: Bool = false,
        outline: TextOutline? = nil,
        lineOverrides: [TextLineOverride] = [],
        fill: SceneFill? = nil,
        lineFill: TextLineFillStyle? = nil,
        pathData: String? = nil,
        tickerSpeed: Double = 0,
        pathReversed: Bool = false,
        pathOffset: Double = 0,
        tickerRepeat: Int = 0,
        tickerLeftToRight: Bool = false,
        tickerStream: Bool = false,
        tickerGap: Double = 0,
        tickerSeparator: String = "",
        wordSpacing: Double = 0,
        chords: [ChordRun] = [],
        chordColor: SceneColor? = nil,
        insetTop: Double = 0,
        insetLeft: Double = 0,
        insetBottom: Double = 0,
        insetRight: Double = 0,
        firstLineIndent: Double = 0,
        leftIndent: Double = 0,
        rightIndent: Double = 0,
        paragraphSpacing: Double = 0,
        underline: Bool = false,
        strikethrough: Bool = false,
        styleRuns: [StyleRun] = [],
        tickerRamp: SceneAnimationRamp = .none,
        scroll: SceneBlockScroll? = nil
    ) {
        self.string = string
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.shadow = shadow
        self.tracking = tracking
        self.lineHeightMultiple = lineHeightMultiple
        self.verticalAlignment = verticalAlignment
        self.transform = transform
        self.tabularFigures = tabularFigures
        self.autoShrink = autoShrink
        self.minFontSize = minFontSize
        self.keepLinesWhole = keepLinesWhole
        self.balancedWrap = balancedWrap
        self.balancedLineInsets = []
        self.outline = outline
        self.lineOverrides = lineOverrides
        self.fill = fill
        self.lineFill = lineFill
        self.pathData = pathData
        self.tickerSpeed = tickerSpeed
        self.pathReversed = pathReversed
        self.pathOffset = pathOffset
        self.tickerRepeat = tickerRepeat
        self.tickerLeftToRight = tickerLeftToRight
        self.tickerStream = tickerStream
        self.tickerGap = tickerGap
        self.tickerSeparator = tickerSeparator
        self.wordSpacing = wordSpacing
        self.chords = chords
        self.chordColor = chordColor
        self.insetTop = insetTop
        self.insetLeft = insetLeft
        self.insetBottom = insetBottom
        self.insetRight = insetRight
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.paragraphSpacing = paragraphSpacing
        self.underline = underline
        self.strikethrough = strikethrough
        self.styleRuns = styleRuns
        self.tickerRamp = tickerRamp
        self.scroll = scroll
    }
}

public struct BalancedLineInset: Hashable, Sendable {

    public var line: Int

    public var left: Double

    public var right: Double

    public init(line: Int, left: Double, right: Double) {
        self.line = line
        self.left = left
        self.right = right
    }
}

public struct SceneBlockScroll: Hashable, Sendable {
    public enum Axis: Hashable, Sendable { case up, down, left, right }
    public var axis: Axis

    public var speed: Double

    public var passes: Int

    public var ramp: SceneAnimationRamp

    public var restAtEnd: Bool

    public var fadeTowardTop: Double

    public init(
        axis: Axis = .up, speed: Double, passes: Int = 0, ramp: SceneAnimationRamp = .none,
        restAtEnd: Bool = false, fadeTowardTop: Double = 0
    ) {
        self.axis = axis
        self.speed = speed
        self.passes = passes
        self.ramp = ramp
        self.restAtEnd = restAtEnd
        self.fadeTowardTop = fadeTowardTop
    }
}

public enum SceneBlendMode: String, Sendable, Hashable, CaseIterable {
    case normal
    case multiply
    case screen
    case add
}

public enum SceneMediaScaleMode: String, Sendable, Hashable {
    case fill
    case fit
    case stretch
}

public struct SceneSourceRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct SceneGradientStop: Hashable, Sendable {
    public var color: SceneColor
    public var position: Double

    public init(color: SceneColor, position: Double) {
        self.color = color
        self.position = position
    }
}

public enum SceneFill: Hashable, Sendable {
    case none
    case solid(SceneColor)

    case linearGradient(angleDegrees: Double, stops: [SceneGradientStop])

    case media(id: String, scaleMode: SceneMediaScaleMode, sourceRect: SceneSourceRect?)

    public static func media(id: String, scaleMode: SceneMediaScaleMode) -> SceneFill {
        .media(id: id, scaleMode: scaleMode, sourceRect: nil)
    }
}

public struct SceneStroke: Hashable, Sendable {
    public enum Dash: Hashable, Sendable {
        case solid
        case dashed
        case dotted
    }

    public var color: SceneColor
    public var width: Double

    public var dash: Dash

    public init(color: SceneColor, width: Double, dash: Dash = .solid) {
        self.color = color
        self.width = width
        self.dash = dash
    }
}

public enum SceneShapeKind: Hashable, Sendable {
    case rectangle
    case roundedRectangle(cornerRadius: Double)
    case ellipse
    case path(String)
}

public struct ShapeStyle: Hashable, Sendable {
    public var kind: SceneShapeKind
    public var fill: SceneFill
    public var stroke: SceneStroke?
    public var shadow: TextShadow?

    public var strokeTrim: StrokeTrim?

    public var fillOpacity: Double

    public struct StrokeTrim: Hashable, Sendable {
        public var start: Double
        public var length: Double
        public var reversed: Bool

        public init(start: Double, length: Double, reversed: Bool = false) {
            self.start = start
            self.length = length
            self.reversed = reversed
        }
    }

    public init(
        kind: SceneShapeKind,
        fill: SceneFill,
        stroke: SceneStroke? = nil,
        shadow: TextShadow? = nil,
        strokeTrim: StrokeTrim? = nil,
        fillOpacity: Double = 1
    ) {
        self.kind = kind
        self.fill = fill
        self.stroke = stroke
        self.shadow = shadow
        self.strokeTrim = strokeTrim
        self.fillOpacity = fillOpacity
    }
}

public enum ItemContent: Hashable, Sendable {
    case solid(SceneColor)
    case text(StyledText)
    case shape(ShapeStyle)

    case media(id: String, scaleMode: SceneMediaScaleMode, sourceRect: SceneSourceRect?)

    public static func media(id: String) -> ItemContent {
        .media(id: id, scaleMode: .fill, sourceRect: nil)
    }

    public static func media(id: String, scaleMode: SceneMediaScaleMode) -> ItemContent {
        .media(id: id, scaleMode: scaleMode, sourceRect: nil)
    }

    public var mediaID: String? {
        switch self {
        case .media(let id, _, _): id
        case .shape(let style):
            if case .media(let id, _, _) = style.fill { id } else { nil }
        case .solid, .text: nil
        }
    }
}

public struct SceneEffect: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {

        case blur(radius: Double)

        case colorAdjust(brightness: Double, contrast: Double, saturation: Double, hue: Double)

        case hueRotate(degrees: Double)

        case invert

        case posterize(levels: Double)

        case pixelate(size: Double)

        case vignette(strength: Double)

        case warp(amount: Double, scale: Double, speed: Double)

        case echo(fade: Double)

        case scatter(amount: Double, size: Double, speed: Double, smooth: Double)

        case stainedGlass(cellSize: Double, leading: Double, jitter: Double, speed: Double)

        case grain(amount: Double, size: Double, speed: Double)

        case ghostTrails(fade: Double, drift: Double, scale: Double, speed: Double)

        case glitch(amount: Double, phase: Double)

        case burn(amount: Double, phase: Double)

        case tint(color: SceneColor, amount: Double)
    }

    public var kind: Kind

    public var opacity: Double

    public init(kind: Kind, opacity: Double = 1) {
        self.kind = kind
        self.opacity = min(max(opacity, 0), 1)
    }

    public static func blur(radius: Double) -> SceneEffect {
        SceneEffect(kind: .blur(radius: radius))
    }

    public static func colorAdjust(
        brightness: Double, contrast: Double, saturation: Double, hue: Double = 0
    ) -> SceneEffect {
        SceneEffect(kind: .colorAdjust(
            brightness: brightness, contrast: contrast, saturation: saturation, hue: hue
        ))
    }
}

public struct ItemVisibility: Sendable, Equatable {
    public enum Match: Sendable, Equatable {
        case all
        case any
        case none
    }

    public struct Condition: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {

            case timer(id: String?)
            case videoCountdown

            case audioPlayback

            case liveInput(id: String?)

            case capture

            case objectText(id: String)

            case unevaluable
        }

        public enum RequiredState: Sendable, Equatable {
            case hasTimeRemaining
            case hasExpired
            case isRunning
            case isNotRunning

            case isConnected
            case isNotConnected
            case hasText
            case hasNoText
        }

        public var kind: Kind
        public var state: RequiredState

        public init(kind: Kind, state: RequiredState) {
            self.kind = kind
            self.state = state
        }
    }

    public var match: Match
    public var conditions: [Condition]

    public init(match: Match, conditions: [Condition]) {
        self.match = match
        self.conditions = conditions
    }
}

public enum SceneTiltPivot: String, Sendable, Equatable {
    case top, center, bottom
}

public struct RenderItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var frame: CGRect
    public var content: ItemContent

    public var rotationDegrees: Double

    public var tilt: Double

    public var swing: Double

    public var tiltPivot: SceneTiltPivot

    public var keystoneTop: Double
    public var keystoneBottom: Double

    public var keystoneStretch: Bool

    public var skewX: Double
    public var skewY: Double

    public var flipHorizontal: Bool

    public var flipVertical: Bool

    public var opacity: Double
    public var blendMode: SceneBlendMode

    public var tickerAnchorHostTime: Double?

    public var maskedBy: String?

    public var maskOut: Bool

    public var matteGroup: String?

    public var effects: [SceneEffect]

    public var effectsApplyBelow: Bool

    public var visibility: ItemVisibility?

    public var animationSteps: [SceneAnimationStep]

    public var animationContext: AnimationContext?

    public init(
        id: String,
        frame: CGRect,
        content: ItemContent,
        rotationDegrees: Double = 0,
        tilt: Double = 0,
        swing: Double = 0,
        tiltPivot: SceneTiltPivot = .center,
        keystoneTop: Double = 1,
        keystoneBottom: Double = 1,
        keystoneStretch: Bool = false,
        skewX: Double = 0,
        skewY: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        opacity: Double = 1,
        blendMode: SceneBlendMode = .normal,
        tickerAnchorHostTime: Double? = nil,
        maskedBy: String? = nil,
        maskOut: Bool = false,
        matteGroup: String? = nil,
        effects: [SceneEffect] = [],
        effectsApplyBelow: Bool = false,
        visibility: ItemVisibility? = nil,
        animationSteps: [SceneAnimationStep] = [],
        animationContext: AnimationContext? = nil
    ) {
        self.id = id
        self.frame = frame
        self.content = content
        self.rotationDegrees = rotationDegrees
        self.tilt = tilt
        self.swing = swing
        self.tiltPivot = tiltPivot
        self.keystoneTop = keystoneTop
        self.keystoneBottom = keystoneBottom
        self.keystoneStretch = keystoneStretch
        self.skewX = skewX
        self.skewY = skewY
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical

        self.opacity = min(max(opacity, 0), 1)
        self.blendMode = blendMode
        self.tickerAnchorHostTime = tickerAnchorHostTime
        self.maskedBy = maskedBy
        self.maskOut = maskOut
        self.matteGroup = matteGroup
        self.effects = effects
        self.effectsApplyBelow = effectsApplyBelow
        self.visibility = visibility
        self.animationSteps = animationSteps
        self.animationContext = animationContext
    }
}

public struct RenderLayer: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: LayerKind
    public var name: String
    public var isHidden: Bool
    public var items: [RenderItem]

    public init(kind: LayerKind, name: String? = nil, isHidden: Bool = false, items: [RenderItem] = []) {
        self.id = kind.rawValue
        self.kind = kind
        self.name = name ?? kind.displayName
        self.isHidden = isHidden
        self.items = items
    }
}

extension RenderScene {

    public func applyingMediaEffects(_ lookup: (String) -> [SceneEffect]) -> RenderScene {
        var scene = self
        for layerIndex in scene.layers.indices {
            for itemIndex in scene.layers[layerIndex].items.indices {
                guard case .media(let id, _, _) = scene.layers[layerIndex].items[itemIndex].content
                else { continue }
                let own = lookup(id)
                guard !own.isEmpty else { continue }
                scene.layers[layerIndex].items[itemIndex].effects =
                    own + scene.layers[layerIndex].items[itemIndex].effects
            }
        }
        return scene
    }

    public func remappingMediaIDs(_ transform: (String) -> String) -> RenderScene {
        var scene = self
        scene.layers = scene.layers.map { layer in
            var layer = layer
            layer.items = layer.items.map { item in
                var item = item
                if case .media(let id, let scaleMode, let sourceRect) = item.content {
                    item.content = .media(
                        id: transform(id), scaleMode: scaleMode, sourceRect: sourceRect
                    )
                }

                if case .shape(var style) = item.content,
                   case .media(let id, let scaleMode, let sourceRect) = style.fill {
                    style.fill = .media(
                        id: transform(id), scaleMode: scaleMode, sourceRect: sourceRect
                    )
                    item.content = .shape(style)
                }
                return item
            }
            return layer
        }
        return scene
    }
}

public struct RenderScene: Equatable, Sendable {

    public var canvasSize: CGSize
    public var background: SceneColor

    public var layers: [RenderLayer]

    public init(
        canvasSize: CGSize = CGSize(width: 1920, height: 1080),
        background: SceneColor = .black,
        layers: [RenderLayer] = RenderScene.defaultLayerStack()
    ) {
        self.canvasSize = canvasSize
        self.background = background
        self.layers = layers
    }

    public static let empty = RenderScene()

    public static func defaultLayerStack() -> [RenderLayer] {
        LayerKind.allCases.map { RenderLayer(kind: $0) }
    }

    public mutating func addItem(_ item: RenderItem, to kind: LayerKind) {
        guard let index = layers.firstIndex(where: { $0.kind == kind }) else { return }
        layers[index].items.append(item)
    }

    public mutating func setLayerHidden(_ hidden: Bool, kind: LayerKind) {
        guard let index = layers.firstIndex(where: { $0.kind == kind }) else { return }
        layers[index].isHidden = hidden
    }

    public var isTimeVarying: Bool {
        layers.contains { layer in
            !layer.isHidden && layer.items.contains { item in

                if item.animationContext != nil, !item.animationSteps.isEmpty { return true }
                return switch item.content {
                case .media: true
                case .text(let text): text.tickerSpeed != 0 || (text.scroll?.speed ?? 0) > 0

                case .shape: item.content.mediaID != nil
                case .solid: false
                }
            }
        }
    }
}
