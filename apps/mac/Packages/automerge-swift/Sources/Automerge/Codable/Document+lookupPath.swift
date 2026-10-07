public extension Document {

    func lookupPath(path: String) throws -> ObjId? {
        let codingPath = try AnyCodingKey.parsePath(path)
        if codingPath.isEmpty {
            return ObjId.ROOT
        }
        let result = retrieveObjectId(
            path: codingPath,
            containerType: .Value,
            strategy: .readonly
        )
        switch result {
        case let .success(objectId):
            let existingValue: Value?
            guard let finalCodingKey = codingPath.last else {
                throw CodingKeyLookupError
                    .NoPathForSingleValue("Attempting to establish a single value container with an empty coding path.")
            }

            if let indexValue = finalCodingKey.intValue {
                let indexSize = length(obj: objectId)
                if indexValue > indexSize {
                    throw CodingKeyLookupError
                        .IndexOutOfBounds("Attempted to look up index \(indexValue) from a list of size \(indexSize).")
                }
                existingValue = try get(obj: objectId, index: UInt64(indexValue))
            } else {
                existingValue = try get(obj: objectId, key: finalCodingKey.stringValue)
            }

            if case let .Object(finalObjectId, _) = existingValue {
                return finalObjectId
            } else {

                return nil
            }
        case let .failure(lookupError):
            throw lookupError
        }
    }
}

public extension Sequence where Element == Automerge.PathElement {

    func stringPath() -> String {
        let path = map { pathElement in
            switch pathElement.prop {
            case let .Index(idx):
                return String("[\(idx)]")
            case let .Key(key):
                return key
            }
        }.joined(separator: ".")
        return ".\(path)"
    }
}
