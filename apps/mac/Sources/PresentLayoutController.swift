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

    private(set) var openNotes: Set<String> = []

    private(set) var serviceControlsWindowOpen = false
    static let serviceControlsAutosaveName = "serviceControls.panel"

    private(set) var libraryWindowOpen = false
    static let libraryAutosaveName = "library.panel"
    static let rightRailHiddenKey = "shell.rightRailHidden"

    private(set) var layouts: [PresentLayout] = []

    private(set) var activeLayoutID: String?

    enum NotesPanelPlacement: String, CaseIterable {
        case hidden, beside, below
    }
    private(set) var notesPanel: NotesPanelPlacement = .hidden
    private(set) var notesPanelNoteID: String?

    private(set) var runOnly = false

    private(set) var runOnlyModules: [ServiceControlsModule]?

    private(set) var runOnlyLibraryKinds = LibraryPresentLogic.volunteerDefaultKinds

    private static let poppedKey = "serviceControls.poppedOut"
    private static let previewKey = "present.previewPopped"  
    private static let previewsKey = "present.openPreviewTargets"
    private static let notesKey = "present.openNotes"
    private static let serviceControlsWindowKey = "present.serviceControlsWindow"
    private static let libraryWindowKey = "present.libraryWindow"
    private static let layoutsKey = "present.layouts"
    private static let activeKey = "present.activeLayoutID"
    private static let notesPanelKey = "present.notesPanel"
    private static let notesPanelNoteKey = "present.notesPanelNoteID"
    static let lockedKey = "present.runOnly"
    private static let runOnlyModulesKey = "present.runOnlyModules"
    private static let runOnlyLibrariesKey = "present.runOnlyLibraries"

    private static let retiredPINKey = "present.runOnlyPIN"
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

    func noteWindowOpened(_ noteID: String) {
        guard !openNotes.contains(noteID) else { return }
        openNotes.insert(noteID)
        save()
    }

    func noteWindowClosed(_ noteID: String) {
        guard openNotes.contains(noteID) else { return }
        openNotes.remove(noteID)
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

    func libraryWindowOpened() {
        if !libraryWindowOpen {
            libraryWindowOpen = true
            save()
        }
    }

    func libraryWindowClosed() {
        if libraryWindowOpen {
            libraryWindowOpen = false
            save()
        }
    }

    func showNotesPanel(_ placement: NotesPanelPlacement, noteID: String) {
        notesPanel = placement
        notesPanelNoteID = noteID
        save()
    }

    func hideNotesPanel() {
        notesPanel = .hidden
        save()
    }

    private func save() {
        UserDefaults.standard.set(poppedOut.map(\.rawValue).sorted(), forKey: Self.poppedKey)
        UserDefaults.standard.set(openPreviews.sorted(), forKey: Self.previewsKey)
        UserDefaults.standard.set(openNotes.sorted(), forKey: Self.notesKey)
        UserDefaults.standard.set(serviceControlsWindowOpen, forKey: Self.serviceControlsWindowKey)
        UserDefaults.standard.set(libraryWindowOpen, forKey: Self.libraryWindowKey)
        UserDefaults.standard.set(notesPanel.rawValue, forKey: Self.notesPanelKey)
        UserDefaults.standard.set(notesPanelNoteID, forKey: Self.notesPanelNoteKey)
    }

    private func restore() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.poppedKey) ?? []
        poppedOut = Set(raw.compactMap(ServiceControlsModule.init(rawValue:)))
        openPreviews = Set(UserDefaults.standard.stringArray(forKey: Self.previewsKey) ?? [])
        openNotes = Set(UserDefaults.standard.stringArray(forKey: Self.notesKey) ?? [])
        serviceControlsWindowOpen = UserDefaults.standard.bool(forKey: Self.serviceControlsWindowKey)
        libraryWindowOpen = UserDefaults.standard.bool(forKey: Self.libraryWindowKey)
        notesPanel = UserDefaults.standard.string(forKey: Self.notesPanelKey)
            .flatMap(NotesPanelPlacement.init(rawValue:)) ?? .hidden
        notesPanelNoteID = UserDefaults.standard.string(forKey: Self.notesPanelNoteKey)

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
        UserDefaults.standard.removeObject(forKey: Self.retiredPINKey)
        runOnlyModules = UserDefaults.standard.string(forKey: Self.runOnlyModulesKey)
            .map(Self.modules(from:))
        runOnlyLibraryKinds = LibraryPresentLogic.volunteerKinds(
            stored: UserDefaults.standard.string(forKey: Self.runOnlyLibrariesKey))
    }

    func enterRunOnly(applying apply: (() -> Void)? = nil) {
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

    var volunteerLibraryKinds: Set<DocumentKind>? {
        runOnly ? Set(runOnlyLibraryKinds) : nil
    }

    func setRunOnlyLibraryKinds(_ kinds: [DocumentKind]) {
        runOnlyLibraryKinds = kinds
        UserDefaults.standard.set(kinds.map(\.rawValue).joined(separator: ","), forKey: Self.runOnlyLibrariesKey)
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
        for note in layout.openNotes ?? [] {
            if let frame = note.frame {
                defaults.set(frame, forKey: "NSWindow Frame \(NoteWindowView.autosaveName(for: note.id))")
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

        let wantedNotes = Set((layout.openNotes ?? []).map(\.id))
        for noteID in openNotes.subtracting(wantedNotes) {
            dismissWindow(id: "note", value: noteID)
        }
        for note in layout.openNotes ?? [] {
            openWindow(id: "note", value: note.id)
            if let frame = note.frame,
               let window = Self.window(autosaveName: NoteWindowView.autosaveName(for: note.id)) {
                window.setFrame(from: frame)
            }
        }
        openNotes = wantedNotes

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
        if let raw = layout.notesPanel {
            notesPanel = NotesPanelPlacement(rawValue: raw) ?? .hidden
            notesPanelNoteID = layout.notesPanelNoteID
        }
        if let width = layout.notesPanelWidth { defaults.set(width, forKey: "shell.notesPanelWidth") }
        if let height = layout.notesBelowHeight { defaults.set(height, forKey: "shell.notesBelowHeight") }
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
            openNotes: openNotes.sorted().map { noteID in
                PresentLayout.PoppedNote(
                    id: noteID,
                    frame: Self.frameDescriptor(autosaveName: NoteWindowView.autosaveName(for: noteID))
                )
            },
            notesPanel: notesPanel.rawValue,
            notesPanelNoteID: notesPanelNoteID,
            notesPanelWidth: defaults.object(forKey: "shell.notesPanelWidth") as? Double,
            notesBelowHeight: defaults.object(forKey: "shell.notesBelowHeight") as? Double,
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
