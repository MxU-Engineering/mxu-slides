import Foundation

public enum SlideObjectKind: String, Codable, Sendable, CaseIterable, Equatable {
    case text
    case media
    case shape
    case liveInput
}

public enum BlendMode: String, Codable, Sendable, CaseIterable, Equatable {
    case normal
    case multiply
    case screen
    case add
}

public enum FillKind: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case solid
    case linearGradient
    case media
}

public enum ShapeKind: String, Codable, Sendable, CaseIterable, Equatable {
    case rectangle
    case roundedRectangle
    case ellipse
    case path
}

public enum ShapeTextPlacement: String, Codable, Sendable, CaseIterable, Equatable {
    case inside
    case edgeOutside
    case edgeInside
}

public enum TickerDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case rightToLeft
    case leftToRight
}

public enum TextPathSide: String, Codable, Sendable, CaseIterable, Equatable {
    case outside
    case inside
}

public enum MediaScaleMode: String, Codable, Sendable, CaseIterable, Equatable {
    case fill
    case fit
    case stretch
}

public struct MediaSourceRect: Codable, Sendable, Equatable {
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
}

public enum TextHorizontalAlignment: String, Codable, Sendable, CaseIterable, Equatable {
    case left
    case center
    case right
}

public enum TextVerticalAlignment: String, Codable, Sendable, CaseIterable, Equatable {
    case top
    case middle
    case bottom
}

public enum TextTransform: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case uppercase
}

public struct GradientStop: Codable, Sendable, Equatable {
    public var colorHex: String
    public var position: Double

    public init(colorHex: String, position: Double) {
        self.colorHex = colorHex
        self.position = position
    }
}

public struct ObjectFill: Codable, Sendable, Equatable {
    public var fillKind: FillKind
    public var colorHex: String?
    public var gradientAngleDegrees: Double?
    public var gradientStops: [GradientStop]?
    public var mediaId: String?
    public var mediaScaleMode: MediaScaleMode?
    public var mediaSourceRect: MediaSourceRect?
    public var loops: Bool?
    public var captureSourceKind: CaptureSourceKind?
    public var captureSourceId: String?
    public var screenSourceId: String?
    public var liveInputId: String?

    public init(fillKind: FillKind, colorHex: String? = nil, gradientAngleDegrees: Double? = nil, gradientStops: [GradientStop]? = nil, mediaId: String? = nil, mediaScaleMode: MediaScaleMode? = nil, mediaSourceRect: MediaSourceRect? = nil, loops: Bool? = nil, captureSourceKind: CaptureSourceKind? = nil, captureSourceId: String? = nil, screenSourceId: String? = nil, liveInputId: String? = nil) {
        self.fillKind = fillKind
        self.colorHex = colorHex
        self.gradientAngleDegrees = gradientAngleDegrees
        self.gradientStops = gradientStops
        self.mediaId = mediaId
        self.mediaScaleMode = mediaScaleMode
        self.mediaSourceRect = mediaSourceRect
        self.loops = loops
        self.captureSourceKind = captureSourceKind
        self.captureSourceId = captureSourceId
        self.screenSourceId = screenSourceId
        self.liveInputId = liveInputId
    }
}

public enum StrokeDashKind: String, Codable, Sendable, CaseIterable, Equatable {
    case solid
    case dashed
    case dotted
}

public struct ObjectStroke: Codable, Sendable, Equatable {
    public var colorHex: String
    public var width: Double
    public var dashKind: StrokeDashKind?

    public init(colorHex: String, width: Double, dashKind: StrokeDashKind? = nil) {
        self.colorHex = colorHex
        self.width = width
        self.dashKind = dashKind
    }
}

public struct ObjectShadow: Codable, Sendable, Equatable {
    public var colorHex: String
    public var blurRadius: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(colorHex: String, blurRadius: Double, offsetX: Double, offsetY: Double) {
        self.colorHex = colorHex
        self.blurRadius = blurRadius
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public struct LineStyleOverride: Codable, Sendable, Equatable {
    public var lineIndex: Int
    public var fontName: String?
    public var fontSize: Double?
    public var colorHex: String?
    public var tracking: Double?
    public var firstLineIndent: Double?
    public var leftIndent: Double?
    public var rightIndent: Double?

    public init(lineIndex: Int, fontName: String? = nil, fontSize: Double? = nil, colorHex: String? = nil, tracking: Double? = nil, firstLineIndent: Double? = nil, leftIndent: Double? = nil, rightIndent: Double? = nil) {
        self.lineIndex = lineIndex
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.tracking = tracking
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
    }
}

public enum TextLineFillWidthMode: String, Codable, Sendable, CaseIterable, Equatable {
    case fullWidth
    case lineWidth
    case maxLineWidth
}

public struct TextLineFill: Codable, Sendable, Equatable {
    public var fill: ObjectFill
    public var widthMode: TextLineFillWidthMode?
    public var verticalPadding: Double?
    public var horizontalPadding: Double?
    public var verticalOffset: Double?
    public var horizontalOffset: Double?
    public var cornerRadius: Double?

    public init(fill: ObjectFill, widthMode: TextLineFillWidthMode? = nil, verticalPadding: Double? = nil, horizontalPadding: Double? = nil, verticalOffset: Double? = nil, horizontalOffset: Double? = nil, cornerRadius: Double? = nil) {
        self.fill = fill
        self.widthMode = widthMode
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.verticalOffset = verticalOffset
        self.horizontalOffset = horizontalOffset
        self.cornerRadius = cornerRadius
    }
}

public enum ChordNotation: String, Codable, Sendable, CaseIterable, Equatable {
    case chords
    case numbers
    case numerals
    case doReMi
}

public struct ChordPlacement: Codable, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var symbol: String

    public init(line: Int, column: Int, symbol: String) {
        self.line = line
        self.column = column
        self.symbol = symbol
    }
}

public struct TextStyle: Codable, Sendable, Equatable {
    public var fontName: String?
    public var fontSize: Double?
    public var colorHex: String?
    public var fill: ObjectFill?
    public var tracking: Double?
    public var lineHeightMultiple: Double?
    public var horizontalAlignment: TextHorizontalAlignment?
    public var verticalAlignment: TextVerticalAlignment?
    public var textTransform: TextTransform?
    public var tabularFigures: Bool?
    public var autoShrink: Bool?
    public var minFontSize: Double?
    public var keepLinesWhole: Bool?
    public var pageOnClick: Bool?
    public var balancedWrap: Bool?
    public var outline: ObjectStroke?
    public var shadow: ObjectShadow?
    public var lineStyles: [LineStyleOverride]?
    public var lineFill: TextLineFill?
    public var pathData: String?
    public var tickerSpeed: Double?
    public var tickerDirection: TickerDirection?
    public var pathSide: TextPathSide?
    public var pathOffset: Double?
    public var tickerRepeat: Int?
    public var tickerRamp: AnimationRamp?
    public var scroll: BlockScroll?
    public var tickerStream: Bool?
    public var tickerGap: Double?
    public var tickerSeparator: String?
    public var wordSpacing: Double?
    public var insetTop: Double?
    public var insetLeft: Double?
    public var insetBottom: Double?
    public var insetRight: Double?
    public var firstLineIndent: Double?
    public var leftIndent: Double?
    public var rightIndent: Double?
    public var paragraphSpacing: Double?
    public var showChords: Bool?
    public var chordNotation: ChordNotation?
    public var chordColorHex: String?
    public var underline: Bool?
    public var strikethrough: Bool?

    public init(fontName: String? = nil, fontSize: Double? = nil, colorHex: String? = nil, fill: ObjectFill? = nil, tracking: Double? = nil, lineHeightMultiple: Double? = nil, horizontalAlignment: TextHorizontalAlignment? = nil, verticalAlignment: TextVerticalAlignment? = nil, textTransform: TextTransform? = nil, tabularFigures: Bool? = nil, autoShrink: Bool? = nil, minFontSize: Double? = nil, keepLinesWhole: Bool? = nil, pageOnClick: Bool? = nil, balancedWrap: Bool? = nil, outline: ObjectStroke? = nil, shadow: ObjectShadow? = nil, lineStyles: [LineStyleOverride]? = nil, lineFill: TextLineFill? = nil, pathData: String? = nil, tickerSpeed: Double? = nil, tickerDirection: TickerDirection? = nil, pathSide: TextPathSide? = nil, pathOffset: Double? = nil, tickerRepeat: Int? = nil, tickerRamp: AnimationRamp? = nil, scroll: BlockScroll? = nil, tickerStream: Bool? = nil, tickerGap: Double? = nil, tickerSeparator: String? = nil, wordSpacing: Double? = nil, insetTop: Double? = nil, insetLeft: Double? = nil, insetBottom: Double? = nil, insetRight: Double? = nil, firstLineIndent: Double? = nil, leftIndent: Double? = nil, rightIndent: Double? = nil, paragraphSpacing: Double? = nil, showChords: Bool? = nil, chordNotation: ChordNotation? = nil, chordColorHex: String? = nil, underline: Bool? = nil, strikethrough: Bool? = nil) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.fill = fill
        self.tracking = tracking
        self.lineHeightMultiple = lineHeightMultiple
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.textTransform = textTransform
        self.tabularFigures = tabularFigures
        self.autoShrink = autoShrink
        self.minFontSize = minFontSize
        self.keepLinesWhole = keepLinesWhole
        self.pageOnClick = pageOnClick
        self.balancedWrap = balancedWrap
        self.outline = outline
        self.shadow = shadow
        self.lineStyles = lineStyles
        self.lineFill = lineFill
        self.pathData = pathData
        self.tickerSpeed = tickerSpeed
        self.tickerDirection = tickerDirection
        self.pathSide = pathSide
        self.pathOffset = pathOffset
        self.tickerRepeat = tickerRepeat
        self.tickerRamp = tickerRamp
        self.scroll = scroll
        self.tickerStream = tickerStream
        self.tickerGap = tickerGap
        self.tickerSeparator = tickerSeparator
        self.wordSpacing = wordSpacing
        self.insetTop = insetTop
        self.insetLeft = insetLeft
        self.insetBottom = insetBottom
        self.insetRight = insetRight
        self.firstLineIndent = firstLineIndent
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.paragraphSpacing = paragraphSpacing
        self.showChords = showChords
        self.chordNotation = chordNotation
        self.chordColorHex = chordColorHex
        self.underline = underline
        self.strikethrough = strikethrough
    }
}

