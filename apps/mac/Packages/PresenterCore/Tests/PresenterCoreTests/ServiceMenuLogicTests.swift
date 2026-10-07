import Foundation
import Testing
@testable import PresenterCore

private let gregorian: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    return calendar
}()

@Test func serviceDateColumnFormatsISODates() {
    let label = ServiceMenuLogic.dateColumnLabel(
        subkind: "2026-07-19", locale: Locale(identifier: "en_US"),
        calendar: gregorian)
    #expect(label == "Jul 19, 2026")
}

@Test func serviceDateColumnSaysNoDateForUndatedAndMalformed() {
    let locale = Locale(identifier: "en_US")
    #expect(ServiceMenuLogic.dateColumnLabel(
        subkind: "", locale: locale, calendar: gregorian) == "No Date")
    #expect(ServiceMenuLogic.dateColumnLabel(
        subkind: "not-a-date", locale: locale, calendar: gregorian) == "No Date")
    #expect(ServiceMenuLogic.dateColumnLabel(
        subkind: "2026-07", locale: locale, calendar: gregorian) == "No Date")
}

@Test func serviceISOParseRoundTrips() {
    let date = ServiceMenuLogic.parseISODate("2026-07-19", calendar: gregorian)
    #expect(date != nil)
    let parts = gregorian.dateComponents([.year, .month, .day], from: date!)
    #expect(parts.year == 2026 && parts.month == 7 && parts.day == 19)
    #expect(ServiceMenuLogic.parseISODate("", calendar: gregorian) == nil)
}
