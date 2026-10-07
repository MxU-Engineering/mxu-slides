import Automerge

public extension Document {

    func equivalentContents(_ anotherDoc: Document) -> Bool {
        do {
            let doc1Contents = try parseToSchema(self, from: .ROOT)
            let doc2Contents = try anotherDoc.parseToSchema(anotherDoc, from: .ROOT)
            return doc1Contents == doc2Contents
        } catch {
            return false
        }
    }
}
