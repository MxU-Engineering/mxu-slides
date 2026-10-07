import Foundation

public protocol ScalarValueRepresentable {

    associatedtype ConvertError: LocalizedError

    static func fromScalarValue(_ val: ScalarValue) -> Result<Self, ConvertError>

    func toScalarValue() -> ScalarValue
}

public enum ScalarValueConversionError: LocalizedError {}

extension ScalarValue: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<ScalarValue, ScalarValueConversionError> {
        .success(val)
    }

    public func toScalarValue() -> ScalarValue {
        self
    }
}

public enum BooleanScalarConversionError: LocalizedError {
    case notboolScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notboolScalarValue(val):
            return "Failed to read the scalar value \(val) as a Boolean."
        }
    }

    public var failureReason: String? { nil }
}

extension Bool: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Bool, BooleanScalarConversionError> {
        switch val {
        case let .Boolean(b):
            return .success(b)
        default:
            return .failure(.notboolScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Boolean(self)
    }
}

public enum URLScalarConversionError: LocalizedError {
    case notStringScalarValue(_ val: ScalarValue)
    case notMatchingURLScheme(String)

    public var errorDescription: String? {
        switch self {
        case let .notStringScalarValue(scalarValue):
            return "Failed to read the scalar value \(scalarValue) as a String before converting to URL."
        case let .notMatchingURLScheme(string):
            return "Failed to convert the string \(string) to URL."
        }
    }

    public var failureReason: String? { nil }
}

extension URL: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<URL, URLScalarConversionError> {
        switch val {
        case let .String(urlString):
            if let url = URL(string: urlString) {
                return .success(url)
            } else {
                return .failure(.notMatchingURLScheme(urlString))
            }
        default:
            return .failure(.notStringScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .String(absoluteString)
    }
}

public enum StringScalarConversionError: LocalizedError {
    case notstringScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notstringScalarValue(val):
            return "Failed to read the scalar value \(val) as a String."
        }
    }

    public var failureReason: String? { nil }
}

extension String: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<String, StringScalarConversionError> {
        switch val {
        case let .String(s):
            return .success(s)
        default:
            return .failure(.notstringScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .String(self)
    }
}

public enum BytesScalarConversionError: LocalizedError {
    case notbytesScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notbytesScalarValue(val):
            return "Failed to read the scalar value \(val) as a bytes."
        }
    }

    public var failureReason: String? { nil }
}

extension Data: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Data, BytesScalarConversionError> {
        switch val {
        case let .Bytes(d):
            return .success(d)
        default:
            return .failure(BytesScalarConversionError.notbytesScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Bytes(self)
    }
}

public enum UIntScalarConversionError: LocalizedError {
    case notUIntScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notUIntScalarValue(val):
            return "Failed to read the scalar value \(val) as an unsigned integer."
        }
    }

    public var failureReason: String? { nil }
}

extension UInt: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<UInt, UIntScalarConversionError> {
        switch val {
        case let .Uint(d):
            return .success(UInt(d))
        default:
            return .failure(UIntScalarConversionError.notUIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Uint(UInt64(self))
    }
}

public enum IntScalarConversionError: LocalizedError {
    case notIntScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notIntScalarValue(val):
            return "Failed to read the scalar value \(val) as a signed integer."
        }
    }

    public var failureReason: String? { nil }
}

extension Int: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Int, IntScalarConversionError> {
        switch val {
        case let .Int(d):
            return .success(Int(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Int(Int64(self))
    }
}

extension Int8: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Int8, IntScalarConversionError> {
        switch val {
        case let .Int(d):
            return .success(Int8(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Int(Int64(self))
    }
}

extension Int16: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Int16, IntScalarConversionError> {
        switch val {
        case let .Int(d):
            return .success(Int16(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Int(Int64(self))
    }
}

extension Int32: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Int32, IntScalarConversionError> {
        switch val {
        case let .Int(d):
            return .success(Int32(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Int(Int64(self))
    }
}

extension Int64: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Int64, IntScalarConversionError> {
        switch val {
        case let .Int(d):
            return .success(Int64(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Int(Int64(self))
    }
}

extension UInt8: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<UInt8, IntScalarConversionError> {
        switch val {
        case let .Uint(d):
            return .success(UInt8(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Uint(UInt64(self))
    }
}

extension UInt16: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<UInt16, IntScalarConversionError> {
        switch val {
        case let .Uint(d):
            return .success(UInt16(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Uint(UInt64(self))
    }
}

extension UInt32: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<UInt32, IntScalarConversionError> {
        switch val {
        case let .Uint(d):
            return .success(UInt32(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Uint(UInt64(self))
    }
}

extension UInt64: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<UInt64, IntScalarConversionError> {
        switch val {
        case let .Uint(d):
            return .success(UInt64(d))
        default:
            return .failure(IntScalarConversionError.notIntScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Uint(self)
    }
}

public enum FloatingPointScalarConversionError: LocalizedError {
    case notF64ScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notF64ScalarValue(val):
            return "Failed to read the scalar value \(val) as a 64-bit floating-point value."
        }
    }

    public var failureReason: String? { nil }
}

extension Double: ScalarValueRepresentable {
    public typealias ConvertError = FloatingPointScalarConversionError

    public static func fromScalarValue(_ val: ScalarValue) -> Result<Double, FloatingPointScalarConversionError> {
        switch val {
        case let .F64(d):
            return .success(Double(d))
        default:
            return .failure(FloatingPointScalarConversionError.notF64ScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .F64(self)
    }
}

extension Float: ScalarValueRepresentable {
    public typealias ConvertError = FloatingPointScalarConversionError

    public static func fromScalarValue(_ val: ScalarValue) -> Result<Float, FloatingPointScalarConversionError> {
        switch val {
        case let .F64(d):
            return .success(Float(d))
        default:
            return .failure(FloatingPointScalarConversionError.notF64ScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .F64(Double(self))
    }
}

public enum TimestampScalarConversionError: LocalizedError {
    case notTimetampScalarValue(_ val: ScalarValue)

    public var errorDescription: String? {
        switch self {
        case let .notTimetampScalarValue(val):
            return "Failed to read the scalar value \(val) as a timestamp value."
        }
    }

    public var failureReason: String? { nil }
}

extension Date: ScalarValueRepresentable {
    public static func fromScalarValue(_ val: ScalarValue) -> Result<Date, TimestampScalarConversionError> {
        switch val {
        case let .Timestamp(d):
            return .success(d)
        default:
            return .failure(.notTimetampScalarValue(val))
        }
    }

    public func toScalarValue() -> ScalarValue {
        .Timestamp(self)
    }
}
