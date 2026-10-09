import PresenterCore
import SwiftUI

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isRestorable = false }
    }
}

@MainActor
enum WindowBridge {
    static var openMain: (() -> Void)?

    static var openPreview: ((String) -> Void)?
    static var previewScreens: (() -> [(id: String, name: String)])?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        MainActor.assumeIsolated {
            if let main = NSApp.windows.first(where: {
                $0.identifier?.rawValue.hasPrefix("main") == true
            }) {
                if main.isMiniaturized { main.deminiaturize(nil) }
                main.makeKeyAndOrderFront(nil)
            } else {
                WindowBridge.openMain?()
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            PresentationFileOpener.open(urls)
        }
    }
}

@main
struct MxUSlidesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var renderContext: RenderContext?
    @State private var appModel: AppModel?

    @State private var controls: ServiceControls?

    @State private var outputPresets: OutputPresetsController?

    @State private var presentLayout = PresentLayoutController()

    @State private var localAPI: LocalAPIController?

    @State private var actionRouter: ActionRouter?

    @State private var confidenceMonitor: ConfidenceMonitorController?

    @State private var scheduler: SchedulerController?

    @State private var midiIn: MIDIInController?

    @State private var keyIn: KeyInController?

    @State private var signage: SignageController?

    @State private var mediaPlaylists: MediaPlaylistController?

    @State private var serviceTracking: ServiceTimingController?

    init() {

        BackupSettings.applyPending()

        DiagnosticsStore.shared.activate()

        MainThreadOpenTrap.armAtLaunch()
        MenuTrackingRecorder.shared.activate()

        InputTrailRecorder.shared.activate()

        SheetWatchRecorder.shared.activate()

        FeedbackController.shared.activate()

        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 250,
        ])

        NDINetworkScope.apply()
        NDINetworkScope.watchNetworkChanges()
        let render = RenderContext()

        UserDefaults.standard.set(AppMode.present.rawValue, forKey: "appMode")
        let model = AppModel()
        PresentationFileOpener.model = model
        #if DEBUG || MXU_PERF_HOOKS

        PerfHooks.start(model: model)
        #endif
        _renderContext = State(initialValue: render)
        _appModel = State(initialValue: model)
        if let render {
            let controls = ServiceControls(appModel: model, render: render)
            let presets = OutputPresetsController(
                appModel: model, outputs: render.outputs, controls: controls
            )
            let confidence = ConfidenceMonitorController(
                appModel: model, render: render, controls: controls
            )

            let signageController = SignageController(appModel: model, render: render)

            controls.signage = signageController
            let mediaPlaylistController = MediaPlaylistController(
                appModel: model, controls: controls
            )
            _mediaPlaylists = State(initialValue: mediaPlaylistController)
            let router = ActionRouter(
                model: model, controls: controls, presets: presets,
                confidenceMonitor: confidence, signage: signageController
            )
            controls.actionRouter = router
            _actionRouter = State(initialValue: router)
            _confidenceMonitor = State(initialValue: confidence)
            let schedulerController = SchedulerController(
                model: model, controls: controls, router: router
            )
            _scheduler = State(initialValue: schedulerController)
            _signage = State(initialValue: signageController)
            _controls = State(initialValue: controls)
            _outputPresets = State(initialValue: presets)
            let api = LocalAPIController(
                appModel: model, controls: controls,
                outputPresets: presets, render: render,
                scheduler: schedulerController
            )
            _localAPI = State(initialValue: api)
            MIDIDeviceInventory.shared.configure(model: model)

            let midiIn = MIDIInController(
                model: model, controls: controls, router: router, bridge: api.bridge
            )
            midiIn.attach()
            _midiIn = State(initialValue: midiIn)

            let keyIn = KeyInController(
                model: model, controls: controls, router: router, bridge: api.bridge
            )
            keyIn.attach()
            _keyIn = State(initialValue: keyIn)
            let tracking = ServiceTimingController(model: model, controls: controls, render: render)
            controls.serviceTracking = tracking
            _serviceTracking = State(initialValue: tracking)
        }
    }

    var body: some Scene {

        WindowGroup("MxU Slides", id: "main") {
            if let appModel, appModel.libraryOpenError != nil {

                Text("Could not open the library.")
                    .padding(40)
            } else if let appModel, !appModel.isLibraryReady {

                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening the library…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(minWidth: 1280, minHeight: 640)
            } else if let appModel {

                ShellView(
                    model: appModel, render: renderContext,
                    controls: controls, presets: outputPresets,
                    layout: presentLayout
                )
                .environment(\.actionRouter, actionRouter)
                .environment(\.scheduler, scheduler)
                .environment(\.confidenceMonitor, confidenceMonitor)
                .environment(\.signage, signage)
                .environment(\.mediaPlaylists, mediaPlaylists)

                .overlay(alignment: .bottom) {
                    GoToSlideHUD(keyIn: keyIn).padding(.bottom, 48)
                }
                .frame(minWidth: 1280, minHeight: 640)

                .sheet(isPresented: $showWelcome) {
                    OnboardingView(
                        model: appModel, render: renderContext,
                        importWorkspace: welcomeImportAction
                    ) { showWelcome = false }
                }
                .onChange(of: showWelcome) { appModel.welcomeShowing = showWelcome }
                .task {
                    if appModel.needsOnboarding && !presentLayout.runOnly {
                        showWelcome = true
                    }
                }

                .sheet(isPresented: $showFeedback) {
                    FeedbackView(model: appModel) { showFeedback = false }
                }
                .onChange(of: FeedbackController.shared.lastRunCrashed, initial: true) { _, crashed in
                    if crashed && !showWelcome && !presentLayout.runOnly {
                        showFeedback = true
                    }
                }
                .task { openEngineWindowIfSoaking() }
                .task { await actionRouter?.runStartupCombos() }
                .task { await scheduler?.start() }
            } else {
                Text("Could not open the library.")
                    .padding(40)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1480, height: 900)
        .commands {
            LibraryCommands()
            EditorCommands(journal: appModel?.moveUndo)
            ViewCommands()
            PresentCommands()
            HelpCommands(model: appModel, showWelcome: $showWelcome, showFeedback: $showFeedback)
        }

        Settings {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "Settings")
                    .frame(width: 420, height: 260)
            } else {
                AppSettingsView(
                    model: appModel, controls: controls, layout: presentLayout,
                    api: localAPI)
            }
        }

        WindowGroup(id: "module", for: ServiceControlsModule.self) { $module in
            if let appModel, let module {
                ModuleWindowView(
                    module: module, model: appModel,
                    controls: controls, presets: outputPresets, layout: presentLayout
                )
                .environment(\.confidenceMonitor, confidenceMonitor)
                .environment(\.signage, signage)
                .environment(\.mediaPlaylists, mediaPlaylists)
            }
        }
        .defaultSize(width: 360, height: 460)

        Window("Service Controls", id: "serviceControls") {
            if let appModel {
                ServiceControlsWindowView(
                    model: appModel, controls: controls,
                    presets: outputPresets, layout: presentLayout
                )
                .environment(\.confidenceMonitor, confidenceMonitor)
                .environment(\.signage, signage)
                .environment(\.mediaPlaylists, mediaPlaylists)
                .environment(\.actionRouter, actionRouter)
                .environment(\.scheduler, scheduler)
            }
        }
        .defaultSize(width: 420, height: 520)

        WindowGroup(id: "preview", for: String.self) { $target in
            PreviewWindowView(
                render: renderContext, controls: controls, layout: presentLayout,
                target: target ?? ""
            )

            .environment(\.confidenceMonitor, confidenceMonitor)
        }
        .defaultSize(width: 640, height: 380)

        Window("Screen Configuration", id: "outputs") {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "Screen Configuration")
                    .background(NonRestorableWindow())
            } else {
                OutputsWindow(render: renderContext, presets: outputPresets)
                    .background(NonRestorableWindow())
                    .environment(\.signage, signage)
            }
        }
        .defaultSize(width: 780, height: 540)

        Window("Engine", id: "engine") {
            if presentLayout.runOnly {
                RunOnlyLockedPlaceholder(surface: "The Engine rig")
                    .background(NonRestorableWindow())
            } else if let renderContext {
                ContentView(render: renderContext, presets: outputPresets)
                    .background(NonRestorableWindow())
                    .task { await AutoSoak.runIfRequested(render: renderContext) }
            } else {
                Text("Metal is not available on this machine.")
                    .padding(40)
            }
        }
        .commandsRemoved()
    }

    @Environment(\.openWindow) private var openWindow

    @State private var showWelcome = false

    @State private var showFeedback = false

    private var welcomeImportAction: ((@escaping (ImportActivityModel?) -> Void) -> Void)? {
        if let appModel, let renderContext, let controls {
            { host in
                WorkspaceImportRunner(
                    model: appModel, render: renderContext, controls: controls,
                    confidenceMonitor: confidenceMonitor, presets: outputPresets,
                    inlineHost: host
                ).present()
            }
        } else {
            nil
        }
    }

    private func openEngineWindowIfSoaking() {
        if CommandLine.arguments.contains("--soak-minutes") {
            openWindow(id: "engine")
        }
    }
}
