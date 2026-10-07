import Foundation

@usableFromInline struct AutomergeDecoderImpl {
    @usableFromInline let doc: Document
    @usableFromInline let codingPath: [CodingKey]
    @usableFromInline let userInfo: [CodingUserInfoKey: Any]

    @usableFromInline let parentObjectId: ObjId?

    @usableFromInline let prefetchedValue: Value?

    @inlinable init(
        doc: Document,
        userInfo: [CodingUserInfoKey: Any],
        codingPath: [CodingKey],
        parentObjectId: ObjId? = nil,
        prefetchedValue: Value? = nil
    ) {
        self.doc = doc
        self.userInfo = userInfo
        self.codingPath = codingPath
        self.parentObjectId = parentObjectId
        self.prefetchedValue = prefetchedValue
    }

    @inlinable public func decode<T: Decodable>(_: T.Type) throws -> T {
        switch T.self {
        case is AutomergeText.Type:
            let directContainer = try singleValueContainer()
            return try directContainer.decode(T.self)
        case is Counter.Type:
            let directContainer = try singleValueContainer()
            return try directContainer.decode(T.self)
        case is Data.Type:
            let directContainer = try singleValueContainer()
            return try directContainer.decode(T.self)
        case is Date.Type:
            let directContainer = try singleValueContainer()
            return try directContainer.decode(T.self)
        default:
            return try T(from: self)
        }
    }
}

extension AutomergeDecoderImpl: Decoder {

    @usableFromInline func retrieveContainerId(_ containerType: EncodingContainerType)
        -> Result<ObjId, CodingKeyLookupError>
    {
        switch (containerType, prefetchedValue) {
        case let (.Key, .Object(objectId, .Map)?), let (.Index, .Object(objectId, .List)?):
            return .success(objectId)
        default:
            return doc.retrieveObjectId(
                path: codingPath,
                containerType: containerType,
                strategy: .readonly,
                parentObjectId: parentObjectId
            )
        }
    }

    @usableFromInline func container<Key>(keyedBy _: Key.Type) throws ->
        KeyedDecodingContainer<Key> where Key: CodingKey
    {
        let result = retrieveContainerId(.Key)
        switch result {
        case let .success(objectId):
            let objectType = doc.objectType(obj: objectId)
            guard case .Map = objectType else {
                throw DecodingError.typeMismatch([String: Value].self, DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "ObjectId \(objectId) returned an type of \(objectType)."
                ))
            }

            let container = AutomergeKeyedDecodingContainer<Key>(
                impl: self,
                codingPath: codingPath,
                objectId: objectId
            )
            return KeyedDecodingContainer(container)
        case let .failure(err):
            throw err
        }
    }

    @usableFromInline func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        let result = retrieveContainerId(.Index)
        switch result {
        case let .success(objectId):
            let objectType = doc.objectType(obj: objectId)
            guard case .List = objectType else {
                throw DecodingError.typeMismatch([String: Value].self, DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "ObjectId \(objectId) returned an type of \(objectType)."
                ))
            }

            return AutomergeUnkeyedDecodingContainer(
                impl: self,
                codingPath: codingPath,
                objectId: objectId
            )
        case let .failure(err):
            throw err
        }
    }

    @usableFromInline func singleValueContainer() throws -> SingleValueDecodingContainer {
        let result = doc.retrieveObjectId(
            path: codingPath,
            containerType: .Value,
            strategy: .readonly,
            parentObjectId: parentObjectId
        )
        switch result {
        case let .success(objectId):
            guard let finalKey = codingPath.last else {
                throw CodingKeyLookupError
                    .NoPathForSingleValue("Attempting to establish a single value container with an empty coding path.")
            }
            let finalAutomergeValue: Value?
            if let prefetchedValue {
                finalAutomergeValue = prefetchedValue
            } else if let indexValue = finalKey.intValue {
                finalAutomergeValue = try doc.get(obj: objectId, index: UInt64(indexValue))
            } else {
                finalAutomergeValue = try doc.get(obj: objectId, key: finalKey.stringValue)
            }
            guard let value = finalAutomergeValue else {
                return AutomergeSingleValueDecodingContainer(
                    impl: self,
                    codingPath: codingPath,
                    automergeValue: .Scalar(.Null),
                    objectId: objectId
                )
            }
            if case let .Object(textObjectId, .Text) = finalAutomergeValue {

                let stringValue = try doc.text(obj: textObjectId)
                return AutomergeSingleValueDecodingContainer(
                    impl: self,
                    codingPath: codingPath,
                    automergeValue: .Scalar(.String(stringValue)),
                    objectId: textObjectId
                )
            } else {
                return AutomergeSingleValueDecodingContainer(
                    impl: self,
                    codingPath: codingPath,
                    automergeValue: value,
                    objectId: objectId
                )
            }

        case let .failure(err):
            throw err
        }
    }
}
