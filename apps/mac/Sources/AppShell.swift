import PresenterCore
import SwiftUI

enum AppMode: String, CaseIterable {
    case present
    case edit
    case scheduler

    var title: String {
        switch self {
        case .present: "Present"
        case .edit: "Edit"
        case .scheduler: "Scheduler"
        }
    }
}

enum EditContext: String, CaseIterable {
    case slides
    case overlays
    case themes
    case confidence

    var title: String {
        switch self {
        case .slides: "Slides"
        case .overlays: "Overlays"
        case .themes: "Themes"
        case .confidence: "Confidence"
        }
    }

    var section: LibrarySection {
        switch self {
        case .slides: .presentations
        case .overlays: .overlays
        case .themes: .themes
        case .confidence: .confidence
        }
    }

    init?(section: LibrarySection) {
        switch section {
        case .presentations: self = .slides
        case .overlays: self = .overlays
        case .themes: self = .themes
        case .confidence: self = .confidence
        default: return nil
        }
    }

    @MainActor
    func apply(to model: AppModel) {
        model.selectedSection = section
        if let id = model.selectedEntryID,
           let entry = model.indexEntry(id),
           entry.kind != section.kind {
            model.selectedEntryID = nil
        }
    }
}

extension CornerStandard {

    static let panelInset: CGFloat = 8

    static var panel: CGFloat { nested(inset: panelInset) }
}

private struct FloatingPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                Color.cardSurface,
                in: RoundedRectangle.standard(CornerStandard.panel)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.panel)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
    }
}

extension View {
    func floatingPanel() -> some View {
        modifier(FloatingPanelStyle())
    }
}

struct SidebarGlyph: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(lineWidth: 1.4)
            Rectangle()
                .frame(width: 1.4)
                .padding(.vertical, 1.4)
                .offset(x: 5.6)
        }
        .frame(width: 17, height: 13.5)
        .foregroundStyle(.secondary)
    }
}

struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    let glyph: GlyphKind
    @ViewBuilder var accessory: Accessory

    init(_ title: String, glyph: GlyphKind, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.glyph = glyph
        self.accessory = accessory()
    }

    var body: some View {

        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

struct ModeSwitcher: View {
    @Binding var modeRaw: String
    @State private var hovering = false

    private var mode: AppMode { AppMode(rawValue: modeRaw) ?? .edit }

    var body: some View {
        Menu {
            ForEach(AppMode.allCases, id: \.rawValue) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { modeRaw == mode.rawValue },
                    set: { _ in modeRaw = mode.rawValue }
                ))
            }
        } label: {
            HStack(spacing: 5) {
                Text(mode.title)
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            hovering ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help("Switch between Present and Edit")
    }
}

struct EditContextSwitcher: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditContext.allCases, id: \.rawValue) { context in
                segment(context)
            }
        }
        .padding(2)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .help("Edit context — one editor, re-targeted (⌘3 ⌘4 ⌘5)")
    }

    private func segment(_ context: EditContext) -> some View {
        let selected = EditContext(section: model.selectedSection) == context
        return Button {
            context.apply(to: model)
        } label: {
            Text(context.title)
                .font(.caption.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)

                .background(
                    selected ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle.standard(
                        CornerStandard.nested(inset: 2, within: CornerStandard.element)
                    )
                )
                .contentShape(RoundedRectangle.standard(
                    CornerStandard.nested(inset: 2, within: CornerStandard.element)
                ))
        }
        .buttonStyle(.plain)
    }
}

struct ViewCommands: Commands {
    @FocusedValue(\.libraryModel) private var model
    @AppStorage("appMode") private var modeRaw = AppMode.edit.rawValue
    @AppStorage("shell.sidebarVisible") private var sidebarVisible = true
    @AppStorage(PresentLayoutController.rightRailHiddenKey) private var rightRailHidden = false
    @AppStorage("preview.screenTarget") private var previewTarget = ""
    @Environment(\.openWindow) private var openWindow

    @AppStorage(PresentLayoutController.lockedKey) private var runOnly = false

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Present") { modeRaw = AppMode.present.rawValue }
                .keyboardShortcut(command: .modePresent)

            Button("Edit") { modeRaw = AppMode.edit.rawValue }
                .keyboardShortcut(command: .modeEdit)
                .disabled(runOnly)
            Button("Scheduler") { modeRaw = AppMode.scheduler.rawValue }
                .keyboardShortcut(command: .modeScheduler)
                .disabled(runOnly)
            Divider()

            ForEach(Array(EditContext.allCases.enumerated()), id: \.element.rawValue) { index, context in
                Button("Edit \(context.title)") {
                    modeRaw = AppMode.edit.rawValue
                    if let model { context.apply(to: model) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 4)")), modifiers: .command)
                .disabled(model == nil || runOnly)
            }
            Divider()
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                sidebarVisible.toggle()
            }
            .keyboardShortcut(command: .toggleSidebar)

            Button(rightRailHidden ? "Show Right Panels" : "Hide Right Panels") {
                rightRailHidden.toggle()
            }
            .keyboardShortcut(command: .toggleRightPanels)
            Button("Move Right Panels to Windows") {
                rightRailHidden = true
                openWindow(id: "preview", value: previewTarget)
                openWindow(id: "serviceControls")
            }
            .disabled(runOnly)
        }
    }
}

