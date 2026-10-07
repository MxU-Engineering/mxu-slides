#if DEBUG || MXU_PERF_HOOKS
import AppKit
import PresenterCore
import QuartzCore

@MainActor
enum PerfHooks {
    nonisolated static let notificationPrefix = "com.example.mxuslides.perf."

    private static weak var editor: SlideEditorModel?

    static func start(model: AppModel) {
        guard let spec = ProcessInfo.processInfo.environment[PerfScenario.environmentKey] else { return }
        guard let scenario = PerfScenario(spec) else {
            DiagnosticsStore.shared.note("perf.scenario.failed", detail: "cannot read \(spec)")
            return
        }
        observe(["mark", "targets", "play", "stop"])
        Task { await run(scenario, spec: spec, model: model) }
    }

    private static func run(_ scenario: PerfScenario, spec: String, model: AppModel) async {
        DiagnosticsStore.shared.note("perf.scenario", detail: spec)
        guard await waitFor({ model.isLibraryReady ? true : nil }) != nil else {
            return fail("the library never opened")
        }
        fitWindow()
        switch scenario {
        case .idle:
            ready(center: nil, handle: nil)
        case .animate(let themeName, let layout):
            guard let editor = await open(named: themeName, in: .themes, model: model) else { return }
            guard let slide = editor.presentation.slides.first(where: { $0.name == layout }) else {
                return fail("no layout named \(layout)")
            }
            editor.selectSlide(slide.id)
            editor.editorMode = .animate
            try? await Task.sleep(for: .seconds(1))
            ready(center: nil, handle: nil)
        case .edit(let deckName, let number, let objectName):
            guard let editor = await open(named: deckName, in: .presentations, model: model) else { return }
            let slides = editor.presentation.slides
            guard slides.indices.contains(number - 1) else { return fail("\(deckName) has no slide \(number)") }
            editor.selectSlide(slides[number - 1].id)
            guard let object = editor.currentSlide?.objects.first(where: { $0.name == objectName }) else {
                return fail("slide \(number) has no object named \(objectName)")
            }
            editor.selectObject(id: object.id)
            try? await Task.sleep(for: .seconds(1))
            let points = canvas(showing: editor.presentation.id)?.perfPressPoints(objectID: object.id)
            ready(center: points?.center, handle: points?.handle)
        }
    }

    private static func open(named name: String, in section: LibrarySection, model: AppModel) async -> SlideEditorModel? {
        guard let entry = model.entries(in: section).first(where: { $0.name == name }) else {
            fail("no \(section) entry named \(name)")
            return nil
        }
        UserDefaults.standard.set(AppMode.edit.rawValue, forKey: "appMode")
        model.selectedSection = section
        model.librarySelection = [entry.id]
        guard let opened = await waitFor({ canvas(showing: entry.id)?.perfEditor }) else {
            fail("the editor never opened \(name)")
            return nil
        }
        editor = opened
        return opened
    }

    private static func waitFor<T>(_ value: () -> T?) async -> T? {
        for _ in 0..<600 {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func fitWindow() {
        guard let screen = NSScreen.main,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return }
        window.setFrame(screen.visibleFrame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func canvas(showing id: String) -> EditorInteractionNSView? {
        for window in NSApp.windows where window.isVisible {
            if let found = window.contentView.flatMap({ find(in: $0, id: id) }) { return found }
        }
        return nil
    }

    private static func find(in view: NSView, id: String) -> EditorInteractionNSView? {
        if let canvas = view as? EditorInteractionNSView, canvas.window != nil, canvas.bounds.width > 0,
           canvas.perfEditor.presentation.id == id {
            return canvas
        }
        for subview in view.subviews {
            if let found = find(in: subview, id: id) { return found }
        }
        return nil
    }

    private static func ready(center: CGPoint?, handle: CGPoint?) {
        DiagnosticsStore.shared.note("perf.scenario.ready", detail: PerfScenario.readyDetail(center: center, handle: handle))
    }

    private static func fail(_ why: String) {
        DiagnosticsStore.shared.note("perf.scenario.failed", detail: why)
    }

    private static func observe(_ names: [String]) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center, nil,
                { _, _, name, _, _ in
                    let signal = (name?.rawValue as String?)?.replacingOccurrences(of: PerfHooks.notificationPrefix, with: "")
                    DispatchQueue.main.async { MainActor.assumeIsolated { PerfHooks.signal(signal ?? "") } }
                },
                (notificationPrefix + name) as CFString, nil, .deliverImmediately)
        }
    }

    private static func signal(_ name: String) {
        switch name {
        case "mark":
            let bodies = DiagnosticsStore.shared.bodyMeter.withLock {
                $0.drainMark(names: MeteredView.allCases.map(\.name))
            }
            DiagnosticsStore.shared.note("perf.mark", detail: bodies)
        case "targets":
            let points = editor.flatMap { editor in
                editor.selectedObjectIDs.first.flatMap {
                    canvas(showing: editor.presentation.id)?.perfPressPoints(objectID: $0)
                }
            }
            DiagnosticsStore.shared.note(
                "perf.targets", detail: PerfScenario.readyDetail(center: points?.center, handle: points?.handle))
        case "play":
            if let editor {
                editor.previewRepeats = true
                editor.playAnimationPreview()
                DiagnosticsStore.shared.note("perf.play", detail: "\(editor.animationPreviewDuration) s on repeat")
            }
        case "stop":
            editor?.stopAnimationPreview()
        default:
            break
        }
    }
}
#endif
