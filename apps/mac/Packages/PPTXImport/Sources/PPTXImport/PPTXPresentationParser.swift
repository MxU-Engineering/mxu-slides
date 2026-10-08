import Foundation

enum PPTXPresentationParser {

    struct Result {

        var partPath: String
        var slideWidthEMU: Double
        var slideHeightEMU: Double
        var slidePartPaths: [String]
        var sections: [PPTXSection] = []
    }

    static func parse(in package: PPTXPackage, warnings: inout [String]) throws -> Result {
        let part = try package.presentationPartPath()
        guard let root = try package.document(at: part).rootElement() else {
            throw PPTXImportError.invalidPackage("\(part) has no root element")
        }

        var width = 12_192_000.0
        var height = 6_858_000.0
        if let size = root.first(local: "sldSz"),
           let cx = size.emuAttr("cx"), let cy = size.emuAttr("cy"), cx > 0, cy > 0 {
            width = cx
            height = cy
        } else {
            warnings.append("the deck declared no slide size — assuming 16:9")
        }

        let rels = package.relationships(of: part)
        var slideParts: [String] = []
        var indexBySlideNumber: [String: Int] = [:]
        if let list = root.first(local: "sldIdLst") {
            for slideID in list.children(local: "sldId") {
                guard let relID = slideID.relationshipAttr("id"),
                      let rel = rels[relID], !rel.external
                else { continue }

                if let number = slideID.attributes?.first(where: { $0.name == "id" })?.stringValue {
                    indexBySlideNumber[number] = slideParts.count
                }
                slideParts.append(package.resolveTarget(rel.target, relativeTo: part))
            }
        }

        return Result(
            partPath: part, slideWidthEMU: width, slideHeightEMU: height,
            slidePartPaths: slideParts,
            sections: sections(in: root, indexBySlideNumber: indexBySlideNumber))
    }

    private static func sections(in root: XMLElement, indexBySlideNumber: [String: Int]) -> [PPTXSection] {
        guard let extLst = root.first(local: "extLst") else { return [] }
        var sectionList: XMLElement?
        for ext in extLst.children(local: "ext") {
            if let found = ext.first(local: "sectionLst") { sectionList = found; break }
        }
        guard let sectionList else { return [] }
        var sections: [PPTXSection] = []
        for section in sectionList.children(local: "section") {
            let guid = (section.attr("id") ?? UUID().uuidString)
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .lowercased()
            var result = PPTXSection(id: guid, name: section.attr("name") ?? "")
            if let idList = section.first(local: "sldIdLst") {
                for slideID in idList.children(local: "sldId") {
                    guard let number = slideID.attr("id"), let index = indexBySlideNumber[number] else { continue }
                    result.slideIndexes.append(index)
                }
            }
            sections.append(result)
        }
        return sections
    }

    static func embeddedFonts(in package: PPTXPackage) -> [PPTXEmbeddedFont] {
        guard let part = try? package.presentationPartPath(),
              let root = try? package.document(at: part).rootElement(),
              let fontList = root.first(local: "embeddedFontLst")
        else { return [] }
        let rels = package.relationships(of: part)
        var fonts: [PPTXEmbeddedFont] = []
        for embedded in fontList.children(local: "embeddedFont") {
            guard let typeface = embedded.first(local: "font")?.attr("typeface") else { continue }
            for variant in ["regular", "bold", "italic", "boldItalic"] {
                guard let relID = embedded.first(local: variant)?.relationshipAttr("id"),
                      let rel = rels[relID], !rel.external
                else { continue }
                guard let file = try? package.fileURL(forPart: package.resolveTarget(rel.target, relativeTo: part)) else { continue }
                let path = file.path
                fonts.append(PPTXEmbeddedFont(typeface: typeface, variant: variant, filePath: path))
            }
        }
        return fonts
    }
}
