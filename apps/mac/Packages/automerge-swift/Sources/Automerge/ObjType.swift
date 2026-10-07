import enum AutomergeUniffi.ObjType

typealias FfiObjtype = AutomergeUniffi.ObjType

public enum ObjType: Sendable {

    case Map

    case List

    case Text

    func toFfi() -> FfiObjtype {
        switch self {
        case .Map:
            return FfiObjtype.map
        case .List:
            return FfiObjtype.list
        case .Text:
            return FfiObjtype.text
        }
    }

    static func fromFfi(ty: FfiObjtype) -> Self {
        switch ty {
        case .map:
            return .Map
        case .list:
            return .List
        case .text:
            return .Text
        }
    }
}

extension ObjType: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .List: return "List"
        case .Map: return "Map"
        case .Text: return "Text"
        }
    }
}
