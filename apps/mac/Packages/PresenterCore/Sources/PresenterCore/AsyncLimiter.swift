import Foundation

public actor AsyncLimiter {
    public nonisolated let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public nonisolated func withPermit<T>(_ body: () async -> T) async -> T {
        await acquire()
        let value = await body()
        await release()
        return value
    }

    private func acquire() async {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
