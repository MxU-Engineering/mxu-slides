import Foundation
import Testing
@testable import SlideScene

private let threeDays: TimeInterval = 3 * 86400 + 11 * 3600 + 18 * 60 + 23  

@Test func unitsRollOverAndTotalsDoNot() {
    #expect(TimerPattern.text(threeDays, pattern: "d h m s") == "3 11 18 23")
    #expect(TimerPattern.text(threeDays, pattern: "H:mm:ss") == "83:18:23")
    #expect(TimerPattern.text(threeDays, pattern: "M") == "4998")
    #expect(TimerPattern.text(threeDays, pattern: "S") == "299903")
    #expect(TimerPattern.text(1046, pattern: "m:ss") == "17:26", "minutes without the hour")
    #expect(TimerPattern.text(1046, pattern: "ss") == "26", "just the seconds in the minute")
}

@Test func doubledTokensZeroPad() {
    #expect(TimerPattern.text(65, pattern: "hh:mm:ss") == "00:01:05")
    #expect(TimerPattern.text(65, pattern: "h:m:s") == "0:1:5")
    #expect(TimerPattern.text(5, pattern: "SSS") == "005")
}

@Test func fractionsTruncateLikeEveryOtherUnit() {
    #expect(TimerPattern.text(26.25, pattern: "s.f") == "26.2")
    #expect(TimerPattern.text(26.25, pattern: "s.ff") == "26.25")
    #expect(TimerPattern.text(26.25, pattern: "s.fff") == "26.250")
    #expect(TimerPattern.text(1046.42, pattern: "m:ss.fff") == "17:26.420", "binary slack never reads 419")
    #expect(TimerPattern.text(1046.9996, pattern: "s.fff") == "26.999", "never rounds into the next second")
}

@Test func quotesFenceLiteralsAndOtherCharactersPassThrough() {
    #expect(TimerPattern.text(threeDays, pattern: "d'd' H:mm") == "3d 83:18")
    #expect(TimerPattern.text(45, pattern: "S 'seconds'") == "45 seconds")
    #expect(TimerPattern.text(45, pattern: "'it''s' S") == "it's 45", "'' is one apostrophe")
    #expect(TimerPattern.text(45, pattern: "[S]") == "[45]")
}

@Test func overtimeCarriesAMinusOnlyWhereDigitsShow() {
    #expect(TimerPattern.text(-75, pattern: "m:ss") == "-1:15")
    #expect(TimerPattern.text(-0.5, pattern: "s") == "0", "no -0")
    #expect(TimerPattern.text(-0.5, pattern: "s.f") == "-0.5")
}

@Test func fractionDetectionSkipsQuotedText() {
    #expect(TimerPattern.hasFraction("m:ss.fff"))
    #expect(!TimerPattern.hasFraction("m:ss"))
    #expect(!TimerPattern.hasFraction("S 'left'"), "the f in 'left' is text, not a token")
}