public enum VisibilityMatch: String, Codable, Sendable, CaseIterable, Equatable {
    case all
    case any
    case none
}

public enum VisibilityConditionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case timer
    case videoCountdown
    case audioPlayback
    case liveInput
    case capture
    case objectText
}

public enum VisibilityConditionState: String, Codable, Sendable, CaseIterable, Equatable {
    case hasTimeRemaining
    case hasExpired
    case isRunning
    case isNotRunning
    case isActive
    case isInactive
    case isConnected
    case isDisconnected
    case hasText
    case hasNoText
}

public struct VisibilityCondition: Codable, Sendable, Equatable {
    public var conditionKind: VisibilityConditionKind
    public var state: VisibilityConditionState
    public var timerId: String?
    public var objectId: String?
    public var liveInputId: String?

    public init(conditionKind: VisibilityConditionKind, state: VisibilityConditionState, timerId: String? = nil, objectId: String? = nil, liveInputId: String? = nil) {
        self.conditionKind = conditionKind
        self.state = state
        self.timerId = timerId
        self.objectId = objectId
        self.liveInputId = liveInputId
    }
}

public struct TextStyleRun: Codable, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var length: Int
    public var underline: Bool?
    public var strikethrough: Bool?
    public var fontName: String?
    public var fontSize: Double?
    public var colorHex: String?
    public var highlightColorHex: String?
    public var tracking: Double?

    public init(line: Int, column: Int, length: Int, underline: Bool? = nil, strikethrough: Bool? = nil, fontName: String? = nil, fontSize: Double? = nil, colorHex: String? = nil, highlightColorHex: String? = nil, tracking: Double? = nil) {
        self.line = line
        self.column = column
        self.length = length
        self.underline = underline
        self.strikethrough = strikethrough
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.highlightColorHex = highlightColorHex
        self.tracking = tracking
    }
}

public struct KeepFromSlideOptions: Codable, Sendable, Equatable {
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikethrough: Bool?
    public var sizeEmphasis: Bool?
    public var wordLetterSpacing: Bool?
    public var highlight: Bool?
    public var textColor: Bool?

    public init(bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strikethrough: Bool? = nil, sizeEmphasis: Bool? = nil, wordLetterSpacing: Bool? = nil, highlight: Bool? = nil, textColor: Bool? = nil) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.sizeEmphasis = sizeEmphasis
        self.wordLetterSpacing = wordLetterSpacing
        self.highlight = highlight
        self.textColor = textColor
    }
}

public enum AnimationKind: String, Codable, Sendable, CaseIterable, Equatable {
    case `in`
    case out
    case emphasis
    case morph
}

public enum AnimationTrigger: String, Codable, Sendable, CaseIterable, Equatable {
    case onClick
    case withPrevious
    case afterPrevious
    case onDismiss
}

public enum StepAnimation: String, Codable, Sendable, CaseIterable, Equatable {
    case fade
    case move
    case scale
    case wipe
    case blur
    case burn
    case glitch
    case draw
    case type
    case pulse
    case color
}

public enum BlockScrollAxis: String, Codable, Sendable, CaseIterable, Equatable {
    case up
    case down
    case left
    case right
}

public struct BlockScroll: Codable, Sendable, Equatable {
    public var axis: BlockScrollAxis?
    public var speed: Double
    public var passes: Int?
    public var ramp: AnimationRamp?
    public var restAtEnd: Bool?
    public var fadeTowardTop: Double?

    public init(axis: BlockScrollAxis? = nil, speed: Double, passes: Int? = nil, ramp: AnimationRamp? = nil, restAtEnd: Bool? = nil, fadeTowardTop: Double? = nil) {
        self.axis = axis
        self.speed = speed
        self.passes = passes
        self.ramp = ramp
        self.restAtEnd = restAtEnd
        self.fadeTowardTop = fadeTowardTop
    }
}

public enum AnimationRamp: String, Codable, Sendable, CaseIterable, Equatable {
    case none
    case `in`
    case out
    case both
}

public enum AnimationEdge: String, Codable, Sendable, CaseIterable, Equatable {
    case left
    case right
    case top
    case bottom
}

public struct AnimationRange: Codable, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var length: Int

    public init(line: Int, column: Int, length: Int) {
        self.line = line
        self.column = column
        self.length = length
    }
}

public enum VideoPushAlignment: String, Codable, Sendable, CaseIterable, Equatable {
    case center
    case left
    case right
    case top
    case bottom
}

public enum VideoPushMode: String, Codable, Sendable, CaseIterable, Equatable {
    case fill
    case fit
    case blurBackground
}

public struct VideoPush: Codable, Sendable, Equatable {
    public var alignment: VideoPushAlignment?
    public var mode: VideoPushMode?
    public var zoom: Double?
    public var margin: Double?
    public var backdrop: Bool?
    public var blurRadius: Double?

    public init(alignment: VideoPushAlignment? = nil, mode: VideoPushMode? = nil, zoom: Double? = nil, margin: Double? = nil, backdrop: Bool? = nil, blurRadius: Double? = nil) {
        self.alignment = alignment
        self.mode = mode
        self.zoom = zoom
        self.margin = margin
        self.backdrop = backdrop
        self.blurRadius = blurRadius
    }
}

public struct AnimationStep: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AnimationKind
    public var animation: StepAnimation
    public var trigger: AnimationTrigger
    public var delaySeconds: Double?
    public var durationSeconds: Double
    public var ramp: AnimationRamp?
    public var withFade: Bool?
    public var ranges: [AnimationRange]?
    public var edge: AnimationEdge?
    public var offsetX: Double?
    public var offsetY: Double?
    public var fromScale: Double?
    public var amount: Double?
    public var softEdge: Double?
    public var cursor: Bool?
    public var colorHex: String?
    public var placeholderUnderline: Bool?
    public var drawStart: Double?
    public var reverse: Bool?
    public var toObject: SlideObject?
    public var videoPush: VideoPush?
    public var fromObject: SlideObject?

    public init(id: String, kind: AnimationKind, animation: StepAnimation, trigger: AnimationTrigger, delaySeconds: Double? = nil, durationSeconds: Double, ramp: AnimationRamp? = nil, withFade: Bool? = nil, ranges: [AnimationRange]? = nil, edge: AnimationEdge? = nil, offsetX: Double? = nil, offsetY: Double? = nil, fromScale: Double? = nil, amount: Double? = nil, softEdge: Double? = nil, cursor: Bool? = nil, colorHex: String? = nil, placeholderUnderline: Bool? = nil, drawStart: Double? = nil, reverse: Bool? = nil, toObject: SlideObject? = nil, videoPush: VideoPush? = nil, fromObject: SlideObject? = nil) {
        self.id = id
        self.kind = kind
        self.animation = animation
        self.trigger = trigger
        self.delaySeconds = delaySeconds
        self.durationSeconds = durationSeconds
        self.ramp = ramp
        self.withFade = withFade
        self.ranges = ranges
        self.edge = edge
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.fromScale = fromScale
        self.amount = amount
        self.softEdge = softEdge
        self.cursor = cursor
        self.colorHex = colorHex
        self.placeholderUnderline = placeholderUnderline
        self.drawStart = drawStart
        self.reverse = reverse
        self.toObject = toObject
        self.videoPush = videoPush
        self.fromObject = fromObject
    }
}

public struct AnimationPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var steps: [AnimationStep]
    public var staggerSeconds: Double?
    public var scroll: BlockScroll?
    public var tilt: Double?

    public init(id: String, name: String, steps: [AnimationStep], staggerSeconds: Double? = nil, scroll: BlockScroll? = nil, tilt: Double? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.staggerSeconds = staggerSeconds
        self.scroll = scroll
        self.tilt = tilt
    }
}

public struct AnimationPresetBoard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var presets: [AnimationPreset]
    public var defaultIn: AnimationStep?
    public var defaultOut: AnimationStep?

    public init(id: String, presets: [AnimationPreset], defaultIn: AnimationStep? = nil, defaultOut: AnimationStep? = nil) {
        self.id = id
        self.presets = presets
        self.defaultIn = defaultIn
        self.defaultOut = defaultOut
    }
}

