import Foundation
import PresenterCore

enum PPTXSlideParser {

    static func parse(
        partPath: String, presentationPart: String? = nil,
        in package: PPTXPackage, warnings: inout [String]
    ) throws -> PPTXSlide {
        guard let root = try package.document(at: partPath).rootElement() else {
            throw PPTXImportError.invalidPackage("\(partPath) has no root element")
        }
        let inheritance = PPTXInheritance(slidePart: partPath, presentationPart: presentationPart, package: package)
        let rels = package.relationships(of: partPath)
        var slide = PPTXSlide()
        let cSld = root.first(local: "cSld")
        slide.name = cSld?.attr("name")

        if let bg = cSld?.first(local: "bg") {
            slide.backgroundFill = parseBackground(bg, owningPart: partPath, package: package, inheritance: inheritance, warnings: &warnings)
        } else if let (bg, owningPart) = inheritance.inheritedBackgroundElement() {
            slide.backgroundFill = parseBackground(bg, owningPart: owningPart, package: package, inheritance: inheritance, warnings: &warnings)
        }

        if root.boolAttr("showMasterSp") ?? true {
            if inheritance.layoutShowsMasterShapes, let masterPart = inheritance.masterPart {
                slide.shapes += parseDecorations(inPart: masterPart, package: package, inheritance: inheritance, warnings: &warnings)
            }
            if let layoutPart = inheritance.layoutPart {
                slide.shapes += parseDecorations(inPart: layoutPart, package: package, inheritance: inheritance, warnings: &warnings)
            }
        }

        if let spTree = cSld?.first(local: "spTree") {
            slide.shapes += parseShapeTreeChildren(
                of: spTree, package: package, partPath: partPath, rels: rels,
                inheritance: inheritance, includePlaceholders: true, warnings: &warnings)
        }

        slide.transition = parseTransition(in: root)
        slide.animationSteps = parseTiming(in: root)
        slide.notes = parseNotes(slidePart: partPath, package: package, rels: rels, inheritance: inheritance, warnings: &warnings)

        for index in slide.shapes.indices
        where slide.shapes[index].usesBackgroundFill && slide.shapes[index].fill == nil {
            slide.shapes[index].fill = slide.backgroundFill
        }
        return slide
    }

