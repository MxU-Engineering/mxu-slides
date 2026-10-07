import Darwin
import Foundation
import MachO
import os

public struct RawStack: Sendable, Equatable {
    public var addresses: [UInt]

    public var startsWithProgramCounter: Bool

    public var hasLinkRegister: Bool

    public init(addresses: [UInt], startsWithProgramCounter: Bool = false, hasLinkRegister: Bool = false) {
        self.addresses = addresses
        self.startsWithProgramCounter = startsWithProgramCounter
        self.hasLinkRegister = hasLinkRegister
    }

    public static let empty = RawStack(addresses: [])
}

public struct StackFrame: Sendable, Equatable, CustomStringConvertible {
    public var address: UInt

    public var image: String
    public var imageBase: UInt
    public var symbol: String?
    public var symbolStart: UInt

    public init(address: UInt, image: String, imageBase: UInt, symbol: String?, symbolStart: UInt) {
        self.address = address
        self.image = image
        self.imageBase = imageBase
        self.symbol = symbol
        self.symbolStart = symbolStart
    }

    public var description: String {
        if let symbol {
            return "\(symbol)+\(address &- symbolStart)"
        } else if !image.isEmpty {
            return "\(image)+0x\(String(address &- imageBase, radix: 16))"
        } else {
            return "0x\(String(address, radix: 16))"
        }
    }
}

public final class ThreadStackCapture: Sendable {

    public static let capacity = 64

    private let thread: mach_port_t

    private let stackLow: UInt
    private let stackHigh: UInt

    nonisolated(unsafe) private let frames: UnsafeMutablePointer<UInt>
    #if arch(arm64)
    nonisolated(unsafe) private let state: UnsafeMutablePointer<arm_thread_state64_t>
    #endif

    private let lock = OSAllocatedUnfairLock()

    private static let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF

    public init(pthread: pthread_t) {
        thread = pthread_mach_thread_np(pthread)
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
        stackHigh = top
        stackLow = top &- UInt(pthread_get_stacksize_np(pthread))
        frames = .allocate(capacity: Self.capacity)
        frames.initialize(repeating: 0, count: Self.capacity)
        #if arch(arm64)

        state = .allocate(capacity: 1)
        state.initialize(to: arm_thread_state64_t())
        #endif
    }

    deinit {
        frames.deallocate()
        #if arch(arm64)
        state.deallocate()
        #endif
    }

    @MainActor public static func mainThread() -> ThreadStackCapture {
        currentThread()
    }

    public static func currentThread() -> ThreadStackCapture {
        ThreadStackCapture(pthread: pthread_self())
    }

    public func capture() -> RawStack {
        #if arch(arm64)
        let taken = lock.withLockUnchecked { () -> (count: Int, linkRegister: Bool) in
            var result = (count: 0, linkRegister: false)
            if thread != pthread_mach_thread_np(pthread_self()), thread_suspend(thread) == KERN_SUCCESS {
                result = walkSuspended()
                thread_resume(thread)
            }
            return result
        }

        var addresses = Array(UnsafeBufferPointer(start: frames, count: taken.count))
        var linkRegister = taken.linkRegister
        if linkRegister, addresses.count >= 3, addresses[1] == addresses[2] {

            addresses.remove(at: 1)
            linkRegister = false
        }
        return RawStack(addresses: addresses, startsWithProgramCounter: !addresses.isEmpty, hasLinkRegister: linkRegister)
        #else
        return .empty
        #endif
    }

    #if arch(arm64)

    private func walkSuspended() -> (count: Int, linkRegister: Bool) {
        var count = 0
        var linkRegister = false
        let words = MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        var stateCount = mach_msg_type_number_t(words)
        let read = UnsafeMutableRawPointer(state).withMemoryRebound(to: natural_t.self, capacity: words) {
            thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
        }
        if read == KERN_SUCCESS {
            let pc = UInt(state.pointee.__pc) & Self.addressMask
            let lr = UInt(state.pointee.__lr) & Self.addressMask
            frames[0] = pc
            count = 1
            if lr != 0 {
                frames[1] = lr
                count = 2
                linkRegister = true
            }
            var framePointer = UInt(state.pointee.__fp)
            var previous: UInt = 0
            while count < Self.capacity, framePointer > previous, framePointer & 0xF == 0,
                  framePointer >= stackLow, framePointer <= stackHigh &- 16
            {
                let record = UnsafePointer<UInt>(bitPattern: framePointer)!
                let returnAddress = record[1] & Self.addressMask
                if returnAddress != 0 {
                    frames[count] = returnAddress
                    count += 1
                }
                previous = framePointer

                framePointer = returnAddress == 0 ? 0 : record[0] & Self.addressMask
            }
        }
        return (count, linkRegister)
    }
    #endif

    public static func symbolicate(_ stack: RawStack, dropLeading: Int = 0) -> [StackFrame] {
        var resolved: [StackFrame] = []
        resolved.reserveCapacity(stack.addresses.count)
        for (index, address) in stack.addresses.enumerated() {
            let isProgramCounter = index == 0 && stack.startsWithProgramCounter
            resolved.append(frame(address, lookup: isProgramCounter ? address : address &- 1))
        }
        if stack.hasLinkRegister, resolved.count >= 2,
           resolved[1].symbol != nil, resolved[1].symbolStart == resolved[0].symbolStart
        {

            resolved.remove(at: 1)
        }
        return Array(resolved.dropFirst(dropLeading))
    }

    private static func frame(_ address: UInt, lookup: UInt) -> StackFrame {
        var info = Dl_info()
        var frame = StackFrame(address: address, image: "", imageBase: 0, symbol: nil, symbolStart: 0)
        if let pointer = UnsafeRawPointer(bitPattern: lookup), dladdr(pointer, &info) != 0 {
            frame.imageBase = UInt(bitPattern: info.dli_fbase)
            frame.image = info.dli_fname.map { String(cString: $0) }
                .map { ($0 as NSString).lastPathComponent } ?? ""
            let start = UInt(bitPattern: info.dli_saddr)

            if let name = info.dli_sname, start != 0, start != frame.imageBase {
                frame.symbol = String(cString: name)
                frame.symbolStart = start
            }
        }
        return frame
    }

    public static let ownImage: LoadedImage = {
        let header = #dsohandle
        return LoadedImage(containing: header)
            ?? LoadedImage(name: "", loadAddress: UInt(bitPattern: header), uuid: nil)
    }()

    private static let mainExecutableBase = UInt(bitPattern: _dyld_get_image_header(0))

    public static func isAppFrame(_ frame: StackFrame) -> Bool {
        frame.imageBase != 0 && (frame.imageBase == ownImage.loadAddress || frame.imageBase == mainExecutableBase)
    }
}