public struct SlideObject: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var objectKind: SlideObjectKind
    public var name: String
    public var text: String
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var rotationDegrees: Double?
    public var hidden: Bool?
    public var visibilityMatch: VisibilityMatch?
    public var visibilityConditions: [VisibilityCondition]?
    public var flipHorizontal: Bool?
    public var flipVertical: Bool?
    public var opacity: Double?
    public var blendMode: BlendMode?
    public var groupId: String?
    public var maskObjectId: String?
    public var maskMode: MaskMode?
    public var effects: [Effect]?
    public var effectsApplyBelow: Bool?
    public var textLink: TextLink?
    public var textStyle: TextStyle?
    public var chords: [ChordPlacement]?
    public var styleRuns: [TextStyleRun]?
    public var shapeKind: ShapeKind?
    public var cornerRadius: Double?
    public var pathData: String?
    public var shapeTextPlacement: ShapeTextPlacement?
    public var shapeTextCornerRadius: Double?
    public var fill: ObjectFill?
    public var stroke: ObjectStroke?
    public var shadow: ObjectShadow?
    public var mediaId: String?
    public var mediaScaleMode: MediaScaleMode?
    public var mediaSourceRect: MediaSourceRect?
    public var loops: Bool?
    public var captureSourceKind: CaptureSourceKind?
    public var captureSourceId: String?
    public var screenSourceId: String?
    public var liveInputId: String?
    public var keepFromSlide: KeepFromSlideOptions?
    public var animationSteps: [AnimationStep]?
    public var builds: [AnimationStep]?
    public var tilt: Double?
    public var swing: Double?
    public var tiltPivot: TiltPivot?
    public var keystoneTop: Double?
    public var keystoneBottom: Double?
    public var skewX: Double?
    public var skewY: Double?
    public var keystoneMode: KeystoneMode?

    public init(id: String, objectKind: SlideObjectKind, name: String, text: String, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil, rotationDegrees: Double? = nil, hidden: Bool? = nil, visibilityMatch: VisibilityMatch? = nil, visibilityConditions: [VisibilityCondition]? = nil, flipHorizontal: Bool? = nil, flipVertical: Bool? = nil, opacity: Double? = nil, blendMode: BlendMode? = nil, groupId: String? = nil, maskObjectId: String? = nil, maskMode: MaskMode? = nil, effects: [Effect]? = nil, effectsApplyBelow: Bool? = nil, textLink: TextLink? = nil, textStyle: TextStyle? = nil, chords: [ChordPlacement]? = nil, styleRuns: [TextStyleRun]? = nil, shapeKind: ShapeKind? = nil, cornerRadius: Double? = nil, pathData: String? = nil, shapeTextPlacement: ShapeTextPlacement? = nil, shapeTextCornerRadius: Double? = nil, fill: ObjectFill? = nil, stroke: ObjectStroke? = nil, shadow: ObjectShadow? = nil, mediaId: String? = nil, mediaScaleMode: MediaScaleMode? = nil, mediaSourceRect: MediaSourceRect? = nil, loops: Bool? = nil, captureSourceKind: CaptureSourceKind? = nil, captureSourceId: String? = nil, screenSourceId: String? = nil, liveInputId: String? = nil, keepFromSlide: KeepFromSlideOptions? = nil, animationSteps: [AnimationStep]? = nil, builds: [AnimationStep]? = nil, tilt: Double? = nil, swing: Double? = nil, tiltPivot: TiltPivot? = nil, keystoneTop: Double? = nil, keystoneBottom: Double? = nil, skewX: Double? = nil, skewY: Double? = nil, keystoneMode: KeystoneMode? = nil) {
        self.id = id
        self.objectKind = objectKind
        self.name = name
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.hidden = hidden
        self.visibilityMatch = visibilityMatch
        self.visibilityConditions = visibilityConditions
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.opacity = opacity
        self.blendMode = blendMode
        self.groupId = groupId
        self.maskObjectId = maskObjectId
        self.maskMode = maskMode
        self.effects = effects
        self.effectsApplyBelow = effectsApplyBelow
        self.textLink = textLink
        self.textStyle = textStyle
        self.chords = chords
        self.styleRuns = styleRuns
        self.shapeKind = shapeKind
        self.cornerRadius = cornerRadius
        self.pathData = pathData
        self.shapeTextPlacement = shapeTextPlacement
        self.shapeTextCornerRadius = shapeTextCornerRadius
        self.fill = fill
        self.stroke = stroke
        self.shadow = shadow
        self.mediaId = mediaId
        self.mediaScaleMode = mediaScaleMode
        self.mediaSourceRect = mediaSourceRect
        self.loops = loops
        self.captureSourceKind = captureSourceKind
        self.captureSourceId = captureSourceId
        self.screenSourceId = screenSourceId
        self.liveInputId = liveInputId
        self.keepFromSlide = keepFromSlide
        self.animationSteps = animationSteps
        self.builds = builds
        self.tilt = tilt
        self.swing = swing
        self.tiltPivot = tiltPivot
        self.keystoneTop = keystoneTop
        self.keystoneBottom = keystoneBottom
        self.skewX = skewX
        self.skewY = skewY
        self.keystoneMode = keystoneMode
    }
}

public enum KeystoneMode: String, Codable, Sendable, CaseIterable, Equatable {
    case perspective
    case stretch
}

public enum TiltPivot: String, Codable, Sendable, CaseIterable, Equatable {
    case top
    case center
    case bottom
}

public enum CueMediaLayer: String, Codable, Sendable, CaseIterable, Equatable {
    case loopingVideos
    case stillGraphics
    case videos
}

public enum CueMediaMode: String, Codable, Sendable, CaseIterable, Equatable {
    case slideOnly
    case untilReplaced
}

public struct CueMedia: Codable, Sendable, Equatable {
    public var mediaId: String
    public var mode: CueMediaMode?
    public var layer: CueMediaLayer?
    public var loops: Bool?
    public var classification: MediaClassification?

    public init(mediaId: String, mode: CueMediaMode? = nil, layer: CueMediaLayer? = nil, loops: Bool? = nil, classification: MediaClassification? = nil) {
        self.mediaId = mediaId
        self.mode = mode
        self.layer = layer
        self.loops = loops
        self.classification = classification
    }
}

public struct Slide: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var objects: [SlideObject]
    public var background: CueMedia?
    public var backgroundFill: ObjectFill?
    public var sectionId: String?
    public var folder: String?
    public var themeSlideName: String?
    public var themeId: String?
    public var unthemed: Bool?
    public var overrideDesigns: [OverrideDesign]?
    public var actions: [SlideAction]?
    public var notes: String?
    public var autoAdvance: AutoAdvance?
    public var transition: Transition?
    public var animationOrder: [String]?
    public var buildOrder: [String]?
    public var keepWords: Bool?
    public var history: [SlideVersion]?

    public init(id: String, name: String, objects: [SlideObject], background: CueMedia? = nil, backgroundFill: ObjectFill? = nil, sectionId: String? = nil, folder: String? = nil, themeSlideName: String? = nil, themeId: String? = nil, unthemed: Bool? = nil, overrideDesigns: [OverrideDesign]? = nil, actions: [SlideAction]? = nil, notes: String? = nil, autoAdvance: AutoAdvance? = nil, transition: Transition? = nil, animationOrder: [String]? = nil, buildOrder: [String]? = nil, keepWords: Bool? = nil, history: [SlideVersion]? = nil) {
        self.id = id
        self.name = name
        self.objects = objects
        self.background = background
        self.backgroundFill = backgroundFill
        self.sectionId = sectionId
        self.folder = folder
        self.themeSlideName = themeSlideName
        self.themeId = themeId
        self.unthemed = unthemed
        self.overrideDesigns = overrideDesigns
        self.actions = actions
        self.notes = notes
        self.autoAdvance = autoAdvance
        self.transition = transition
        self.animationOrder = animationOrder
        self.buildOrder = buildOrder
        self.keepWords = keepWords
        self.history = history
    }
}

public struct AutoAdvance: Codable, Sendable, Equatable {
    public var delaySeconds: Double
    public var loopToStart: Bool?
    public var afterPlayback: Bool?

    public init(delaySeconds: Double, loopToStart: Bool? = nil, afterPlayback: Bool? = nil) {
        self.delaySeconds = delaySeconds
        self.loopToStart = loopToStart
        self.afterPlayback = afterPlayback
    }
}

public struct PresentationSection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var background: CueMedia?
    public var colorHex: String?

    public init(id: String, name: String, background: CueMedia? = nil, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.background = background
        self.colorHex = colorHex
    }
}

public struct CCLIInfo: Codable, Sendable, Equatable {
    public var songNumber: Int?
    public var songTitle: String?
    public var author: String?
    public var publisher: String?
    public var copyrightYear: Int?
    public var copyright: String?

    public init(songNumber: Int? = nil, songTitle: String? = nil, author: String? = nil, publisher: String? = nil, copyrightYear: Int? = nil, copyright: String? = nil) {
        self.songNumber = songNumber
        self.songTitle = songTitle
        self.author = author
        self.publisher = publisher
        self.copyrightYear = copyrightYear
        self.copyright = copyright
    }
}

public struct Arrangement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var sectionIds: [String]

    public init(id: String, name: String, sectionIds: [String]) {
        self.id = id
        self.name = name
        self.sectionIds = sectionIds
    }
}

public enum PresentationOriginSource: String, Codable, Sendable, CaseIterable, Equatable {
    case madeHere
    case proPresenter
    case planningCenterChart
    case planningCenterLyrics
    case songSelect
    case lyricsFile
    case chartFile
    case pastedLyrics
    case slidesFile
    case duplicate
}

public struct PresentationOrigin: Codable, Sendable, Equatable {
    public var source: PresentationOriginSource
    public var detail: String?
    public var createdAt: String?

    public init(source: PresentationOriginSource, detail: String? = nil, createdAt: String? = nil) {
        self.source = source
        self.detail = detail
        self.createdAt = createdAt
    }
}

public enum PresentationKind: String, Codable, Sendable, CaseIterable, Equatable {
    case song
    case deck
}

public struct Presentation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var presentationKind: PresentationKind
    public var themeId: String
    public var folder: String?
    public var folderId: String?
    public var slides: [Slide]
    public var canvasWidth: Int?
    public var canvasHeight: Int?
    public var background: CueMedia?
    public var backgroundFill: ObjectFill?
    public var sections: [PresentationSection]?
    public var arrangements: [Arrangement]?
    public var defaultArrangementId: String?
    public var reflowSource: String?
    public var ccli: CCLIInfo?
    public var chordProSource: String?
    public var musicKey: String?
    public var autoAdvance: AutoAdvance?
    public var displayKey: String?
    public var origin: PresentationOrigin?

    public init(id: String, name: String, presentationKind: PresentationKind, themeId: String, folder: String? = nil, folderId: String? = nil, slides: [Slide], canvasWidth: Int? = nil, canvasHeight: Int? = nil, background: CueMedia? = nil, backgroundFill: ObjectFill? = nil, sections: [PresentationSection]? = nil, arrangements: [Arrangement]? = nil, defaultArrangementId: String? = nil, reflowSource: String? = nil, ccli: CCLIInfo? = nil, chordProSource: String? = nil, musicKey: String? = nil, autoAdvance: AutoAdvance? = nil, displayKey: String? = nil, origin: PresentationOrigin? = nil) {
        self.id = id
        self.name = name
        self.presentationKind = presentationKind
        self.themeId = themeId
        self.folder = folder
        self.folderId = folderId
        self.slides = slides
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.background = background
        self.backgroundFill = backgroundFill
        self.sections = sections
        self.arrangements = arrangements
        self.defaultArrangementId = defaultArrangementId
        self.reflowSource = reflowSource
        self.ccli = ccli
        self.chordProSource = chordProSource
        self.musicKey = musicKey
        self.autoAdvance = autoAdvance
        self.displayKey = displayKey
        self.origin = origin
    }
}

