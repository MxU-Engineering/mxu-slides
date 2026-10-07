import Foundation
import PresenterCore

struct PPTXDeck: Sendable, Equatable {
    var slideWidthEMU: Double
    var slideHeightEMU: Double
    var slides: [PPTXSlide] = []
    var sections: [PPTXSection] = []
    var warnings: [String] = []
}

struct PPTXSection: Sendable, Equatable {

    var id: String
    var name: String
    var slideIndexes: [Int] = []
}

struct PPTXSlide: Sendable, Equatable {
    var name: String?
    var shapes: [PPTXShape] = []
    var backgroundFill: PPTXFill?
    var transition: PPTXTransition?
    var notes: String?

    var animationSteps: [PPTXAnimation] = []
}

struct PPTXAnimation: Sendable, Equatable {
    var shapeID: Int

    var presetClass: String?
    var presetID: Int?
    var presetSubtype: Int?

    var nodeType: String?
    var delayMs: Double = 0

    var durationMs: Double?

    var paragraphStart: Int?
    var paragraphEnd: Int?
}

enum PPTXFill: Sendable, Equatable {

    case noFill

    case solid(colorHex: String)

    case blip(path: String)

    case blipTiled(path: String, alpha: Double, scaleX: Double, scaleY: Double, tiled: Bool)

    case pattern(preset: String, foregroundHex: String, backgroundHex: String)
    case gradient(PPTXGradient)
}

struct PPTXGradientStop: Sendable, Equatable {

    var position: Double

    var colorHex: String
}

struct PPTXGradient: Sendable, Equatable {

    var angle60k: Double?
    var stops: [PPTXGradientStop] = []
}

struct PPTXStroke: Sendable, Equatable {
    var colorHex: String
    var widthEMU: Double

    var dash: StrokeDashKind?
}

struct PPTXTransform: Sendable, Equatable {
    var offXEMU: Double
    var offYEMU: Double
    var extXEMU: Double
    var extYEMU: Double
    var rotation60k: Double = 0
    var flipH: Bool = false
    var flipV: Bool = false
}

struct PPTXSourceRect: Sendable, Equatable {
    var l: Double = 0
    var t: Double = 0
    var r: Double = 0
    var b: Double = 0

    var isFullFrame: Bool { l == 0 && t == 0 && r == 0 && b == 0 }
}

enum PPTXMediaKind: Sendable, Equatable {
    case image
    case video
    case audio
}

struct PPTXShape: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case shape
        case picture
    }

    var kind: Kind
    var name: String?

    var shapeID: Int?
    var transform: PPTXTransform
    var textBody: PPTXTextBody?
    var fill: PPTXFill?
    var stroke: PPTXStroke?
    var presetGeometry: String?

    var roundRectAdjustment: Double?

    var customPathData: String?
    var sourceRect: PPTXSourceRect?
    var mediaRelationshipID: String?

    var mediaPath: String?
    var mediaKind: PPTXMediaKind = .image

    var blipAlpha: Double?

    var usesBackgroundFill: Bool = false

    var usesGroupFill: Bool = false

    var isPlaceholder: Bool = false
    var placeholderType: String?
    var placeholderIndex: Int?
}

struct PPTXTextBody: Sendable, Equatable {
    var anchor: String?
    var wrap: String?
    var topInsetEMU: Double?
    var leftInsetEMU: Double?
    var bottomInsetEMU: Double?
    var rightInsetEMU: Double?

    var hasNormAutofit: Bool = false
    var autofitFontScale: Double?

    var hasSpAutofit: Bool = false
    var paragraphs: [PPTXParagraph] = []
}

struct PPTXParagraph: Sendable, Equatable {
    var alignment: String?
    var runs: [PPTXRun] = []
}

struct PPTXRun: Sendable, Equatable {
    var text: String = ""

    var isBreak: Bool = false
    var fontFamily: String?
    var sizeHundredthsPt: Double?
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strike: Bool = false

    var colorHex: String?
    var trackingHundredthsPt: Double?
}

struct PPTXTransition: Sendable, Equatable {

    var kind: String?
    var throughBlack: Bool = false
    var durationSeconds: Double?
    var advanceAfterMs: Double?
}

struct PPTXTextLine: Sendable, Equatable {
    var alignment: String?
    var runs: [PPTXRun] = []

    var text: String { runs.map(\.text).joined() }
}

extension PPTXTextBody {

    var lines: [PPTXTextLine] {
        var result: [PPTXTextLine] = []
        for paragraph in paragraphs {
            var current = PPTXTextLine(alignment: paragraph.alignment)
            for run in paragraph.runs {
                if run.isBreak {
                    result.append(current)
                    current = PPTXTextLine(alignment: paragraph.alignment)
                } else {
                    current.runs.append(run)
                }
            }
            result.append(current)
        }
        return result
    }

    var plainText: String { lines.map(\.text).joined(separator: "\n") }
}

struct PPTXEmbeddedFont: Sendable, Equatable {
    var typeface: String

    var variant: String
    var filePath: String
}

func appendUnique(_ message: String, _ warnings: inout [String]) {
    if !warnings.contains(message) { warnings.append(message) }
}
