#if canImport(os)
import os 
#endif

extension Document {
    @usableFromInline
    func tracePrint(indent: Int = 0, _ stringval: @autoclosure () -> String) {
        #if DEBUG && canImport(os)
        if reportingLogLevel >= .tracing {
            if #available(macOS 11, iOS 14, *) {
                let logger = Logger(subsystem: "Automerge", category: "AutomergeEncoder")
                let prefix = String(repeating: " ", count: indent)
                let message = stringval()
                logger.debug("\(prefix, privacy: .public)\(message, privacy: .public)")
            }
        }
        #endif
    }

    @inlinable func retrieveObjectId(
        path: [CodingKey],
        containerType: EncodingContainerType,
        strategy: SchemaStrategy,
        parentObjectId: ObjId? = nil
    ) -> Result<ObjId, CodingKeyLookupError> {

        var matchingObjectIds: [Int: ObjId] = [:]
        matchingObjectIds.reserveCapacity(path.count)

        tracePrint(
            "`retrieveObjectId` with path [\(path.map { AnyCodingKey($0) })] for container type \(containerType), with strategy: \(strategy)"
        )

        var startingPosition = 0
        var previousObjectId = ObjId.ROOT

        if strategy == .override {
            return .failure(CodingKeyLookupError.UnexpectedLookupFailure("Override strategy not yet implemented"))
        }

        if path.isEmpty {
            switch containerType {
            case .Key:
                return .success(ObjId.ROOT)
            case .Index, .Value:
                return .failure(
                    CodingKeyLookupError
                        .InvalidIndexLookup("An empty path refers to ROOT and is always a map.")
                )
            }
        }

        if let parentObjectId {
            startingPosition = path.count - 1
            previousObjectId = parentObjectId
            if path.count >= 2 {
                matchingObjectIds[path.count - 2] = parentObjectId
            }
        }

        for position in startingPosition ..< (path.count - 1) {
            tracePrint(indent: position, "Checking position \(position): '\(path[position])'")

            if let indexValue = path[position].intValue {
                tracePrint(indent: position, "Checking against index position \(indexValue).")

                if indexValue > length(obj: previousObjectId) {
                    if strategy == .readonly {
                        return .failure(
                            CodingKeyLookupError
                                .IndexOutOfBounds(
                                    "Index value \(indexValue) is beyond the length: \(length(obj: previousObjectId)) and schema is read-only"
                                )
                        )
                    } else if indexValue > (length(obj: previousObjectId) + 1) {
                        return .failure(
                            CodingKeyLookupError
                                .IndexOutOfBounds(
                                    "Index value \(indexValue) is too far beyond the length: \(length(obj: previousObjectId)) to append a new item."
                                )
                        )
                    }
                }

                do {
                    if let value = try get(obj: previousObjectId, index: UInt64(indexValue)) {
                        switch value {
                        case let .Object(objId, objType):

                            if objType == .Text {

                                return .failure(
                                    CodingKeyLookupError
                                        .PathExtendsThroughText(
                                            "Path at \(path[0 ... position]) is a Text object, which is not a container - and the path has additional elements: \(path[(position + 1)...])."
                                        )
                                )
                            }
                            matchingObjectIds[position] = objId
                            previousObjectId = objId
                            tracePrint(
                                indent: position,
                                "Found \(path[0 ... position]) as objectId \(objId) of type \(objType)"
                            )
                        case .Scalar:

                            return .failure(
                                CodingKeyLookupError
                                    .PathExtendsThroughScalar(
                                        "Path at \(path[0 ... position]) is a single value, not a container - and the path has additional elements: \(path[(position + 1)...])."
                                    )
                            )
                        }
                    } else { 
                        tracePrint(
                            indent: position,
                            "Nothing pre-existing in schema at \(path[0 ... position]), will need to create a container."
                        )
                        if strategy == .readonly {

                            return .failure(
                                CodingKeyLookupError
                                    .SchemaMissing(
                                        "Nothing in schema exists at \(path[0 ... position]) - look u returns nil"
                                    )
                            )
                        } else { 

                            tracePrint(indent: position, "Need to create a container at \(path[0 ... position]).")
                            tracePrint(indent: position, "Next path element is '\(path[position + 1])'.")
                            if let _ = path[position + 1].intValue {

                                let newObjectId = try insertObject(
                                    obj: previousObjectId,
                                    index: UInt64(indexValue),
                                    ty: .List
                                )
                                matchingObjectIds[position] = newObjectId
                                previousObjectId = newObjectId
                                tracePrint(
                                    indent: position,
                                    "created \(path[0 ... position]) as objectId \(newObjectId) of type List"
                                )

                            } else {

                                let newObjectId = try insertObject(
                                    obj: previousObjectId,
                                    index: UInt64(indexValue),
                                    ty: .Map
                                )
                                matchingObjectIds[position] = newObjectId
                                previousObjectId = newObjectId
                                tracePrint(
                                    indent: position,
                                    "created \(path[0 ... position]) as objectId \(newObjectId) of type Map"
                                )

                            }
                        }
                    }
                } catch {
                    return .failure(.AutomergeDocError(error))
                }
            } else { 
                let keyValue = path[position].stringValue
                tracePrint(indent: position, "Checking against key \(keyValue).")
                do {
                    if let value = try get(obj: previousObjectId, key: keyValue) {
                        switch value {
                        case let .Object(objId, objType):

                            if objType == .Text {
                                return .failure(
                                    CodingKeyLookupError
                                        .PathExtendsThroughText(
                                            "Path at \(path[0 ... position]) is a Text object, which is not a container - and the path has additional elements: \(path[(position + 1)...])."
                                        )
                                )
                            }
                            matchingObjectIds[position] = objId
                            previousObjectId = objId
                            tracePrint(
                                indent: position,
                                "Found \(path[0 ... position]) as objectId \(objId) of type \(objType)"
                            )
                        case .Scalar:

                            return .failure(
                                CodingKeyLookupError
                                    .PathExtendsThroughScalar(
                                        "Path at \(path[0 ... position]) is a single value, not a container - and the path has additional elements: \(path[(position + 1)...])."
                                    )
                            )
                        }
                    } else { 
                        tracePrint(
                            indent: position,
                            "Nothing pre-existing in schema at \(path[0 ... position]), will need to create a container."
                        )
                        if strategy == .readonly {

                            return .failure(
                                CodingKeyLookupError
                                    .SchemaMissing(
                                        "Nothing in schema exists at \(path[0 ... position]) - look u returns nil"
                                    )
                            )
                        } else { 
                            tracePrint(indent: position, "Need to create a container at \(path[0 ... position]).")
                            tracePrint(indent: position, "Next path element is \(path[position + 1]).")

                            if let _ = path[position + 1].intValue {

                                let newObjectId = try putObject(
                                    obj: previousObjectId,
                                    key: keyValue,
                                    ty: .List
                                )
                                matchingObjectIds[position] = newObjectId
                                previousObjectId = newObjectId
                                tracePrint(
                                    indent: position,
                                    "created \(path[0 ... position]) as objectId \(newObjectId) of type List"
                                )

                            } else {

                                let newObjectId = try putObject(
                                    obj: previousObjectId,
                                    key: keyValue,
                                    ty: .Map
                                )
                                matchingObjectIds[position] = newObjectId
                                previousObjectId = newObjectId
                                tracePrint(
                                    indent: position,
                                    "created \(path[0 ... position]) as objectId \(newObjectId) of type Map"
                                )

                            }
                        }
                    }
                } catch {
                    return .failure(.AutomergeDocError(error))
                }
            }
        }

        #if DEBUG
        tracePrint("All prior containers created or found:")
        for position in startingPosition ..< (path.count - 1) {
            tracePrint("   \(position) -> \(String(describing: matchingObjectIds[position]))")
        }
        #endif

        let finalpiece = path[path.count - 1]
        switch containerType {
        case .Index, .Key: 
            if let indexValue = finalpiece.intValue { 
                tracePrint(
                    indent: path.count - 1,
                    "Final piece of the path is '\(finalpiece)', index \(indexValue) of a List."
                )

                if indexValue > length(obj: previousObjectId) {
                    if strategy == .readonly {
                        return .failure(
                            CodingKeyLookupError
                                .IndexOutOfBounds(
                                    "Index value \(indexValue) is beyond the length: \(length(obj: previousObjectId)) and schema is read-only"
                                )
                        )
                    } else if indexValue > (length(obj: previousObjectId) + 1) {
                        return .failure(
                            CodingKeyLookupError
                                .IndexOutOfBounds(
                                    "Index value \(indexValue) is too far beyond the length: \(length(obj: previousObjectId)) to append a new item."
                                )
                        )
                    }
                }

                do {
                    tracePrint(
                        indent: path.count - 1,
                        "Look up what's at index \(indexValue) of objectId: \(previousObjectId):"
                    )
                    if let value = try get(obj: previousObjectId, index: UInt64(indexValue)) {
                        switch value {
                        case let .Object(objId, objType):
                            switch objType {
                            case .Text:
                                return .failure(
                                    CodingKeyLookupError
                                        .MismatchedSchema(
                                            "Path at \(path) is a Text object, which is not the List container that we expected."
                                        )
                                )
                            case .Map:
                                if containerType == .Key {
                                    tracePrint("Found Object container with ObjectId \(objId).")
                                    return .success(objId)
                                } else {
                                    return .failure(
                                        CodingKeyLookupError
                                            .MismatchedSchema(
                                                "Path at \(path) is an object container, not the List container that we expected."
                                            )
                                    )
                                }
                            case .List:

                                if containerType == .Index {
                                    tracePrint("Found List container with ObjectId \(objId).")
                                    return .success(objId)
                                } else {
                                    return .failure(
                                        CodingKeyLookupError
                                            .MismatchedSchema(
                                                "Path at \(path) is a list container, not the Object container that we expected."
                                            )
                                    )
                                }
                            }
                        case .Scalar:

                            return .failure(
                                CodingKeyLookupError
                                    .MismatchedSchema(
                                        "Path at \(path) is an scalar value, which is not the List container that we expected."
                                    )
                            )
                        }
                    } else { 
                        tracePrint(indent: path.count - 1, "Need to create a container at \(path).")
                        tracePrint(indent: path.count - 1, "Path type to create is \(containerType).")
                        if strategy == .readonly {

                            return .failure(
                                CodingKeyLookupError
                                    .SchemaMissing(
                                        "Nothing in schema exists at \(path) - look u returns nil"
                                    )
                            )
                        } else {
                            if containerType == .Index {

                                let newObjectId = try insertObject(
                                    obj: previousObjectId,
                                    index: UInt64(indexValue),
                                    ty: .List
                                )

                                tracePrint(
                                    indent: path.count - 1,
                                    "Created new List container with ObjectId \(newObjectId)."
                                )
                                return .success(newObjectId)
                            } else {

                                let newObjectId = try insertObject(
                                    obj: previousObjectId,
                                    index: UInt64(indexValue),
                                    ty: .Map
                                )

                                tracePrint(
                                    indent: path.count - 1,
                                    "Created new Map container with ObjectId \(newObjectId)."
                                )
                                return .success(newObjectId)
                            }
                        }
                    }
                } catch {
                    return .failure(.AutomergeDocError(error))
                }
            } else { 
                let keyValue = finalpiece.stringValue

                do {
                    tracePrint(
                        indent: path.count - 1,
                        "Look up what's at key '\(keyValue)' of objectId: \(previousObjectId)."
                    )
                    if let value = try get(obj: previousObjectId, key: keyValue) {
                        switch value {
                        case let .Object(objId, objType):
                            switch objType {
                            case .Text:
                                return .failure(
                                    CodingKeyLookupError
                                        .MismatchedSchema(
                                            "Container at \(path) is a Text object, which is not the Object container expected."
                                        )
                                )
                            case .Map:
                                if containerType == .Key {

                                    tracePrint(indent: path.count - 1, "Found Map container with ObjectId \(objId).")
                                    return .success(objId)
                                } else {
                                    return .failure(
                                        CodingKeyLookupError
                                            .MismatchedSchema(
                                                "Container at \(path) is a Map container, not the List container that we expected."
                                            )
                                    )
                                }
                            case .List:
                                if containerType == .Index {

                                    tracePrint(indent: path.count - 1, "Found List container with ObjectId \(objId).")
                                    return .success(objId)
                                } else {
                                    return .failure(
                                        CodingKeyLookupError
                                            .MismatchedSchema(
                                                "Container at \(path) is a List container, not the object container that we expected."
                                            )
                                    )
                                }
                            }
                        case .Scalar:

                            return .failure(
                                CodingKeyLookupError
                                    .MismatchedSchema(
                                        "Item at \(path) is an scalar value, which is not the List container that we expected."
                                    )
                            )
                        }
                    } else { 
                        tracePrint(indent: path.count - 1, "Need to create a container at \(path).")
                        tracePrint(indent: path.count - 1, "Path type to create is \(containerType).")
                        if strategy == .readonly {

                            return .failure(
                                CodingKeyLookupError
                                    .SchemaMissing(
                                        "Nothing in schema exists at \(path) - look u returns nil"
                                    )
                            )
                        } else {
                            if containerType == .Index {

                                let newObjectId = try putObject(
                                    obj: previousObjectId,
                                    key: keyValue,
                                    ty: .List
                                )

                                tracePrint(
                                    indent: path.count - 1,
                                    "Created new List container with ObjectId \(newObjectId)."
                                )
                                return .success(newObjectId)
                            } else {

                                let newObjectId = try putObject(
                                    obj: previousObjectId,
                                    key: keyValue,
                                    ty: .Map
                                )

                                tracePrint(
                                    indent: path.count - 1,
                                    "Created new Map container with ObjectId \(newObjectId)."
                                )
                                return .success(newObjectId)
                            }
                        }
                    }
                } catch {
                    return .failure(.AutomergeDocError(error))
                }
            }
        case .Value:
            if path.count < 2 {

                return .success(ObjId.ROOT)
            } else {
                guard let containerObjectId = matchingObjectIds[path.count - 2] else {
                    fatalError(
                        "objectId lookups failed to identify an object Id for the last element in path: \(path)"
                    )
                }
                return .success(containerObjectId)
            }
        }
    }
}