public enum MediaKind: String, Codable, Sendable, CaseIterable, Equatable {
    case image
    case video
}

public enum MediaClassification: String, Codable, Sendable, CaseIterable, Equatable {
    case foreground
    case background
}

public enum MediaFileStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case ready
    case needsTranscode
    case transcoding
    case transcodeFailed
}

public struct MediaItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mediaKind: MediaKind
    public var classification: MediaClassification
    public var fileHash: String
    public var fileName: String
    public var fileStatus: MediaFileStatus
    public var statusDetail: String
    public var tags: [String]
    public var favorite: Bool
    public var collections: [String]
    public var loops: Bool
    public var inPoint: Double?
    public var outPoint: Double?
    public var playRate: Double?
    public var effects: [Effect]?
    public var transition: Transition?
    public var durationSeconds: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var folder: String?
    public var folderId: String?
    public var recordedAt: Double?
    public var recordedByPresetId: String?
    public var actions: [SlideAction]?
    public var autoAdvance: AutoAdvance?

    public init(id: String, name: String, mediaKind: MediaKind, classification: MediaClassification, fileHash: String, fileName: String, fileStatus: MediaFileStatus, statusDetail: String, tags: [String], favorite: Bool, collections: [String], loops: Bool, inPoint: Double? = nil, outPoint: Double? = nil, playRate: Double? = nil, effects: [Effect]? = nil, transition: Transition? = nil, durationSeconds: Double? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, folder: String? = nil, folderId: String? = nil, recordedAt: Double? = nil, recordedByPresetId: String? = nil, actions: [SlideAction]? = nil, autoAdvance: AutoAdvance? = nil) {
        self.id = id
        self.name = name
        self.mediaKind = mediaKind
        self.classification = classification
        self.fileHash = fileHash
        self.fileName = fileName
        self.fileStatus = fileStatus
        self.statusDetail = statusDetail
        self.tags = tags
        self.favorite = favorite
        self.collections = collections
        self.loops = loops
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.playRate = playRate
        self.effects = effects
        self.transition = transition
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.folder = folder
        self.folderId = folderId
        self.recordedAt = recordedAt
        self.recordedByPresetId = recordedByPresetId
        self.actions = actions
        self.autoAdvance = autoAdvance
    }
}

public struct AudioItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var fileHash: String
    public var fileName: String
    public var tags: [String]
    public var favorite: Bool
    public var inPoint: Double?
    public var outPoint: Double?
    public var durationSeconds: Double?
    public var folder: String?
    public var folderId: String?

    public init(id: String, name: String, fileHash: String, fileName: String, tags: [String], favorite: Bool, inPoint: Double? = nil, outPoint: Double? = nil, durationSeconds: Double? = nil, folder: String? = nil, folderId: String? = nil) {
        self.id = id
        self.name = name
        self.fileHash = fileHash
        self.fileName = fileName
        self.tags = tags
        self.favorite = favorite
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.durationSeconds = durationSeconds
        self.folder = folder
        self.folderId = folderId
    }
}

public enum PlaylistRefKind: String, Codable, Sendable, CaseIterable, Equatable {
    case media
    case audio
}

public struct PlaylistEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var refKind: PlaylistRefKind
    public var refId: String
    public var autoAdvanceDelaySeconds: Double?

    public init(id: String, refKind: PlaylistRefKind, refId: String, autoAdvanceDelaySeconds: Double? = nil) {
        self.id = id
        self.refKind = refKind
        self.refId = refId
        self.autoAdvanceDelaySeconds = autoAdvanceDelaySeconds
    }
}

public enum PlaybackMode: String, Codable, Sendable, CaseIterable, Equatable {
    case playAll
    case loopPlaylist
    case loopSingle

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "shuffle": self = .playAll
        default:
            guard let value = Self(rawValue: raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown PlaybackMode value: \(raw)"
                ))
            }
            self = value
        }
    }
}

public enum PlaylistKind: String, Codable, Sendable, CaseIterable, Equatable {
    case media
    case audio
}

public struct Playlist: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var playlistKind: PlaylistKind?
    public var entries: [PlaylistEntry]
    public var playbackMode: PlaybackMode
    public var shuffle: Bool?
    public var crossfadeSeconds: Double?
    public var autoAdvance: Bool?
    public var autoAdvanceDelaySeconds: Double?

    public init(id: String, name: String, playlistKind: PlaylistKind? = nil, entries: [PlaylistEntry], playbackMode: PlaybackMode, shuffle: Bool? = nil, crossfadeSeconds: Double? = nil, autoAdvance: Bool? = nil, autoAdvanceDelaySeconds: Double? = nil) {
        self.id = id
        self.name = name
        self.playlistKind = playlistKind
        self.entries = entries
        self.playbackMode = playbackMode
        self.shuffle = shuffle
        self.crossfadeSeconds = crossfadeSeconds
        self.autoAdvance = autoAdvance
        self.autoAdvanceDelaySeconds = autoAdvanceDelaySeconds
    }
}

public enum ServiceItemKind: String, Codable, Sendable, CaseIterable, Equatable {
    case presentation
    case media
    case audio
    case playlist
    case header
    case info
}

public struct ServiceItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var itemKind: ServiceItemKind
    public var name: String
    public var refId: String
    public var arrangementId: String?
    public var colorHex: String?
    public var outputPresetId: String?
    public var mxuItemHexId: String?
    public var duration: Int?
    public var mxuKind: String?
    public var excludedTimeHexIds: [String]?
    public var hiddenInPresenter: Bool?
    public var mxuSongTitle: String?
    public var mxuCcliNumber: Int?
    public var mxuArrangementName: String?
    public var mxuSongAuthor: String?
    public var mxuMultiTracksUrl: String?
    public var mxuNotes: [MxUPlanItemNote]?
    public var mxuMessageNotesDocumentHexId: String?
    public var mxuMessageNotesSubmittedAt: String?
    public var mxuMessageNotesOnReady: String?
    public var mxuMessageNotesDeckDocId: String?
    public var mxuPcoItemId: String?
    public var mxuPcoSongId: String?
    public var mxuPcoArrangementId: String?
    public var mxuPcoKeyId: String?
    public var mxuSongKey: String?
    public var mxuDescription: String?
    public var mxuServicePosition: String?
    public var mxuBpm: Double?
    public var mxuTimeSignature: String?
    public var mxuSongKeyApplied: String?

    public init(id: String, itemKind: ServiceItemKind, name: String, refId: String, arrangementId: String? = nil, colorHex: String? = nil, outputPresetId: String? = nil, mxuItemHexId: String? = nil, duration: Int? = nil, mxuKind: String? = nil, excludedTimeHexIds: [String]? = nil, hiddenInPresenter: Bool? = nil, mxuSongTitle: String? = nil, mxuCcliNumber: Int? = nil, mxuArrangementName: String? = nil, mxuSongAuthor: String? = nil, mxuMultiTracksUrl: String? = nil, mxuNotes: [MxUPlanItemNote]? = nil, mxuMessageNotesDocumentHexId: String? = nil, mxuMessageNotesSubmittedAt: String? = nil, mxuMessageNotesOnReady: String? = nil, mxuMessageNotesDeckDocId: String? = nil, mxuPcoItemId: String? = nil, mxuPcoSongId: String? = nil, mxuPcoArrangementId: String? = nil, mxuPcoKeyId: String? = nil, mxuSongKey: String? = nil, mxuDescription: String? = nil, mxuServicePosition: String? = nil, mxuBpm: Double? = nil, mxuTimeSignature: String? = nil, mxuSongKeyApplied: String? = nil) {
        self.id = id
        self.itemKind = itemKind
        self.name = name
        self.refId = refId
        self.arrangementId = arrangementId
        self.colorHex = colorHex
        self.outputPresetId = outputPresetId
        self.mxuItemHexId = mxuItemHexId
        self.duration = duration
        self.mxuKind = mxuKind
        self.excludedTimeHexIds = excludedTimeHexIds
        self.hiddenInPresenter = hiddenInPresenter
        self.mxuSongTitle = mxuSongTitle
        self.mxuCcliNumber = mxuCcliNumber
        self.mxuArrangementName = mxuArrangementName
        self.mxuSongAuthor = mxuSongAuthor
        self.mxuMultiTracksUrl = mxuMultiTracksUrl
        self.mxuNotes = mxuNotes
        self.mxuMessageNotesDocumentHexId = mxuMessageNotesDocumentHexId
        self.mxuMessageNotesSubmittedAt = mxuMessageNotesSubmittedAt
        self.mxuMessageNotesOnReady = mxuMessageNotesOnReady
        self.mxuMessageNotesDeckDocId = mxuMessageNotesDeckDocId
        self.mxuPcoItemId = mxuPcoItemId
        self.mxuPcoSongId = mxuPcoSongId
        self.mxuPcoArrangementId = mxuPcoArrangementId
        self.mxuPcoKeyId = mxuPcoKeyId
        self.mxuSongKey = mxuSongKey
        self.mxuDescription = mxuDescription
        self.mxuServicePosition = mxuServicePosition
        self.mxuBpm = mxuBpm
        self.mxuTimeSignature = mxuTimeSignature
        self.mxuSongKeyApplied = mxuSongKeyApplied
    }
}

public struct ServiceLinkRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var normalizedName: String
    public var serviceTypeName: String?
    public var itemKind: ServiceItemKind
    public var refId: String

    public init(id: String, normalizedName: String, serviceTypeName: String? = nil, itemKind: ServiceItemKind, refId: String) {
        self.id = id
        self.normalizedName = normalizedName
        self.serviceTypeName = serviceTypeName
        self.itemKind = itemKind
        self.refId = refId
    }
}