    private static func parseDecorations(
        inPart part: String, package: PPTXPackage,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> [PPTXShape] {
        guard let spTree = inheritance.decorationSpTree(ofPart: part) else { return [] }
        return parseShapeTreeChildren(
            of: spTree, package: package, partPath: part,
            rels: package.relationships(of: part),
            inheritance: inheritance, includePlaceholders: false, warnings: &warnings)
    }

    private static func parseShapeTreeChildren(
        of spTree: XMLElement, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, includePlaceholders: Bool, warnings: inout [String]
    ) -> [PPTXShape] {
        var shapes: [PPTXShape] = []
        for child in (spTree.children ?? []).compactMap({ $0 as? XMLElement }) {
            switch child.localName {
            case "sp", "cxnSp":
                if !includePlaceholders, child.descendant(["nvSpPr", "nvPr", "ph"]) != nil { continue }
                if let shape = parseSp(child, package: package, partPath: partPath, rels: rels, inheritance: inheritance, warnings: &warnings) {
                    shapes.append(shape)
                }
            case "pic":
                if !includePlaceholders, child.descendant(["nvPicPr", "nvPr", "ph"]) != nil { continue }
                if let shape = parsePic(child, package: package, partPath: partPath, rels: rels, inheritance: inheritance, warnings: &warnings) {
                    shapes.append(shape)
                }
            case "grpSp":
                shapes += parseGroup(
                    child, package: package, partPath: partPath, rels: rels,
                    inheritance: inheritance, includePlaceholders: includePlaceholders, warnings: &warnings)
            case "graphicFrame":
                shapes += parseGraphicFrame(
                    child, package: package, partPath: partPath, rels: rels,
                    inheritance: inheritance, warnings: &warnings)
            default:
                break
            }
        }
        return shapes
    }

    private static func parseGroup(
        _ grpSp: XMLElement, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, includePlaceholders: Bool, warnings: inout [String]
    ) -> [PPTXShape] {
        let xfrm = grpSp.first(local: "grpSpPr")?.first(local: "xfrm")
        guard let group = parseTransform(xfrm) else {
            appendUnique("a shape group has no position — its shapes were dropped", &warnings)
            return []
        }
        let chOff = xfrm?.first(local: "chOff")
        let chExt = xfrm?.first(local: "chExt")
        let childSpace = (
            x: chOff?.emuAttr("x") ?? 0, y: chOff?.emuAttr("y") ?? 0,
            width: chExt?.emuAttr("cx") ?? group.extXEMU, height: chExt?.emuAttr("cy") ?? group.extYEMU
        )
        let children = parseShapeTreeChildren(
            of: grpSp, package: package, partPath: partPath, rels: rels,
            inheritance: inheritance, includePlaceholders: includePlaceholders, warnings: &warnings)

        let groupFill = grpSp.first(local: "grpSpPr").flatMap { grpSpPr in
            parseFill(
                in: grpSpPr, context: "a shape group",
                package: package, partPath: partPath, rels: rels,
                inheritance: inheritance, warnings: &warnings)
        }
        return children.map { shape in
            var shape = shape
            shape.transform = composed(shape.transform, group: group, childSpace: childSpace, warnings: &warnings)
            if shape.usesGroupFill, shape.fill == nil, let groupFill {
                shape.fill = groupFill
                shape.usesGroupFill = false
            }
            return shape
        }
    }

    private static func composed(
        _ child: PPTXTransform, group: PPTXTransform,
        childSpace: (x: Double, y: Double, width: Double, height: Double),
        warnings: inout [String]
    ) -> PPTXTransform {
        let scaleX = childSpace.width > 0 ? group.extXEMU / childSpace.width : 1
        let scaleY = childSpace.height > 0 ? group.extYEMU / childSpace.height : 1
        if abs(scaleX - scaleY) > 0.0001, child.rotation60k != 0 {

            appendUnique("a rotated shape inside a stretched group may sit slightly off", &warnings)
        }
        var result = child
        result.offXEMU = group.offXEMU + (child.offXEMU - childSpace.x) * scaleX
        result.offYEMU = group.offYEMU + (child.offYEMU - childSpace.y) * scaleY
        result.extXEMU = child.extXEMU * scaleX
        result.extYEMU = child.extYEMU * scaleY

        let groupCenter = (x: group.offXEMU + group.extXEMU / 2, y: group.offYEMU + group.extYEMU / 2)
        var center = (x: result.offXEMU + result.extXEMU / 2, y: result.offYEMU + result.extYEMU / 2)
        if group.flipH {
            center.x = 2 * groupCenter.x - center.x
            result.flipH.toggle()
            result.rotation60k = -result.rotation60k
        }
        if group.flipV {
            center.y = 2 * groupCenter.y - center.y
            result.flipV.toggle()
            result.rotation60k = -result.rotation60k
        }
        if group.rotation60k != 0 {
            let angle = group.rotation60k / 60000 * .pi / 180
            let dx = center.x - groupCenter.x
            let dy = center.y - groupCenter.y
            center.x = groupCenter.x + dx * cos(angle) - dy * sin(angle)
            center.y = groupCenter.y + dx * sin(angle) + dy * cos(angle)
            result.rotation60k += group.rotation60k
        }
        result.offXEMU = center.x - result.extXEMU / 2
        result.offYEMU = center.y - result.extYEMU / 2
        return result
    }

    private static func parseGraphicFrame(
        _ frame: XMLElement, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> [PPTXShape] {
        let name = frame.descendant(["nvGraphicFramePr", "cNvPr"])?.attr("name") ?? "content"
        let transform = parseTransform(frame.first(local: "xfrm"))
        guard let data = frame.descendant(["graphic", "graphicData"]) else { return [] }
        if let table = data.first(local: "tbl") {
            guard let transform else {
                appendUnique("table \"\(name)\" has no position and was skipped", &warnings)
                return []
            }
            return [tableShape(table, name: name, transform: transform, inheritance: inheritance, warnings: &warnings)]
        }
        if data.first(local: "chart") != nil {
            appendUnique("chart \"\(name)\" was skipped — charts are not imported yet", &warnings)
            return []
        }
        if data.first(local: "relIds") != nil {
            return smartArtShapes(
                data, frameName: name, transform: transform,
                package: package, partPath: partPath, rels: rels,
                inheritance: inheritance, warnings: &warnings)
        }
        appendUnique("\"\(name)\" embeds an unsupported content type and was skipped", &warnings)
        return []
    }

    private static func tableShape(
        _ table: XMLElement, name: String?, transform: PPTXTransform,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXShape {
        appendUnique("tables are imported as plain text — cells joined by tabs", &warnings)
        var style: PPTXRun?
        var rows: [String] = []
        for row in table.children(local: "tr") {
            var cells: [String] = []
            for cell in row.children(local: "tc") {
                guard let txBody = cell.first(local: "txBody") else {
                    cells.append("")
                    continue
                }
                let body = parseTextBody(txBody, placeholder: nil, inheritance: inheritance, warnings: &warnings)
                if style == nil {
                    style = body.lines.flatMap(\.runs).first { !$0.text.isEmpty }
                }
                cells.append(body.plainText.replacingOccurrences(of: "\n", with: " "))
            }
            rows.append(cells.joined(separator: "\t"))
        }
        var body = PPTXTextBody()
        body.paragraphs = rows.map { row in
            var run = style ?? PPTXRun()
            run.text = row
            return PPTXParagraph(runs: [run])
        }
        return PPTXShape(kind: .shape, name: name, transform: transform, textBody: body)
    }

    private static func smartArtShapes(
        _ data: XMLElement, frameName: String, transform: PPTXTransform?,
        package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> [PPTXShape] {
        guard let transform else {
            appendUnique("SmartArt \"\(frameName)\" has no position and was skipped", &warnings)
            return []
        }
        var drawingPart: String?

        if let dmRel = data.first(local: "relIds").flatMap({ $0.relationshipAttr("dm") }),
           let rel = rels[dmRel], !rel.external {
            let dataPart = package.resolveTarget(rel.target, relativeTo: partPath)
            if let dataRoot = try? package.document(at: dataPart).rootElement(),
               let ext = firstDescendant(of: dataRoot, local: "dataModelExt"),
               let relID = ext.attr("relId"),
               let drawingRel = package.relationships(of: dataPart)[relID], !drawingRel.external {
                drawingPart = package.resolveTarget(drawingRel.target, relativeTo: dataPart)
            }
        }

        if drawingPart == nil,
           let rel = rels.values.first(where: { $0.type.contains("diagramDrawing") && !$0.external }) {
            drawingPart = package.resolveTarget(rel.target, relativeTo: partPath)
        }
        guard let drawingPart,
              let spTree = (try? package.document(at: drawingPart).rootElement())?.first(local: "spTree")
        else {
            appendUnique("SmartArt \"\(frameName)\" carries no pre-laid-out drawing and was skipped", &warnings)
            return []
        }
        let drawingRels = package.relationships(of: drawingPart)
        var shapes: [PPTXShape] = []
        for sp in spTree.children(local: "sp") {
            guard let shape = parseSp(sp, package: package, partPath: drawingPart, rels: drawingRels, inheritance: inheritance, warnings: &warnings) else { continue }
            var moved = shape
            moved.transform.offXEMU += transform.offXEMU
            moved.transform.offYEMU += transform.offYEMU
            shapes.append(moved)
        }
        return shapes
    }

    private static func firstDescendant(of element: XMLElement, local name: String) -> XMLElement? {
        for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
            if child.localName == name { return child }
            if let found = firstDescendant(of: child, local: name) { return found }
        }
        return nil
    }

    private static func parseSp(
        _ sp: XMLElement, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXShape? {
        let name = sp.descendant(["nvSpPr", "cNvPr"])?.attr("name")
            ?? sp.descendant(["nvCxnSpPr", "cNvPr"])?.attr("name")
        let spPr = sp.first(local: "spPr")
        let phElement = sp.descendant(["nvSpPr", "nvPr", "ph"])
        let placeholder: (type: String?, idx: Int?)? = phElement.map { ($0.attr("type"), $0.intAttr("idx")) }

        var transform = parseTransform(spPr?.first(local: "xfrm"))
        if transform == nil, let placeholder {
            transform = inheritance.inheritedTransform(placeholderType: placeholder.type, placeholderIndex: placeholder.idx)
        }
        guard let transform else {
            appendUnique("\"\(name ?? "a shape")\" has no position on the slide or its layout — dropped", &warnings)
            return nil
        }
        var shape = PPTXShape(kind: .shape, name: name, transform: transform)
        shape.shapeID = (sp.descendant(["nvSpPr", "cNvPr"]) ?? sp.descendant(["nvCxnSpPr", "cNvPr"]))?.intAttr("id")
        shape.isPlaceholder = placeholder != nil
        shape.placeholderType = placeholder?.type
        shape.placeholderIndex = placeholder?.idx
        shape.usesBackgroundFill = sp.boolAttr("useBgFill") ?? false

        parseGeometry(into: &shape, spPr: spPr, transform: transform, warnings: &warnings)
        if let spPr {
            shape.fill = parseFill(
                in: spPr, context: "\"\(name ?? "a shape")\"",
                package: package, partPath: partPath, rels: rels,
                inheritance: inheritance, warnings: &warnings)
            shape.stroke = parseLine(spPr.first(local: "ln"), inheritance: inheritance, warnings: &warnings)

            if spPr.first(local: "grpFill") != nil { shape.usesGroupFill = true }
        }

        if shape.fill == nil, !shape.usesGroupFill, !shape.usesBackgroundFill,
           let styleElement = sp.first(local: "style"),
           let fillRef = styleElement.first(local: "fillRef"),
           let index = fillRef.intAttr("idx"), index > 0 {
            let phClr = inheritance.colors.color(in: fillRef, warnings: &warnings)
                .map { String($0.prefix(6)) }
            if let themeStyle = inheritance.themeFillStyle(index: index) {
                shape.fill = fill(
                    fromElement: themeStyle, context: "\"\(name ?? "a shape")\"",
                    phClr: phClr, mediaContext: nil,
                    inheritance: inheritance, warnings: &warnings)
            }
        }
        if let txBody = sp.first(local: "txBody") {
            shape.textBody = parseTextBody(txBody, placeholder: placeholder, inheritance: inheritance, warnings: &warnings)
        }
        return shape
    }

    private static func parsePic(
        _ pic: XMLElement, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXShape? {
        let name = pic.descendant(["nvPicPr", "cNvPr"])?.attr("name")
        let spPr = pic.first(local: "spPr")
        guard let transform = parseTransform(spPr?.first(local: "xfrm")) else {
            appendUnique("\"\(name ?? "a picture")\" has no position on the slide or its layout — dropped", &warnings)
            return nil
        }
        var shape = PPTXShape(kind: .picture, name: name, transform: transform)
        shape.shapeID = pic.descendant(["nvPicPr", "cNvPr"])?.intAttr("id")

        parseGeometry(into: &shape, spPr: spPr, transform: transform, warnings: &warnings)
        if let spPr {
            shape.stroke = parseLine(spPr.first(local: "ln"), inheritance: inheritance, warnings: &warnings)
        }

        let nvPr = pic.descendant(["nvPicPr", "nvPr"])
        if let video = nvPr?.first(local: "videoFile") {
            shape.mediaKind = .video
            shape.mediaRelationshipID = video.relationshipAttr("link") ?? video.attr("link")
        } else if let audio = nvPr?.first(local: "audioFile") {
            shape.mediaKind = .audio
            shape.mediaRelationshipID = audio.relationshipAttr("link") ?? audio.attr("link")
        }
        if let blipFill = pic.first(local: "blipFill") {
            let blip = blipFill.first(local: "blip")
            if shape.mediaKind == .image {
                shape.mediaRelationshipID = blip.flatMap { $0.relationshipAttr("embed") ?? $0.attr("embed") }
            }

            if let amount = blip?.first(local: "alphaModFix")?.doubleAttr("amt"), amount < 100_000 {
                shape.blipAlpha = amount / 100_000
            }
            if let rect = blipFill.first(local: "srcRect") {
                let sourceRect = PPTXSourceRect(
                    l: rect.doubleAttr("l") ?? 0, t: rect.doubleAttr("t") ?? 0,
                    r: rect.doubleAttr("r") ?? 0, b: rect.doubleAttr("b") ?? 0)
                if !sourceRect.isFullFrame { shape.sourceRect = sourceRect }
            }
        }
        shape.mediaPath = mediaPath(
            relationshipID: shape.mediaRelationshipID, context: "\"\(name ?? "a picture")\"",
            package: package, partPath: partPath, rels: rels,

            externalAsPath: shape.mediaKind != .image,
            warnings: &warnings)
        return shape
    }

    private static func customPath(
        _ custGeom: XMLElement, extXEMU: Double, extYEMU: Double, warnings: inout [String]
    ) -> String? {
        guard let pathList = custGeom.first(local: "pathLst") else { return nil }
        var segments: [String] = []
        for path in pathList.children(local: "path") {
            let width = path.doubleAttr("w") ?? extXEMU
            let height = path.doubleAttr("h") ?? extYEMU
            guard width > 0, height > 0 else { continue }
            if let segment = pathCommands(path, width: width, height: height, warnings: &warnings) {
                segments.append(segment)
            } else {
                appendUnique("a custom shape uses formula-driven geometry — that outline was skipped", &warnings)
            }
        }
        return segments.isEmpty ? nil : segments.joined(separator: " ")
    }

    private static func pathCommands(
        _ path: XMLElement, width: Double, height: Double, warnings: inout [String]
    ) -> String? {
        func point(_ pt: XMLElement?) -> (x: Double, y: Double)? {
            guard let pt, let x = pt.doubleAttr("x"), let y = pt.doubleAttr("y") else { return nil }
            return (x / width, y / height)
        }
        func coordinate(_ p: (x: Double, y: Double)) -> String { PPTXPresetGeometry.coordinate(p) }

        var commands: [String] = []
        var current: (x: Double, y: Double)?
        var subpathStart: (x: Double, y: Double)?
        for command in (path.children ?? []).compactMap({ $0 as? XMLElement }) {
            switch command.localName {
            case "moveTo":
                guard let p = point(command.first(local: "pt")) else { return nil }
                commands.append("M \(coordinate(p))")
                current = p
                subpathStart = p
            case "lnTo":
                guard let from = current, let p = point(command.first(local: "pt")) else { return nil }
                commands.append("C \(coordinate(from)) \(coordinate(p)) \(coordinate(p))")
                current = p
            case "cubicBezTo":
                let pts = command.children(local: "pt")
                guard pts.count == 3, let c1 = point(pts[0]), let c2 = point(pts[1]), let end = point(pts[2]) else { return nil }
                commands.append("C \(coordinate(c1)) \(coordinate(c2)) \(coordinate(end))")
                current = end
            case "quadBezTo":

                let pts = command.children(local: "pt")
                guard let from = current, pts.count == 2, let q = point(pts[0]), let end = point(pts[1]) else { return nil }
                let c1 = (x: from.x + 2.0 / 3 * (q.x - from.x), y: from.y + 2.0 / 3 * (q.y - from.y))
                let c2 = (x: end.x + 2.0 / 3 * (q.x - end.x), y: end.y + 2.0 / 3 * (q.y - end.y))
                commands.append("C \(coordinate(c1)) \(coordinate(c2)) \(coordinate(end))")
                current = end
            case "arcTo":

                guard let from = current,
                      let radiusW = command.doubleAttr("wR"), let radiusH = command.doubleAttr("hR"),
                      let startAngle = command.doubleAttr("stAng"), let sweep = command.doubleAttr("swAng")
                else { return nil }
                appendUnique("curved arc segments in custom shapes are approximated as straight edges", &warnings)
                let rx = radiusW / width
                let ry = radiusH / height
                let start = startAngle / 60000 * .pi / 180
                let end = (startAngle + sweep) / 60000 * .pi / 180
                let center = (x: from.x - rx * cos(start), y: from.y - ry * sin(start))
                let p = (x: center.x + rx * cos(end), y: center.y + ry * sin(end))
                commands.append("C \(coordinate(from)) \(coordinate(p)) \(coordinate(p))")
                current = p
            case "close":
                if let from = current, let start = subpathStart {
                    commands.append("C \(coordinate(from)) \(coordinate(start)) \(coordinate(start))")
                    commands.append("Z")
                    current = start
                }
            default:
                break
            }
        }
        return commands.count >= 2 ? commands.joined(separator: " ") : nil
    }

    private static func parseGeometry(
        into shape: inout PPTXShape, spPr: XMLElement?, transform: PPTXTransform, warnings: inout [String]
    ) {
        if let geometry = spPr?.first(local: "prstGeom") {
            shape.presetGeometry = geometry.attr("prst")
            if let fmla = geometry.descendant(["avLst", "gd"])?.attr("fmla"), fmla.hasPrefix("val ") {
                shape.roundRectAdjustment = Double(fmla.dropFirst(4))
            }
        }
        if let custom = spPr?.first(local: "custGeom") {
            shape.customPathData = customPath(
                custom, extXEMU: transform.extXEMU, extYEMU: transform.extYEMU, warnings: &warnings)
        }
    }

    static func parseTransform(_ xfrm: XMLElement?) -> PPTXTransform? {
        guard let xfrm,
              let off = xfrm.first(local: "off"), let ext = xfrm.first(local: "ext"),
              let x = off.emuAttr("x"), let y = off.emuAttr("y"),
              let cx = ext.emuAttr("cx"), let cy = ext.emuAttr("cy")
        else { return nil }
        return PPTXTransform(
            offXEMU: x, offYEMU: y, extXEMU: cx, extYEMU: cy,
            rotation60k: xfrm.doubleAttr("rot") ?? 0,
            flipH: xfrm.boolAttr("flipH") ?? false,
            flipV: xfrm.boolAttr("flipV") ?? false)
    }

    private static func parseFill(
        in parent: XMLElement, context: String, phClr: String? = nil,
        package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXFill? {
        let kinds = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]
        guard let element = (parent.children ?? []).lazy.compactMap({ $0 as? XMLElement })
            .first(where: { kinds.contains($0.localName ?? "") })
        else { return nil }
        return fill(
            fromElement: element, context: context, phClr: phClr,
            mediaContext: (package, partPath, rels),
            inheritance: inheritance, warnings: &warnings)
    }

    private static func fill(
        fromElement element: XMLElement, context: String, phClr: String?,
        mediaContext: (package: PPTXPackage, partPath: String, rels: [String: PPTXPackage.Relationship])?,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXFill? {
        switch element.localName {
        case "noFill":
            return .noFill
        case "solidFill":
            return inheritance.colors.color(in: element, phClr: phClr, warnings: &warnings)
                .map { .solid(colorHex: $0) }
        case "gradFill":
            return gradient(from: element, phClr: phClr, inheritance: inheritance, warnings: &warnings)
                .map { .gradient($0) }
        case "blipFill":
            guard let mediaContext else {
                appendUnique("theme picture backgrounds are not imported yet", &warnings)
                return nil
            }
            let blip = element.first(local: "blip")
            let embed = blip.flatMap { $0.relationshipAttr("embed") ?? $0.attr("embed") }
            guard let path = mediaPath(
                relationshipID: embed, context: context,
                package: mediaContext.package, partPath: mediaContext.partPath,
                rels: mediaContext.rels, warnings: &warnings
            ) else { return nil }

            let tile = element.first(local: "tile")
            let alpha = blip?.first(local: "alphaModFix")?.doubleAttr("amt").map { $0 / 100_000 } ?? 1
            if tile != nil || alpha < 1 {
                return .blipTiled(
                    path: path,
                    alpha: alpha,
                    scaleX: (tile?.doubleAttr("sx") ?? 100_000) / 100_000,
                    scaleY: (tile?.doubleAttr("sy") ?? 100_000) / 100_000,
                    tiled: tile != nil
                )
            }
            return .blip(path: path)
        case "pattFill":

            let foreground = inheritance.colors.color(in: element.first(local: "fgClr"), phClr: phClr, warnings: &warnings)
            let background = inheritance.colors.color(in: element.first(local: "bgClr"), phClr: phClr, warnings: &warnings)
            guard let foreground else { return background.map { .solid(colorHex: $0) } }
            guard let background else { return .solid(colorHex: foreground) }
            return .pattern(
                preset: element.attr("prst") ?? "",
                foregroundHex: foreground, backgroundHex: background)
        default:
            return nil
        }
    }

    static func blend(_ foreground: String, _ background: String, coverage: Double) -> String {
        func bytes(_ hex: String) -> [Double] {
            var padded = hex
            if padded.count == 6 { padded += "FF" }
            return stride(from: 0, to: 8, by: 2).compactMap { offset -> Double? in
                let start = padded.index(padded.startIndex, offsetBy: offset)
                let end = padded.index(start, offsetBy: 2)
                return UInt8(padded[start..<end], radix: 16).map(Double.init)
            }
        }
        let fg = bytes(foreground), bg = bytes(background)
        guard fg.count == 4, bg.count == 4 else { return foreground }
        let mixed = zip(fg, bg).map { $0 * coverage + $1 * (1 - coverage) }
        return mixed.map { String(format: "%02X", UInt8(min(max($0.rounded(), 0), 255))) }.joined()
    }

    private static func gradient(
        from element: XMLElement, phClr: String?,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXGradient? {
        var stops: [PPTXGradientStop] = []
        if let gsLst = element.first(local: "gsLst") {
            for gs in gsLst.children(local: "gs") {
                guard let color = inheritance.colors.color(in: gs, phClr: phClr, warnings: &warnings) else { continue }
                stops.append(PPTXGradientStop(position: gs.doubleAttr("pos") ?? 0, colorHex: color))
            }
        }
        guard stops.count >= 2 else {
            appendUnique("a gradient fill had fewer than two resolvable stops and was skipped", &warnings)
            return nil
        }
        stops.sort { $0.position < $1.position }
        var gradient = PPTXGradient(stops: stops)
        if let lin = element.first(local: "lin") {
            gradient.angle60k = lin.doubleAttr("ang") ?? 0
        } else {

            appendUnique("radial gradient approximated as linear", &warnings)
        }
        return gradient
    }

    private static func parseLine(
        _ ln: XMLElement?, inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXStroke? {
        guard let ln else { return nil }

        let width = ln.emuAttr("w") ?? 9525

        let dash: StrokeDashKind? = ln.first(local: "prstDash")?.attr("val").flatMap { value in
            switch value {
            case "dot", "sysDot": .dotted
            case "solid": nil
            default: .dashed  
            }
        }
        if let solid = ln.first(local: "solidFill"),
           let hex = inheritance.colors.color(in: solid, warnings: &warnings) {
            return PPTXStroke(colorHex: hex, widthEMU: width, dash: dash)
        }

        if let gradient = ln.first(local: "gradFill"),
           let firstStop = gradient.first(local: "gsLst")?.children(local: "gs").first,
           let hex = inheritance.colors.color(in: firstStop, warnings: &warnings) {
            appendUnique("gradient outlines are approximated as their first color", &warnings)
            return PPTXStroke(colorHex: hex, widthEMU: width, dash: dash)
        }
        return nil
    }

    private static func mediaPath(
        relationshipID: String?, context: String, package: PPTXPackage, partPath: String,
        rels: [String: PPTXPackage.Relationship],
        externalAsPath: Bool = false, warnings: inout [String]
    ) -> String? {
        guard let relationshipID else { return nil }
        guard let rel = rels[relationshipID] else {
            appendUnique("\(context) references a missing relationship and was skipped", &warnings)
            return nil
        }
        if rel.external {
            if externalAsPath {
                if let url = URL(string: rel.target), url.isFileURL { return url.path }
                if rel.target.hasPrefix("/") { return rel.target.removingPercentEncoding ?? rel.target }
                appendUnique("\(context) links media at an unresolvable location and was skipped", &warnings)
                return nil
            }
            appendUnique("\(context) links media outside the file — linked media is not imported yet", &warnings)
            return nil
        }
        return package.fileURL(forPart: package.resolveTarget(rel.target, relativeTo: partPath)).path
    }

    private static func parseBackground(
        _ bg: XMLElement, owningPart: String, package: PPTXPackage,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXFill? {
        if let bgPr = bg.first(local: "bgPr") {
            return parseFill(
                in: bgPr, context: "the slide background",
                package: package, partPath: owningPart,
                rels: package.relationships(of: owningPart),
                inheritance: inheritance, warnings: &warnings)
        }
        if let bgRef = bg.first(local: "bgRef") {
            let index = bgRef.intAttr("idx") ?? 0
            guard index > 0 else { return nil }

            let phClr = inheritance.colors.color(in: bgRef, warnings: &warnings).map { String($0.prefix(6)) }
            guard let style = inheritance.themeFillStyle(index: index) else {
                appendUnique("the theme has no background style for this slide — background skipped", &warnings)
                return nil
            }
            return fill(
                fromElement: style, context: "the slide background", phClr: phClr,
                mediaContext: nil, inheritance: inheritance, warnings: &warnings)
        }
        return nil
    }

    private static func parseTextBody(
        _ txBody: XMLElement, placeholder: (type: String?, idx: Int?)?,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXTextBody {
        var body = PPTXTextBody()
        if let bodyPr = txBody.first(local: "bodyPr") {
            body.anchor = bodyPr.attr("anchor")
            body.wrap = bodyPr.attr("wrap")
            body.topInsetEMU = bodyPr.emuAttr("tIns")
            body.leftInsetEMU = bodyPr.emuAttr("lIns")
            body.bottomInsetEMU = bodyPr.emuAttr("bIns")
            body.rightInsetEMU = bodyPr.emuAttr("rIns")
            if let autofit = bodyPr.first(local: "normAutofit") {
                body.hasNormAutofit = true
                body.autofitFontScale = autofit.doubleAttr("fontScale")
            }

            if bodyPr.first(local: "spAutoFit") != nil { body.hasSpAutofit = true }
            if let vertical = bodyPr.attr("vert"), vertical != "horz" {
                appendUnique("vertical text is not supported — imported horizontal", &warnings)
            }
        }
        for paragraphElement in txBody.children(local: "p") {
            let pPr = paragraphElement.first(local: "pPr")
            let level = pPr?.intAttr("lvl") ?? 0

            var defaults = inheritance.textDefaults(placeholder: placeholder, level: level, warnings: &warnings)
            defaults = defaults.merging(inheritance.defaults(fromParagraphProperties: pPr, warnings: &warnings))
            var paragraph = PPTXParagraph()
            paragraph.alignment = defaults.alignment
            for child in (paragraphElement.children ?? []).compactMap({ $0 as? XMLElement }) {
                switch child.localName {
                case "r":
                    paragraph.runs.append(parseRun(child, defaults: defaults, inheritance: inheritance, warnings: &warnings))
                case "br":
                    paragraph.runs.append(PPTXRun(isBreak: true))
                case "fld":

                    appendUnique("dynamic fields (slide numbers, dates) imported as static text", &warnings)
                    paragraph.runs.append(parseRun(child, defaults: defaults, inheritance: inheritance, warnings: &warnings))
                default:
                    break
                }
            }
            body.paragraphs.append(paragraph)
        }
        return body
    }

    private static func parseRun(
        _ r: XMLElement, defaults: PPTXTextDefaults,
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> PPTXRun {
        var effective = defaults
        if let rPr = r.first(local: "rPr") {
            effective = defaults.merging(inheritance.runProperties(rPr, warnings: &warnings))
        }
        var run = PPTXRun()
        run.text = r.first(local: "t")?.stringValue ?? ""
        run.fontFamily = effective.fontFamily
        run.sizeHundredthsPt = effective.sizeHundredthsPt
        run.bold = effective.bold ?? false
        run.italic = effective.italic ?? false
        run.underline = effective.underline ?? false
        run.strike = effective.strike ?? false
        run.colorHex = effective.colorHex
        run.trackingHundredthsPt = effective.trackingHundredthsPt
        return run
    }

    private static func parseTransition(in root: XMLElement) -> PPTXTransition? {
        func find(_ element: XMLElement) -> XMLElement? {
            for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                if child.localName == "cSld" { continue }
                if child.localName == "transition" { return child }
                if let found = find(child) { return found }
            }
            return nil
        }
        guard let transition = find(root) else { return nil }
        var result = PPTXTransition()

        if let effect = (transition.children ?? []).compactMap({ $0 as? XMLElement }).first(where: { $0.localName != "extLst" }) {
            result.kind = effect.localName
            result.throughBlack = effect.boolAttr("thruBlk") ?? false
            if let ms = transition.doubleAttr("dur") {  
                result.durationSeconds = ms / 1000
            } else {
                switch transition.attr("spd") {
                case "slow": result.durationSeconds = 1.0
                case "med": result.durationSeconds = 0.75
                default: result.durationSeconds = 0.5  
                }
            }
        }
        result.advanceAfterMs = transition.doubleAttr("advTm")
        return result
    }

    private static func parseTiming(in root: XMLElement) -> [PPTXAnimation] {
        guard let timing = root.first(local: "timing") else { return [] }
        var animationSteps: [PPTXAnimation] = []
        func walk(_ element: XMLElement) {
            for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                if child.localName == "cTn", let presetClass = child.attr("presetClass") {
                    if let build = effect(child, presetClass: presetClass) { animationSteps.append(build) }
                    continue 
                }
                walk(child)
            }
        }
        func effect(_ cTn: XMLElement, presetClass: String) -> PPTXAnimation? {
            var target: XMLElement?
            var duration: Double?
            func scan(_ element: XMLElement) {
                for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                    if child.localName == "spTgt", target == nil { target = child }
                    if child.localName == "cTn", let dur = child.doubleAttr("dur") {
                        duration = max(duration ?? 0, dur)
                    }
                    scan(child)
                }
            }
            scan(cTn)
            guard let target, let spid = target.intAttr("spid") else { return nil }
            var build = PPTXAnimation(shapeID: spid)
            build.presetClass = presetClass
            build.presetID = cTn.intAttr("presetID")
            build.presetSubtype = cTn.intAttr("presetSubtype")
            build.nodeType = cTn.attr("nodeType")
            build.delayMs = cTn.first(local: "stCondLst")?.first(local: "cond")?.doubleAttr("delay") ?? 0
            build.durationMs = duration
            if let range = target.descendant(["txEl", "pRg"]) {
                build.paragraphStart = range.intAttr("st")
                build.paragraphEnd = range.intAttr("end")
            }
            return build
        }
        walk(timing)
        return animationSteps
    }

    private static func parseNotes(
        slidePart: String, package: PPTXPackage,
        rels: [String: PPTXPackage.Relationship],
        inheritance: PPTXInheritance, warnings: inout [String]
    ) -> String? {
        guard let rel = rels.values.first(where: { $0.type.hasSuffix("/notesSlide") && !$0.external }) else { return nil }
        let part = package.resolveTarget(rel.target, relativeTo: slidePart)
        guard let root = try? package.document(at: part).rootElement(),
              let spTree = root.descendant(["cSld", "spTree"])
        else { return nil }
        for sp in spTree.children(local: "sp") {
            guard sp.descendant(["nvSpPr", "nvPr", "ph"])?.attr("type") == "body",
                  let txBody = sp.first(local: "txBody")
            else { continue }
            let text = parseTextBody(txBody, placeholder: nil, inheritance: inheritance, warnings: &warnings).plainText
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
