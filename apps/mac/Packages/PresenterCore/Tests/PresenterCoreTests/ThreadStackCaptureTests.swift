import Darwin
import Foundation
import Synchronization
import Testing
import os

@testable import PresenterCore

@available(macOS 15, *)
private final class SpinFlag: Sendable {
    let released = Atomic<Bool>(false)
    let ticks = Atomic<Int>(0)
}

@available(macOS 15, *)
@inline(never)
private func stackCaptureSpinTarget(_ flag: SpinFlag, entered: DispatchSemaphore) {
    entered.signal()
    while !flag.released.load(ordering: .acquiring) {
        flag.ticks.add(1, ordering: .relaxed)
    }
}

@available(macOS 15, *)
private func spawn(_ body: @escaping @Sendable (DispatchSemaphore) -> Void) throws -> ThreadStackCapture {
    let handle = OSAllocatedUnfairLock<ThreadStackCapture?>(initialState: nil)
    let entered = DispatchSemaphore(value: 0)
    let thread = Thread {
        handle.withLock { $0 = ThreadStackCapture.currentThread() }
        body(entered)
    }
    thread.start()
    #expect(entered.wait(timeout: .now() + 5) == .success)
    return try #require(handle.withLock { $0 })
}

@Suite struct ThreadStackCaptureTests {
    @available(macOS 15, *)
    @Test func aStackTakenFromOutsideNamesTheFunctionTheThreadIsIn() throws {
        let flag = SpinFlag()
        let capture = try spawn { entered in stackCaptureSpinTarget(flag, entered: entered) }
        let stack = capture.capture()
        flag.released.store(true, ordering: .releasing)

        #if arch(arm64)
        #expect(stack.startsWithProgramCounter)
        #expect(stack.addresses.count >= 3, "leaf, the spin target and its callers")
        let frames = ThreadStackCapture.symbolicate(stack)
        #expect(
            frames.contains { $0.symbol?.contains("stackCaptureSpinTarget") == true },
            "\(frames.map(\.description))"
        )

        let target = try #require(frames.first { $0.symbol?.contains("stackCaptureSpinTarget") == true })
        #expect(ThreadStackCapture.isAppFrame(target))
        #expect(target.imageBase == ThreadStackCapture.ownImage.loadAddress)
        #expect(target.description.hasPrefix(target.symbol! + "+"))

        #expect(ThreadStackCapture.symbolicate(stack, dropLeading: 1).count == frames.count - 1)
        #else
        #expect(stack.addresses.isEmpty)
        #endif
    }

    @available(macOS 15, *)
    @Test func aCaptureOfAnIdleThreadIsQuickAndTheThreadKeepsRunning() throws {
        let flag = SpinFlag()
        let capture = try spawn { entered in
            entered.signal()
            while !flag.released.load(ordering: .acquiring) {
                flag.ticks.add(1, ordering: .relaxed)
                usleep(1_000)
            }
        }
        while flag.ticks.load(ordering: .relaxed) == 0 { usleep(1_000) }

        let start = ContinuousClock.now
        let stack = capture.capture()
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .milliseconds(100), "capture took \(elapsed)")
        #if arch(arm64)
        #expect(!stack.addresses.isEmpty)
        #endif
        let before = flag.ticks.load(ordering: .relaxed)
        let deadline = ContinuousClock.now + .seconds(2)
        while flag.ticks.load(ordering: .relaxed) <= before + 3, ContinuousClock.now < deadline {
            usleep(1_000)
        }
        #expect(flag.ticks.load(ordering: .relaxed) > before + 3, "the thread runs again after the capture")
        flag.released.store(true, ordering: .releasing)
    }

    @Test func theCallingThreadIsNeverSuspended() {

        #expect(ThreadStackCapture.currentThread().capture().addresses.isEmpty)
    }

    @Test func framesWithoutAnImageOrSymbolFallBack() {
        let unmapped = ThreadStackCapture.symbolicate(RawStack(addresses: [0x10], startsWithProgramCounter: true))
        #expect(unmapped.map(\.description) == ["0x10"])

        let noSymbol = StackFrame(address: 0x1_0000_1234, image: "MxU Slides", imageBase: 0x1_0000_0000, symbol: nil, symbolStart: 0)
        #expect(noSymbol.description == "MxU Slides+0x1234")
        let symbol = StackFrame(address: 0x1_0000_1234, image: "MxU Slides", imageBase: 0x1_0000_0000, symbol: "$s3Foo3baryyF", symbolStart: 0x1_0000_1200)
        #expect(symbol.description == "$s3Foo3baryyF+52")
    }

    @Test func aLinkRegisterBackInsideTheLeafIsDropped() throws {

        let own = try #require(
            ThreadStackCapture.symbolicate(RawStack(addresses: Thread.callStackReturnAddresses.map(\.uintValue))).first
        )
        let inside = own.symbolStart + 4
        let stack = RawStack(addresses: [inside, inside + 4, 0x10], startsWithProgramCounter: true, hasLinkRegister: true)
        #expect(ThreadStackCapture.symbolicate(stack).count == 2)
        let caller = RawStack(addresses: [inside, 0x10], startsWithProgramCounter: true, hasLinkRegister: true)
        #expect(ThreadStackCapture.symbolicate(caller).count == 2, "LR outside the leaf is its caller")
    }
}
