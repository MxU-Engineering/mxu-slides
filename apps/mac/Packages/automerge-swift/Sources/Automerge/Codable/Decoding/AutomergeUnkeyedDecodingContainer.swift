import Foundation

struct AutomergeUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let impl: AutomergeDecoderImpl
    let codingPath: [CodingKey]
    let objectId: ObjId

    var count: Int?
    var isAtEnd: Bool { currentIndex >= (count ?? 0) }
    var currentIndex = 0

    private let elements: [Value]?

    init(impl: AutomergeDecoderImpl, codingPath: [CodingKey], objectId: ObjId) {
        self.impl = impl
        self.codingPath = codingPath
        self.objectId = objectId
        let count = Int(impl.doc.length(obj: objectId))
        self.count = count
        if let values = try? impl.doc.values(obj: objectId), values.count == count {
            elements = values
        } else {
            elements = nil
        }
    }

    mutating func decodeNil() throws -> Bool {
        if try getNextValue(ofType: Never.self) == .Scalar(.Null) {
            currentIndex += 1
            return true
        }

        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let value = try getNextValue(ofType: Bool.self)
        guard case let .Scalar(.Boolean(bool)) = value else {
            throw createTypeMismatchError(type: type, value: value)
        }

        currentIndex += 1
        return bool
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let value = try getNextValue(ofType: String.self)
        guard case let .Scalar(.String(string)) = value else {
            throw createTypeMismatchError(type: type, value: value)
        }

        currentIndex += 1
        return string
    }

    mutating func decode(_: Double.Type) throws -> Double {
        try decodeBinaryFloatingPoint()
    }

    mutating func decode(_: Float.Type) throws -> Float {
        try decodeBinaryFloatingPoint()
    }

    mutating func decode(_: Int.Type) throws -> Int {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: Int8.Type) throws -> Int8 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: Int16.Type) throws -> Int16 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: Int32.Type) throws -> Int32 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: Int64.Type) throws -> Int64 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: UInt.Type) throws -> UInt {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: UInt8.Type) throws -> UInt8 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: UInt16.Type) throws -> UInt16 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: UInt32.Type) throws -> UInt32 {
        try decodeFixedWidthInteger()
    }

    mutating func decode(_: UInt64.Type) throws -> UInt64 {
        try decodeFixedWidthInteger()
    }

    mutating func decode<S>(_: S.Type) throws -> S where S: ScalarValueRepresentable {
        let value = try getNextValue(ofType: S.self)

        switch value {
        case let .Scalar(scalarValue):
            let conversionResult = S.fromScalarValue(scalarValue)
            switch conversionResult {
            case let .success(success):
                currentIndex += 1
                return success
            case let .failure(failure):
                throw DecodingError.typeMismatch(S.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(S.self) but found \(value) instead.",
                    underlyingError: failure
                ))
            }
        default:
            throw createTypeMismatchError(type: S.self, value: value)
        }
    }

    mutating func decode<T>(_: T.Type) throws -> T where T: Decodable {
        switch T.self {
        case is URL.Type:
            let retrievedValue = try getNextValue(ofType: URL.self)
            if case let Value.Scalar(.String(urlString)) = retrievedValue, let url = URL(string: urlString) {
                currentIndex += 1
                return url as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.timestamp`."
                ))
            }
        case is Date.Type:
            let retrievedValue = try getNextValue(ofType: Date.self)
            if case let Value.Scalar(.Timestamp(date)) = retrievedValue {
                currentIndex += 1
                return date as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.timestamp`."
                ))
            }
        case is Data.Type:
            let retrievedValue = try getNextValue(ofType: Data.self)
            if case let Value.Scalar(.Bytes(data)) = retrievedValue {
                currentIndex += 1
                return data as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.data`."
                ))
            }
        case is Counter.Type:
            let retrievedValue = try getNextValue(ofType: Counter.self)
            if case Value.Scalar(.Counter) = retrievedValue {
                let counterReference = try Counter(
                    doc: impl.doc,
                    objId: objectId,
                    key: AnyCodingKey(UInt64(currentIndex))
                )
                currentIndex += 1
                return counterReference as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.counter`."
                ))
            }
        case is AutomergeText.Type:
            let retrievedValue = try getNextValue(ofType: AutomergeText.self)
            if case let Value.Object(objectId, .Text) = retrievedValue {
                currentIndex += 1
                let reference = try AutomergeText(doc: impl.doc, objId: objectId)
                return reference as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.text` object."
                ))
            }
        default:
            let decoder = try decoderForNextElement(ofType: T.self)
            let result = try T(from: decoder)

            currentIndex += 1
            return result
        }
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey
    {
        let decoder = try decoderForNextElement(ofType: KeyedDecodingContainer<NestedKey>.self, isNested: true)
        let container = try decoder.container(keyedBy: type)

        currentIndex += 1
        return container
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let decoder = try decoderForNextElement(ofType: UnkeyedDecodingContainer.self, isNested: true)
        let container = try decoder.unkeyedContainer()

        currentIndex += 1
        return container
    }

    mutating func superDecoder() throws -> Decoder {
        impl
    }
}

extension AutomergeUnkeyedDecodingContainer {
    private mutating func decoderForNextElement<T>(
        ofType _: T.Type,
        isNested _: Bool = false
    ) throws -> AutomergeDecoderImpl {
        let newPath = codingPath + [AnyCodingKey(UInt64(currentIndex))]

        var prefetchedValue: Value?
        if let elements, currentIndex < elements.count {
            prefetchedValue = elements[currentIndex]
        }
        return AutomergeDecoderImpl(
            doc: impl.doc,
            userInfo: impl.userInfo,
            codingPath: newPath,
            parentObjectId: objectId,
            prefetchedValue: prefetchedValue
        )
    }

    @inline(__always)
    private func getNextValue<T>(ofType _: T.Type) throws -> Value {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                T.self,
                .init(
                    codingPath: [AnyCodingKey(UInt64(currentIndex))],
                    debugDescription: "Unkeyed container is at end.",
                    underlyingError: nil
                )
            )
        }
        if let elements, currentIndex < elements.count {
            return elements[currentIndex]
        } else if let value = try impl.doc.get(obj: objectId, index: UInt64(currentIndex)) {
            return value
        } else {
            throw DecodingError.valueNotFound(
                T.self,
                .init(
                    codingPath: codingPath,
                    debugDescription: "Cannot get nested keyed container -- unkeyed container is at end.",
                    underlyingError: nil
                )
            )
        }
    }

    @inline(__always) private func createTypeMismatchError(type: Any.Type, value: Value) -> DecodingError {
        let codingPath = codingPath + [AnyCodingKey(UInt64(currentIndex))]
        return DecodingError.typeMismatch(type, .init(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(type) but found \(value) instead."
        ))
    }

    @inline(__always) private mutating func decodeFixedWidthInteger<T: FixedWidthInteger>() throws -> T {
        let value = try getNextValue(ofType: T.self)

        switch value {
        case let .Scalar(.Int(intValue)):
            let integer = T(intValue)
            currentIndex += 1
            return integer
        case let .Scalar(.Uint(intValue)):
            let integer = T(intValue)
            currentIndex += 1
            return integer
        default:
            throw createTypeMismatchError(type: T.self, value: value)
        }
    }

    @inline(__always) private mutating func decodeBinaryFloatingPoint<T: LosslessStringConvertible>() throws -> T {
        let value = try getNextValue(ofType: T.self)
        guard case let .Scalar(.F64(double)) = value else {
            throw createTypeMismatchError(type: T.self, value: value)
        }

        guard let float = T(double.description) else {
            throw DecodingError.dataCorruptedError(
                in: self,
                debugDescription: "Parsed Automerge floating point value <\(double)> does not fit in \(T.self)."
            )
        }

        currentIndex += 1
        return float
    }
}
