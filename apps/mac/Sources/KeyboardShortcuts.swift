import AppKit
import PresenterCore
import SlideScene
import SwiftUI

@MainActor
@Observable
final class KeyMapStore {
    static let shared = KeyMapStore()
    static let defaultsKey = "keyboard.map"

    var map: KeyCommandMap {
        didSet {
            guard map != oldValue else { return }
            if let data = try? JSONEncoder().encode(map) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    var recorder: ((KeyRecorderResult) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(KeyCommandMap.self, from: data) {
            map = stored
        } else {
            map = KeyCommandMap()
        }
    }
}

enum KeyRecorderResult {
    case chord(KeyChord)
    case unbind
    case cancel
}

extension KeyChord {

    static func from(_ event: NSEvent) -> KeyChord? {
        guard event.type == .keyDown,
              let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first
        else { return nil }
        let token: String
        switch scalar.value {
        case 0xF700: token = "up"
        case 0xF701: token = "down"
        case 0xF702: token = "left"
        case 0xF703: token = "right"
        case 0xF704 ... 0xF70F: token = "f\(scalar.value - 0xF703)"
        case 0x0D, 0x03: token = "return"
        case 0x1B: token = "escape"
        case 0x7F, 0x08: token = "delete"
        case 0xF728: token = "delete" 
        case 0x09: token = "tab"
        case 0x20: token = "space"
        default:
            guard scalar.value >= 0x21 else { return nil }
            token = String(scalar).lowercased()
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyChord(
            token,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }

    var keyEquivalent: KeyEquivalent? {
        let token = KeyChord.normalizeToken(key)
        switch token {
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "space": return .space
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "tab": return .tab
        default:
            if token.hasPrefix("f"), let number = Int(token.dropFirst()),
               (1 ... 12).contains(number),
               let scalar = UnicodeScalar(0xF703 + UInt32(number)) {
                return KeyEquivalent(Character(scalar))
            }
            guard token.count == 1, let character = token.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if hasCommand { modifiers.insert(.command) }
        if hasOption { modifiers.insert(.option) }
        if hasControl { modifiers.insert(.control) }
        if hasShift { modifiers.insert(.shift) }
        return modifiers
    }
}

extension View {

    @ViewBuilder
    func keyboardShortcut(command: KeyCommand) -> some View {
        let chord = KeyMapStore.shared.map.chords(for: command).first
        if let chord, let equivalent = chord.keyEquivalent {
            keyboardShortcut(equivalent, modifiers: chord.eventModifiers)
        } else {
            self
        }
    }
}

@MainActor
@Observable
final class KeyInController {
    private let model: AppModel
    private let controls: ServiceControls
    private let router: ActionRouter
    private let bridge: AppAPIBridge

    private(set) var goToBuffer = ""
    private var goToExpiry: Task<Void, Never>?

    init(model: AppModel, controls: ServiceControls, router: ActionRouter, bridge: AppAPIBridge) {
        self.model = model
        self.controls = controls
        self.router = router
        self.bridge = bridge
    }

    func attach() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handle(event) ? nil : event
        }
    }

    private static let monitorExecuted: Set<KeyCommand> = [
        .nextSlide, .previousSlide, .nextServiceItem, .previousServiceItem,
        .videoPlayPause, .videoGoToBeginning, .openKeyboardSettings,
    ]

    private func handle(_ event: NSEvent) -> Bool {
        guard let chord = KeyChord.from(event) else { return false }

        if let recorder = KeyMapStore.shared.recorder {
            switch KeyChord.normalizeToken(chord.key) {
            case "escape" where chord.isBare: recorder(.cancel)
            case "delete" where chord.isBare: recorder(.unbind)
            default: recorder(.chord(chord))
            }
            return true
        }

        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextView {
            cancelGoTo()
            return false
        }

        if NSApp.keyWindow?.attachedSheet != nil { return false }

        let runOnly = UserDefaults.standard.bool(forKey: PresentLayoutController.lockedKey)

        let onShowSurface = ["main", "module", "preview"].contains { prefix in
            NSApp.keyWindow?.identifier?.rawValue.hasPrefix(prefix) == true
        }
        let inPresentMode = UserDefaults.standard.string(forKey: "appMode")
            .map { $0 == AppMode.present.rawValue } ?? true
        let presentActive = onShowSurface && inPresentMode
        if !presentActive { cancelGoTo() }

        if presentActive, !goToBuffer.isEmpty, chord.isBare {
            switch KeyChord.normalizeToken(chord.key) {
            case "return": commitGoTo(); return true
            case "escape": cancelGoTo(); return true
            case "delete": goToBuffer = String(goToBuffer.dropLast()); armGoToExpiry(); return true
            case let token where token.count == 1 && token.first!.isNumber:
                appendGoTo(token); return true
            default: cancelGoTo() 
            }
        }

        if let target = KeyMapStore.shared.map.resolve(
            chord: chord, activeScopes: presentActive ? [.present] : []
        ) {
            switch target {
            case let locked where runOnly && !locked.runsInRunOnly:
                DiagnosticsStore.shared.note("key.in.runOnly", detail: chord.display)
                return true
            case .command(let command) where Self.monitorExecuted.contains(command):

                if command == .nextSlide || command == .previousSlide,
                   command.defaultChords.contains(where: { $0.matches(chord) }) {
                    return false
                }
                execute(command)
                return true
            case .generated(let key):
                dispatch(key)
                return true
            case .command:
                return false 
            }
        }

        guard presentActive, chord.isBare else { return false }
        let token = KeyChord.normalizeToken(chord.key)
        if token.count == 1, let character = token.first {
            if character.isNumber {
                appendGoTo(token)
                return true
            }
            if character.isLetter {
                return fireHotKey(letter: token)
            }
        }
        return false
    }

    private func execute(_ command: KeyCommand) {
        DiagnosticsStore.shared.note("key.in", detail: command.rawValue)
        switch command {
        case .nextSlide:
            bridge.advanceIgnoringErrors(steps: 1, settled: false)
            controls.noteKeyboardFire()
        case .previousSlide:
            bridge.advanceIgnoringErrors(steps: -1, settled: false)
            controls.noteKeyboardFire()
        case .nextServiceItem: try? bridge.advanceServiceItem(steps: 1)
        case .previousServiceItem: try? bridge.advanceServiceItem(steps: -1)
        case .videoPlayPause:
            for row in controls.media.rows { controls.media.togglePlayPause(row.id) }
        case .videoGoToBeginning:
            for row in controls.media.rows { controls.media.resetToStart(row.id) }
        case .openKeyboardSettings: openKeyboardSettings()
        default: break 
        }
    }

    private func openKeyboardSettings() {
        openSettingsPage(SettingsCategory.keyboard.rawValue)
    }

    private func dispatch(_ key: GeneratedKey) {
        DiagnosticsStore.shared.note("key.in", detail: key.mapKey)
        switch key.kind {
        case .combo:
            router.fire(comboID: key.id)
        case .outputPreset:

            var action = SlideAction(id: UUID().uuidString, kind: .switchOutputPreset)
            action.presetId = key.id
            router.execute([action])
        case .overlayToggle:
            if controls.state.liveOverlays.contains(where: { $0.id == key.id }) {
                controls.dismissOverlay(id: key.id)
            } else if let overlay = model.overlay(key.id) {
                controls.fire(overlay: overlay)
            } else {
                DiagnosticsStore.shared.note("key.in.skipped", detail: "\(key.mapKey) missing")
            }
        case .timerStart: controls.timers.start(id: key.id)
        case .timerPause: controls.timers.pause(id: key.id)
        case .timerReset: controls.timers.reset(id: key.id)
        case .settingsPage: openSettingsPage(key.id)
        case .preview: WindowBridge.openPreview?(key.id)
        }
    }

    private func openSettingsPage(_ id: String) {
        if id.hasPrefix("streamRecord/") {
            SettingsRouter.shared.openStreamRecord(
                tab: id.hasSuffix("presets") ? .presets : .destinations)
        } else if let category = SettingsCategory(rawValue: id) {
            SettingsRouter.shared.pending = category
        } else {
            return DiagnosticsStore.shared.note("key.in.skipped", detail: "settings \(id)")
        }

        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func fireHotKey(letter: String) -> Bool {
        let targets = model.groupPalette.hotKeyTargets
        guard let names = targets[letter] else { return false }
        guard let live = controls.state.liveSlide, let presentation = live.presentation
        else {
            DiagnosticsStore.shared.note("key.in.skipped", detail: "hotkey \(letter) nothing live")
            return false
        }
        guard let start = SlideSceneBuilder.hotKeyJumpStart(
            for: presentation, arrangementId: live.arrangementId,
            matching: names, liveIndex: controls.liveOccurrence
        ) else {
            DiagnosticsStore.shared.note("key.in.skipped", detail: "hotkey \(letter) no block")
            return false
        }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: live.arrangementId)
        guard slides.indices.contains(start) else { return false }
        DiagnosticsStore.shared.note("key.in", detail: "hotkey \(letter) → \(start)")
        controls.fire(
            slide: slides[start], in: presentation, arrangementId: live.arrangementId,
            contextID: controls.liveContextID, occurrence: start
        )
        controls.noteKeyboardFire()
        return true
    }

    private func appendGoTo(_ digit: String) {

        guard goToBuffer.count < 4 else { return }
        goToBuffer += digit
        armGoToExpiry()
    }

    private func armGoToExpiry() {
        goToExpiry?.cancel()
        guard !goToBuffer.isEmpty else { return }
        goToExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.goToBuffer = ""
        }
    }

    private func cancelGoTo() {
        goToExpiry?.cancel()
        goToBuffer = ""
    }

    private func commitGoTo() {
        defer { cancelGoTo() }
        guard let number = Int(goToBuffer), number >= 1 else { return }
        guard let live = controls.state.liveSlide, let presentation = live.presentation
        else {
            DiagnosticsStore.shared.note("key.in.skipped", detail: "goto \(goToBuffer) nothing live")
            return
        }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: live.arrangementId)
        let index = number - 1
        guard slides.indices.contains(index) else {
            DiagnosticsStore.shared.note("key.in.skipped", detail: "goto \(number) out of range")
            return
        }
        DiagnosticsStore.shared.note("key.in", detail: "goto \(number)")
        controls.fire(
            slide: slides[index], in: presentation, arrangementId: live.arrangementId,
            contextID: controls.liveContextID, occurrence: index
        )
        controls.noteKeyboardFire()
    }
}

struct GoToSlideHUD: View {
    let keyIn: KeyInController?

    var body: some View {
        if let keyIn, !keyIn.goToBuffer.isEmpty {
            HStack(spacing: 10) {
                Text("Go to slide")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(keyIn.goToBuffer)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                Text("⏎")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 12, y: 4)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}
