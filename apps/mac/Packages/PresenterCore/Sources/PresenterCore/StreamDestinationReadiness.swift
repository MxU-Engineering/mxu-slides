import Foundation

public enum StreamDestinationReadiness {

    public static func problem(_ destination: StreamPresetDestination) -> String? {
        if destination.url.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(destination.name): no server URL"
        }
        if destination.transport != .srt, destination.streamKey?.isEmpty != false {
            return "\(destination.name): no stream key"
        }
        return nil
    }

    public static func isReady(_ destination: StreamPresetDestination) -> Bool {
        problem(destination) == nil
    }

    public static func problems(_ destinations: [StreamPresetDestination]) -> [String] {
        destinations.compactMap(problem)
    }

    public static func startRefusal(kind: StreamPresetKind, destinations: [StreamPresetDestination]) -> String? {
        guard kind == .stream else { return nil }
        guard !destinations.isEmpty else { return "Won't go live: no destinations selected" }
        let ready = destinations.filter(isReady)
        if ready.isEmpty {
            return "Won't go live: " + problems(destinations).joined(separator: " \u{B7} ")
        }
        return nil
    }
}
