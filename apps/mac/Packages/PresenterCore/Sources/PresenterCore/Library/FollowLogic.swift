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
