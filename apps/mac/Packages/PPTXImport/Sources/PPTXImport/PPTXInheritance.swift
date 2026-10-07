import Foundation

struct PPTXTextDefaults {
    var alignment: String?
    var sizeHundredthsPt: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var colorHex: String?
    var fontFamily: String?
    var trackingHundredthsPt: Double?

    func merging(_ inner: PPTXTextDefaults) -> PPTXTextDefaults {
        var result = self
        if let value = inner.alignment { result.alignment = value }
        if let value = inner.sizeHundredthsPt { result.sizeHundredthsPt = value }
        if let value = inner.bold { result.bold = value }
        if let value = inner.italic { result.italic = value }
        if let value = inner.underline { result.underline = value }
        if let value = inner.strike { result.strike = value }
        if let value = inner.colorHex { result.colorHex = value }
        if let value = inner.fontFamily { result.fontFamily = value }
        if let value = inner.trackingHundredthsPt { result.trackingHundredthsPt = value }
        return result
    }
}

final class PPTXInheritance {

    let colors: PPTXColorResolver
    let layoutPart: String?
    let masterPart: String?

    let layoutShowsMasterShapes: Bool

    private let package: PPTXPackage
    private let layoutRoot: XMLElement?
    private let masterRoot: XMLElement?
    private let themeElements: XMLElement?
    private let defaultTextStyle: XMLElement?
    private let majorLatinFamily: String?
    private let minorLatinFamily: String?

    init(slidePart: String, presentationPart: String?, package: PPTXPackage) {
        self.package = package

        func related(_ part: String?, suffix: String) -> String? {
            guard let part else { return nil }
            guard let rel = package.relationships(of: part).values
                .first(where: { $0.type.hasSuffix(suffix) && !$0.external })
            else { return nil }
            return package.resolveTarget(rel.target, relativeTo: part)
        }
        layoutPart = related(slidePart, suffix: "/slideLayout")
        masterPart = related(layoutPart, suffix: "/slideMaster")
        let themePart = related(masterPart, suffix: "/theme")
        layoutRoot = layoutPart.flatMap { try? package.document(at: $0).rootElement() }
        masterRoot = masterPart.flatMap { try? package.document(at: $0).rootElement() }
        themeElements = themePart
            .flatMap { try? package.document(at: $0).rootElement() }?
            .first(local: "themeElements")
        defaultTextStyle = presentationPart
            .flatMap { try? package.document(at: $0).rootElement() }?
            .first(local: "defaultTextStyle")
        layoutShowsMasterShapes = layoutRoot?.boolAttr("showMasterSp") ?? true

        var scheme: [String: String] = [:]
        if let clrScheme = themeElements?.first(local: "clrScheme") {
            for slot in (clrScheme.children ?? []).compactMap({ $0 as? XMLElement }) {
                guard let name = slot.localName else { continue }
                if let srgb = slot.first(local: "srgbClr")?.attr("val") {
                    scheme[name] = srgb.uppercased()
                } else if let sys = slot.first(local: "sysClr")?.attr("lastClr") {
                    scheme[name] = sys.uppercased()
                }
            }
        }
        let fontScheme = themeElements?.first(local: "fontScheme")
        majorLatinFamily = fontScheme?.descendant(["majorFont", "latin"])?.attr("typeface")
        minorLatinFamily = fontScheme?.descendant(["minorFont", "latin"])?.attr("typeface")

        func mapping(from element: XMLElement?) -> [String: String]? {
            guard let element else { return nil }
            var result: [String: String] = [:]
            for attribute in element.attributes ?? [] {
                if let name = attribute.localName, let value = attribute.stringValue {
                    result[name] = value
                }
            }
            return result.isEmpty ? nil : result
        }
        var slotMap = mapping(from: masterRoot?.first(local: "clrMap")) ?? [:]
        let slideRoot = (try? package.document(at: slidePart))?.rootElement()
        for source in [layoutRoot, slideRoot] {
            if let override = mapping(from: source?.first(local: "clrMapOvr")?.first(local: "overrideClrMapping")) {
                slotMap = override
            }
        }
        colors = PPTXColorResolver(scheme: scheme, slotMap: slotMap)
    }

    func resolveFontFamily(_ typeface: String?) -> String? {
        guard let typeface else { return nil }
        guard typeface.hasPrefix("+") else { return typeface }
        return typeface.hasPrefix("+mj") ? majorLatinFamily : minorLatinFamily
    }

    func inheritedTransform(placeholderType: String?, placeholderIndex: Int?) -> PPTXTransform? {
        if let element = matchingPlaceholder(in: layoutRoot, type: placeholderType, idx: placeholderIndex, useIdx: true),
           let transform = PPTXSlideParser.parseTransform(element.first(local: "spPr")?.first(local: "xfrm")) {
            return transform
        }
        if let element = matchingPlaceholder(in: masterRoot, type: placeholderType, idx: nil, useIdx: false),
           let transform = PPTXSlideParser.parseTransform(element.first(local: "spPr")?.first(local: "xfrm")) {
            return transform
        }
        return nil
    }