public struct ServiceLinkRules: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var rules: [ServiceLinkRule]

    public init(id: String, rules: [ServiceLinkRule]) {
        self.id = id
        self.rules = rules
    }
}

public struct MxUPlanTime: Codable, Sendable, Equatable {
    public var hexId: String
    public var name: String
    public var startsAt: String?
    public var isRehearsal: Bool?

    public init(hexId: String, name: String, startsAt: String? = nil, isRehearsal: Bool? = nil) {
        self.hexId = hexId
        self.name = name
        self.startsAt = startsAt
        self.isRehearsal = isRehearsal
    }
}

public struct MxUPlanItemNote: Codable, Sendable, Equatable {
    public var label: String?
    public var text: String
    public var kind: String?
    public var positions: [String]?

    public init(label: String? = nil, text: String, kind: String? = nil, positions: [String]? = nil) {
        self.label = label
        self.text = text
        self.kind = kind
        self.positions = positions
    }
}

public struct MxUPlanTimeOrder: Codable, Sendable, Equatable {
    public var timeHexId: String
    public var itemHexIds: [String]

    public init(timeHexId: String, itemHexIds: [String]) {
        self.timeHexId = timeHexId
        self.itemHexIds = itemHexIds
    }
}

public struct ServiceVersionStation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ServiceItemChange: Codable, Sendable, Equatable {
    public var itemId: String
    public var after: String?
    public var hidden: Bool?
    public var itemKind: ServiceItemKind?
    public var refId: String?
    public var name: String?
    public var arrangementId: String?
    public var outputPresetId: String?

    public init(itemId: String, after: String? = nil, hidden: Bool? = nil, itemKind: ServiceItemKind? = nil, refId: String? = nil, name: String? = nil, arrangementId: String? = nil, outputPresetId: String? = nil) {
        self.itemId = itemId
        self.after = after
        self.hidden = hidden
        self.itemKind = itemKind
        self.refId = refId
        self.name = name
        self.arrangementId = arrangementId
        self.outputPresetId = outputPresetId
    }
}

public struct ServiceVersion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var stations: [ServiceVersionStation]?
    public var added: [ServiceItem]?
    public var changes: [ServiceItemChange]?

    public init(id: String, name: String, stations: [ServiceVersionStation]? = nil, added: [ServiceItem]? = nil, changes: [ServiceItemChange]? = nil) {
        self.id = id
        self.name = name
        self.stations = stations
        self.added = added
        self.changes = changes
    }
}

public struct Service: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var serviceDate: String
    public var items: [ServiceItem]
    public var origin: String?
    public var mxuPlanHexId: String?
    public var mxuServiceTypeName: String?
    public var mxuPlanVersion: String?
    public var mxuPlanTimes: [MxUPlanTime]?
    public var mxuTimeOrders: [MxUPlanTimeOrder]?
    public var mxuSyncedOrder: [String]?
    public var mxuDerivedName: String?
    public var mxuSyncPaused: Bool?
    public var versions: [ServiceVersion]?

    public init(id: String, name: String, serviceDate: String, items: [ServiceItem], origin: String? = nil, mxuPlanHexId: String? = nil, mxuServiceTypeName: String? = nil, mxuPlanVersion: String? = nil, mxuPlanTimes: [MxUPlanTime]? = nil, mxuTimeOrders: [MxUPlanTimeOrder]? = nil, mxuSyncedOrder: [String]? = nil, mxuDerivedName: String? = nil, mxuSyncPaused: Bool? = nil, versions: [ServiceVersion]? = nil) {
        self.id = id
        self.name = name
        self.serviceDate = serviceDate
        self.items = items
        self.origin = origin
        self.mxuPlanHexId = mxuPlanHexId
        self.mxuServiceTypeName = mxuServiceTypeName
        self.mxuPlanVersion = mxuPlanVersion
        self.mxuPlanTimes = mxuPlanTimes
        self.mxuTimeOrders = mxuTimeOrders
        self.mxuSyncedOrder = mxuSyncedOrder
        self.mxuDerivedName = mxuDerivedName
        self.mxuSyncPaused = mxuSyncPaused
        self.versions = versions
    }
}

public struct Overlay: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var objects: [SlideObject]
    public var folder: String?
    public var folderId: String?
    public var layer: String?
    public var animationOrder: [String]?
    public var buildOrder: [String]?

    public init(id: String, name: String, objects: [SlideObject], folder: String? = nil, folderId: String? = nil, layer: String? = nil, animationOrder: [String]? = nil, buildOrder: [String]? = nil) {
        self.id = id
        self.name = name
        self.objects = objects
        self.folder = folder
        self.folderId = folderId
        self.layer = layer
        self.animationOrder = animationOrder
        self.buildOrder = buildOrder
    }
}

public enum OutputTargetKind: String, Codable, Sendable, CaseIterable, Equatable {
    case display
    case placeholderScreen

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "virtualScreen": self = .placeholderScreen
        default:
            guard let value = Self(rawValue: raw) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown OutputTargetKind value: \(raw)"
                ))
            }
            self = value
        }
    }
}

public struct OutputAssignment: Codable, Sendable, Equatable {
    public var targetKind: OutputTargetKind
    public var targetId: String
    public var enabledLayers: [String]
    public var slideThemeId: String?
    public var slideThemeFolder: String?
    public var slideThemeSlideId: String?
    public var maskIds: [String]?

    public init(targetKind: OutputTargetKind, targetId: String, enabledLayers: [String], slideThemeId: String? = nil, slideThemeFolder: String? = nil, slideThemeSlideId: String? = nil, maskIds: [String]? = nil) {
        self.targetKind = targetKind
        self.targetId = targetId
        self.enabledLayers = enabledLayers
        self.slideThemeId = slideThemeId
        self.slideThemeFolder = slideThemeFolder
        self.slideThemeSlideId = slideThemeSlideId
        self.maskIds = maskIds
    }
}

public struct OutputPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var assignments: [OutputAssignment]

    public init(id: String, name: String, assignments: [OutputAssignment]) {
        self.id = id
        self.name = name
        self.assignments = assignments
    }
}

public enum MIDIDeviceItemDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case input
    case output
    case both
}

public struct MIDIDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var direction: MIDIDeviceItemDirection?
    public var channel: Int?
    public var enabled: Bool?
    public var sourceNames: [String]?
    public var destinationNames: [String]?
    public var autoReconnect: Bool?

    public init(id: String, name: String, direction: MIDIDeviceItemDirection? = nil, channel: Int? = nil, enabled: Bool? = nil, sourceNames: [String]? = nil, destinationNames: [String]? = nil, autoReconnect: Bool? = nil) {
        self.id = id
        self.name = name
        self.direction = direction
        self.channel = channel
        self.enabled = enabled
        self.sourceNames = sourceNames
        self.destinationNames = destinationNames
        self.autoReconnect = autoReconnect
    }
}

public enum AlertBehavior: String, Codable, Sendable, CaseIterable, Equatable {
    case persist
    case flash
}

public enum AlertTarget: String, Codable, Sendable, CaseIterable, Equatable {
    case confidence
    case audience
    case both
}

public struct AlertPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var message: String
    public var behavior: AlertBehavior
    public var target: AlertTarget?
    public var themeId: String?
    public var layer: String?

    public init(id: String, name: String, message: String, behavior: AlertBehavior, target: AlertTarget? = nil, themeId: String? = nil, layer: String? = nil) {
        self.id = id
        self.name = name
        self.message = message
        self.behavior = behavior
        self.target = target
        self.themeId = themeId
        self.layer = layer
    }
}

public struct Theme: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var fontFamily: String
    public var fontSize: Double
    public var textColorHex: String
    public var backgroundColorHex: String
    public var slides: [Slide]?

    public init(id: String, name: String, fontFamily: String, fontSize: Double, textColorHex: String, backgroundColorHex: String, slides: [Slide]? = nil) {
        self.id = id
        self.name = name
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColorHex = textColorHex
        self.backgroundColorHex = backgroundColorHex
        self.slides = slides
    }
}

public enum StreamTransport: String, Codable, Sendable, CaseIterable, Equatable {
    case rtmp
    case rtmps
    case srt
    case hls
}

public enum StreamVideoCodec: String, Codable, Sendable, CaseIterable, Equatable {
    case h264
    case hevc
}

