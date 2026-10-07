import Foundation
import QuartzCore

public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) {
        storage = value
    }

    public var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    @discardableResult
    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&storage) }
    }
}

public final class RenderThread: @unchecked Sendable {
    public static let shared = RenderThread()

    private final class LoopBox: @unchecked Sendable {
        var runLoop: RunLoop?
    }

    private let thread: Thread
    private let loopBox = LoopBox()

    private init() {
        let box = loopBox
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.runLoop = RunLoop.current

            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "RenderEngine.RenderThread"
        thread.qualityOfService = .userInteractive
        thread.threadPriority = 1.0
        self.thread = thread
        thread.start()
        ready.wait()
    }

    public var runLoop: RunLoop {
        loopBox.runLoop!
    }

    public var isCurrent: Bool {
        Thread.current === thread
    }

    public func perform(_ work: @escaping @Sendable () -> Void) {
        if isCurrent {
            work()
            return
        }
        guard let runLoop = loopBox.runLoop else { return }
        runLoop.perform(work)
        CFRunLoopWakeUp(runLoop.getCFRunLoop())
    }
}
