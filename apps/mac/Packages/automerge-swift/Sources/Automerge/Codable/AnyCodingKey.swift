import Foundation 

public struct AnyCodingKey: Equatable {
    private let pathElement: Automerge.Prop

    public init(_ pathProperty: Automerge.Prop) {
        pathElement = pathProperty
    }

    public init(_ element: Automerge.PathElement) {
        pathElement = element.prop
    }

    public init(_ key: some CodingKey) {
        if let intValue = key.intValue {
            pathElement = .Index(UInt64(intValue))
        } else {
            pathElement = .Key(key.stringValue)
        }
    }

    public init(_ stringVal: String) {
        pathElement = .Key(stringVal)
    }

    public init(_ intValue: UInt64) {
        pathElement = .Index(intValue)
    }

    public static let ROOT = AnyCodingKey(.Key(""))
}

extension AnyCodingKey: CodingKey {

    public init?(intValue: Int) {
        if intValue < 0 {
            preconditionFailure("Schema index positions can't be negative")
        }
        pathElement = Automerge.Prop.Index(UInt64(intValue))
    }

    public init?(stringValue: String) {
        pathElement = Automerge.Prop.Key(stringValue)
    }

    public var stringValue: String {
        if case let .Key(stringVal) = pathElement {
            return stringVal
        }
        preconditionFailure("Invalid string value from CodingKey that is an index \(pathElement)")
    }

    public var intValue: Int? {
        if case let .Index(intValue) = pathElement {
            return Int(intValue)
        }
        return nil
    }
}

public enum PathParseError: LocalizedError {

    case InvalidPathElement(String)

    case EmptyListIndex(String)

    public var errorDescription: String? {
        switch self {
        case let .InvalidPathElement(str):
            return str
        case let .EmptyListIndex(str):
            return str
        }
    }
}

public extension AnyCodingKey {

    static func parsePath(_ path: String) throws -> [AnyCodingKey] {

        try path
            .split(separator: ".")
            .map { String($0) }
            .map { strValue in
                if let firstChar = strValue.first, firstChar.isASCII, firstChar.isLetter {
                    return AnyCodingKey(strValue)
                } else if strValue.first == "[", strValue.last == "]" {
                    let start = strValue.index(after: strValue.startIndex)
                    let end = strValue.index(before: strValue.endIndex)
                    let substring = String(strValue[start ..< end])
                    if !substring.isEmpty, let parsedIndexValue = UInt64(substring) {
                        return AnyCodingKey(parsedIndexValue)
                    } else {
                        throw PathParseError.EmptyListIndex(String(strValue))
                    }
                }
                throw PathParseError.InvalidPathElement(String(strValue))
            }
    }
}

extension AnyCodingKey: CustomStringConvertible {

    public var description: String {
        switch pathElement {
        case let .Index(uintVal):
            return "[\(uintVal)]"
        case let .Key(strVal):
            return strVal
        }
    }
}

extension AnyCodingKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch pathElement {
        case let .Index(intVal):
            hasher.combine(intVal)
        case let .Key(strVal):
            hasher.combine(strVal)
        }
    }
}

public extension Sequence where Element == any CodingKey {

    func stringPath() -> String {
        let path = map { pathElement in
            AnyCodingKey(pathElement).description
        }
        .joined(separator: ".")
        return ".\(path)"
    }
}

public extension Sequence where Element == AnyCodingKey {

    func stringPath() -> String {
        let path = map { pathElement in
            pathElement.description
        }
        .joined(separator: ".")
        return ".\(path)"
    }
}
