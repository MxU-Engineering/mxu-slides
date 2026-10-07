import Foundation

extension XMLElement {

    func children(local name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    func first(local name: String) -> XMLElement? {
        (children ?? []).lazy.compactMap { $0 as? XMLElement }.first { $0.localName == name }
    }

    func descendant(_ path: [String]) -> XMLElement? {
        var node: XMLElement? = self
        for step in path { node = node?.first(local: step) }
        return node
    }

    func attr(_ localName: String) -> String? {
        attributes?.first { $0.localName == localName }?.stringValue
    }

    func relationshipAttr(_ localName: String) -> String? {
        attributes?.first {
            $0.localName == localName
                && ($0.uri?.contains("/relationships") == true || $0.name?.hasPrefix("r:") == true)
        }?.stringValue
    }

    func emuAttr(_ localName: String) -> Double? { attr(localName).flatMap(Double.init) }

    func intAttr(_ localName: String) -> Int? { attr(localName).flatMap(Int.init) }

    func doubleAttr(_ localName: String) -> Double? { attr(localName).flatMap(Double.init) }

    func boolAttr(_ localName: String) -> Bool? {
        switch attr(localName) {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }
}