public struct StreamPresetDestination: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var transport: StreamTransport
    public var url: String
    public var streamKey: String?
    public var linkedPlatform: String?
    public var linkedTargetId: String?
    public var videoCodec: StreamVideoCodec?
    public var maxHeight: Int?
    public var hdr: Bool?
    public var privacy: String?
    public var canvasScreenId: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?

    public init(id: String, name: String, transport: StreamTransport, url: String, streamKey: String? = nil, linkedPlatform: String? = nil, linkedTargetId: String? = nil, videoCodec: StreamVideoCodec? = nil, maxHeight: Int? = nil, hdr: Bool? = nil, privacy: String? = nil, canvasScreenId: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.streamKey = streamKey
        self.linkedPlatform = linkedPlatform
        self.linkedTargetId = linkedTargetId
        self.videoCodec = videoCodec
        self.maxHeight = maxHeight
        self.hdr = hdr
        self.privacy = privacy
        self.canvasScreenId = canvasScreenId
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

public enum StreamPresetKind: String, Codable, Sendable, CaseIterable, Equatable {
    case stream
    case recordOnly
}

public struct StreamDestination: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var transport: StreamTransport
    public var url: String
    public var streamKey: String?
    public var linkedPlatform: String?
    public var linkedTargetId: String?
    public var linkedTargetName: String?
    public var videoCodec: StreamVideoCodec?
    public var maxHeight: Int?
    public var hdr: Bool?
    public var defaultPrivacy: String?
    public var canvasScreenId: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?

    public init(id: String, name: String, transport: StreamTransport, url: String, streamKey: String? = nil, linkedPlatform: String? = nil, linkedTargetId: String? = nil, linkedTargetName: String? = nil, videoCodec: StreamVideoCodec? = nil, maxHeight: Int? = nil, hdr: Bool? = nil, defaultPrivacy: String? = nil, canvasScreenId: String? = nil, width: Int? = nil, height: Int? = nil, frameRate: Int? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.streamKey = streamKey
        self.linkedPlatform = linkedPlatform
        self.linkedTargetId = linkedTargetId
        self.linkedTargetName = linkedTargetName
        self.videoCodec = videoCodec
        self.maxHeight = maxHeight
        self.hdr = hdr
        self.defaultPrivacy = defaultPrivacy
        self.canvasScreenId = canvasScreenId
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

public enum StreamSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case screen
    case mediaItem
    case latestRecording
}

public struct StreamRecordPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var destinations: [StreamPresetDestination]
    public var destinationIds: [String]?
    public var presetKind: StreamPresetKind?
    public var width: Int?
    public var height: Int?
    public var frameRate: Int?
    public var videoBitrateKbps: Int?
    public var canvasScreenId: String?
    public var recordWhileStreaming: Bool?
    public var recordCodec: String?
    public var title: String?
    public var streamDescription: String?
    public var recordFolder: String?
    public var audioInputUid: String?
    public var audioIncludesProgram: Bool?
    public var audioInputId: String?
    public var audioMixId: String?
    public var audioDelayMs: Int?
    public var sourceKind: StreamSourceKind?
    public var sourceMediaId: String?
    public var sourceFolder: String?
    public var sourceMaxAgeHours: Int?
    public var recordLibraryFolder: String?
    public var recordExportFolder: String?

    public init(id: String, name: String, destinations: [StreamPresetDestination], destinationIds: [String]? = nil, presetKind: StreamPresetKind? = nil, width: Int? = nil, height: Int? = nil, frameRate: Int? = nil, videoBitrateKbps: Int? = nil, canvasScreenId: String? = nil, recordWhileStreaming: Bool? = nil, recordCodec: String? = nil, title: String? = nil, streamDescription: String? = nil, recordFolder: String? = nil, audioInputUid: String? = nil, audioIncludesProgram: Bool? = nil, audioInputId: String? = nil, audioMixId: String? = nil, audioDelayMs: Int? = nil, sourceKind: StreamSourceKind? = nil, sourceMediaId: String? = nil, sourceFolder: String? = nil, sourceMaxAgeHours: Int? = nil, recordLibraryFolder: String? = nil, recordExportFolder: String? = nil) {
        self.id = id
        self.name = name
        self.destinations = destinations
        self.destinationIds = destinationIds
        self.presetKind = presetKind
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrateKbps = videoBitrateKbps
        self.canvasScreenId = canvasScreenId
        self.recordWhileStreaming = recordWhileStreaming
        self.recordCodec = recordCodec
        self.title = title
        self.streamDescription = streamDescription
        self.recordFolder = recordFolder
        self.audioInputUid = audioInputUid
        self.audioIncludesProgram = audioIncludesProgram
        self.audioInputId = audioInputId
        self.audioMixId = audioMixId
        self.audioDelayMs = audioDelayMs
        self.sourceKind = sourceKind
        self.sourceMediaId = sourceMediaId
        self.sourceFolder = sourceFolder
        self.sourceMaxAgeHours = sourceMaxAgeHours
        self.recordLibraryFolder = recordLibraryFolder
        self.recordExportFolder = recordExportFolder
    }
}

public enum CaptureSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case camera
    case ndi
}

public enum SlideActionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case clearLayer
    case clearAll
    case clearAudio
    case clearSignage
    case switchOutputPreset
    case fireMedia
    case fireAlert
    case dismissAlert
    case timerStart
    case timerPause
    case timerReset
    case timerConfigure
    case midiOut
    case fireCombo
    case captureStart
    case captureStop
    case firePresentation
    case setConfidenceLayout
    case fireOverlay
    case dismissOverlay
    case fireLiveInput
    case setSignage
    case setScreenSource
    case enableAudioInput
    case disableAudioInput
    case fireAudio
    case fireAudioPlaylist
}

public enum MIDIMessageKind: String, Codable, Sendable, CaseIterable, Equatable {
    case noteOn
    case controlChange
}

public enum TimerMode: String, Codable, Sendable, CaseIterable, Equatable {
    case countdown
    case countdownToTime
    case countUp
}

public struct SlideAction: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: SlideActionKind
    public var layer: String?
    public var presetId: String?
    public var mediaId: String?
    public var alertId: String?
    public var timerId: String?
    public var timerMode: TimerMode?
    public var timerDurationSeconds: Double?
    public var timerHour: Int?
    public var timerMinute: Int?
    public var comboId: String?
    public var midiKind: MIDIMessageKind?
    public var midiChannel: Int?
    public var midiNumber: Int?
    public var midiValue: Int?
    public var midiDeviceId: String?
    public var capturePresetId: String?
    public var capturePrivacy: String?
    public var presentationId: String?
    public var slideIndex: Int?
    public var confidenceLayoutId: String?
    public var confidenceScreenId: String?
    public var overlayId: String?
    public var inputSourceKind: CaptureSourceKind?
    public var inputSourceId: String?
    public var liveInputId: String?
    public var audioInputId: String?
    public var playlistId: String?
    public var audioItemId: String?
    public var audioEntryId: String?
    public var audioRepeat: Bool?
    public var signageId: String?
    public var screenId: String?
    public var delaySeconds: Double?

    public init(id: String, kind: SlideActionKind, layer: String? = nil, presetId: String? = nil, mediaId: String? = nil, alertId: String? = nil, timerId: String? = nil, timerMode: TimerMode? = nil, timerDurationSeconds: Double? = nil, timerHour: Int? = nil, timerMinute: Int? = nil, comboId: String? = nil, midiKind: MIDIMessageKind? = nil, midiChannel: Int? = nil, midiNumber: Int? = nil, midiValue: Int? = nil, midiDeviceId: String? = nil, capturePresetId: String? = nil, capturePrivacy: String? = nil, presentationId: String? = nil, slideIndex: Int? = nil, confidenceLayoutId: String? = nil, confidenceScreenId: String? = nil, overlayId: String? = nil, inputSourceKind: CaptureSourceKind? = nil, inputSourceId: String? = nil, liveInputId: String? = nil, audioInputId: String? = nil, playlistId: String? = nil, audioItemId: String? = nil, audioEntryId: String? = nil, audioRepeat: Bool? = nil, signageId: String? = nil, screenId: String? = nil, delaySeconds: Double? = nil) {
        self.id = id
        self.kind = kind
        self.layer = layer
        self.presetId = presetId
        self.mediaId = mediaId
        self.alertId = alertId
        self.timerId = timerId
        self.timerMode = timerMode
        self.timerDurationSeconds = timerDurationSeconds
        self.timerHour = timerHour
        self.timerMinute = timerMinute
        self.comboId = comboId
        self.midiKind = midiKind
        self.midiChannel = midiChannel
        self.midiNumber = midiNumber
        self.midiValue = midiValue
        self.midiDeviceId = midiDeviceId
        self.capturePresetId = capturePresetId
        self.capturePrivacy = capturePrivacy
        self.presentationId = presentationId
        self.slideIndex = slideIndex
        self.confidenceLayoutId = confidenceLayoutId
        self.confidenceScreenId = confidenceScreenId
        self.overlayId = overlayId
        self.inputSourceKind = inputSourceKind
        self.inputSourceId = inputSourceId
        self.liveInputId = liveInputId
        self.audioInputId = audioInputId
        self.playlistId = playlistId
        self.audioItemId = audioItemId
        self.audioEntryId = audioEntryId
        self.audioRepeat = audioRepeat
        self.signageId = signageId
        self.screenId = screenId
        self.delaySeconds = delaySeconds
    }
}

public struct ActionCombo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var actions: [SlideAction]
    public var colorHex: String?
    public var iconName: String?
    public var runOnStartup: Bool?

    public init(id: String, name: String, actions: [SlideAction], colorHex: String? = nil, iconName: String? = nil, runOnStartup: Bool? = nil) {
        self.id = id
        self.name = name
        self.actions = actions
        self.colorHex = colorHex
        self.iconName = iconName
        self.runOnStartup = runOnStartup
    }
}

public enum ScheduleConditionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case weekly
    case oneTime
    case timerReaches
}

public struct ScheduleCondition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ScheduleConditionKind
    public var days: [Int]?
    public var timeOfDay: String?
    public var date: String?
    public var timerId: String?
    public var timerSeconds: Double?
    public var excludedDates: [String]?

    public init(id: String, kind: ScheduleConditionKind, days: [Int]? = nil, timeOfDay: String? = nil, date: String? = nil, timerId: String? = nil, timerSeconds: Double? = nil, excludedDates: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.days = days
        self.timeOfDay = timeOfDay
        self.date = date
        self.timerId = timerId
        self.timerSeconds = timerSeconds
        self.excludedDates = excludedDates
    }
}

public enum ScheduleConditionLogic: String, Codable, Sendable, CaseIterable, Equatable {
    case any
    case all
}

public struct ScheduleTrigger: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var conditions: [ScheduleCondition]
    public var actions: [SlideAction]
    public var conditionLogic: ScheduleConditionLogic?
    public var enabled: Bool?
    public var notes: String?
    public var archived: Bool?
    public var disabledUntil: String?
    public var enabledUntil: String?

    public init(id: String, name: String, conditions: [ScheduleCondition], actions: [SlideAction], conditionLogic: ScheduleConditionLogic? = nil, enabled: Bool? = nil, notes: String? = nil, archived: Bool? = nil, disabledUntil: String? = nil, enabledUntil: String? = nil) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.actions = actions
        self.conditionLogic = conditionLogic
        self.enabled = enabled
        self.notes = notes
        self.archived = archived
        self.disabledUntil = disabledUntil
        self.enabledUntil = enabledUntil
    }
}