struct ShellView: View {
    @Bindable var model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let presets: OutputPresetsController?
    let layout: PresentLayoutController?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.confidenceMonitor) private var confidenceMonitor

    @State private var pinFlow: PinFlow?

    private var workspaceImportAction: MenuAction? {
        if let render, let controls {
            MenuAction("workspaceImport") {
                WorkspaceImportRunner(
                    model: model, render: render, controls: controls,
                    confidenceMonitor: confidenceMonitor, presets: presets
                ).present()
            }
        } else {
            nil
        }
    }

    private var isRunOnly: Bool { layout?.runOnly ?? false }

    private var findInLibraryAction: MenuAction? {
        if isRunOnly {
            nil
        } else {
            MenuAction("findInLibrary") {
                if !sidebarVisible { sidebarVisible = true }
                model.libraryFindPending = true
            }
        }
    }

    private static let presentNewSlideAction = MenuAction("presentNewSlide") {
        NewSlideRouter.shared.request()
    }

    private var runOnlyLockChip: some View {
        Button {
            pinFlow = .verify
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text("Run-Only")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .help("Run-only mode — enter the passcode to exit")
    }


    @AppStorage("appMode") private var modeRaw = AppMode.edit.rawValue
    @AppStorage("present.continuous") private var continuousPresent = true

    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage("slideGrid.transparencyGrid") private var transparencyGrid = true
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback

    @AppStorage("diagnostics.performanceHUD") private var performanceHUD = false
    @AppStorage("shell.sidebarVisible") private var sidebarVisible = true
    @AppStorage("shell.sidebarSplit") private var splitFraction = 0.42
    @AppStorage("shell.sidebarWidth") private var sidebarWidth = 272.0

    @AppStorage("shell.sidebarWidthPresent") private var presentSidebarWidth = 272.0
    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @State private var widthGripHovering = false

    @State private var draftSidebarWidth: Double?

    @State private var sidebarDragStartWidth: Double?
    @State private var draftSplitFraction: Double?
    @State private var serviceItemID: String?

    @State private var presentFocusScroll = PresentFocusScroll()
    @State private var gripHovering = false
    @State private var gripDragging = false

    @AppStorage("shell.rightSplit") private var rightSplit = 0.5
    @State private var draftRightSplit: Double?
    @State private var rightGripHovering = false
    @State private var rightGripDragging = false

    @AppStorage("shell.rightRailWidth") private var rightRailWidth = 280.0

    @AppStorage(PresentLayoutController.rightRailHiddenKey) private var rightRailHidden = false

    @State private var shellWidth: CGFloat = 1480
    @State private var draftRightRailWidth: Double?

    @State private var rightRailDragStartWidth: Double?
    @State private var rightWidthGripHovering = false
    @State private var renamingServiceID: String?
    @State private var servicePickerOpen = false

    @State private var presentViewOpen = false

    static let servicePage = 12
    @State private var localShownLimit = 12
    @State private var localEarlierOpen = false
    @State private var localEarlierLimit = 12
    @State private var serviceRenameText = ""
    @State private var pendingServiceDelete: [String] = []

    @State private var versionNaming: ServiceVersionTarget?
    @State private var versionNameText = ""
    @State private var pendingVersionDelete: ServiceVersionTarget?
    @State private var editingServiceDateID: String?

    @State private var servicePickerSelection: Set<String> = []
    @State private var servicePickerAnchorID: String?

    private var mode: AppMode { AppMode(rawValue: modeRaw) ?? .edit }

    private var railVisible: Bool {
        (mode == .present || mode == .scheduler) && !rightRailHidden
    }

    static let headerHeight: CGFloat = 52

    static let minSidebarWidth: CGFloat = 272

    static let shellSpace = "shell"

    var body: some View {
        let _ = BodyMeter.tick(.shell)
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: draftSidebarWidth ?? sidebarWidth)
                    .overlay(alignment: .trailing) { widthGrip }
                    .transition(.move(edge: .leading))
            }
            mainRegion

            if railVisible {
                rightRail
                    .frame(width: draftRightRailWidth ?? rightRailWidth)
                    .overlay(alignment: .leading) { rightRailWidthGrip }
                    .padding([.trailing, .top, .bottom], CornerStandard.panelInset)
            }
        }
        .overlay(alignment: .top) {

            TitlebarBehavior()
                .frame(maxWidth: .infinity)
                .frame(height: Self.headerHeight)
                .padding(
                    .leading,
                    sidebarVisible
                        ? (draftSidebarWidth ?? sidebarWidth) + CornerStandard.panelInset
                        : 0
                )
                .padding(
                    .trailing,
                    railVisible
                        ? (draftRightRailWidth ?? rightRailWidth) + CornerStandard.panelInset
                        : 0
                )
        }
        .overlay(alignment: .top) {

            HStack(spacing: 8) {
                if isRunOnly {
                    runOnlyLockChip
                } else {
                    ModeSwitcher(modeRaw: $modeRaw)
                    if mode == .edit {
                        EditContextSwitcher(model: model)
                    }
                }
            }
            .frame(height: Self.headerHeight)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 94)
                sidebarToggle

                if mode == .present, !sidebarVisible {
                    if let name = currentServiceName {

                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    presentViewMenu
                    transitionChips
                }
            }
            .frame(height: Self.headerHeight)
        }

        .overlay(alignment: .topLeading) {
            if mode == .present, sidebarVisible {
                HStack(spacing: 6) {
                    presentViewMenu
                    transitionChips
                }
                .frame(height: Self.headerHeight)
                .padding(.leading, (draftSidebarWidth ?? sidebarWidth) + 16)
            }
        }

        .overlay(alignment: .topTrailing) {
            if let controls {

                HStack(spacing: 0) {

                    BroadcastStatusChip(controls: controls)

                    if let presets {
                        Spacer().frame(width: 8)
                        OutputPresetChip(presets: presets, showName: showPresetName)
                    }

                    ClearChip(controls: controls)
                        .padding(.leading, 8)
                    Spacer()
                        .frame(
                            width: railVisible
                                ? (draftRightRailWidth ?? rightRailWidth) + CornerStandard.panelInset + 16
                                : 16
                        )
                }
                .frame(height: Self.headerHeight)
            }
        }
        .animation(.easeOut(duration: 0.15), value: sidebarVisible)
        .coordinateSpace(name: Self.shellSpace)

        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ShellWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(ShellWidthKey.self) { shellWidth = $0 }
        .background(BasePlane())
        .background(WindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)

        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
        .focusedSceneValue(\.libraryModel, model)
        .focusedSceneValue(\.serviceControls, controls)
        .focusedSceneValue(\.presentWorkspaceImport, workspaceImportAction)
        .focusedSceneValue(\.presentLibrarySearch, findInLibraryAction)

        .focusedSceneValue(\.presentNewSlide, mode == .present ? Self.presentNewSlideAction : nil)

        .environment(\.runOnly, isRunOnly)
        .sheet(item: $pinFlow) { flow in
            PasscodeSheet(
                flow: flow,
                verify: { layout?.verifyPIN($0) ?? false },
                waitSeconds: { layout?.pinWaitSeconds() ?? 0 }
            ) { pin in
                switch flow {
                case .set:
                    layout?.setPIN(pin)
                    layout?.enterRunOnly()
                case .change:
                    layout?.setPIN(pin)
                case .verify:
                    layout?.exitRunOnly(openWindow: openWindow, dismissWindow: dismissWindow)
                }
            }
        }

        .task {
            await model.resident.ready([.service, .serviceLinkRules, .media, .audio, .playlist])
        }

        .task {
            guard let layout else { return }
            for module in layout.poppedOut {
                openWindow(id: "module", value: module)
            }
            for target in layout.openPreviews.sorted() {
                openWindow(id: "preview", value: target)
            }
            if layout.serviceControlsWindowOpen {
                openWindow(id: "serviceControls")
            }
        }
        .onAppear {
            WindowBridge.openMain = { openWindow(id: "main") }

            WindowBridge.openPreview = { openWindow(id: "preview", value: $0) }
            if let render {
                WindowBridge.previewScreens = { PreviewTargets.screens(render) }
            }

            model.adoptFallbackServiceIfNeeded()
            model.protectEditorSelection = mode == .edit

            if sidebarWidth < Self.minSidebarWidth { sidebarWidth = Self.minSidebarWidth }
            if presentSidebarWidth < Self.minSidebarWidth {
                presentSidebarWidth = Self.minSidebarWidth
            }
        }
        .onChange(of: serviceItemID) { _, itemID in
            if mode == .edit {
                openRunOrderItemInEditor(itemID)

                if itemID != nil { model.retargetPresentReturn(entryID: nil) }
            } else if itemID != nil {

                model.selectedEntryID = nil
            }
        }
        .onChange(of: model.selectedEntryID) { _, entryID in

            presentFocusScroll.reset()
            if mode == .present, entryID != nil {
                serviceItemID = nil
            }
        }

        .onChange(of: model.currentServiceID) { _, _ in presentFocusScroll.reset() }
        .onChange(of: continuousPresent) { _, _ in presentFocusScroll.reset() }
        .onChange(of: modeRaw) { oldRaw, _ in
            presentFocusScroll.reset()

            if isRunOnly && mode != .present {
                modeRaw = AppMode.present.rawValue
            } else {
                if oldRaw == AppMode.present.rawValue {
                    model.stashPresentSelection()
                }

                model.protectEditorSelection = mode == .edit

                if mode == .edit {
                    if model.pendingEditorSlideID == nil {
                        openRunOrderItemInEditor(serviceItemID)
                    }
                    model.restoreEditorSelection()
                }

                if mode == .present {
                    model.stashEditorSelection()
                    model.restorePresentSelection()
                }

                withAnimation(.easeOut(duration: 0.15)) {
                    if mode == .edit {
                        presentSidebarWidth = sidebarWidth
                        sidebarWidth = Self.minSidebarWidth
                    } else {
                        sidebarWidth = presentSidebarWidth
                    }
                }
            }
        }
        .onChange(of: model.selectedEntryID) { _, entryID in
            adoptSelectedService(entryID)
        }
        .alert(
            "Rename Service",
            isPresented: Binding(
                get: { renamingServiceID != nil },
                set: { if !$0 { renamingServiceID = nil } }
            )
        ) {
            TextField("Name", text: $serviceRenameText)
            Button("Rename") {
                if let serviceID = renamingServiceID,
                   let entry = model.indexEntry(serviceID) {
                    model.rename(entry, to: serviceRenameText)
                }
                renamingServiceID = nil
            }
            Button("Cancel", role: .cancel) { renamingServiceID = nil }
        }
        .alert(
            pendingServiceDelete.count > 1
                ? "Delete \(pendingServiceDelete.count) Services?"
                : "Delete Service?",
            isPresented: Binding(
                get: { !pendingServiceDelete.isEmpty },
                set: { if !$0 { pendingServiceDelete = [] } }
            )
        ) {
            Button("Delete", role: .destructive) {
                let deleting = pendingServiceDelete
                for serviceID in deleting {
                    if let entry = model.indexEntry(serviceID) {
                        model.delete(entry)
                    }
                }
                if let current = model.currentServiceID, deleting.contains(current) {
                    serviceItemID = nil
                }
                pendingServiceDelete = []

                model.adoptFallbackServiceIfNeeded()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingServiceDelete.count > 1
                ? "The run orders are deleted; the presentations and media in them stay in the library."
                : "The run order is deleted; the presentations and media in it stay in the library.")
        }
    }

    private var sidebar: some View {
        GeometryReader { geo in
            let gap = CornerStandard.panelInset
            let available = geo.size.height - gap
            let topHeight = min(
                max(available * (draftSplitFraction ?? splitFraction), 170), available - 180
            )
            VStack(spacing: 0) {

                VStack(spacing: 0) {

                    HStack {
                        Spacer()
                        Text("Service Flow")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    serviceHeader
                    Divider()
                    serviceSection
                }
                .frame(height: isRunOnly ? nil : topHeight)
                .frame(maxHeight: isRunOnly ? .infinity : nil)
                .floatingPanel()

                if !isRunOnly {
                    splitGrip(available: available)
                        .frame(height: gap)

                    LibrarySidebar(model: model, render: render, layout: layout, controls: controls)
                        .frame(maxHeight: .infinity)
                        .floatingPanel()
                        .inputRegion("library")
                }
            }
            .coordinateSpace(name: "sidebar")
        }
        .padding([.leading, .top, .bottom], CornerStandard.panelInset)
    }

    private var widthGrip: some View {
        ZStack {
            Color.clear
            if widthGripHovering || draftSidebarWidth != nil {
                Capsule()
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 3, height: 28)
            }
        }
        .frame(width: 10)

        .overlay {
            ResizeGripArea(
                hovering: { widthGripHovering = $0 },
                changed: { moved in
                    let start = sidebarDragStartWidth ?? sidebarWidth
                    sidebarDragStartWidth = start
                    draftSidebarWidth = PanelResize.width(
                        start: start, moved: moved, leadingEdge: false, range: Self.minSidebarWidth ... 420)
                },
                ended: {
                    if let draft = draftSidebarWidth { sidebarWidth = draft }
                    draftSidebarWidth = nil
                    sidebarDragStartWidth = nil
                })
            .padding(.horizontal, -3)
        }
    }

    private var sidebarToggle: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            SidebarGlyph()
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Toggle the sidebar")
    }

    @ViewBuilder
    private var serviceSection: some View {
        if let serviceID = model.currentServiceID {
            VStack(spacing: 0) {
                RunOrderList(
                    model: model, controls: controls, serviceID: serviceID, render: render,
                    selectedItemID: $serviceItemID,

                    onReselect: { if mode == .present { presentFocusScroll.reselect() } }
                )
            }
        } else {
            ContentUnavailableView(
                "No Service", systemImage: "calendar",
                description: Text("Create one from the menu above.")
            )
        }
    }

    private var serviceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                serviceMenu
                Spacer(minLength: 0)
                if let label = serviceDateLabel {
                    if !isRunOnly {
                        Button {
                            editingServiceDateID = model.currentServiceID
                        } label: {
                            HStack(spacing: 3) {
                                Text(label)

                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7, weight: .semibold))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Change the service date")
                    } else {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("The service date")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .popover(
            isPresented: Binding(
                get: { editingServiceDateID != nil && !isRunOnly },
                set: { if !$0 { editingServiceDateID = nil } }
            ),
            arrowEdge: .bottom
        ) {

            if let serviceID = editingServiceDateID,
               let service = try? model.service(serviceID) {
                VStack(spacing: 4) {
                    Text(model.indexEntry(serviceID)?.name ?? "Service")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: {
                                ServiceMenuLogic.parseISODate(service.serviceDate) ?? .now
                            },
                            set: { date in
                                model.updateService(serviceID) {
                                    $0.serviceDate = AppModel.isoDate(date)
                                }
                            }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                }
                .frame(width: 260)
                .padding(10)
            }
        }
    }

    private var serviceDateLabel: String? {
        guard let serviceID = model.currentServiceID,
              let service = try? model.service(serviceID) else { return nil }
        guard let date = ServiceMenuLogic.parseISODate(service.serviceDate)
        else { return service.serviceDate }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    private var serviceMenu: some View {
        Button {
            servicePickerOpen.toggle()
        } label: {

            HStack(spacing: 4) {
                Text(serviceName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $servicePickerOpen, arrowEdge: .bottom) {
            servicePickerPopup
        }
        .modifier(versionAlerts)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }

    private var serviceName: String {
        guard let serviceID = model.currentServiceID,
              let entry = model.indexEntry(serviceID)
        else { return "Choose…" }

        let version = (try? model.mainService(serviceID)).flatMap(model.runningVersion(of:))
        return version.map { "\(entry.name) · \($0.name)" } ?? entry.name
    }

    private static let serviceDateColumnWidth: CGFloat = 82

    private var servicePickerPopup: some View {
        let grouped = Self.groupLocalServices(model.entries(in: .services), today: Self.localToday())
        let currentShown = Array(grouped.current.prefix(localShownLimit))
        let earlierShown = localEarlierOpen ? Array(grouped.earlier.prefix(localEarlierLimit)) : []
        let visible = currentShown + earlierShown

        let versions: [String: [ServiceVersion]] = Dictionary(uniqueKeysWithValues: visible.compactMap { entry in
            (try? model.mainService(entry.id))?.versions.flatMap { $0.isEmpty ? nil : (entry.id, $0) }
        })
        let rowCount = currentShown.count
            + (grouped.current.count > currentShown.count ? 1 : 0)
            + (grouped.earlier.isEmpty ? 0 : 1)
            + earlierShown.count
            + (localEarlierOpen && grouped.earlier.count > earlierShown.count ? 1 : 0)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(currentShown, id: \.id) { entry in
                        servicePickerRow(entry, entries: visible, versions: versions[entry.id])
                    }
                    if grouped.current.count > currentShown.count {
                        showMoreRow(remaining: grouped.current.count - currentShown.count) {
                            localShownLimit += Self.servicePage
                        }
                    }
                    if !grouped.earlier.isEmpty {
                        earlierRow(count: grouped.earlier.count, isOpen: $localEarlierOpen)
                        if localEarlierOpen {
                            ForEach(earlierShown, id: \.id) { entry in
                                servicePickerRow(entry, entries: visible, versions: versions[entry.id])
                            }
                            if grouped.earlier.count > earlierShown.count {
                                showMoreRow(remaining: grouped.earlier.count - earlierShown.count) {
                                    localEarlierLimit += Self.servicePage
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }

            .frame(height: min(CGFloat(rowCount) * 23 + 11, 334))

            if !isRunOnly {
                Divider()
                VStack(spacing: 1) {
                    servicePickerAction("New Service") {
                        if let id = model.createEntity(in: .services) {
                            model.currentServiceID = id
                            serviceItemID = nil
                        }
                    }
                }
                .padding(6)
            }
        }
        .font(.system(size: 12))
        .frame(width: 320)
        .onAppear {
            servicePickerSelection = []
            servicePickerAnchorID = nil
            localShownLimit = Self.servicePage
            localEarlierOpen = false
            localEarlierLimit = Self.servicePage
        }
    }

    static func groupLocalServices(
        _ entries: [LibraryIndex.Entry], today: String
    ) -> (current: [LibraryIndex.Entry], earlier: [LibraryIndex.Entry]) {
        let dated = entries.filter { !$0.subkind.isEmpty }
        let undated = entries.filter { $0.subkind.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let upcoming = dated.filter { $0.subkind >= today }.sorted { $0.subkind < $1.subkind }
        let earlier = dated.filter { $0.subkind < today }.sorted { $0.subkind > $1.subkind }
        return (upcoming + undated, earlier)
    }

    static func localToday() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }

    private func showMoreRow(remaining: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 12)
                Text("Show \(min(remaining, Self.servicePage)) more")
                Text("\(remaining)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func earlierRow(count: Int, isOpen: Binding<Bool>) -> some View {
        Button {
            isOpen.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                    .frame(width: 12)
                Text("Earlier")
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func servicePickerRow(
        _ entry: LibraryIndex.Entry, entries: [LibraryIndex.Entry], versions: [ServiceVersion]?
    ) -> some View {
        let isCurrent = entry.id == model.currentServiceID
        let isSelected = servicePickerSelection.contains(entry.id)
        return Button {
            servicePickerRowClicked(entry, entries: entries)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if versions != nil {
                    Color.clear.frame(width: Self.serviceVersionChipWidth, height: 1)
                }
                Text(ServiceMenuLogic.dateColumnLabel(subkind: entry.subkind))
                    .foregroundStyle(entry.subkind.isEmpty ? .tertiary : .secondary)
                    .monospacedDigit()
                    .frame(width: Self.serviceDateColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.22)
                : isCurrent ? Color.primary.opacity(0.06) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )

        .help(entry.name)
        .overlay(alignment: .trailing) {
            if let versions {
                serviceVersionMenu(entry, versions: versions)
                    .padding(.trailing, 6 + Self.serviceDateColumnWidth + 8)
            }
        }

        .contextMenu { servicePickerRowMenu(entry) }
    }

    private var versionAlerts: some ViewModifier {
        ServiceVersionAlerts(
            model: model, naming: $versionNaming, nameText: $versionNameText, pendingDelete: $pendingVersionDelete)
    }

    private static let serviceVersionChipWidth: CGFloat = 110

    private func serviceVersionMenu(_ entry: LibraryIndex.Entry, versions: [ServiceVersion]) -> some View {
        let running = (try? model.mainService(entry.id)).flatMap(model.runningVersion(of:))
        return Menu {
            Toggle("Main", isOn: Binding(get: { running == nil }, set: { _ in runServiceVersion(entry, versionID: nil) }))
            ForEach(versions) { version in
                let computers = (version.stations ?? []).map(\.name).joined(separator: ", ")
                Toggle(
                    computers.isEmpty ? version.name : "\(version.name) \u{2014} \(computers)",
                    isOn: Binding(get: { running?.id == version.id }, set: { _ in runServiceVersion(entry, versionID: version.id) }))
            }
            if !isRunOnly {
                Divider()
                Button("New Version\u{2026}") {
                    versionNameText = ""
                    closeServicePickerThen { versionNaming = ServiceVersionTarget(serviceID: entry.id, versionID: nil) }
                }
                if let running {
                    Button("Rename \u{201C}\(running.name)\u{201D}\u{2026}") {
                        versionNameText = running.name
                        closeServicePickerThen { versionNaming = ServiceVersionTarget(serviceID: entry.id, versionID: running.id) }
                    }
                    Button("Delete \u{201C}\(running.name)\u{201D}\u{2026}", role: .destructive) {
                        closeServicePickerThen { pendingVersionDelete = ServiceVersionTarget(serviceID: entry.id, versionID: running.id) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(running?.name ?? "Main")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: Self.serviceVersionChipWidth, alignment: .trailing)
        .help("Which version of this service this computer runs")
    }

    private func runServiceVersion(_ entry: LibraryIndex.Entry, versionID: String?) {
        servicePickerSelection = []
        servicePickerAnchorID = nil
        model.chooseServiceVersion(entry.id, versionID: versionID)
        model.currentServiceID = entry.id
        serviceItemID = nil
        servicePickerOpen = false
    }

    private func servicePickerRowClicked(
        _ entry: LibraryIndex.Entry, entries: [LibraryIndex.Entry]
    ) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if servicePickerSelection.contains(entry.id) {
                servicePickerSelection.remove(entry.id)
            } else {
                servicePickerSelection.insert(entry.id)
            }
            servicePickerAnchorID = entry.id
        } else if flags.contains(.shift) {
            let anchorID = servicePickerAnchorID ?? entry.id
            if let anchor = entries.firstIndex(where: { $0.id == anchorID }),
               let clicked = entries.firstIndex(where: { $0.id == entry.id }) {
                let range = min(anchor, clicked)...max(anchor, clicked)
                servicePickerSelection = Set(entries[range].map(\.id))
            }
        } else {
            servicePickerSelection = []
            servicePickerAnchorID = nil
            model.currentServiceID = entry.id
            serviceItemID = nil
            servicePickerOpen = false
        }
    }

    private func selectAllServices() {
        servicePickerSelection = Set(model.entries(in: .services).map(\.id))
    }

    @ViewBuilder
    private func servicePickerRowMenu(_ entry: LibraryIndex.Entry) -> some View {
        if !isRunOnly {
            let ids = servicePickerSelection.contains(entry.id)
                ? Array(servicePickerSelection) : [entry.id]
            if ids.count == 1 {
                Button("Rename…") {
                    serviceRenameText = entry.name
                    closeServicePickerThen { renamingServiceID = entry.id }
                }
                Button("Change Date…") {
                    closeServicePickerThen { editingServiceDateID = entry.id }
                }
                Button("Duplicate") { model.duplicate(entry) }
                Button("New Version…") {
                    versionNameText = ""
                    closeServicePickerThen { versionNaming = ServiceVersionTarget(serviceID: entry.id, versionID: nil) }
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    closeServicePickerThen { pendingServiceDelete = ids }
                }
            } else {
                Button("Duplicate \(ids.count) Services") {
                    for id in ids {
                        if let target = model.indexEntry(id) {
                            model.duplicate(target)
                        }
                    }
                }
                Button("Delete \(ids.count) Services…", role: .destructive) {
                    closeServicePickerThen { pendingServiceDelete = ids }
                }
            }
            Divider()
            Button("Select All") { selectAllServices() }
        }
    }

    private func closeServicePickerThen(_ action: @escaping () -> Void) {
        servicePickerOpen = false
        DispatchQueue.main.async { action() }
    }

    private func servicePickerAction(
        _ title: String, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button {
            servicePickerOpen = false
            DispatchQueue.main.async { action() }
        } label: {
            Text(title)
                .foregroundStyle(destructive ? Color.red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func splitGrip(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            if gripHovering || gripDragging {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 28, height: 3)
            }
        }
        .contentShape(Rectangle().inset(by: -3))
        .onHover { inside in
            gripHovering = inside

            guard !gripDragging else { return }
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(coordinateSpace: .named("sidebar"))
                .onChanged { value in
                    guard available > 0 else { return }
                    gripDragging = true
                    draftSplitFraction = min(max(value.location.y / available, 0.15), 0.8)
                }
                .onEnded { _ in
                    if let draft = draftSplitFraction { splitFraction = draft }
                    draftSplitFraction = nil
                    gripDragging = false
                    if !gripHovering { NSCursor.pop() }
                }
        )
    }

    private var rightRail: some View {
        GeometryReader { geo in
            let gap = CornerStandard.panelInset
            let available = geo.size.height - gap
            let topHeight = min(
                max(available * (draftRightSplit ?? rightSplit), 200), max(200, available - 160)
            )
            VStack(spacing: 0) {
                LivePanel(
                    model: model, render: render, controls: controls,
                    layout: layout
                )
                    .frame(height: topHeight)
                    .floatingPanel()
                rightSplitGrip(available: available)
                    .frame(height: gap)
                ServiceControlsPanel(
                    model: model, controls: controls, presets: presets, layout: layout
                )
                    .frame(maxHeight: .infinity)
                    .floatingPanel()
            }
            .coordinateSpace(name: "rightRail")
        }
    }

    private var rightRailWidthGrip: some View {
        ZStack {
            Color.clear
            if rightWidthGripHovering || draftRightRailWidth != nil {
                Capsule()
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 3, height: 28)
            }
        }
        .frame(width: 10)

        .overlay {
            ResizeGripArea(
                hovering: { rightWidthGripHovering = $0 },
                changed: { moved in
                    let start = rightRailDragStartWidth ?? rightRailWidth
                    rightRailDragStartWidth = start
                    draftRightRailWidth = PanelResize.width(
                        start: start, moved: moved, leadingEdge: true, range: 240 ... 480)
                },
                ended: {
                    if let draft = draftRightRailWidth { rightRailWidth = draft }
                    draftRightRailWidth = nil
                    rightRailDragStartWidth = nil
                })
            .padding(.horizontal, -3)
        }
    }

    private func rightSplitGrip(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            if rightGripHovering || rightGripDragging {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 28, height: 3)
            }
        }
        .contentShape(Rectangle().inset(by: -3))
        .onHover { inside in
            rightGripHovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(coordinateSpace: .named("rightRail"))
                .onChanged { value in
                    guard available > 0 else { return }
                    rightGripDragging = true
                    draftRightSplit = min(max(value.location.y / available, 0.25), 0.85)
                }
                .onEnded { _ in
                    if let draft = draftRightSplit { rightSplit = draft }
                    draftRightSplit = nil
                    rightGripDragging = false
                }
        )
    }

    private var editorTakesOver: Bool {
        guard mode == .edit, let id = model.selectedEntryID,
              let entry = model.indexEntry(id)
        else { return false }

        return entry.kind == .presentation || entry.kind == .theme || entry.kind == .overlay
            || entry.kind == .confidenceLayout || entry.kind == .media || entry.kind == .audio
    }

    private var mainRegion: some View {
        VStack(spacing: 0) {
            if !editorTakesOver {
                Color.clear
                    .frame(height: Self.headerHeight)
            }

            HStack(spacing: 0) {
                centerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, CornerStandard.panelInset)
                    .padding(.bottom, mode == .present ? 0 : CornerStandard.panelInset)
                    .padding(.top, editorTakesOver ? CornerStandard.panelInset : 0)

                    .clipped()

            }

            if mode == .present, !editorTakesOver {
                presentFooter
            }
        }

        .overlay(alignment: .bottom) {
            if mode != .present || editorTakesOver {
                MediaTransportStrip(controls: controls, floating: true)
                    .padding(.bottom, 14)
            }
        }

        .overlay(alignment: .bottomLeading) {
            if performanceHUD, let controls, let render {
                PerformanceHUD(render: render, media: controls.media)
                    .padding(.leading, 14)
                    .padding(.bottom, 60)
            }
        }
    }

    private var presentFooter: some View {
        MediaTransportStrip(controls: controls)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: Self.headerHeight)
            .padding(.horizontal, 12)

            .overlay(alignment: .trailing) {
                if let controls {
                    AutoAdvanceChip(controls: controls)
                        .padding(.trailing, 12)
                }
            }
    }

    private var centerWidth: CGFloat {
        shellWidth
            - (sidebarVisible ? (draftSidebarWidth ?? sidebarWidth) : 0)
            - (railVisible ? (draftRightRailWidth ?? rightRailWidth) + CornerStandard.panelInset : 0)
    }

    private var showTransitionSliders: Bool { centerWidth > 950 }
    private var showPresetName: Bool { centerWidth > 800 }

    private var transitionChips: some View {
        HStack(spacing: 10) {
            TransitionChip(
                glyph: .media,
                kindKey: "transition.media.kind", durationKey: "transition.media.duration",
                fallbackKind: TransitionKind.dissolve.rawValue, fallbackDuration: 0.7,
                showSlider: showTransitionSliders
            )
            TransitionChip(
                glyph: .presentations,
                kindKey: "transition.slide.kind", durationKey: "transition.slide.duration",
                fallbackKind: "", fallbackDuration: 0.5,
                showSlider: showTransitionSliders
            )
        }
        .fixedSize()
    }

    private var presentViewMenu: some View {
        Button {
            presentViewOpen.toggle()
        } label: {

            Glyph(kind: .viewOptions, size: 17)
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Present view preferences — thumbnails only, never output")
        .popover(isPresented: $presentViewOpen, arrowEdge: .bottom) {
            presentViewPopover
        }
    }

    private var presentViewPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Slides Across")
                Spacer(minLength: 8)
                SlidesAcrossControl(count: $slidesAcross)
                    .frame(width: 150)
            }
            Divider()
            Toggle("Continuous Service View", isOn: $continuousPresent)
            presentViewHeading("Thumbnails")
            Toggle("Rounded Corners", isOn: $roundedCorners)
            Toggle("Readable Text", isOn: $legibleText)
            Toggle("Backgrounds Only on Declaring Slide", isOn: $hideScopedBackgrounds)
            Toggle("Transparency Grid", isOn: $transparencyGrid)
            Divider()
            Toggle("Performance HUD", isOn: $performanceHUD)
        }

        .toggleStyle(InspectorToggleStyle())
        .padding(10)
        .font(.system(size: 12))
        .frame(width: 280)
    }

    private func presentViewHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var currentServiceName: String? {
        guard let serviceID = model.currentServiceID else { return nil }
        return model.indexEntry(serviceID)?.name
    }

    @ViewBuilder
    private var centerContent: some View {
        switch mode {
        case .present:

            if let id = model.selectedEntryID,
               let entry = model.indexEntry(id),
               entry.kind == .presentation || entry.kind == .media || entry.kind == .audio {
                if entry.kind == .presentation {
                    PresentGridView(
                        model: model, render: render, controls: controls,
                        presentationID: entry.id, arrangementId: nil
                    )
                    .id(entry.id)
                    .inputRegion("single deck")
                } else if entry.kind == .media {
                    MediaFireView(model: model, controls: controls, mediaID: entry.id)
                } else {

                    AudioFireView(model: model, controls: controls, audioID: entry.id)
                }
            } else if let serviceID = model.currentServiceID {
                if continuousPresent {

                    ServiceContinuousView(
                        model: model, render: render, controls: controls,
                        serviceID: serviceID, focusItemID: serviceItemID,
                        focusScroll: $presentFocusScroll
                    )
                } else {
                    ServiceItemDetailView(
                        model: model, render: render, controls: controls,
                        serviceID: serviceID, itemID: serviceItemID
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Service", systemImage: "calendar",
                    description: Text("Choose a service to present.")
                )
            }
        case .edit:
            editDetail
        case .scheduler:

            SchedulerView(model: model, controls: controls)
        }
    }

    @ViewBuilder
    private var editDetail: some View {
        if let id = model.selectedEntryID,
           let entry = model.indexEntry(id) {
            switch entry.kind {
            case .presentation, .theme, .overlay, .confidenceLayout:

                SlideEditorView(
                    appModel: model, render: render,
                    presentationID: entry.id, isTheme: entry.kind == .theme,
                    isOverlay: entry.kind == .overlay,
                    isConfidenceLayout: entry.kind == .confidenceLayout
                )

                .id("\(entry.id)::\(model.importReplaceVersion)")
            case .service:

                ServiceItemDetailView(
                    model: model, render: render, controls: controls,
                    serviceID: entry.id, itemID: serviceItemID
                )
            case .media, .audio:

                MediaEditorView(model: model, entry: entry)
                    .id(entry.id)
            default:
                InspectorView(model: model, entry: entry)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView(
                "Nothing Open", systemImage: "sidebar.left",
                description: Text("Pick a library item to edit, or a service item to review.")
            )
        }
    }

    private func openRunOrderItemInEditor(_ itemID: String?) {
        guard mode == .edit, let itemID, let serviceID = model.currentServiceID,
              let service = try? model.service(serviceID),
              let item = service.items.first(where: { $0.id == itemID }),
              !item.refId.isEmpty
        else { return }
        if let entry = model.indexEntry(item.refId) {
            switch entry.kind {
            case .presentation: model.selectedSection = .presentations
            case .media: model.selectedSection = .media
            default: break
            }
            model.selectedEntryID = entry.id
        }
    }

    private func adoptSelectedService(_ entryID: String?) {
        guard let entryID,
              let entry = model.indexEntry(entryID),
              entry.kind == .service
        else { return }
        if model.currentServiceID != entry.id {
            model.currentServiceID = entry.id
            serviceItemID = nil
        }
    }
}

private struct TitlebarBehavior: NSViewRepresentable {
    final class CatcherView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.zoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { CatcherView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.configure(nsView.window)
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        if window.toolbar == nil {
            window.toolbar = NSToolbar(identifier: "shell-chrome")
        }
        window.toolbarStyle = .unified
    }
}

struct BasePlane: View {
    var body: some View {
        Color.basePlane
            .ignoresSafeArea()
    }
}

private struct ShellWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension FocusedValues {

    @Entry var libraryModel: AppModel?

    @Entry var presentLibrarySearch: MenuAction?

    @Entry var presentLyricImport: MenuAction?

    @Entry var presentNewSlide: MenuAction?

    @Entry var presentWorkspaceImport: MenuAction?

    @Entry var serviceControls: ServiceControls?

    @Entry var slideEditor: SlideEditorModel?
}

struct ServiceVersionTarget: Equatable {
    let serviceID: String
    let versionID: String?
}

private struct ServiceVersionAlerts: ViewModifier {
    let model: AppModel
    @Binding var naming: ServiceVersionTarget?
    @Binding var nameText: String
    @Binding var pendingDelete: ServiceVersionTarget?

    func body(content: Content) -> some View {
        content
            .alert(
                naming?.versionID == nil ? "New Version" : "Rename Version",
                isPresented: Binding(
                    get: { naming != nil },
                    set: { if !$0 { naming = nil } }
                )
            ) {
                TextField("Name", text: $nameText)
                Button(naming?.versionID == nil ? "Create" : "Rename") {
                    let name = nameText.trimmingCharacters(in: .whitespaces)
                    if let target = naming, !name.isEmpty {
                        if let versionID = target.versionID {
                            model.renameServiceVersion(target.serviceID, versionID: versionID, name: name)
                        } else {
                            model.createServiceVersion(target.serviceID, name: name)
                            model.currentServiceID = target.serviceID
                        }
                    }
                    naming = nil
                }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                if naming?.versionID == nil {
                    Text("A version starts as a copy of Main. This computer runs it; changes you make while it runs stay in the version, and Main is untouched.")
                }
            }
            .alert(
                "Delete Version?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let target = pendingDelete, let versionID = target.versionID {
                        model.deleteServiceVersion(target.serviceID, versionID: versionID)
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its changes are deleted, and any computer running it goes back to Main.")
            }
    }
}
