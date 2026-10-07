import Foundation

struct AutomergeKeyedDecodingContainer<K: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = K

    let impl: AutomergeDecoderImpl
    let codingPath: [CodingKey]
    let objectId: ObjId
    let keys: [String]

    private var prefetched: (key: String, value: Value)?

    private let entries: [String: Value]?

    init(impl: AutomergeDecoderImpl, codingPath: [CodingKey], objectId: ObjId) {
        self.impl = impl
        self.codingPath = codingPath
        self.objectId = objectId
        if let mapEntries = try? impl.doc.mapEntries(obj: objectId) {
            keys = mapEntries.map(\.0)
            entries = Dictionary(mapEntries, uniquingKeysWith: { first, _ in first })
        } else {
            keys = impl.doc.keys(obj: objectId)
            entries = nil
        }
    }

    private func pathWithKey(_ key: K) -> String {

        var basePath = codingPath.map { AnyCodingKey($0) }
        basePath.append(AnyCodingKey(key))
        return basePath.stringPath()
    }

    var allKeys: [K] {
        keys.compactMap { K(stringValue: $0) }
    }

    func contains(_ key: K) -> Bool {
        keys.contains(key.stringValue)
    }

    func decodeNil(forKey key: K) throws -> Bool {
        let value = try getValue(forKey: key)
        return value == .Scalar(.Null)
    }

    func decode(_ type: Bool.Type, forKey key: K) throws -> Bool {
        let value = try getValue(forKey: key)

        guard case let .Scalar(.Boolean(bool)) = value else {
            throw createTypeMismatchError(type: type, forKey: key, value: value)
        }

        return bool
    }

    func decode(_ type: String.Type, forKey key: K) throws -> String {
        let value = try getValue(forKey: key)

        guard case let .Scalar(.String(string)) = value else {
            throw createTypeMismatchError(type: type, forKey: key, value: value)
        }

        return string
    }

    func decode(_: Double.Type, forKey key: K) throws -> Double {
        try decodeLosslessStringConvertible(key: key)
    }

    func decode(_: Float.Type, forKey key: K) throws -> Float {
        try decodeLosslessStringConvertible(key: key)
    }

    func decode(_: Int.Type, forKey key: K) throws -> Int {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: Int8.Type, forKey key: K) throws -> Int8 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: Int16.Type, forKey key: K) throws -> Int16 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: Int32.Type, forKey key: K) throws -> Int32 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: Int64.Type, forKey key: K) throws -> Int64 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: UInt.Type, forKey key: K) throws -> UInt {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: UInt8.Type, forKey key: K) throws -> UInt8 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: UInt16.Type, forKey key: K) throws -> UInt16 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: UInt32.Type, forKey key: K) throws -> UInt32 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode(_: UInt64.Type, forKey key: K) throws -> UInt64 {
        try decodeFixedWidthInteger(key: key)
    }

    func decode<S>(_: S.Type, forKey key: K) throws -> S where S: ScalarValueRepresentable {
        let value = try getValue(forKey: key)
        switch value {
        case let .Scalar(scalarValue):
            let conversionResult = S.fromScalarValue(scalarValue)
            switch conversionResult {
            case let .success(success):
                return success
            case let .failure(failure):
                throw DecodingError.typeMismatch(S.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(S.self) from key \(key) but found \(value) instead.",
                    underlyingError: failure
                ))
            }
        default:
            throw createTypeMismatchError(type: S.self, forKey: key, value: value)
        }
    }

    func decode<T>(_: T.Type, forKey key: K) throws -> T where T: Decodable {
        switch T.self {
        case is Date.Type:
            let retrievedValue = try getValue(forKey: key)
            if case let Value.Scalar(.Timestamp(date)) = retrievedValue {
                return date as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.timestamp`."
                ))
            }
        case is Data.Type:
            let retrievedValue = try getValue(forKey: key)
            if case let Value.Scalar(.Bytes(data)) = retrievedValue {
                return data as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.data`."
                ))
            }
        case is Counter.Type:
            let retrievedValue = try getValue(forKey: key)
            if case Value.Scalar(.Counter) = retrievedValue {
                return try Counter(doc: impl.doc, objId: objectId, key: AnyCodingKey(key)) as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.counter`."
                ))
            }
        case is AutomergeText.Type:
            let retrievedValue = try getValue(forKey: key)
            if case let Value.Object(objectId, .Text) = retrievedValue {
                let reference = try AutomergeText(doc: impl.doc, objId: objectId)
                return reference as! T
            } else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(T.self) from \(retrievedValue), but it wasn't a `.text` object."
                ))
            }
        case is URL.Type:
            let retrievedValue = try getValue(forKey: key)
            guard case let .Scalar(.String(urlString)) = retrievedValue, let url = URL(string: urlString) else {
                throw DecodingError.typeMismatch(T.self, .init(
                    codingPath: codingPath,
                    debugDescription: "Expected to decode \(URL.self) from \(retrievedValue), but it wasn't a `URL` type."
                ))
            }

            return url as! T
        default:
            let decoder = try decoderForKey(key)
            return try T(from: decoder)
        }
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: K) throws -> Bool? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: String.Type, forKey key: K) throws -> String? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Double.Type, forKey key: K) throws -> Double? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Float.Type, forKey key: K) throws -> Float? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Int.Type, forKey key: K) throws -> Int? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Int8.Type, forKey key: K) throws -> Int8? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Int16.Type, forKey key: K) throws -> Int16? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Int32.Type, forKey key: K) throws -> Int32? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: Int64.Type, forKey key: K) throws -> Int64? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: UInt.Type, forKey key: K) throws -> UInt? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: UInt8.Type, forKey key: K) throws -> UInt8? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: UInt16.Type, forKey key: K) throws -> UInt16? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: UInt32.Type, forKey key: K) throws -> UInt32? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent(_ type: UInt64.Type, forKey key: K) throws -> UInt64? {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func decodeIfPresent<T>(_ type: T.Type, forKey key: K) throws -> T? where T: Decodable {
        try decodeOnceIfPresent(forKey: key) { try $0.decode(type, forKey: key) }
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: K) throws
        -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey
    {
        try decoderForKey(key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: K) throws -> UnkeyedDecodingContainer {
        try decoderForKey(key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        impl
    }

    func superDecoder(forKey _: K) throws -> Decoder {
        impl
    }
}

extension AutomergeKeyedDecodingContainer {
    private func decoderForKey(_ key: K) throws -> AutomergeDecoderImpl {
        var newPath = codingPath
        newPath.append(key)

        var prefetchedValue: Value?
        if key.intValue == nil {
            prefetchedValue = heldValue(forKey: key)
        }
        return AutomergeDecoderImpl(
            doc: impl.doc,
            userInfo: impl.userInfo,
            codingPath: newPath,
            parentObjectId: objectId,
            prefetchedValue: prefetchedValue
        )
    }

    private func decodeOnceIfPresent<T>(forKey key: K, _ decode: (Self) throws -> T) throws -> T? {
        if contains(key) {
            let value = try getValue(forKey: key)
            if value != .Scalar(.Null) {
                var container = self
                container.prefetched = (key.stringValue, value)
                return try decode(container)
            }
        }
        return nil
    }

    @inline(__always) private func heldValue(forKey key: K) -> Value? {
        if let prefetched, prefetched.key == key.stringValue {
            return prefetched.value
        }
        return entries?[key.stringValue]
    }

    @inline(__always) private func getValue(forKey key: K) throws -> Value {
        guard let value = try heldValue(forKey: key) ?? impl.doc.get(obj: objectId, key: key.stringValue) else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath,
                debugDescription: "No value associated with key \(key) (\"\(key.stringValue)\")."
            ))
        }
        return value
    }

    @inline(__always) private func createTypeMismatchError(type: Any.Type, forKey key: K, value: Value) ->
        DecodingError
    {
        let codingPath = codingPath + [key]
        return DecodingError.typeMismatch(type, .init(
            codingPath: codingPath,
            debugDescription: "Expected to decode \(type) but found \(value) instead."
        ))
    }

    @inline(__always) private func decodeFixedWidthInteger<T: FixedWidthInteger>(key: Self.Key) throws -> T {
        let value = try getValue(forKey: key)

        guard case let .Scalar(scalar) = value else {
            throw createTypeMismatchError(type: T.self, forKey: key, value: value)
        }
        switch scalar {
        case let .Int(intValue):
            return T(intValue)
        case let .Uint(intValue):
            return T(intValue)
        default:
            throw createTypeMismatchError(type: T.self, forKey: key, value: value)
        }
    }

    @inline(__always) private func decodeLosslessStringConvertible<T: LosslessStringConvertible>(
        key: Self.Key
    ) throws -> T {
        let value = try getValue(forKey: key)

        let description: String
        switch value {
        case let .Scalar(.F64(number)):
            description = number.description
        case let .Scalar(.Int(number)):
            description = number.description
        default:
            throw createTypeMismatchError(type: T.self, forKey: key, value: value)
        }

        guard let floatingPoint = T(description) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Parsed Automerge number <\(description)> does not fit in \(T.self)."
            )
        }

        return floatingPoint
    }
}
