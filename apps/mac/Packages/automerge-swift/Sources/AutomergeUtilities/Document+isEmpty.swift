import Automerge

public extension Document {

    func isEmpty() throws -> Bool {
        let x = try mapEntries(obj: .ROOT)
        return x.count < 1
    }
}