    private func matchingPlaceholder(in root: XMLElement?, type: String?, idx: Int?, useIdx: Bool) -> XMLElement? {
        guard let spTree = root?.descendant(["cSld", "spTree"]) else { return nil }
        var candidates: [(sp: XMLElement, type: String, idx: Int?)] = []
        for sp in spTree.children(local: "sp") {
            guard let ph = sp.descendant(["nvSpPr", "nvPr", "ph"]) else { continue }
            candidates.append((sp, Self.normalizedType(ph.attr("type")), ph.intAttr("idx")))
        }
        if useIdx, let idx, let match = candidates.first(where: { $0.idx == idx }) { return match.sp }
        let wanted = Self.normalizedType(type)
        if let match = candidates.first(where: { $0.type == wanted }) { return match.sp }
        if !useIdx, ["body", "subTitle"].contains(wanted),
           let match = candidates.first(where: { $0.type == "body" }) {
            return match.sp
        }
        return nil
    }

    private static func normalizedType(_ type: String?) -> String {
        switch type {
        case "ctrTitle": return "title"
        case nil: return "body"
        case .some(let value): return value
        }
    }

    func textDefaults(
        placeholder: (type: String?, idx: Int?)?, level: Int, warnings: inout [String]
    ) -> PPTXTextDefaults {
        let clamped = min(max(level, 0), 4)
        var defaults = PPTXTextDefaults()
        guard let placeholder else {
            defaults.fontFamily = minorLatinFamily
            if let defaultTextStyle {
                defaults = defaults.merging(levelDefaults(from: defaultTextStyle, level: clamped, warnings: &warnings))
            }
            return defaults
        }

        let family = Self.normalizedType(placeholder.type)
        defaults.fontFamily = family == "title" ? (majorLatinFamily ?? minorLatinFamily) : minorLatinFamily
        let styleName: String
        switch family {
        case "title": styleName = "titleStyle"
        case "body", "subTitle": styleName = "bodyStyle"
        default: styleName = "otherStyle"
        }
        if let style = masterRoot?.first(local: "txStyles")?.first(local: styleName) {
            defaults = defaults.merging(levelDefaults(from: style, level: clamped, warnings: &warnings))
        }
        if let layoutPh = matchingPlaceholder(in: layoutRoot, type: placeholder.type, idx: placeholder.idx, useIdx: true),
           let lstStyle = layoutPh.first(local: "txBody")?.first(local: "lstStyle") {
            defaults = defaults.merging(levelDefaults(from: lstStyle, level: clamped, warnings: &warnings))
        }
        return defaults
    }

    private func levelDefaults(from container: XMLElement, level: Int, warnings: inout [String]) -> PPTXTextDefaults {
        defaults(fromParagraphProperties: container.first(local: "lvl\(level + 1)pPr"), warnings: &warnings)
    }

    func defaults(fromParagraphProperties element: XMLElement?, warnings: inout [String]) -> PPTXTextDefaults {
        guard let element else { return PPTXTextDefaults() }
        var defaults = PPTXTextDefaults()
        defaults.alignment = element.attr("algn")
        if let defRPr = element.first(local: "defRPr") {
            defaults = defaults.merging(runProperties(defRPr, warnings: &warnings))
        }
        return defaults
    }

    func runProperties(_ element: XMLElement, warnings: inout [String]) -> PPTXTextDefaults {
        var defaults = PPTXTextDefaults()
        defaults.sizeHundredthsPt = element.doubleAttr("sz")
        defaults.bold = element.boolAttr("b")
        defaults.italic = element.boolAttr("i")
        if let underline = element.attr("u") { defaults.underline = underline != "none" }
        if let strike = element.attr("strike") { defaults.strike = strike != "noStrike" }
        defaults.trackingHundredthsPt = element.doubleAttr("spc")
        if let solidFill = element.first(local: "solidFill") {
            defaults.colorHex = colors.color(in: solidFill, warnings: &warnings)
        }
        defaults.fontFamily = resolveFontFamily(element.first(local: "latin")?.attr("typeface"))
        return defaults
    }

    func inheritedBackgroundElement() -> (element: XMLElement, part: String)? {
        if let layoutRoot, let layoutPart, let bg = layoutRoot.descendant(["cSld", "bg"]) {
            return (bg, layoutPart)
        }
        if let masterRoot, let masterPart, let bg = masterRoot.descendant(["cSld", "bg"]) {
            return (bg, masterPart)
        }
        return nil
    }

    func themeFillStyle(index: Int) -> XMLElement? {
        let fmtScheme = themeElements?.first(local: "fmtScheme")
        let list = index >= 1001
            ? fmtScheme?.first(local: "bgFillStyleLst")
            : fmtScheme?.first(local: "fillStyleLst")
        let fills = (list?.children ?? []).compactMap { $0 as? XMLElement }
        let position = index >= 1001 ? index - 1001 : index - 1
        guard position >= 0, position < fills.count else { return nil }
        return fills[position]
    }

    func decorationSpTree(ofPart part: String?) -> XMLElement? {
        guard let part else { return nil }
        return (try? package.document(at: part).rootElement())?.descendant(["cSld", "spTree"])
    }
}
