import Foundation
import Testing
@testable import PresenterCore

@Suite struct AsyncLimiterTests {
    private actor Probe {
        private(set) var peak = 0
        private var now = 0

        func enter() {
            now += 1
            peak = max(peak, now)
        }

        func leave() { now -= 1 }
    }

    @Test func neverRunsMoreThanTheLimitAtOnce() async {
        let limiter = AsyncLimiter(limit: 2)
        let probe = Probe()
        let results = await withTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    await limiter.withPermit {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.leave()
                        return index
                    }
                }
            }
            var finished: [Int] = []
            for await index in group { finished.append(index) }
            return finished
        }
        #expect(results.sorted() == Array(0..<8), "every body runs and hands back its value")
        #expect(await probe.peak == 2)
    }

    @Test func aLimitBelowOneStillRunsOneAtATime() async {
        let limiter = AsyncLimiter(limit: 0)
        #expect(limiter.limit == 1)
        #expect(await limiter.withPermit { "ran" } == "ran")
    }
}
