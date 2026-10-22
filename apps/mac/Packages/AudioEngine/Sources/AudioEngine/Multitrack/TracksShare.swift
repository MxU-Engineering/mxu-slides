import CAudioAtomics
import Darwin
import Foundation

public final class TracksShare: @unchecked Sendable {
    public static let slots = 32

    public static let slotFrames = 48_000
    private static let magic: Int64 = 0x4D78_5554_726B_0002

    private static let headerBytes = 64
    private static let lineBytes = 64
    static var byteCount: Int {
        headerBytes + slots * lineBytes + slots * 2 * slotFrames * MemoryLayout<Float>.size
    }

    private let base: UnsafeMutableRawPointer
    private let name: String?
    private let unmap: () -> Void

    private let written: UnsafeMutablePointer<Int64>

    private init(base: UnsafeMutableRawPointer, name: String?, unmap: @escaping () -> Void) {
        self.base = base
        self.name = name
        self.unmap = unmap
        written = .allocate(capacity: Self.slots)
        for slot in 0 ..< Self.slots { written[slot] = mxu_load_i64(counter(slot)) }
    }

    public convenience init() {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Self.byteCount, alignment: 64)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: Self.byteCount)
        self.init(base: memory, name: nil, unmap: { memory.deallocate() })
        stamp()
    }

    deinit {
        written.deallocate()
        unmap()
    }

    public static func create(name: String) -> TracksShare? {
        shm_unlink(name)
        let fd = mxu_shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ftruncate(fd, off_t(byteCount)) == 0,
              let memory = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              memory != MAP_FAILED
        else {
            shm_unlink(name)
            return nil
        }
        memset(memory, 0, byteCount)
        let share = TracksShare(base: memory, name: name, unmap: { munmap(memory, byteCount) })
        share.stamp()
        return share
    }

    public static func open(name: String) -> TracksShare? {
        let fd = mxu_shm_open(name, O_RDONLY, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) >= byteCount,
              let memory = mmap(nil, byteCount, PROT_READ, MAP_SHARED, fd, 0), memory != MAP_FAILED
        else { return nil }
        let header = memory.assumingMemoryBound(to: mxu_atomic_i64.self)
        guard mxu_load_i64(header) == magic, mxu_load_i64(header + 1) == Int64(slotFrames) else {
            munmap(memory, byteCount)
            return nil
        }
        return TracksShare(base: memory, name: nil, unmap: { munmap(memory, byteCount) })
    }

    public func remove() {
        if let name { shm_unlink(name) }
    }

    private func stamp() {
        let header = base.assumingMemoryBound(to: mxu_atomic_i64.self)
        mxu_store_i64(header + 1, Int64(Self.slotFrames))
        mxu_store_i64(header, Self.magic)
    }

    private func counter(_ slot: Int) -> UnsafeMutablePointer<mxu_atomic_i64> {
        (base + Self.headerBytes + slot * Self.lineBytes).assumingMemoryBound(to: mxu_atomic_i64.self)
    }

    private func samples(_ slot: Int, side: Int) -> UnsafeMutablePointer<Float> {
        (base + Self.headerBytes + Self.slots * Self.lineBytes).assumingMemoryBound(to: Float.self)
            + (slot * 2 + side) * Self.slotFrames
    }

    public var sampleRate: Double {
        get { Double(bitPattern: UInt64(bitPattern: mxu_load_i64(base.assumingMemoryBound(to: mxu_atomic_i64.self) + 2))) }
        set { mxu_store_i64(base.assumingMemoryBound(to: mxu_atomic_i64.self) + 2, Int64(bitPattern: newValue.bitPattern)) }
    }

    func write(slot: Int, left: UnsafePointer<Float>?, right: UnsafePointer<Float>?, count: Int) {
        guard slot >= 0, slot < Self.slots else { return }
        var position = written[slot]
        var done = 0
        while done < count {
            let start = Int(position % Int64(Self.slotFrames))
            let run = min(count - done, Self.slotFrames - start)
            copy(left.map { $0 + done }, to: samples(slot, side: 0) + start, count: run)
            copy(right.map { $0 + done }, to: samples(slot, side: 1) + start, count: run)
            position += Int64(run)
            done += run
        }
        written[slot] = position
        mxu_store_i64(counter(slot), position)
    }

    private func copy(_ source: UnsafePointer<Float>?, to target: UnsafeMutablePointer<Float>, count: Int) {
        if let source { target.update(from: source, count: count) } else { target.update(repeating: 0, count: count) }
    }

    public func writtenFrames(slot: Int) -> Int64 { mxu_load_i64(counter(slot)) }

    func read(slot: Int, from: Int64, count: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var position = from
        var done = 0
        while done < count {
            let start = Int(position % Int64(Self.slotFrames))
            let run = min(count - done, Self.slotFrames - start)
            (left + done).update(from: samples(slot, side: 0) + start, count: run)
            (right + done).update(from: samples(slot, side: 1) + start, count: run)
            position += Int64(run)
            done += run
        }
    }
}
