import Foundation 
#if canImport(os)
import os 
#endif

struct AutomergeKeyedEncodingContainer<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K

    let impl: AutomergeEncoderImpl

    let codingPath: [CodingKey]

    let document: Document

    let objectId: ObjId?

    let lookupError: Error?

    init(impl: AutomergeEncoderImpl, codingPath: [CodingKey], doc: Document) {
        self.impl = impl
        self.codingPath = codingPath
        document = doc
        switch doc.retrieveObjectId(
            path: codingPath,
            containerType: .Key,
            strategy: impl.schemaStrategy
        ) {
        case let .success(objId):
            objectId = objId
            impl.objectIdForContainer = objId
            lookupError = nil
        case let .failure(capturedError):
            objectId = nil
            lookupError = capturedError
        }
        #if canImport(os)
        if #available(macOS 11, iOS 14, *) {
            let logger = Logger(subsystem: "Automerge", category: "AutomergeEncoder")
            if impl.reportingLogLevel >= LogVerbosity.debug {
                logger.debug("Establishing Keyed Encoding Container for path \(codingPath.map { AnyCodingKey($0) })")
            }
        }
        #endif
    }

    fileprivate func reportBestError() -> Error {

        if let containerLookupError = lookupError {
            return containerLookupError
        } else {

            return CodingKeyLookupError
                .UnexpectedLookupFailure(
                    "Encoding called on KeyedContainer when ObjectId is nil, and there was no recorded lookup error for the path \(codingPath)"
                )
        }
    }

    fileprivate func checkTypeMatch<T>(value: T, objectId: ObjId, key: Self.Key, type: TypeOfAutomergeValue) throws {
        if let testCurrentValue = try document.get(obj: objectId, key: key.stringValue),
           TypeOfAutomergeValue.from(testCurrentValue) != type
        {

            throw EncodingError.invalidValue(
                value,
                EncodingError
                    .Context(
                        codingPath: codingPath,
                        debugDescription: "The type in the automerge document (\(TypeOfAutomergeValue.from(testCurrentValue))) doesn't match the type being written (\(type))"
                    )
            )
        }
    }

    mutating func encodeNil(forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        try document.put(obj: objectId, key: key.stringValue, value: .Null)
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Bool, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .bool)
        }
        try document.put(obj: objectId, key: key.stringValue, value: .Boolean(value))
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: String, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .string)
        }
        try document.put(obj: objectId, key: key.stringValue, value: .String(value))
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Double, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        guard !value.isNaN, !value.isInfinite else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: codingPath + [key],
                debugDescription: "Unable to encode Double.\(value) at \(codingPath) into an Automerge F64."
            ))
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .double)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Float, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        guard !value.isNaN, !value.isInfinite else {
            throw EncodingError.invalidValue(value, .init(
                codingPath: codingPath + [key],
                debugDescription: "Unable to encode Float.\(value) directly in JSON."
            ))
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .double)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Int, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .int)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Int8, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .int)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Int16, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .int)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Int32, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .int)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: Int64, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .int)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: UInt, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: UInt8, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: UInt16, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: UInt32, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode(_ value: UInt64, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        if impl.cautiousWrite {
            try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
        }
        try document.put(obj: objectId, key: key.stringValue, value: value.toScalarValue())
        impl.mapKeysWritten.append(key.stringValue)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Self.Key) throws {
        guard let objectId = objectId else {
            throw reportBestError()
        }
        let newPath = impl.codingPath + [key]

        switch value {
        case let date as Date:

            if impl.cautiousWrite {
                try checkTypeMatch(value: value, objectId: objectId, key: key, type: .timestamp)
            }
            try document.put(obj: objectId, key: key.stringValue, value: date.toScalarValue())
            impl.mapKeysWritten.append(key.stringValue)
        case let data as Data:

            if impl.cautiousWrite {
                try checkTypeMatch(value: value, objectId: objectId, key: key, type: .bytes)
            }
            try document.put(obj: objectId, key: key.stringValue, value: data.toScalarValue())
            impl.mapKeysWritten.append(key.stringValue)
        case let counter as Counter:

            if impl.cautiousWrite {
                try checkTypeMatch(value: value, objectId: objectId, key: key, type: .counter)
            }
            if counter.doc == nil || counter.objId == nil {

                if case let .Scalar(.Counter(currentCounterValue)) = try document.get(
                    obj: objectId,
                    key: key.stringValue
                ) {
                    let counterDifference = currentCounterValue - Int64(counter._unboundStorage)
                    try document.increment(obj: objectId, key: key.stringValue, by: counterDifference)
                } else {
                    try document.put(
                        obj: objectId,
                        key: key.stringValue,
                        value: .Counter(Int64(counter._unboundStorage))
                    )
                }
            }
            impl.mapKeysWritten.append(key.stringValue)
        case let text as AutomergeText:

            let textNodeId: ObjId
            if let existingNode = try document.get(obj: objectId, key: key.stringValue) {
                guard case let .Object(textId, .Text) = existingNode else {
                    throw CodingKeyLookupError
                        .MismatchedSchema(
                            "Text Encoding on KeyedContainer at \(codingPath) exists and is \(existingNode), not Text."
                        )
                }
                textNodeId = textId
                try text.bind(doc: document, id: textNodeId)
            } else {
                textNodeId = try document.putObject(obj: objectId, key: key.stringValue, ty: .Text)
                try text.bind(doc: document, id: textNodeId)
            }

            if text.doc == nil || text.objId == nil {

                if !text._unboundStorage.isEmpty {

                    let currentText = try document.text(obj: textNodeId)
                    if currentText != text._unboundStorage {
                        try document.updateText(obj: textNodeId, value: text._unboundStorage)
                    }
                }
            }
            impl.mapKeysWritten.append(key.stringValue)
        case let url as URL:
            if impl.cautiousWrite {
                try checkTypeMatch(value: value, objectId: objectId, key: key, type: .uint)
            }
            try document.put(obj: objectId, key: key.stringValue, value: url.toScalarValue())
            impl.mapKeysWritten.append(key.stringValue)
        default:
            let newEncoder = AutomergeEncoderImpl(
                userInfo: impl.userInfo,
                codingPath: newPath,
                doc: document,
                strategy: impl.schemaStrategy,
                cautiousWrite: impl.cautiousWrite,
                logLevel: impl.reportingLogLevel
            )

            impl.childEncoders.append(newEncoder)

            try value.encode(to: newEncoder)
            impl.mapKeysWritten.append(key.stringValue)
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type, forKey key: Self.Key) ->
        KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey
    {
        let newPath = impl.codingPath + [key]
        let nestedContainer = AutomergeKeyedEncodingContainer<NestedKey>(
            impl: impl,
            codingPath: newPath,
            doc: document
        )
        return KeyedEncodingContainer(nestedContainer)
    }

    mutating func nestedUnkeyedContainer(forKey key: Self.Key) -> UnkeyedEncodingContainer {
        let newPath = impl.codingPath + [key]
        let nestedContainer = AutomergeUnkeyedEncodingContainer(
            impl: impl,
            codingPath: newPath,
            doc: document
        )
        return nestedContainer
    }

    mutating func superEncoder() -> Encoder {
        impl
    }

    mutating func superEncoder(forKey _: Self.Key) -> Encoder {
        impl
    }
}
