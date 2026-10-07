import Foundation

public enum PerfScenario: Equatable, Sendable {
    public static let environmentKey = "MXU_PERF_SCENARIO"

    case animate(theme: String, layout: String)

    case edit(deck: String, slide: Int, object: String)

    case idle

    public init?(_ spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let fields = parts.count == 2 ? parts[1].split(separator: "/", omittingEmptySubsequences: false).map(String.init) : []
        switch parts.first {
        case "animate" where fields.count == 2 && !fields.contains(where: \.isEmpty):
            self = .animate(theme: fields[0], layout: fields[1])
        case "edit" where fields.count == 3 && !fields[0].isEmpty && !fields[2].isEmpty:
            guard let slide = Int(fields[1]), slide >= 1 else { return nil }
            self = .edit(deck: fields[0], slide: slide, object: fields[2])
        case "idle" where parts.count == 1:
            self = .idle
        default:
            return nil
        }
    }

    public static func readyDetail(center: CGPoint?, handle: CGPoint?) -> String {
        func point(_ point: CGPoint?) -> String {
            point.map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "none"
        }
        return "center \(point(center)) handle \(point(handle))"
    }
}
