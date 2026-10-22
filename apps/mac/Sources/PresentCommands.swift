import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct PresentCommands: Commands {
    @FocusedValue(\.serviceControls) private var controls

    @AppStorage(VolunteerModeLogic.enabledKey) private var volunteerEnabled = false
    @AppStorage(PresentLayoutController.lockedKey) private var locked = false

    var body: some Commands {
        CommandMenu("Present") {
            if volunteerEnabled {
                Button("Volunteer Mode") { VolunteerModeRouter.shared.request() }
                    .keyboardShortcut(command: .modeVolunteer)
                    .disabled(locked)
                Divider()
            }
            Button("Clear Slides") { controls?.clear(function: .slides) }
                .keyboardShortcut(command: .clearSlides)
            Button("Clear Media") { controls?.clear(function: .media) }
                .keyboardShortcut(command: .clearMedia)
            Button("Clear Overlays") { controls?.clear(function: .overlays) }
                .keyboardShortcut(command: .clearOverlays)
            Button("Clear Music") { controls?.clear(function: .audio) }
                .keyboardShortcut(command: .clearAudio)
            Button("Clear Alerts") { controls?.clear(function: .alerts) }
                .keyboardShortcut(command: .clearAlerts)
            Button("Clear Inputs") { controls?.clear(function: .inputs) }
                .keyboardShortcut(command: .clearInputs)
            Button("Clear Tracks") { controls?.clear(function: .tracks) }
            Divider()
            Menu("Clear Layer") {

                ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                    Button("Clear \(layer.displayName)") { controls?.clear(layer: layer) }
                }
            }
            Button("Clear All") { controls?.clearAll() }
                .keyboardShortcut(command: .clearAll)
        }
    }
}
