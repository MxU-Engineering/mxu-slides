import AudioEngine
import PresenterCore
import SwiftUI

struct AudioSourceMenuItems: View {
    let select: (StreamAudioSource) -> Void

    var body: some View {
        Button("Program Audio") { select(.program) }
        Menu("Mix") {
            ForEach(AudioMixInventory.shared.entries) { mix in
                Button(mix.name) { select(.mix(mix.id)) }
            }
        }
        Menu("Input") {
            ForEach(AudioInputInventory.shared.entries) { entry in
                Button(entry.name) { select(.input(entry.id)) }
            }
            if AudioInputInventory.shared.entries.isEmpty {
                Text("Create inputs in Audio/Video Inputs")
            }
        }
    }

    static func title(_ preset: StreamRecordPreset) -> String {
        if let mixId = preset.audioMixId, !mixId.isEmpty {
            "Mix \u{B7} " + (AudioMixInventory.shared.entry(id: mixId)?.name ?? "Missing")
        } else if let inputId = preset.audioInputId, !inputId.isEmpty {
            "Input \u{B7} " + (AudioInputInventory.shared.name(forId: inputId) ?? "Missing Input")
        } else if let uid = preset.audioInputUid, !uid.isEmpty {
            "Input \u{B7} " + (AudioInputInventory.shared.name(forUid: uid)
                ?? AudioDeviceList.inputDevice(uid: uid)?.name ?? "Missing Input")
        } else {
            "Program Audio"
        }
    }
}
