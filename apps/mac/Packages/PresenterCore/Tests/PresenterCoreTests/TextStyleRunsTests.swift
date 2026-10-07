import Foundation
import Testing
@testable import PresenterCore

struct TextStyleRunsTests {

    @Test func utf16SelectionConvertsToCharacters() {

        let text = "🎸 Amazing"
        let range = TextStyleRuns.characterRange(fromUTF16: 3, length: 7, in: text)
        #expect(range == 2..<9)  
        #expect(TextStyleRuns.characterRange(fromUTF16: 0, length: 2, in: text) == 0..<1)
    }

    @Test func stylingASelectionEmitsOneRun() {
        let runs = TextStyleRuns.applying(
            { $0.colorHex = "#FF0000FF" },
            to: [], in: "Amazing grace", selection: 8..<13
        )
        #expect(runs == [TextStyleRun(line: 0, column: 8, length: 5, colorHex: "#FF0000FF")])
    }

    @Test func overlappingSelectionSplitsExistingRuns() {

        let existing = [TextStyleRun(line: 0, column: 0, length: 7, underline: true)]
        let runs = TextStyleRuns.applying(
            { $0.colorHex = "#00FF00FF" },
            to: existing, in: "Amazing grace", selection: 2..<6
        )
        #expect(runs == [
            TextStyleRun(line: 0, column: 0, length: 2, underline: true),
            TextStyleRun(line: 0, column: 2, length: 4, underline: true, colorHex: "#00FF00FF"),
            TextStyleRun(line: 0, column: 6, length: 1, underline: true),
        ])
    }

    @Test func clearingAFieldSplitsTheRun() {
        let existing = [TextStyleRun(line: 0, column: 0, length: 13, underline: true)]
        let runs = TextStyleRuns.applying(
            { $0.underline = nil },
            to: existing, in: "Amazing grace", selection: 7..<13
        )
        #expect(runs == [TextStyleRun(line: 0, column: 0, length: 7, underline: true)])
    }

    @Test func identicalNeighborsCoalesce() {
        let existing = [TextStyleRun(line: 0, column: 0, length: 7, underline: true)]
        let runs = TextStyleRuns.applying(
            { $0.underline = true },
            to: existing, in: "Amazing grace", selection: 7..<13
        )
        #expect(runs == [TextStyleRun(line: 0, column: 0, length: 13, underline: true)])
    }

    @Test func multiLineSelectionNeverSpansLines() {
        let runs = TextStyleRuns.applying(
            { $0.fontSize = 90 },
            to: [], in: "Amazing\ngrace", selection: 5..<10
        )
        #expect(runs == [
            TextStyleRun(line: 0, column: 5, length: 2, fontSize: 90),
            TextStyleRun(line: 1, column: 0, length: 2, fontSize: 90),
        ])
    }

    @Test func untouchedLinesPassThroughVerbatim() {
        let other = TextStyleRun(line: 1, column: 0, length: 5, strikethrough: true)
        let runs = TextStyleRuns.applying(
            { $0.underline = true },
            to: [other], in: "Amazing\ngrace", selection: 0..<3
        )
        #expect(runs.contains(other))
    }

    @Test func effectiveRunFoldsOverlaps() {
        let runs = [
            TextStyleRun(line: 0, column: 0, length: 7, underline: true),
            TextStyleRun(line: 0, column: 2, length: 3, colorHex: "#FF0000FF"),
        ]
        let effective = TextStyleRuns.effectiveRun(at: 3, runs: runs, in: "Amazing grace")
        #expect(effective?.underline == true)
        #expect(effective?.colorHex == "#FF0000FF")
        #expect(TextStyleRuns.effectiveRun(at: 10, runs: runs, in: "Amazing grace") == nil)
    }

    @Test func insertionBeforeARunShiftsIt() {
        let runs = TextStyleRuns.replacing(
            [TextStyleRun(line: 0, column: 8, length: 5, underline: true)],
            range: 0..<0, with: "O! ", in: "Amazing grace"
        )
        #expect(runs == [TextStyleRun(line: 0, column: 11, length: 5, underline: true)])
    }

    @Test func typingInsideARunGrowsIt() {
        let runs = TextStyleRuns.replacing(
            [TextStyleRun(line: 0, column: 8, length: 5, underline: true)],
            range: 10..<10, with: "aa", in: "Amazing grace"
        )
        #expect(runs == [TextStyleRun(line: 0, column: 8, length: 7, underline: true)])
    }

    @Test func deletionAcrossARunEdgeTrimsIt() {

        let runs = TextStyleRuns.replacing(
            [TextStyleRun(line: 0, column: 8, length: 5, underline: true)],
            range: 5..<10, with: "", in: "Amazing grace"
        )
        #expect(runs == [TextStyleRun(line: 0, column: 5, length: 3, underline: true)])
    }

    @Test func replacingARunEntirelyDropsIt() {
        let runs = TextStyleRuns.replacing(
            [TextStyleRun(line: 0, column: 8, length: 5, underline: true)],
            range: 8..<13, with: "mercy", in: "Amazing grace"
        )
        #expect(runs.isEmpty)
    }

    @Test func pastedNewlineSplitsARun() {
        let runs = TextStyleRuns.replacing(
            [TextStyleRun(line: 0, column: 0, length: 13, underline: true)],
            range: 7..<8, with: "\n", in: "Amazing grace"
        )
        #expect(runs == [
            TextStyleRun(line: 0, column: 0, length: 7, underline: true),
            TextStyleRun(line: 1, column: 0, length: 5, underline: true),
        ])
    }

    @Test func editsOnOtherLinesLeaveRunsAlone() {
        let run = TextStyleRun(line: 1, column: 0, length: 5, colorHex: "#FF0000FF")
        let runs = TextStyleRuns.replacing(
            [run], range: 0..<7, with: "Boundless", in: "Amazing\ngrace"
        )
        #expect(runs == [TextStyleRun(line: 1, column: 0, length: 5, colorHex: "#FF0000FF")])
    }

    @Test func chordAnchorsShiftAndDrop() {
        let chords = [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 8, symbol: "C"),
        ]

        let afterDelete = TextStyleRuns.replacing(
            chords, range: 7..<13, with: "", in: "Amazing grace"
        )
        #expect(afterDelete == [ChordPlacement(line: 0, column: 0, symbol: "G")])

        let afterInsert = TextStyleRuns.replacing(
            chords, range: 8..<8, with: "a", in: "Amazing grace"
        )
        #expect(afterInsert == [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 9, symbol: "C"),
        ])
    }
}

