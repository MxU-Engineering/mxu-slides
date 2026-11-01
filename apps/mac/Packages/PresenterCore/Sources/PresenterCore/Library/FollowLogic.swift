import Foundation

public enum Follow {

    public static func holds(_ kind: SlideActionKind) -> Bool {
        switch kind {
        case .midiOut, .captureStart, .captureStop: true
        default: false
        }
    }

    public static func unconnectedScreens(in defaults: [String: Any]) -> [String] {
        guard let data = defaults["outputs.placeholderScreens"] as? Data,
              let screens = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var carried = Set(defaults["ndi.screenBackings"] as? [String] ?? [])
        carried.formUnion(defaults["syphon.screenBackings"] as? [String] ?? [])
        if let deckLink = defaults["decklink.screenBackings"] as? Data,
           let backings = try? JSONSerialization.jsonObject(with: deckLink) as? [String: Any] {
            carried.formUnion(backings.keys)
        }
        return screens.compactMap { screen in
            guard let id = screen["id"] as? String, let name = screen["name"] as? String else { return nil }
            return screen["deviceDisplayUUID"] == nil && !carried.contains(id) ? name : nil
        }
    }

    public enum State: Equatable, Sendable {
        case connecting
        case live

        case lost(frozen: Bool)

        case gaveUp
    }

    public static func banner(following name: String, state: State, lastFire: Date?, calendar: Calendar = .current) -> (title: String, detail: String) {
        switch state {
        case .connecting:
            ("Connecting to \(name)\u{2026}", "This computer's triggers wait until it takes over.")
        case .live:
            ("Backing up \(name).", lastFire.map {
                "Last fire \($0.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute().second())). This computer's triggers wait until it takes over."
            } ?? "In step. This computer's triggers wait until it takes over.")
        case .lost(let frozen):
            (frozen ? "\(name) froze." : "\(name) stopped answering.", "This computer keeps showing the last thing it fired.")
        case .gaveUp:
            ("Can't reach \(name).", "Check that both computers are on the same network, then try again.")
        }
    }
}

public struct FollowRole: Codable, Equatable, Sendable {

    public var term: Int

    public var inCharge: String

    public init(term: Int, inCharge: String) {
        self.term = term
        self.inCharge = inCharge
    }

    public func handed(to station: String) -> FollowRole {
        FollowRole(term: term + 1, inCharge: station)
    }

    public func newer(_ other: FollowRole) -> FollowRole? {
        other.term > term ? other : nil
    }

    public static func start(booth: String) -> FollowRole {
        FollowRole(term: 0, inCharge: booth)
    }
}

public extension Follow {

    static func takesOverOnItsOwn(automatic: Bool, backingUp: Bool, wasLive: Bool, now state: State) -> Bool {
        guard automatic, backingUp, wasLive else { return false }
        if case .lost = state { return true }
        return false
    }

    static func inChargeBanner(over booth: String, since: Date, boothStreamed: Bool = false, calendar: Calendar = .current) -> (title: String, detail: String) {
        let time = since.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        let detail = boothStreamed
            ? "\(booth) was streaming. Start Stream Here to send it from this computer."
            : "It answers MIDI, Companion and the Scheduler now."
        return ("This computer took over from \(booth) at \(time).", detail)
    }

    static func copiedLine(_ items: Int) -> String {
        switch items {
        case 0: ""
        case 1: " 1 This Mac only item copied here."
        default: " \(items) This Mac only items copied here."
        }
    }

    static func steppedDownBanner(backup: String) -> (title: String, detail: String) {
        ("\(backup) took over.", "This computer's triggers wait until it takes back.")
    }
}