public struct ScheduleFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool?
    public var collapsed: Bool?
    public var triggerIds: [String]

    public init(id: String, name: String, enabled: Bool? = nil, collapsed: Bool? = nil, triggerIds: [String]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.collapsed = collapsed
        self.triggerIds = triggerIds
    }
}

public struct SchedulerBoard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var nodes: [String]
    public var folders: [ScheduleFolder]

    public init(id: String, nodes: [String], folders: [ScheduleFolder]) {
        self.id = id
        self.nodes = nodes
        self.folders = folders
    }
}

public struct ControlFolder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var collapsed: Bool?
    public var itemIds: [String]

    public init(id: String, name: String, collapsed: Bool? = nil, itemIds: [String]) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.itemIds = itemIds
    }
}

public struct ControlBoard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var nodes: [String]
    public var folders: [ControlFolder]

    public init(id: String, nodes: [String], folders: [ControlFolder]) {
        self.id = id
        self.nodes = nodes
        self.folders = folders
    }
}

public struct GroupDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var colorHex: String
    public var hotKey: String?

    public init(id: String, name: String, colorHex: String, hotKey: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.hotKey = hotKey
    }
}

public struct GroupPalette: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var groups: [GroupDefinition]

    public init(id: String, groups: [GroupDefinition]) {
        self.id = id
        self.groups = groups
    }
}

public struct ImportLedgerEntry: Codable, Sendable, Equatable {
    public var docId: String
    public var hash: String

    public init(docId: String, hash: String) {
        self.docId = docId
        self.hash = hash
    }
}

public struct ImportLedger: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var entries: [ImportLedgerEntry]

    public init(id: String, entries: [ImportLedgerEntry]) {
        self.id = id
        self.entries = entries
    }
}

public enum TransitionKind: String, Codable, Sendable, CaseIterable, Equatable {
    case cut
    case dissolve
    case fadeBlack
    case fadeWhite
    case fadeColor
    case blurDissolve
    case filmBurn
}

public struct Transition: Codable, Sendable, Equatable {
    public var transitionKind: TransitionKind
    public var durationSeconds: Double?
    public var colorHex: String?

    public init(transitionKind: TransitionKind, durationSeconds: Double? = nil, colorHex: String? = nil) {
        self.transitionKind = transitionKind
        self.durationSeconds = durationSeconds
        self.colorHex = colorHex
    }
}

public struct EffectPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var effects: [Effect]

    public init(id: String, name: String, effects: [Effect]) {
        self.id = id
        self.name = name
        self.effects = effects
    }
}

public struct EffectPresetBoard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var presets: [EffectPreset]

    public init(id: String, presets: [EffectPreset]) {
        self.id = id
        self.presets = presets
    }
}

public enum MaskMode: String, Codable, Sendable, CaseIterable, Equatable {
    case `in`
    case out
}

public enum EffectKind: String, Codable, Sendable, CaseIterable, Equatable {
    case blur
    case colorAdjust
    case hueRotate
    case invert
    case posterize
    case pixelate
    case vignette
    case warp
    case echo
    case scatter
    case stainedGlass
    case grain
    case ghostTrails
}

public struct Effect: Codable, Sendable, Equatable {
    public var effectKind: EffectKind
    public var enabled: Bool?
    public var opacity: Double?
    public var radius: Double?
    public var amount: Double?
    public var scale: Double?
    public var speed: Double?
    public var fade: Double?
    public var smooth: Double?
    public var brightness: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var hue: Double?

    public init(effectKind: EffectKind, enabled: Bool? = nil, opacity: Double? = nil, radius: Double? = nil, amount: Double? = nil, scale: Double? = nil, speed: Double? = nil, fade: Double? = nil, smooth: Double? = nil, brightness: Double? = nil, contrast: Double? = nil, saturation: Double? = nil, hue: Double? = nil) {
        self.effectKind = effectKind
        self.enabled = enabled
        self.opacity = opacity
        self.radius = radius
        self.amount = amount
        self.scale = scale
        self.speed = speed
        self.fade = fade
        self.smooth = smooth
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.hue = hue
    }
}

public enum TextSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case currentSlide
    case nextSlide
    case lastSlide
    case clock
    case timer
    case videoCountdown
    case slidePosition
    case currentServiceItem
    case nextServiceItem
    case stageMessage
    case currentGroup
    case currentPresentation
    case nextServiceTitle
}

public enum TimerTextFormat: String, Codable, Sendable, CaseIterable, Equatable {
    case digits
    case abbreviated
    case words
}

public struct TextLink: Codable, Sendable, Equatable {
    public var source: TextSourceKind
    public var timerId: String?
    public var clockFormat: String?
    public var usesWarningColor: Bool?
    public var maxLines: Int?
    public var includeSteps: Bool?
    public var includeBuilds: Bool?
    public var sourceObjectName: String?
    public var showsVideoName: Bool?
    public var videoLayer: String?
    public var timerFormat: TimerTextFormat?
    public var timerPattern: String?

    public init(source: TextSourceKind, timerId: String? = nil, clockFormat: String? = nil, usesWarningColor: Bool? = nil, maxLines: Int? = nil, includeSteps: Bool? = nil, includeBuilds: Bool? = nil, sourceObjectName: String? = nil, showsVideoName: Bool? = nil, videoLayer: String? = nil, timerFormat: TimerTextFormat? = nil, timerPattern: String? = nil) {
        self.source = source
        self.timerId = timerId
        self.clockFormat = clockFormat
        self.usesWarningColor = usesWarningColor
        self.maxLines = maxLines
        self.includeSteps = includeSteps
        self.includeBuilds = includeBuilds
        self.sourceObjectName = sourceObjectName
        self.showsVideoName = showsVideoName
        self.videoLayer = videoLayer
        self.timerFormat = timerFormat
        self.timerPattern = timerPattern
    }
}

public enum MultiViewSplitAxis: String, Codable, Sendable, CaseIterable, Equatable {
    case columns
    case rows
}

public enum MultiViewSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case empty
    case screen
    case liveInput
    case media
    case clock
    case timer
    case videoCountdown
    case text
}

public struct MultiViewNode: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var axis: MultiViewSplitAxis?
    public var children: [String]?
    public var fractions: [Double]?
    public var sourceKind: MultiViewSourceKind?
    public var screenSourceId: String?
    public var screenSourceName: String?
    public var liveInputId: String?
    public var mediaId: String?
    public var timerId: String?
    public var text: String?
    public var label: String?
    public var scaleMode: MediaScaleMode?
    public var matchSourceShape: Bool?

    public init(id: String, axis: MultiViewSplitAxis? = nil, children: [String]? = nil, fractions: [Double]? = nil, sourceKind: MultiViewSourceKind? = nil, screenSourceId: String? = nil, screenSourceName: String? = nil, liveInputId: String? = nil, mediaId: String? = nil, timerId: String? = nil, text: String? = nil, label: String? = nil, scaleMode: MediaScaleMode? = nil, matchSourceShape: Bool? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.fractions = fractions
        self.sourceKind = sourceKind
        self.screenSourceId = screenSourceId
        self.screenSourceName = screenSourceName
        self.liveInputId = liveInputId
        self.mediaId = mediaId
        self.timerId = timerId
        self.text = text
        self.label = label
        self.scaleMode = scaleMode
        self.matchSourceShape = matchSourceShape
    }
}

public struct MultiViewTree: Codable, Sendable, Equatable {
    public var rootId: String
    public var nodes: [MultiViewNode]

    public init(rootId: String, nodes: [MultiViewNode]) {
        self.rootId = rootId
        self.nodes = nodes
    }
}

public struct ConfidenceLayout: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var objects: [SlideObject]
    public var folder: String?
    public var folderId: String?
    public var canvasWidth: Int?
    public var canvasHeight: Int?
    public var animationOrder: [String]?
    public var buildOrder: [String]?
    public var multiView: MultiViewTree?

    public init(id: String, name: String, objects: [SlideObject], folder: String? = nil, folderId: String? = nil, canvasWidth: Int? = nil, canvasHeight: Int? = nil, animationOrder: [String]? = nil, buildOrder: [String]? = nil, multiView: MultiViewTree? = nil) {
        self.id = id
        self.name = name
        self.objects = objects
        self.folder = folder
        self.folderId = folderId
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.animationOrder = animationOrder
        self.buildOrder = buildOrder
        self.multiView = multiView
    }
}

public struct SignageChannel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var playlistId: String?

    public init(id: String, name: String, playlistId: String? = nil) {
        self.id = id
        self.name = name
        self.playlistId = playlistId
    }
}

public struct SignageBoard: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var signages: [SignageChannel]

    public init(id: String, signages: [SignageChannel]) {
        self.id = id
        self.signages = signages
    }
}

public struct NoteRun: Codable, Sendable, Equatable {
    public var text: String
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strike: Bool?
    public var code: Bool?
    public var highlight: String?
    public var color: String?
    public var size: String?
    public var href: String?
    public var slideGroup: String?
    public var slideType: String?
    public var slideId: String?
    public var commentId: String?

    public init(text: String, bold: Bool? = nil, italic: Bool? = nil, underline: Bool? = nil, strike: Bool? = nil, code: Bool? = nil, highlight: String? = nil, color: String? = nil, size: String? = nil, href: String? = nil, slideGroup: String? = nil, slideType: String? = nil, slideId: String? = nil, commentId: String? = nil) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.code = code
        self.highlight = highlight
        self.color = color
        self.size = size
        self.href = href
        self.slideGroup = slideGroup
        self.slideType = slideType
        self.slideId = slideId
        self.commentId = commentId
    }
}

public enum NoteBlockType: String, Codable, Sendable, CaseIterable, Equatable {
    case heading
    case paragraph
    case list
    case taskList
    case quote
    case code
    case rule
    case image
    case attachment
    case slideRef
    case unknown
}

public struct NoteListItem: Codable, Sendable, Equatable {
    public var runs: [NoteRun]
    public var checked: Bool?
    public var blocks: [NoteBlock]?

    public init(runs: [NoteRun], checked: Bool? = nil, blocks: [NoteBlock]? = nil) {
        self.runs = runs
        self.checked = checked
        self.blocks = blocks
    }
}

