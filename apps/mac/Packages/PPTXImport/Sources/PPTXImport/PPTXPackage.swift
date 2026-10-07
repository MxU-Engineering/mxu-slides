import Foundation

final class PPTXPackage {

    struct Relationship {
        let type: String
        let target: String
        let external: Bool
    }

    let root: URL
    private var documents: [String: XMLDocument] = [:]

    init(root: URL) {
        self.root = root
    }

    func presentationPartPath() throws -> String {
        let rels = try relationships(inRelsPart: "_rels/.rels")
        guard let rel = rels.values.first(where: { $0.type.hasSuffix("/officeDocument") }), !rel.external else {
            throw PPTXImportError.invalidPackage("no presentation part in _rels/.rels — not a PowerPoint file")
        }
        return resolveTarget(rel.target, relativeTo: "")
    }

    func relationships(of part: String) -> [String: Relationship] {
        let directory = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        let relsPart = directory.isEmpty ? "_rels/\(name).rels" : "\(directory)/_rels/\(name).rels"
        return (try? relationships(inRelsPart: relsPart)) ?? [:]
    }

    private func relationships(inRelsPart part: String) throws -> [String: Relationship] {
        guard let rootElement = try document(at: part).rootElement() else { return [:] }
        var result: [String: Relationship] = [:]
        for rel in rootElement.children(local: "Relationship") {
            guard let id = rel.attr("Id"), let type = rel.attr("Type"), let target = rel.attr("Target") else { continue }
            result[id] = Relationship(type: type, target: target, external: rel.attr("TargetMode") == "External")
        }
        return result
    }

    func resolveTarget(_ target: String, relativeTo part: String) -> String {
        if target.hasPrefix("/") {
            return String(target.drop { $0 == "/" })
        }
        var components = (part as NSString).deletingLastPathComponent
            .split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else {
                    // Preserve an escape attempt so fileURL(forPart:) rejects it.
                    components.append("..")
                }
            case ".": break
            default: components.append(String(piece))
            }
        }
        return components.joined(separator: "/")
    }

    func fileURL(forPart part: String) throws -> URL {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = directory.appendingPathComponent(part).standardizedFileURL
        guard !part.contains("\0"), file.path.hasPrefix(directory.path + "/") else {
            throw PPTXImportError.invalidPackage("a package part points outside the presentation")
        }
        // Check the original components before resolving links, including dangling
        // links and links to other files inside the package.
        var component = file
        while component.path != directory.path {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw PPTXImportError.invalidPackage("symbolic links are not allowed in presentation parts")
            }
            component.deleteLastPathComponent()
        }
        let resolved = file.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(directory.path + "/") else {
            throw PPTXImportError.invalidPackage("a package part points outside the presentation")
        }
        return resolved
    }

    func document(at part: String) throws -> XMLDocument {
        if let cached = documents[part] { return cached }
        let data = try Data(contentsOf: fileURL(forPart: part))
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard document.dtd == nil else {
            throw PPTXImportError.invalidPackage("DTD declarations are not allowed in presentation XML")
        }
        documents[part] = document
        return document
    }
}
