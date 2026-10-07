import Foundation
import Testing

@testable import PresenterCore

@Suite(.serialized) struct LibraryPerfNoticeTests {
    @MainActor @Test func eachPassTakesItsMainThreadOpensAndStatements() throws {
        _ = Library.takeMainPassOpens()
        _ = LibraryIndex.takeMainThreadStatementCount()

        Library.measuringOpen(kind: .presentation, id: "perf-deck") {}
        Library.measuringOpen(kind: .presentation, id: "perf-deck") {}
        LibraryIndex.countStatement()

        let pass = Library.takeMainPassOpens()
        #expect(pass.count == 2)
        #expect(pass.kinds == ["presentations": 2])
        #expect(LibraryIndex.takeMainThreadStatementCount() >= 1)

        #expect(Library.takeMainPassOpens().count == 0)
        #expect(LibraryIndex.takeMainThreadStatementCount() == 0)

        let done = DispatchSemaphore(value: 0)
        Thread {
            Library.measuringOpen(kind: .presentation, id: "perf-deck") {}
            LibraryIndex.countStatement()
            done.signal()
        }.start()
        done.wait()
        #expect(Library.takeMainPassOpens().count == 0)
        #expect(LibraryIndex.takeMainThreadStatementCount() == 0)
    }
}
