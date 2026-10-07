import AppKit
import Foundation
import Observation
import PresenterCore
import SwiftUI

@MainActor
@Observable
final class PresentLayoutController {

    private(set) var poppedOut: Set<ServiceControlsModule> = []

    private(set) var openPreviews: Set<String> = []

    private(set) var serviceControlsWindowOpen = false
    static let serviceControlsAutosaveName = "serviceControls.panel"
    static let rightRailHiddenKey = "shell.rightRailHidden"

    private(set) var layouts: [PresentLayout] = []

    private(set) var activeLayoutID: String?

    private(set) var runOnly = false

    private(set) var attempts = RunOnlyAttempts()

    private(set) var runOnlyModules: [ServiceControlsModule]?

    private static let poppedKey = "serviceControls.poppedOut"
    private static let previewKey = "present.previewPopped"  
    private static let previewsKey = "present.openPreviewTargets"
    private static let serviceControlsWindowKey = "present.serviceControlsWindow"
    private static let layoutsKey = "present.layouts"
    private static let activeKey = "present.activeLayoutID"
    static let lockedKey = "present.runOnly"
    private static let runOnlyModulesKey = "present.runOnlyModules"
    private static let pinKey = "present.runOnlyPIN"
    private static let preRunOnlyKey = "present.preRunOnly"

    init() {
        restore()
    }

    func popOut(_ module: ServiceControlsModule) {
        poppedOut.insert(module)
        save()
    }

    func returnToRail(_ module: ServiceControlsModule) {
        poppedOut.remove(module)
        save()
    }

    func previewOpened(_ target: String) {
        guard !openPreviews.contains(target) else { return }
        openPreviews.insert(target)
        save()
    }

    func previewClosed(_ target: String) {
        guard openPreviews.contains(target) else { return }
        openPreviews.remove(target)
        save()
    }

    func serviceControlsWindowOpened() {
        if !serviceControlsWindowOpen {
            serviceControlsWindowOpen = true
            save()
        }
    }

    func serviceControlsWindowClosed() {
        if serviceControlsWindowOpen {
            serviceControlsWindowOpen = false
            UserDefaults.standard.set(false, forKey: Self.rightRailHiddenKey)
            save()
        }
    }

    private func save() {
        UserDefaults.standard.set(poppedOut.map(\.rawValue).sorted(), forKey: Self.poppedKey)
        UserDefaults.standard.set(openPreviews.sorted(), forKey: Self.previewsKey)
        UserDefaults.standard.set(serviceControlsWindowOpen, forKey: Self.serviceControlsWindowKey)
    }

