import Foundation

enum DocxMedia {
    static func pictures(of url: URL, save: NoteFileReader.SaveMedia?) -> [(afterWordLines: Int, media: NoteFileReader.Media)] {
        guard save != nil, let root = try? ZipExtract.extract(url) else { return [] }
        defer { try? FileManager.default.removeItem(at: root) }
        let word = root.appendingPathComponent("word")
        guard let document = try? XMLDocument(contentsOf: word.appendingPathComponent("document.xml")),
              let rels = try? XMLDocument(contentsOf: word.appendingPathComponent("_rels/document.xml.rels"))
        else { return [] }
        var targets: [String: String] = [:]
        for case let rel as XMLElement in (try? rels.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
            if let id = rel.attribute(forName: "Id")?.stringValue, let target = rel.attribute(forName: "Target")?.stringValue {
                targets[id] = target
            }
        }
        var found: [(Int, NoteFileReader.Media)] = []
        var words = 0
        for paragraph in (try? document.nodes(forXPath: "//*[local-name()='body']//*[local-name()='p']")) ?? [] {
            let text = ((try? paragraph.nodes(forXPath: ".//*[local-name()='t']")) ?? []).compactMap(\.stringValue).joined()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { words += 1 }
            for case let blip as XMLElement in (try? paragraph.nodes(forXPath: ".//*[local-name()='blip']")) ?? [] {
                guard let id = blip.attributes?.first(where: { $0.localName == "embed" })?.stringValue,
                      let target = targets[id], !target.hasPrefix("http") else { continue }
                let file = word.appendingPathComponent(target).standardizedFileURL
                guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file),
                      let media = NoteFileReader.Media.saving(data, fileName: file.lastPathComponent, with: save)
                else { continue }
                found.append((words, media))
            }
        }
        return found.map { (afterWordLines: $0.0, media: $0.1) }
    }
}
