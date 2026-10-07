import PresenterCore
import QuartzCore

enum MeteredView: Int, CaseIterable {
    case shell
    case librarySidebar
    case slideEditor
    case slideObjectInspector
    case animationTimelinePanel
    case serviceContinuous

    var name: String {
        switch self {
        case .shell: "ShellView"
        case .librarySidebar: "LibrarySidebar"
        case .slideEditor: "SlideEditorView"
        case .slideObjectInspector: "SlideObjectInspector"
        case .animationTimelinePanel: "AnimationTimelinePanel"
        case .serviceContinuous: "ServiceContinuousView"
        }
    }

    var limit: Int {
        switch self {
        case .shell, .librarySidebar, .slideObjectInspector, .animationTimelinePanel, .serviceContinuous: 20
        case .slideEditor: 20
        }
    }
}

enum BodyMeter {

    static func tick(_ view: MeteredView) {
        let now = CACurrentMediaTime()
        if let storm = DiagnosticsStore.shared.bodyMeter.withLock({ $0.tick(view.rawValue, now: now) }) {
            let name = MeteredView(rawValue: storm.view)?.name ?? "?"
            DiagnosticsStore.shared.note(
                "perf.bodyStorm",
                detail: PerfLineLimiter.annotate(
                    "view=\(name) \(storm.perSecond)/s for \(storm.seconds) s", dropped: storm.dropped))
        }
    }
}
