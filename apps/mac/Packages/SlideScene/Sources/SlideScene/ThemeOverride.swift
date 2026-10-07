import CoreText
import Foundation
import PresenterCore

public enum ThemeOverride {

    static let defaultFontName = "HelveticaNeue-Bold"
    static let defaultFontSize = 96.0

    struct Keep {
        var bold: Bool
        var italic: Bool
        var underline: Bool
        var strikethrough: Bool
        var sizeEmphasis: Bool
        var wordLetterSpacing: Bool
        var highlight: Bool
        var textColor: Bool

        init(_ options: KeepFromSlideOptions?) {
            bold = options?.bold ?? true
            italic = options?.italic ?? true
            underline = options?.underline ?? true
            strikethrough = options?.strikethrough ?? true
            sizeEmphasis = options?.sizeEmphasis ?? true
            wordLetterSpacing = options?.wordLetterSpacing ?? true
            highlight = options?.highlight ?? false
            textColor = options?.textColor ?? false
        }
    }

    struct BaseStyle {
        var fontName: String
        var fontSize: Double
        var tracking: Double

        init(object: SlideObject, placeholder: SlideObject?, theme: Theme?) {
            let own = object.textStyle

            let base = (placeholder?.id == object.id) ? nil : placeholder?.textStyle
            fontName = own?.fontName ?? base?.fontName
                ?? theme?.fontFamily ?? ThemeOverride.defaultFontName
            fontSize = own?.fontSize ?? base?.fontSize
                ?? theme?.fontSize ?? ThemeOverride.defaultFontSize
            tracking = own?.tracking ?? base?.tracking ?? 0
        }
    }

    public static func overrideObjects(
        for slide: Slide,
        objects: [SlideObject],
        originalTheme: Theme?,
        overrideTheme: Theme
    ) -> [SlideObject] {
        let originalTemplate = SlideSceneBuilder.themeSlide(for: slide, theme: originalTheme)
        let overrideTemplate = SlideSceneBuilder.themeSlide(for: slide, theme: overrideTheme)
        let originalAssignments = SlideSceneBuilder.placeholderAssignments(
            for: objects, in: originalTemplate
        )
        let overrideAssignments = SlideSceneBuilder.placeholderAssignments(
            for: objects, in: overrideTemplate
        )
        return objects.map { object in
            guard object.objectKind == .text else { return object }
            let overridePlaceholder = overrideAssignments[object.id]
            let from = BaseStyle(
                object: object,
                placeholder: originalAssignments[object.id],
                theme: originalTheme
            )

            var stripped = object
            stripped.textStyle = nil
            let to = BaseStyle(
                object: stripped,
                placeholder: overridePlaceholder,
                theme: overrideTheme
            )
            let keep = Keep(overridePlaceholder?.keepFromSlide)

            var result = stripped
            result.x = nil
            result.y = nil
            result.width = nil
            result.height = nil
            let lineStyles = (object.textStyle?.lineStyles ?? [])
                .compactMap { carriedLineStyle($0, from: from, to: to, keep: keep) }
            if !lineStyles.isEmpty {

                var style = TextStyle()
                style.lineStyles = lineStyles
                result.textStyle = style
            }
            result.styleRuns = (object.styleRuns ?? [])
                .compactMap { carriedRun($0, from: from, to: to, keep: keep) }
                .nonEmpty
            return result
        }
    }

    static func carriedRun(
        _ run: TextStyleRun, from: BaseStyle, to: BaseStyle, keep: Keep
    ) -> TextStyleRun? {
        var carried = TextStyleRun(line: run.line, column: run.column, length: run.length)

        if keep.underline, run.underline == true { carried.underline = true }
        if keep.strikethrough, run.strikethrough == true { carried.strikethrough = true }
        if keep.highlight { carried.highlightColorHex = run.highlightColorHex }
        if keep.textColor { carried.colorHex = run.colorHex }
        carried.fontName = carriedFontName(run.fontName, from: from, to: to, keep: keep)
        if keep.sizeEmphasis, let size = run.fontSize, from.fontSize > 0 {
            let ratio = size / from.fontSize
            if abs(ratio - 1) > 0.001 {
                carried.fontSize = ratio * to.fontSize
            }
        }
        if keep.wordLetterSpacing, let tracking = run.tracking {

            let delta = tracking - from.tracking
            if abs(delta) > 0.001, from.fontSize > 0 {
                carried.tracking = to.tracking + delta * (to.fontSize / from.fontSize)
            }
        }
        return carried.stylesAnything ? carried : nil
    }

    static func carriedLineStyle(
        _ line: LineStyleOverride, from: BaseStyle, to: BaseStyle, keep: Keep
    ) -> LineStyleOverride? {
        var carried = LineStyleOverride(lineIndex: line.lineIndex)
        carried.fontName = carriedFontName(line.fontName, from: from, to: to, keep: keep)
        if keep.sizeEmphasis, let size = line.fontSize, from.fontSize > 0 {
            let ratio = size / from.fontSize
            if abs(ratio - 1) > 0.001 {
                carried.fontSize = ratio * to.fontSize
            }
        }
        if keep.textColor { carried.colorHex = line.colorHex }
        guard carried.fontName != nil || carried.fontSize != nil || carried.colorHex != nil
        else { return nil }
        return carried
    }

    static func carriedFontName(
        _ runFontName: String?, from: BaseStyle, to: BaseStyle, keep: Keep
    ) -> String? {
        guard keep.bold || keep.italic, let runFontName, !runFontName.isEmpty
        else { return nil }
        let base = traits(ofFontNamed: from.fontName)
        let run = traits(ofFontNamed: runFontName)
        let addBold = keep.bold && run.bold && !base.bold
        let addItalic = keep.italic && run.italic && !base.italic
        guard addBold || addItalic else { return nil }
        let target = traits(ofFontNamed: to.fontName)
        return fontName(
            basedOn: to.fontName,
            bold: target.bold || addBold,
            italic: target.italic || addItalic
        )
    }

    static func traits(ofFontNamed name: String) -> (bold: Bool, italic: Bool) {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let traits = CTFontGetSymbolicTraits(font)
        return (traits.contains(.traitBold), traits.contains(.traitItalic))
    }

    static func fontName(basedOn name: String, bold: Bool, italic: Bool) -> String? {
        let base = CTFontCreateWithName(name as CFString, 12, nil)
        var wanted: CTFontSymbolicTraits = []
        if bold { wanted.insert(.traitBold) }
        if italic { wanted.insert(.traitItalic) }
        guard let derived = CTFontCreateCopyWithSymbolicTraits(
            base, 0, nil, wanted, [.traitBold, .traitItalic]
        ) else { return nil }
        return CTFontCopyPostScriptName(derived) as String
    }
}

extension [TextStyleRun] {
    fileprivate var nonEmpty: [TextStyleRun]? { isEmpty ? nil : self }
}

extension TextStyleRun {
    fileprivate var stylesAnything: Bool {
        underline != nil || strikethrough != nil || fontName != nil
            || fontSize != nil || colorHex != nil || highlightColorHex != nil
            || tracking != nil
    }
}
