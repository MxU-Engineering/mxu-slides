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

    public static func banner(following name: String, state: State, lastFire: Date?, boothQuit: Bool = false, standby: Bool = false, calendar: Calendar = .current) -> (title: String, detail: String) {
        if boothQuit, state != .live, state != .connecting {
            return ("\(name) quit.", standby
                ? "Nothing shows here, and this computer stands by again when \(name) opens."
                : "This computer keeps showing the last thing it fired, and follows again when \(name) opens.")
        }
        let waits = standby ? "Nothing shows here until this computer takes over." : "This computer's triggers wait until it takes over."
        return switch state {
        case .connecting:
            ("Connecting to \(name)\u{2026}", waits)
        case .live:
            (standby ? "Ready to take over from \(name)." : "Backing up \(name).", lastFire.map {
                "Last fire \($0.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute().second())). \(waits)"
            } ?? (standby ? waits : "In step. \(waits)"))
        case .lost(let frozen):
            (frozen ? "\(name) froze." : "\(name) stopped answering.", standby
                ? "Take Over puts up what \(name) last showed."
                : "This computer keeps showing the last thing it fired.")
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
    static func takesOverOnItsOwn(automatic: Bool, backingUp: Bool, wasLive: Bool, boothQuit: Bool = false, now state: State) -> Bool {
        guard automatic, backingUp, wasLive, !boothQuit else { return false }
        if case .lost = state { return true }
        return false
    }

    static func inChargeBanner(over booth: String, since: Date, onItsOwn: Bool = false, boothStreamed: Bool = false, calendar: Calendar = .current) -> (title: String, detail: String) {
        let time = since.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        let detail = boothStreamed
            ? "\(booth) was streaming. Start Stream Here to send it from this computer."
            : "It answers MIDI, Companion and the Scheduler now."
        let title = onItsOwn
            ? "\(booth) stopped answering, so this computer took over at \(time)."
            : "This computer took over from \(booth) at \(time)."
        return (title, detail)
    }

    static func copiedLine(_ items: Int) -> String {
        switch items {
        case 0: ""
        case 1: " 1 item copied here over the network."
        default: " \(items) items copied here over the network."
        }
    }

    static let handBackWindow: TimeInterval = 60

    static func handsBackOnReturn(onItsOwn: Bool, frozen: Bool, since: Date, now: Date, launchThen: String?, launchNow: String?) -> Bool {
        guard onItsOwn, !frozen, let launchThen, launchThen == launchNow else { return false }
        return now.timeIntervalSince(since) <= handBackWindow
    }

    static func cameBackLine(_ booth: String, after seconds: TimeInterval) -> String {
        "\(booth) came back after \(max(1, Int(seconds.rounded()))) seconds, so it answers again."
    }

    static func boothBackupLine(_ backup: String, connected: Bool, inCharge: Bool = false) -> String {
        if inCharge { return "\(backup) took over, so it answers MIDI, Companion and the Scheduler. Take Back when this computer should again." }
        return connected
            ? "\(backup) is backing up this computer, fire for fire. If this computer stops answering, it takes over."
            : "\(backup) isn't connected. It follows again when MxU Slides opens on it, on this network."
    }

    static func boothSettingsLine(backups: [String], connected: Set<String>, tookOver: String?) -> (title: String, detail: String) {
        if let tookOver { return ("\(tookOver) took over", "This computer's triggers wait until it takes back.") }
        guard backups.count < 2 else {
            let on = backups.filter(connected.contains)
            return ("\(backups.count) backups follow this computer", on.isEmpty ? "None connected now." : "Connected now: \(on.joined(separator: ", ")).")
        }
        guard let name = backups.first else {
            return ("No backup computer", "A second Mac on this network can stand in if this one stops.")
        }
        return connected.contains(name)
            ? ("\(name) is following this computer", "Connected. It can stand in if this computer stops.")
            : ("\(name) isn't connected", "It follows again when MxU Slides opens on it, on this network.")
    }

    static func backupSettingsLine(following name: String, state: State, inCharge: Bool, standby: Bool, automatic: Bool, copied: Int, boothQuit: Bool = false) -> (title: String, detail: String) {
        if inCharge { return ("Took over from \(name)", "This computer answers every trigger until it hands back.") }
        let line = banner(following: name, state: state, lastFire: nil, boothQuit: boothQuit, standby: standby)
        let title = line.title.hasSuffix(".") ? String(line.title.dropLast()) : line.title
        guard state == .live, !boothQuit else { return (title, line.detail) }

        let shows = standby ? "Stays ready with clear screens." : "Shows the same thing live."
        let stops = automatic ? "Takes over after 3 seconds." : "Waits for Take Over."
        let copies = copied == 0 ? "" : copied == 1 ? " 1 item copied." : " \(copied) items copied."
        return (title, "\(shows) \(stops)\(copies)")
    }

    static func backupDroppedBanner(_ backup: String) -> (title: String, detail: String) {
        ("\(backup) stopped following.", "This computer keeps running the service. \(backup) follows again when it reconnects.")
    }

    static func steppedDownBanner(backup: String) -> (title: String, detail: String) {
        ("\(backup) took over.", "This computer's triggers wait until it takes back.")
    }
}
