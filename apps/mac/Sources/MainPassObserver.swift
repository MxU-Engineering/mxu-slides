import AppKit
import PresenterCore
import QuartzCore

@MainActor
final class MainPassObserver {
    static let shared = MainPassObserver()

    private var passStart: Double?
    private var observers: [CFRunLoopObserver] = []
    private var inputMonitor: Any?

    private init() {}

    func start() {
        if observers.isEmpty {

            let began = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault,
                CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.entry.rawValue
                    | CFRunLoopActivity.exit.rawValue,
                true, CFIndex.min
            ) { _, activity in
                MainActor.assumeIsolated { MainPassObserver.shared.passBegan(activity) }
            }
            let ended = CFRunLoopObserverCreateWithHandler(
                kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
            ) { _, _ in
                MainActor.assumeIsolated { MainPassObserver.shared.passEnded() }
            }
            for observer in [began, ended].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }

            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.inputEvents) { event in
                let now = CACurrentMediaTime()
                DiagnosticsStore.shared.spin.withLock { $0.input(at: now) }
                return event
            }
        }
    }

    private static let inputEvents: NSEvent.EventTypeMask = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .keyDown, .keyUp, .flagsChanged, .scrollWheel,
        .magnify, .rotate, .swipe, .smartMagnify, .gesture,
    ]

    private func passBegan(_ activity: CFRunLoopActivity) {
        if activity == .afterWaiting || passStart == nil {
            let now = CACurrentMediaTime()
            passStart = now
            DiagnosticsStore.shared.spin.withLock { $0.passBegan(at: now) }
        }
    }

    private func passEnded() {

        let opens = Library.takeMainPassOpens()
        let statements = LibraryIndex.takeMainThreadStatementCount()
        if let start = passStart {
            passStart = nil
            let now = CACurrentMediaTime()
            DiagnosticsStore.shared.spin.withLock { $0.passEnded(at: now) }
            let line = DiagnosticsStore.shared.passMeter.withLock {
                $0.finish(ms: (now - start) * 1000, opens: opens, sqlStatements: statements, now: now)
            }
            if let line {
                let mode = RunLoopModeName.short(
                    CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String })
                DiagnosticsStore.shared.note("perf.pass", detail: line.detail(mode: mode))
            }
        }
    }
}
