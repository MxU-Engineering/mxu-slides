import Foundation

public enum ServiceMenuLogic {

    public static func parseISODate(
        _ iso: String, calendar: Calendar = .current
    ) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]
        ))
    }

    public static func dateColumnLabel(
        subkind: String, locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        guard let date = parseISODate(subkind, calendar: calendar) else {
            return "No Date"
        }
        return date.formatted(
            Date.FormatStyle(
                locale: locale, calendar: calendar, timeZone: calendar.timeZone
            )
            .month(.abbreviated).day().year()
        )
    }
}