    private func restore() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.poppedKey) ?? []
        poppedOut = Set(raw.compactMap(ServiceControlsModule.init(rawValue:)))
        openPreviews = Set(UserDefaults.standard.stringArray(forKey: Self.previewsKey) ?? [])
        serviceControlsWindowOpen = UserDefaults.standard.bool(forKey: Self.serviceControlsWindowKey)

        if openPreviews.isEmpty, UserDefaults.standard.bool(forKey: Self.previewKey) {
            openPreviews = [""]
            UserDefaults.standard.removeObject(forKey: Self.previewKey)
        }
        if let data = UserDefaults.standard.data(forKey: Self.layoutsKey),
           let saved = try? JSONDecoder().decode([PresentLayout].self, from: data) {
            layouts = saved
        }
        activeLayoutID = UserDefaults.standard.string(forKey: Self.activeKey)
        runOnly = UserDefaults.standard.bool(forKey: Self.lockedKey)
        runOnlyModules = UserDefaults.standard.string(forKey: Self.runOnlyModulesKey)
            .map(Self.modules(from:))
    }

    var hasPIN: Bool {
        UserDefaults.standard.string(forKey: Self.pinKey) != nil
    }

    func setPIN(_ pin: String) {
        UserDefaults.standard.set(RunOnlyPasscode.record(for: pin), forKey: Self.pinKey)
    }

    func verifyPIN(_ pin: String) -> Bool {
        let record = UserDefaults.standard.string(forKey: Self.pinKey)
        let matched = record.map { RunOnlyPasscode.matches(pin, record: $0) } ?? false
        if matched {
            attempts.noteSuccess()
        } else {
            attempts.noteFailure(at: Date())
        }
        return matched
    }

    func pinWaitSeconds() -> Int {
        attempts.secondsLeft(at: Date())
    }

    func enterRunOnly(applying apply: (() -> Void)? = nil) {
        guard hasPIN else { return }
        if let data = try? JSONEncoder().encode(captureCurrent()) {
            UserDefaults.standard.set(data, forKey: Self.preRunOnlyKey)
        }
        apply?()
        UserDefaults.standard.set(AppMode.present.rawValue, forKey: "appMode")
        runOnly = true
        UserDefaults.standard.set(true, forKey: Self.lockedKey)
    }

    var volunteerModules: Set<ServiceControlsModule>? {
        runOnly ? runOnlyModules.map(Set.init) : nil
    }

    var suggestedRunOnlyModules: [ServiceControlsModule] {
        let hidden = Self.modules(from: UserDefaults.standard.string(forKey: "serviceControls.hiddenModules") ?? "")
        return runOnlyModules
            ?? ServiceControlsModule.defaultOrder.filter { !hidden.contains($0) }
    }

    func setRunOnlyModules(_ modules: [ServiceControlsModule]) {
        runOnlyModules = modules
        UserDefaults.standard.set(modules.map(\.rawValue).joined(separator: ","), forKey: Self.runOnlyModulesKey)
    }

    func setLayoutRunOnlyModules(id: String, _ modules: [ServiceControlsModule]) {
        if let index = layouts.firstIndex(where: { $0.id == id }) {
            layouts[index].runOnlyModules = modules.map(\.rawValue)
            saveLayouts()
        }
    }

    static func modules(from raw: String) -> [ServiceControlsModule] {
        raw.split(separator: ",").compactMap { ServiceControlsModule(rawValue: String($0)) }
    }

    func exitRunOnly(openWindow: OpenWindowAction, dismissWindow: DismissWindowAction) {
        runOnly = false
        UserDefaults.standard.set(false, forKey: Self.lockedKey)
        if let data = UserDefaults.standard.data(forKey: Self.preRunOnlyKey),
           let snapshot = try? JSONDecoder().decode(PresentLayout.self, from: data) {
            apply(snapshot, openWindow: openWindow, dismissWindow: dismissWindow)

            activeLayoutID = nil
            saveLayouts()
        }
        UserDefaults.standard.removeObject(forKey: Self.preRunOnlyKey)
    }

    @discardableResult
    func saveLayout(named name: String) -> PresentLayout {
        var layout = captureCurrent()
        layout.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Layout" : name
        layouts.append(layout)
        activeLayoutID = layout.id
        saveLayouts()
        return layout
    }

    func updateLayout(id: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        var fresh = captureCurrent()
        fresh.id = layouts[index].id
        fresh.name = layouts[index].name
        fresh.runOnly = layouts[index].runOnly
        fresh.runOnlyModules = layouts[index].runOnlyModules
        layouts[index] = fresh
        activeLayoutID = id
        saveLayouts()
    }

    func renameLayout(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].name = trimmed
        saveLayouts()
    }

    func setLayoutRunOnly(id: String, _ runOnly: Bool) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].runOnly = runOnly
        saveLayouts()
    }

    func deleteLayout(id: String) {
        layouts.removeAll { $0.id == id }
        if activeLayoutID == id { activeLayoutID = nil }
        saveLayouts()
    }

    func layout(id: String) -> PresentLayout? {
        layouts.first { $0.id == id }
    }

    func apply(
        _ layout: PresentLayout,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        let defaults = UserDefaults.standard
        defaults.set(layout.selectedModule, forKey: "serviceControls.module")
        defaults.set(layout.rightRailWidth, forKey: "shell.rightRailWidth")
        defaults.set(layout.rightSplit, forKey: "shell.rightSplit")
        defaults.set(layout.sidebarWidth, forKey: "shell.sidebarWidth")
        defaults.set(layout.sidebarVisible, forKey: "shell.sidebarVisible")
        defaults.set(layout.rightRailHidden ?? false, forKey: Self.rightRailHiddenKey)
        if let frame = layout.serviceControlsWindowFrame {
            defaults.set(frame, forKey: "NSWindow Frame \(Self.serviceControlsAutosaveName)")
        }

        for popped in layout.poppedOut {
            if let frame = popped.frame {
                defaults.set(frame, forKey: "NSWindow Frame serviceControls.module.\(popped.module)")
            }
        }
        for preview in layout.previewWindows {
            if let frame = preview.frame {
                defaults.set(
                    frame,
                    forKey: "NSWindow Frame \(PreviewWindowView.autosaveName(for: preview.target))")
            }
        }

        let wanted = Set(layout.poppedOut.compactMap {
            ServiceControlsModule(rawValue: $0.module)
        })
        for module in poppedOut.subtracting(wanted) {
            dismissWindow(id: "module", value: module)
        }
        for module in wanted {
            openWindow(id: "module", value: module)

            if let frame = layout.poppedOut.first(where: { $0.module == module.rawValue })?.frame,
               let window = Self.window(autosaveName: "serviceControls.module.\(module.rawValue)") {
                window.setFrame(from: frame)
            }
        }
        poppedOut = wanted

        let wantedPreviews = Set(layout.previewWindows.map(\.target))
        for target in openPreviews.subtracting(wantedPreviews) {
            dismissWindow(id: "preview", value: target)
        }
        for preview in layout.previewWindows {
            openWindow(id: "preview", value: preview.target)
            if let frame = preview.frame,
               let window = Self.window(
                   autosaveName: PreviewWindowView.autosaveName(for: preview.target)) {
                window.setFrame(from: frame)
            }
        }
        openPreviews = wantedPreviews

        let wantsServiceControls = layout.serviceControlsWindowOpen ?? false
        serviceControlsWindowOpen = wantsServiceControls
        if wantsServiceControls {
            openWindow(id: "serviceControls")
            if let frame = layout.serviceControlsWindowFrame,
               let window = Self.window(autosaveName: Self.serviceControlsAutosaveName) {
                window.setFrame(from: frame)
            }
        } else {
            dismissWindow(id: "serviceControls")
        }
        activeLayoutID = layout.id
        save()
        saveLayouts()
    }

    private func captureCurrent() -> PresentLayout {
        let defaults = UserDefaults.standard
        return PresentLayout(
            id: UUID().uuidString,
            name: "Layout",
            selectedModule: defaults.string(forKey: "serviceControls.module")
                ?? ServiceControlsModule.audio.rawValue,
            poppedOut: poppedOut.map { module in
                PresentLayout.PoppedModule(
                    module: module.rawValue,
                    frame: Self.frameDescriptor(
                        autosaveName: "serviceControls.module.\(module.rawValue)"
                    )
                )
            }.sorted { $0.module < $1.module },
            openPreviews: openPreviews.sorted().map { target in
                PresentLayout.PoppedPreview(
                    target: target,
                    frame: Self.frameDescriptor(
                        autosaveName: PreviewWindowView.autosaveName(for: target))
                )
            },
            rightRailWidth: defaults.object(forKey: "shell.rightRailWidth") as? Double ?? 280,
            rightSplit: defaults.object(forKey: "shell.rightSplit") as? Double ?? 0.5,
            sidebarWidth: defaults.object(forKey: "shell.sidebarWidth") as? Double ?? 272,
            sidebarVisible: defaults.object(forKey: "shell.sidebarVisible") as? Bool ?? true,
            rightRailHidden: defaults.bool(forKey: Self.rightRailHiddenKey),
            serviceControlsWindowOpen: serviceControlsWindowOpen,
            serviceControlsWindowFrame: Self.frameDescriptor(
                autosaveName: Self.serviceControlsAutosaveName),
            runOnly: false
        )
    }

    private static func frameDescriptor(autosaveName: String) -> String? {
        if let window = window(autosaveName: autosaveName) {
            return window.frameDescriptor
        }
        return UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)")
    }

    private static func window(autosaveName: String) -> NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == autosaveName }
    }

    private func saveLayouts() {
        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.layoutsKey)
        }
        UserDefaults.standard.set(activeLayoutID, forKey: Self.activeKey)
    }
}
