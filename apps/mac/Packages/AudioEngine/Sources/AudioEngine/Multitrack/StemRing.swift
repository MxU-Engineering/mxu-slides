import CAudioAtomics
import Foundation

final class StemRing: @unchecked Sendable {
    let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let written = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let read = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private let starved = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    init(capacity: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        mxu_store_i64(written, 0)
        mxu_store_i64(read, 0)
        mxu_store_i64(starved, 0)
    }

    deinit {
        left.deallocate(); right.deallocate()
        written.deallocate(); read.deallocate(); starved.deallocate()
    }

    var writtenFrames: Int64 { mxu_load_i64(written) }
    var readFrames: Int64 { mxu_load_i64(read) }
    var starvedFrames: Int64 { mxu_load_i64(starved) }
    var buffered: Int { max(0, Int(writtenFrames - readFrames)) }

    var framesToDrop: Int { max(0, Int(readFrames - writtenFrames)) }

    func drop(_ count: Int) {
        mxu_store_i64(written, writtenFrames + Int64(count))
    }

    var space: Int { capacity - buffered }

    @discardableResult
    func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int) -> Int {
        let w = writtenFrames
        let n = min(count, capacity - max(0, Int(w - readFrames)))
        guard n > 0 else { return 0 }
        let start = Int(w % Int64(capacity))
        let first = min(n, capacity - start)
        (left + start).update(from: l, count: first)
        (right + start).update(from: r, count: first)
        if first < n {
            left.update(from: l + first, count: n - first)
            right.update(from: r + first, count: n - first)
        }
        mxu_store_i64(written, w + Int64(n))
        return n
    }

    func skip(_ count: Int) {
        mxu_store_i64(read, readFrames + Int64(count))
    }

    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, count: Int) {
        let rd = readFrames
        let available = min(count, max(0, Int(writtenFrames - rd)))
        let start = Int(rd % Int64(capacity))
        let first = min(available, capacity - start)
        l.update(from: left + start, count: first)
        r.update(from: right + start, count: first)
        if first < available {
            (l + first).update(from: left, count: available - first)
            (r + first).update(from: right, count: available - first)
        }
        if available < count {
            (l + available).update(repeating: 0, count: count - available)
            (r + available).update(repeating: 0, count: count - available)
            mxu_store_i64(starved, starvedFrames + Int64(count - available))
        }
        mxu_store_i64(read, rd + Int64(count))
    }
}
