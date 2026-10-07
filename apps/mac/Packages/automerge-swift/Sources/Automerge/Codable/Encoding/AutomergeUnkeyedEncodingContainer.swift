import Foundation 
#if canImport(os)
import os 
#endif

struct AutomergeUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let impl: AutomergeEncoderImpl
    let codingPath: [CodingKey]

    let document: Document

    let objectId: ObjId?

    let lookupError: Error?

    private(set) var count: Int = 0

    init(impl: AutomergeEncoderImpl, codingPath: [CodingKey], doc: Document) {
        self.impl = impl
        self.codingPath = codingPath
        document = doc
        switch doc.retrieveObjectId(
            path: codingPath,
            containerType: .Index,
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
                logger.debug("Established Unkeyed Encoding Container for path \(codingPath.map { AnyCodingKey($0) })")
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
                    "Encoding called on UnkeyedContainer when ObjectId is nil, and there was no recorded lookup error for the path \(codingPath)"
                )
        }
    }

    mutating func encodeNil() throws {}

    mutating func encode<T>(_ value: T) throws where T: Encodable {
        guard let objectId = objectId else {
            throw reportBestError()
        }

        switch value {
        case let url as URL:
            let valueToWrite = url.toScalarValue()
            if impl.cautiousWrite {
                try checkTypeMatch(value: valueToWrite, objectId: objectId, index: UInt64(count), type: .string)
            }
            try document.insert(obj: objectId, index: UInt64(count), value: valueToWrite)
            impl.highestUnkeyedIndexWritten = UInt64(count)
        case let date as Date:

            let valueToWrite = date.toScalarValue()
            if impl.cautiousWrite {
                try checkTypeMatch(value: valueToWrite, objectId: objectId, index: UInt64(count), type: .timestamp)
            }
            try document.insert(obj: objectId, index: UInt64(count), value: valueToWrite)
            impl.highestUnkeyedIndexWritten = UInt64(count)
        case let data as Data:

            let valueToWrite = data.toScalarValue()
            if impl.cautiousWrite {
                try checkTypeMatch(value: valueToWrite, objectId: objectId, index: UInt64(count), type: .bytes)
            }
            try document.insert(obj: objectId, index: UInt64(count), value: valueToWrite)
            impl.highestUnkeyedIndexWritten = UInt64(count)
        case let counter as Counter:

            if impl.cautiousWrite {
                try checkTypeMatch(
                    value: counter.value,
                    objectId: objectId,
                    index: UInt64(count),
                    type: .counter
                )
            }
            if counter.doc == nil || counter.objId == nil {

                if case .Scalar(.Counter) = try document.get(
                    obj: objectId,
                    index: UInt64(count)
                ) {

                    try document.increment(
                        obj: objectId,
                        index: UInt64(count),
                        by: Int64(counter._unboundStorage)
                    )
                } else {

                    try document.insert(
                        obj: objectId,
                        index: UInt64(count),
                        value: .Counter(Int64(counter._unboundStorage))
                    )
                }
            } else {
                if case let .Scalar(.Counter(currentCounterValue)) = try document.get(
                    obj: objectId,
                    index: UInt64(count)
                ) {
                    let counterDifference = currentCounterValue - Int64(counter._unboundStorage)
                    try document.increment(obj: objectId, index: UInt64(count), by: counterDifference)
                } else {
                    try document.insert(
                        obj: objectId,
                        index: UInt64(count),
                        value: .Counter(Int64(counter._unboundStorage))
                    )
                }
            }
            impl.highestUnkeyedIndexWritten = UInt64(count)
        case let text as AutomergeText:

            let textNodeId: ObjId
            if let existingNode = try document.get(obj: objectId, index: UInt64(count)) {
                guard case let .Object(textId, .Text) = existingNode else {
                    throw CodingKeyLookupError
                        .MismatchedSchema(
                            "Text Encoding on KeyedContainer at \(codingPath) exists and is \(existingNode), not Text."
                        )
                }
                textNodeId = textId
                try text.bind(doc: document, id: textNodeId)
            } else {
                textNodeId = try document.insertObject(obj: objectId, index: UInt64(count), ty: .Text)
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
            impl.highestUnkeyedIndexWritten = UInt64(count)
        default:
            let newPath = impl.codingPath + [AnyCodingKey(UInt64(count))]
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
            impl.highestUnkeyedIndexWritten = UInt64(count)
        }
        count += 1
    }

    fileprivate func checkTypeMatch<T>(value: T, objectId: ObjId, index: UInt64, type: TypeOfAutomergeValue) throws {
        if let testCurrentValue = try document.get(obj: objectId, index: index),
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

    mutating func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type) ->
        KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey
    {
        let newPath = impl.codingPath + [AnyCodingKey(UInt64(count))]
        let nestedContainer = AutomergeKeyedEncodingContainer<NestedKey>(
            impl: impl,
            codingPath: newPath,
            doc: document
        )
        return KeyedEncodingContainer(nestedContainer)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let newPath = impl.codingPath + [AnyCodingKey(UInt64(count))]
        let nestedContainer = AutomergeUnkeyedEncodingContainer(
            impl: impl,
            codingPath: newPath,
            doc: document
        )
        return nestedContainer
    }

    mutating func superEncoder() -> Encoder {
        preconditionFailure()
    }
}
