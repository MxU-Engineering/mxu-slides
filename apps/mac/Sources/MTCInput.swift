import Darwin
import Foundation
import PresenterCore
import QuartzCore

protocol TimecodeReader: AnyObject {

    func drain() -> (heard: [TimecodeHeard], peak: Float)
    func stop()
}

final class MTCReader: TimecodeReader, @unchecked Sendable {
    let sourceUID: Int32
    private let lock = NSLock()
    private var heard: [TimecodeHeard] = []

    private var decoder = MTCDecoder()
    private static let ticksToSeconds: Double = {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(base.numer) / Double(base.denom) / 1_000_000_000
    }()

    init(sourceUID: Int32) {
        self.sourceUID = sourceUID
        MIDIInService.shared.setTimecodeSource(sourceUID) { [weak self] bytes, timeStamp in
            self?.read(bytes, timeStamp: timeStamp)
        }
    }

    func stop() {
        MIDIInService.shared.setTimecodeSource(nil, handler: nil)
    }

    private func read(_ bytes: [UInt8], timeStamp: UInt64) {
        let hostTime = timeStamp == 0 ? CACurrentMediaTime() : Double(timeStamp) * Self.ticksToSeconds
        let frames = decoder.receive(bytes, hostTime: hostTime)
        guard !frames.isEmpty else { return }
        lock.withLock {
            heard += frames

            if heard.count > 90 { heard.removeFirst(heard.count - 90) }
        }
    }

    func drain() -> (heard: [TimecodeHeard], peak: Float) {
        lock.withLock {
            defer { heard.removeAll(keepingCapacity: true) }
            return (heard, heard.isEmpty ? 0 : 1)
        }
    }
}