@Test func buildRangesFromSelectionSplitPerLineAndReanchorThroughEdits() {
    let text = "one two\nthree"

    let ranges = AnimationRanges.ranges(forSelection: 4..<10, in: text)
    #expect(ranges == [AnimationRange(line: 0, column: 4, length: 3), AnimationRange(line: 1, column: 0, length: 2)])
    #expect(AnimationRanges.text(of: ranges[0], in: text) == "two")

    let shifted = AnimationRanges.replacing([ranges[0]], range: 4..<4, with: "very ", in: text)
    #expect(shifted == [AnimationRange(line: 0, column: 9, length: 3)])

    let step = AnimationStep(id: "s", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5, ranges: [ranges[0]])
    let whole = AnimationStep(id: "w", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)
    let after = AnimationRanges.reanchor([step, whole], range: 4..<7, with: "", in: text)
    #expect(after.map(\.id) == ["w"], "ranged step lost its text; whole-object step untouched")

    let grown = AnimationRanges.reanchor([step], range: 5..<5, with: "w", in: text)
    #expect(grown.first?.ranges == [AnimationRange(line: 0, column: 4, length: 4)])
    #expect(AnimationRanges.ranges(forSelection: 3..<3, in: text).isEmpty)
}

@Test func buildRangesByWordGeneratorSplitsInsideTheSelection() {
    let text = "Grace comes  first\nFaith answers"
    let selection = AnimationRanges.ranges(forSelection: 2..<26, in: text) 
    let words = AnimationRanges.words(in: selection, text: text)
    #expect(words == [
        AnimationRange(line: 0, column: 2, length: 3), AnimationRange(line: 0, column: 6, length: 5),
        AnimationRange(line: 0, column: 13, length: 5), AnimationRange(line: 1, column: 0, length: 5),
        AnimationRange(line: 1, column: 6, length: 1),
    ])
}

@Test func buildRangesSplitFollowsTheGenerator() {
    let text = "Grace comes\nFaith answers"
    let ranges = [
        AnimationRange(line: 0, column: 0, length: 11),
        AnimationRange(line: 1, column: 0, length: 0), 
        AnimationRange(line: 1, column: 0, length: 13),
    ]
    #expect(AnimationRanges.split(ranges, by: .line, in: text) == [ranges[0], ranges[2]])
    #expect(AnimationRanges.split(ranges, by: .word, in: text) == AnimationRanges.words(in: ranges, text: text))
}

@Test func appendingToLastStepGroupsOnlyWhenTheLastStepIsRanged() {
    let ranged = AnimationStep(
        id: "r", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5,
        ranges: [AnimationRange(line: 0, column: 0, length: 5)]
    )
    let whole = AnimationStep(id: "w", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)
    let extra = [AnimationRange(line: 0, column: 6, length: 5)]

    let merged = AnimationRanges.appendingToLastStep(extra, in: [whole, ranged])
    #expect(merged?.stepID == "r")
    #expect(merged?.animationSteps.last?.ranges == [
        AnimationRange(line: 0, column: 0, length: 5), AnimationRange(line: 0, column: 6, length: 5),
    ])

    #expect(AnimationRanges.appendingToLastStep(extra, in: [ranged, whole]) == nil)
    #expect(AnimationRanges.appendingToLastStep(extra, in: nil) == nil)
}
