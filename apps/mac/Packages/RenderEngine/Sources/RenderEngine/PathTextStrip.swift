import CoreGraphics
import CoreText
import Foundation
import Metal

enum PathTextStrip {

    static let maxStripWidth = 16384

    struct Key: Hashable {
        let text: StyledText

        let scaleMilli: Int
    }

    struct Strip {
        let texture: MTLTexture
        let run: PathTextLayout.Run
    }

    static func normalizedText(_ text: StyledText) -> StyledText {
        var flat = text
        flat.string = text.string
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        flat.alignment = .left
        flat.verticalAlignment = .middle
        flat.lineHeightMultiple = 1
        flat.autoShrink = false
        flat.minFontSize = StyledText.defaultMinFontSize
        flat.lineOverrides = []

        flat.styleRuns = []
        flat.underline = false
        flat.strikethrough = false

        flat.lineFill = nil

        flat.insetTop = 0
        flat.insetLeft = 0
        flat.insetBottom = 0
        flat.insetRight = 0
        flat.firstLineIndent = 0
        flat.leftIndent = 0
        flat.rightIndent = 0
        flat.paragraphSpacing = 0
        flat.pathData = nil
        flat.tickerSpeed = 0

        flat.pathReversed = false
        flat.pathOffset = 0
        flat.tickerRepeat = 0
        flat.tickerLeftToRight = false
        flat.tickerStream = false
        flat.tickerGap = 0
        flat.tickerSeparator = ""
        flat.tickerRamp = .none
        flat.scroll = nil

        if text.tickerStream, !text.tickerSeparator.isEmpty {
            flat.string += text.tickerSeparator
            flat.tickerSeparator = text.tickerSeparator
        }
        return flat
    }

    static func make(text: StyledText, scale: CGFloat, device: MTLDevice) -> Strip? {
        guard !text.string.isEmpty, text.fontSize > 0, scale > 0,
              let colorSpace = LinearRaster.colorSpace
        else { return nil }

        let attributed = TextRasterizer.attributedString(
            for: text, fontScale: 1, pixelScale: scale, colorSpace: colorSpace,
            includeOutline: text.fill == nil
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard advance > 0, ascent + descent > 0 else { return nil }

        let outlineWidth = text.outline?.width ?? 0
        let shadowSpread: Double = text.shadow.map { shadow in
            shadow.blurRadius + max(abs(shadow.offsetX), abs(shadow.offsetY))
        } ?? 0
        let pad = ceil((4 + outlineWidth + shadowSpread) * scale)

        let width = Int(ceil(advance) + 2 * pad)
        let height = Int(ceil(ascent + descent) + 2 * pad)
        guard width > 0, height > 0, width <= maxStripWidth else { return nil }

        guard let context = LinearRaster.makeContext(pixelWidth: width, pixelHeight: height) else {
            return nil
        }

        if let shadow = text.shadow {
            context.setShadow(

                offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
                blur: shadow.blurRadius * scale,
                color: LinearRaster.cgColor(shadow.color)
            )
        }

        let baselineFromBottom = pad + descent
        context.textPosition = CGPoint(x: pad, y: baselineFromBottom)

        if let fill = text.fill {
            let stripRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

            let shadowed = text.shadow != nil
            if shadowed { context.beginTransparencyLayer(auxiliaryInfo: nil) }

            context.saveGState()
            context.setTextDrawingMode(.clip)
            CTLineDraw(line, context)
            TextRasterizer.drawInkFill(fill, over: stripRect, context: context)
            context.restoreGState()

            if let outline = text.outline, outline.width > 0 {
                context.saveGState()
                context.setTextDrawingMode(.stroke)
                if let strokeColor = LinearRaster.cgColor(outline.color) {
                    context.setStrokeColor(strokeColor)
                }
                context.setLineWidth(outline.width * scale)
                context.textPosition = CGPoint(x: pad, y: baselineFromBottom)
                CTLineDraw(line, context)
                context.restoreGState()
            }

            if shadowed { context.endTransparencyLayer() }
        } else {
            CTLineDraw(line, context)
        }

        guard let texture = LinearRaster.makeTexture(from: context, device: device),
              var run = PathTextLayout.run(
                line: line,
                stripWidthPx: width,
                stripHeightPx: height,
                baselineFromBottomPx: baselineFromBottom,
                padXPx: pad
              )
        else { return nil }

        if !text.tickerSeparator.isEmpty, text.string.hasSuffix(text.tickerSeparator) {
            let phrase = String(text.string.dropLast(text.tickerSeparator.count))
            let displayPhrase = switch text.transform {
            case .none: phrase
            case .uppercase: phrase.uppercased()
            }
            run.separatorStartPx = CGFloat(
                CTLineGetOffsetForStringIndex(line, displayPhrase.utf16.count, nil)
            )
        }
        return Strip(texture: texture, run: run)
    }
}
