import enum AutomergeUniffi.ScalarValue
import Foundation

typealias FFIScalar = AutomergeUniffi.ScalarValue

public enum ScalarValue: Equatable, Hashable, Sendable {

    case Bytes(Data)

    case String(String)

    case Uint(UInt64)

    case Int(Int64)

    case F64(Double)

    case Counter(Int64)

    case Timestamp(Date)

    case Boolean(Bool)

    case Unknown(typeCode: UInt8, data: Data)

    case Null

    func toFfi() -> FFIScalar {
        switch self {
        case let .Bytes(b):
            return .bytes(value: Array(b))
        case let .String(s):
            return .string(value: s)
        case let .Uint(i):
            return .uint(value: i)
        case let .Int(i):
            return .int(value: i)
        case let .F64(d):
            return .f64(value: d)
        case let .Counter(i):
            return .counter(value: i)
        case let .Timestamp(date):
            return .timestamp(value: Int64(date.timeIntervalSince1970 * 1000))
        case let .Boolean(v):
            return .boolean(value: v)
        case let .Unknown(t, d):
            return .unknown(typeCode: t, data: Array(d))
        case .Null:
            return .null
        }
    }

    static func fromFfi(value: FFIScalar) -> Self {
        switch value {
        case let .bytes(value):
            return .Bytes(Data(value))
        case let .string(value):
            return .String(value)
        case let .uint(value):
            return .Uint(value)
        case let .int(value):
            return .Int(value)
        case let .f64(value):
            return .F64(value)
        case let .counter(value):
            return .Counter(value)
        case let .timestamp(value):
            return .Timestamp(Date(timeIntervalSince1970: Double(value) / 1000))
        case let .boolean(value):
            return .Boolean(value)
        case let .unknown(typeCode, data):
            return .Unknown(typeCode: typeCode, data: Data(data))
        case .null:
            return .Null
        }
    }
}

extension ScalarValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .Boolean(boolValue):
            return "Boolean(\(boolValue))"
        case let .Bytes(data):
            var stringRep = "Data("
            if data.count > 16 {
                let first16Bytes = data[0 ..< 15]
                stringRep.append(first16Bytes.map { Swift.String(format: "%02hhx", $0) }.joined())
            } else {
                stringRep.append(data.map { Swift.String(format: "%02hhx", $0) }.joined())
            }
            return stringRep.appending(")")
        case let .String(stringVal):
            return "String(\(stringVal))"
        case let .Uint(uintVal):
            return "UInt(\(uintVal))"
        case let .Int(intValue):
            return "Int(\(intValue))"
        case let .F64(doubleValue):
            #if canImport(Darwin)
            if #available(iOS 15.0, macOS 12.0, *) {
                return "Double(\(doubleValue.formatted(.number.precision(.significantDigits(2)))))"
            } else {
                return "Double(\(doubleValue))"
            }
            #else

            return "Double(\(doubleValue))"
            #endif
        case let .Counter(intValue):
            return "Counter(\(intValue))"
        case let .Timestamp(intValue):
            return "Timestamp(\(intValue))"
        case let .Unknown(typeCode: typeCode, data: data):
            return "Unknown(type: \(typeCode), data: \(data.map { Swift.String(format: "%02hhx", $0) }.joined()))"
        case .Null:
            return "Null()"
        }
    }
}
