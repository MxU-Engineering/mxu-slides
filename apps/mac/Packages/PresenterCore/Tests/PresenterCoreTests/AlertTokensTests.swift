import Foundation
import Testing
@testable import PresenterCore

struct AlertTokensTests {
    @Test func namesParseInOrderAndDedupe() {
        #expect(AlertTokens.tokenNames(in: "Car {plate} in lot {lot}") == ["plate", "lot"])
        #expect(AlertTokens.tokenNames(in: "{Room} … {room} again") == ["Room"])
        #expect(AlertTokens.tokenNames(in: "No tokens here").isEmpty)
        #expect(AlertTokens.tokenNames(in: "Empty {} braces").isEmpty)
    }

    @Test func composeFillsInPlaceKeepingCopy() {
        #expect(
            AlertTokens.compose(
                template: "Car with plate {plate} — please move it",
                values: ["plate": "7ABC123"]
            ) == "Car with plate 7ABC123 — please move it"
        )
    }

    @Test func composeIsCaseInsensitiveAndRepeats() {
        #expect(
            AlertTokens.compose(
                template: "{Child} to room {room}. Repeat: {child} to room {ROOM}.",
                values: ["child": "042", "Room": "B"]
            ) == "042 to room B. Repeat: 042 to room B."
        )
    }

    @Test func missingValuesRemoveTheSlot() {
        #expect(
            AlertTokens.compose(template: "Hi {name}!", values: [:]) == "Hi !"
        )
    }

    @Test func malformedBracesPassThrough() {
        #expect(
            AlertTokens.compose(template: "a { b } {c", values: ["b": "X", " b ": "X"])
                == "a X {c"
        )
        #expect(AlertTokens.compose(template: "{}", values: [:]) == "{}")
    }
}
