enum TypeOfAutomergeValue: Equatable, Hashable {

    case array

    case object

    case text

    case bytes

    case string

    case uint

    case int

    case double

    case counter

    case timestamp

    case bool

    case unknown(UInt8)

    case null

    static func from(_ val: Value) -> Self {
        switch val {
        case let .Object(_, objType):
            switch objType {
            case .List:
                return .array
            case .Map:
                return .object
            case .Text:
                return .text
            }
        case let .Scalar(scalarValue):
            switch scalarValue {
            case .Boolean:
                return .bool
            case .Bytes:
                return .bytes
            case .String:
                return .string
            case .Uint:
                return .uint
            case .Int:
                return .int
            case .F64:
                return .double
            case .Counter:
                return .counter
            case .Timestamp:
                return .timestamp
            case let .Unknown(type, _):
                return .unknown(type)
            case .Null:
                return .null
            }
        }
    }

    static func from(_ val: ScalarValue) -> Self {
        switch val {
        case .Boolean:
            return .bool
        case .Bytes:
            return .bytes
        case .String:
            return .string
        case .Uint:
            return .uint
        case .Int:
            return .int
        case .F64:
            return .double
        case .Counter:
            return .counter
        case .Timestamp:
            return .timestamp
        case let .Unknown(type, _):
            return .unknown(type)
        case .Null:
            return .null
        }
    }
}
