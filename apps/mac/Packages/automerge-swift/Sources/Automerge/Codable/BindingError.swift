import Foundation

public enum BindingError: LocalizedError, Equatable {

    case InvalidPath(String)

    case NotText

    case NotCounter

    case Unbound

    public var errorDescription: String? {
        switch self {
        case let .InvalidPath(path):
            return "Attempted to bind to an invalid path within the Automerge document: \(path)"
        case .NotText:
            return "Path location was not an Automerge Text object."
        case .NotCounter:
            return "Path location and key or index does not reference a Counter."
        case .Unbound:
            return "The object does not yet reference an Automerge Text object."
        }
    }
}
