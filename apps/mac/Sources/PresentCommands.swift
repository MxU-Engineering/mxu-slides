import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct PresentCommands: Commands {
    @FocusedValue(\.serviceControls) private var controls

    var body: some Commands {
        CommandMenu("Present") {
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
            Button("Clear Signage") { controls?.clear(function: .signage) }
                .keyboardShortcut(command: .clearSignage)
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