public struct NoteSlideRef: Codable, Sendable, Equatable {
    public var presentationId: String?
    public var slideId: String?
    public var slideIndex: Int?
    public var ppIntegrationHexId: String?
    public var ppPresentationUuid: String?
    public var ppPlaylistUuid: String?
    public var ppItemIndex: Int?
    public var ppSlideIndex: Int?
    public var presentationName: String?
    public var slideText: String?
    public var slideLabel: String?
    public var slideLabelColor: String?
    public var slideNotes: String?
    public var thumbnailUrl: String?
    public var showThumbnail: Bool?
    public var showText: Bool?
    public var showNotes: Bool?
    public var showLabels: Bool?
    public var showName: Bool?
    public var showNumber: Bool?
    public var width: Int?
    public var placedByHand: Bool?

    public init(presentationId: String? = nil, slideId: String? = nil, slideIndex: Int? = nil, ppIntegrationHexId: String? = nil, ppPresentationUuid: String? = nil, ppPlaylistUuid: String? = nil, ppItemIndex: Int? = nil, ppSlideIndex: Int? = nil, presentationName: String? = nil, slideText: String? = nil, slideLabel: String? = nil, slideLabelColor: String? = nil, slideNotes: String? = nil, thumbnailUrl: String? = nil, showThumbnail: Bool? = nil, showText: Bool? = nil, showNotes: Bool? = nil, showLabels: Bool? = nil, showName: Bool? = nil, showNumber: Bool? = nil, width: Int? = nil, placedByHand: Bool? = nil) {
        self.presentationId = presentationId
        self.slideId = slideId
        self.slideIndex = slideIndex
        self.ppIntegrationHexId = ppIntegrationHexId
        self.ppPresentationUuid = ppPresentationUuid
        self.ppPlaylistUuid = ppPlaylistUuid
        self.ppItemIndex = ppItemIndex
        self.ppSlideIndex = ppSlideIndex
        self.presentationName = presentationName
        self.slideText = slideText
        self.slideLabel = slideLabel
        self.slideLabelColor = slideLabelColor
        self.slideNotes = slideNotes
        self.thumbnailUrl = thumbnailUrl
        self.showThumbnail = showThumbnail
        self.showText = showText
        self.showNotes = showNotes
        self.showLabels = showLabels
        self.showName = showName
        self.showNumber = showNumber
        self.width = width
        self.placedByHand = placedByHand
    }
}

public struct NoteBlock: Codable, Sendable, Equatable {
    public var type: NoteBlockType
    public var level: Int?
    public var runs: [NoteRun]?
    public var ordered: Bool?
    public var items: [NoteListItem]?
    public var blocks: [NoteBlock]?
    public var language: String?
    public var text: String?
    public var url: String?
    public var width: Int?
    public var alt: String?
    public var attachmentKind: String?
    public var hexId: String?
    public var filename: String?
    public var slide: NoteSlideRef?

    public init(type: NoteBlockType, level: Int? = nil, runs: [NoteRun]? = nil, ordered: Bool? = nil, items: [NoteListItem]? = nil, blocks: [NoteBlock]? = nil, language: String? = nil, text: String? = nil, url: String? = nil, width: Int? = nil, alt: String? = nil, attachmentKind: String? = nil, hexId: String? = nil, filename: String? = nil, slide: NoteSlideRef? = nil) {
        self.type = type
        self.level = level
        self.runs = runs
        self.ordered = ordered
        self.items = items
        self.blocks = blocks
        self.language = language
        self.text = text
        self.url = url
        self.width = width
        self.alt = alt
        self.attachmentKind = attachmentKind
        self.hexId = hexId
        self.filename = filename
        self.slide = slide
    }
}

public struct NoteBody: Codable, Sendable, Equatable {
    public var blocks: [NoteBlock]
    public var plainText: String

    public init(blocks: [NoteBlock], plainText: String) {
        self.blocks = blocks
        self.plainText = plainText
    }
}

public struct OverrideDesign: Codable, Sendable, Equatable {
    public var themeId: String
    public var themeSlideName: String

    public init(themeId: String, themeSlideName: String) {
        self.themeId = themeId
        self.themeSlideName = themeSlideName
    }
}

public struct SlideAnchor: Codable, Sendable, Equatable {
    public var presentationId: String
    public var slideId: String
    public var slideIndex: Int
    public var blockIndex: Int
    public var offset: Int?

    public init(presentationId: String, slideId: String, slideIndex: Int, blockIndex: Int, offset: Int? = nil) {
        self.presentationId = presentationId
        self.slideId = slideId
        self.slideIndex = slideIndex
        self.blockIndex = blockIndex
        self.offset = offset
    }
}

public struct NoteMadeBox: Codable, Sendable, Equatable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct NoteMadeSlide: Codable, Sendable, Equatable {
    public var slideId: String
    public var boxes: [NoteMadeBox]

    public init(slideId: String, boxes: [NoteMadeBox]) {
        self.slideId = slideId
        self.boxes = boxes
    }
}

public struct NoteMadePassage: Codable, Sendable, Equatable {
    public var groupId: String
    public var text: String
    public var kind: String?
    public var themeSlideName: String?
    public var themeId: String?
    public var slides: [NoteMadeSlide]

    public init(groupId: String, text: String, kind: String? = nil, themeSlideName: String? = nil, themeId: String? = nil, slides: [NoteMadeSlide]) {
        self.groupId = groupId
        self.text = text
        self.kind = kind
        self.themeSlideName = themeSlideName
        self.themeId = themeId
        self.slides = slides
    }
}

public struct NotePendingUpdate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var groupId: String
    public var slideId: String?
    public var afterSlideId: String?
    public var before: [NoteMadeBox]?
    public var after: [NoteMadeBox]?
    public var proposed: Slide?

    public init(id: String, kind: String, groupId: String, slideId: String? = nil, afterSlideId: String? = nil, before: [NoteMadeBox]? = nil, after: [NoteMadeBox]? = nil, proposed: Slide? = nil) {
        self.id = id
        self.kind = kind
        self.groupId = groupId
        self.slideId = slideId
        self.afterSlideId = afterSlideId
        self.before = before
        self.after = after
        self.proposed = proposed
    }
}

public struct SlideVersion: Codable, Sendable, Equatable {
    public var at: String
    public var reason: String
    public var slide: Slide

    public init(at: String, reason: String, slide: Slide) {
        self.at = at
        self.reason = reason
        self.slide = slide
    }
}

public struct NoteDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var folder: String?
    public var origin: String
    public var mxuDocumentHexId: String?
    public var mxuVersion: String?
    public var mxuUpdatedAt: String?
    public var mxuIconEmoji: String?
    public var body: NoteBody?
    public var anchors: [SlideAnchor]?
    public var removedFromMxU: Bool?
    public var presentationId: String?
    public var slidesMadeFromSubmittedAt: String?
    public var madePassages: [NoteMadePassage]?
    public var markedByStructure: Bool?
    public var pendingUpdates: [NotePendingUpdate]?

    public init(id: String, name: String, folder: String? = nil, origin: String, mxuDocumentHexId: String? = nil, mxuVersion: String? = nil, mxuUpdatedAt: String? = nil, mxuIconEmoji: String? = nil, body: NoteBody? = nil, anchors: [SlideAnchor]? = nil, removedFromMxU: Bool? = nil, presentationId: String? = nil, slidesMadeFromSubmittedAt: String? = nil, madePassages: [NoteMadePassage]? = nil, markedByStructure: Bool? = nil, pendingUpdates: [NotePendingUpdate]? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.origin = origin
        self.mxuDocumentHexId = mxuDocumentHexId
        self.mxuVersion = mxuVersion
        self.mxuUpdatedAt = mxuUpdatedAt
        self.mxuIconEmoji = mxuIconEmoji
        self.body = body
        self.anchors = anchors
        self.removedFromMxU = removedFromMxU
        self.presentationId = presentationId
        self.slidesMadeFromSubmittedAt = slidesMadeFromSubmittedAt
        self.madePassages = madePassages
        self.markedByStructure = markedByStructure
        self.pendingUpdates = pendingUpdates
    }
}

public struct StationSettings: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var localOnlyThresholdBytes: Int?

    public init(id: String, localOnlyThresholdBytes: Int? = nil) {
        self.id = id
        self.localOnlyThresholdBytes = localOnlyThresholdBytes
    }
}

public struct SlideBuildingSettings: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var designMap: String?
    public var messageNotesThemeId: String?
    public var lyricsImportThemeId: String?
    public var lyricsImportDesign: String?

    public init(id: String, designMap: String? = nil, messageNotesThemeId: String? = nil, lyricsImportThemeId: String? = nil, lyricsImportDesign: String? = nil) {
        self.id = id
        self.designMap = designMap
        self.messageNotesThemeId = messageNotesThemeId
        self.lyricsImportThemeId = lyricsImportThemeId
        self.lyricsImportDesign = lyricsImportDesign
    }
}

public struct FontFile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var family: String
    public var faces: [String]
    public var ext: String
    public var byteSize: Int?

    public init(id: String, family: String, faces: [String], ext: String, byteSize: Int? = nil) {
        self.id = id
        self.family = family
        self.faces = faces
        self.ext = ext
        self.byteSize = byteSize
    }
}

public struct WorkspaceSettings: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var screens: String?
    public var timers: String?
    public var transitions: String?
    public var controlMappings: String?
    public var audio: String?
    public var confidence: String?
    public var signage: String?
    public var inputs: String?
    public var behavior: String?

    public init(id: String, screens: String? = nil, timers: String? = nil, transitions: String? = nil, controlMappings: String? = nil, audio: String? = nil, confidence: String? = nil, signage: String? = nil, inputs: String? = nil, behavior: String? = nil) {
        self.id = id
        self.screens = screens
        self.timers = timers
        self.transitions = transitions
        self.controlMappings = controlMappings
        self.audio = audio
        self.confidence = confidence
        self.signage = signage
        self.inputs = inputs
        self.behavior = behavior
    }
}
