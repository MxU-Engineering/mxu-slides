import Foundation 

public enum CodingKeyLookupError: LocalizedError, Equatable {
    public static func == (lhs: CodingKeyLookupError, rhs: CodingKeyLookupError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }

    case UnexpectedLookupFailure(String)

    case InvalidPathElement(String)

    case EmptyListIndex(String)

    case IndexOutOfBounds(String)

    case InvalidValueLookup(String)

    case InvalidIndexLookup(String)

    case PathExtendsThroughText(String)

    case PathExtendsThroughScalar(String)

    case MismatchedSchema(String)

    case SchemaMissing(String)

    case NoPathForSingleValue(String)

    case AutomergeDocError(Error)

    public var errorDescription: String? {
        switch self {
        case let .UnexpectedLookupFailure(str):
            return str
        case let .InvalidPathElement(str):
            return str
        case let .EmptyListIndex(str):
            return str
        case let .IndexOutOfBounds(str):
            return str
        case let .InvalidValueLookup(str):
            return str
        case let .InvalidIndexLookup(str):
            return str
        case let .PathExtendsThroughText(str):
            return str
        case let .PathExtendsThroughScalar(str):
            return str
        case let .SchemaMissing(str):
            return str
        case let .MismatchedSchema(str):
            return str
        case let .NoPathForSingleValue(str):
            return str
        case let .AutomergeDocError(err):
            return "An underlying Automerge error: \(err.localizedDescription)"
        }
    }

    public var failureReason: String? { nil }
}
