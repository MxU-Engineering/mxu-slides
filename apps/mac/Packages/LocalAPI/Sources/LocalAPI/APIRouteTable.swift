import Foundation

public enum APIRouteTable {
    public static func build(bridge: any LocalAPIBridge) -> [APIRoute] {
        var routes: [APIRoute] = []

        routes.append(APIRoute(
            "GET", "/v1/library", scope: .view,
            operationId: "getLibrary", summary: "Library section counts.", tag: "Library",
            responseSchema: .ref("LibrarySummary")
        ) { _ in
            .json(try await bridge.librarySummary())
        })

        routes.append(APIRoute(
            "GET", "/v1/library/{kind}", scope: .view,
            operationId: "listLibraryEntries",
            summary: "List a section's entries (id, name, folder).", tag: "Library",
            responseSchema: .array([.ref("LibraryEntry")])
        ) { context in
            .json(try await bridge.libraryEntries(kind: context.documentKind()))
        })

        routes.append(APIRoute(
            "GET", "/v1/documents/{kind}/{id}", scope: .view,
            operationId: "getDocument",
            summary: "Fetch a full document as schema JSON. Stream presets require edit access because they can contain ingest credentials.", tag: "Documents",
            responseSchema: .ref("Document")
        ) { context in
            let kind = try context.documentKind()
            guard kind != .streamPresets || context.scope.allows(.edit) else {
                throw APIError.forbidden(.edit)
            }
            return .raw(try await bridge.documentJSON(
                kind: kind, id: context.pathParameter("id")
            ))
        })

        routes.append(APIRoute(
            "GET", "/v1/status", scope: .view,
            operationId: "getShowStatus",
            summary: "Live show state: slide, layers, overlays, alert, next.", tag: "Show",
            responseSchema: .ref("ShowStatus")
        ) { _ in
            .json(await bridge.showStatus())
        })

        routes.append(APIRoute(
            "GET", "/v1/timers", scope: .view,
            operationId: "listTimers", summary: "All timers with run state.", tag: "Timers",
            responseSchema: .array([.ref("TimerStatus")])
        ) { _ in
            .json(await bridge.timers())
        })

        routes.append(APIRoute(
            "GET", "/v1/audio", scope: .view,
            operationId: "getAudioStatus", summary: "Playing audio buses.", tag: "Audio",
            responseSchema: .ref("AudioStatus")
        ) { _ in
            .json(await bridge.audioStatus())
        })

        routes.append(APIRoute(
            "GET", "/v1/transport", scope: .view,
            operationId: "getTransport", summary: "Playing videos with positions.", tag: "Transport",
            responseSchema: .array([.ref("TransportRow")])
        ) { _ in
            .json(await bridge.transportRows())
        })

        routes.append(APIRoute(
            "GET", "/v1/outputs", scope: .view,
            operationId: "getOutputs", summary: "Screens and output presets.", tag: "Outputs",
            responseSchema: .ref("OutputsStatus")
        ) { _ in
            .json(await bridge.outputsStatus())
        })

        routes.append(APIRoute(
            "GET", "/v1/scheduler", scope: .view,
            operationId: "getSchedulerStatus",
            summary: "Scheduler state: on/off (this machine), next fire, per-trigger status.",
            tag: "Scheduler",
            responseSchema: .ref("SchedulerStatus")
        ) { _ in
            .json(await bridge.schedulerStatus())
        })

        routes.append(APIRoute(
            "POST", "/v1/scheduler/enabled", scope: .control,
            operationId: "setSchedulerEnabled",
            summary: "Turn the Scheduler on or off on THIS machine.", tag: "Scheduler",
            requestSchema: .ref("SchedulerEnableCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APISchedulerEnableCommand.self)
            await bridge.setSchedulerEnabled(command.enabled)
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/scheduler/triggers/{id}/enabled", scope: .control,
            operationId: "setScheduleTriggerEnabled",
            summary: "Pause or resume one trigger.", tag: "Scheduler",
            requestSchema: .ref("SchedulerEnableCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APISchedulerEnableCommand.self)
            try await bridge.setScheduleTriggerEnabled(
                id: context.pathParameter("id"), enabled: command.enabled
            )
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/scheduler/triggers/{id}/fire", scope: .control,
            operationId: "fireScheduleTrigger",
            summary: "Run a trigger's actions now — gates ignored (Run Now).", tag: "Scheduler",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireScheduleTrigger(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "GET", "/v1/inputs/video", scope: .view,
            operationId: "listVideoInputs",
            summary: "Named video inputs: created items with their assigned capture device and attached audio input.",
            tag: "Inputs",
            responseSchema: .array([.ref("VideoInputStatus")])
        ) { _ in
            .json(await bridge.videoInputs())
        })

        routes.append(APIRoute(
            "GET", "/v1/inputs/audio", scope: .view,
            operationId: "listAudioInputs",
            summary: "Named audio inputs with their mixer strip state (on air, gain, mute).",
            tag: "Inputs",
            responseSchema: .array([.ref("AudioInputStatus")])
        ) { _ in
            .json(await bridge.audioInputs())
        })

        routes.append(APIRoute(
            "GET", "/v1/audio/mixes", scope: .view,
            operationId: "listAudioMixes",
            summary: "The room's mixes: in-app summing points with destination, fader, and mute.",
            tag: "Inputs",
            responseSchema: .array([.ref("AudioMixStatus")])
        ) { _ in
            .json(await bridge.audioMixes())
        })

        routes.append(APIRoute(
            "POST", "/v1/inputs/audio/{id}/mixer", scope: .control,
            operationId: "setMixerInput",
            summary: "Change one audio input's mixer strip: on-air switch, gain, mute, lip-sync delay (ms). Absent fields don't change.",
            tag: "Inputs",
            requestSchema: .ref("MixerInputCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APIMixerInputCommand.self)
            let id = try context.pathParameter("id")
            try await bridge.setMixerInput(id: id, command: command)
            return .ok
        })

        routes.append(APIRoute(
            "GET", "/v1/midi/devices", scope: .view,
            operationId: "listMIDIDevices",
            summary: "MIDI device items with enabled, direction, connected state, and this machine's resolved endpoints.",
            tag: "MIDI",
            responseSchema: .array([.ref("MIDIDeviceStatus")])
        ) { _ in
            .json(await bridge.midiDevices())
        })

        routes.append(APIRoute(
            "POST", "/v1/midi/devices/{id}/enabled", scope: .control,
            operationId: "setMIDIDeviceEnabled",
            summary: "Turn one MIDI device on or off (both directions).",
            tag: "MIDI",
            requestSchema: .ref("MIDIDeviceEnableCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APIMIDIDeviceEnableCommand.self)
            let id = try context.pathParameter("id")
            try await bridge.setMIDIDeviceEnabled(id: id, enabled: command.enabled)
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/show/slide", scope: .control,
            operationId: "fireSlide",
            summary: "Fire a slide (library context, or a service item's flattened position).",
            tag: "Show",
            requestSchema: .ref("FireSlideCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireSlide(context.decode(APIFireSlideCommand.self))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/show/advance", scope: .control,
            operationId: "advance",
            summary: "Advance (the grid's arrows; negative steps go back). Consumes the live slide's pending animation steps first — one call reveals one click group; past the last click one more call plays the EXIT group while the cue stays live, and the call after that moves to the next slide. Going back un-plays the exit / un-reveals a step before leaving the slide. Pass settled=true for the cut advance: the next slide fires with its With Slide steps already settled.",
            tag: "Show",
            requestSchema: .ref("AdvanceCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APIAdvanceCommand.self)
            try await bridge.advance(steps: command.steps ?? 1, settled: command.settled ?? false)
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/show/clear", scope: .control,
            operationId: "clear",
            summary: "Clear one function or one layer.", tag: "Show",
            requestSchema: .ref("ClearCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.clear(context.decode(APIClearCommand.self))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/show/clear-all", scope: .control,
            operationId: "clearAll", summary: "The panic clear.", tag: "Show",
            responseSchema: .ref("OK")
        ) { _ in
            await bridge.clearAll()
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/media/{id}/fire", scope: .control,
            operationId: "fireMedia",
            summary: "Fire a media item onto its classification's default layer.", tag: "Media",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireMedia(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/action-combos/{id}/fire", scope: .control,
            operationId: "fireActionCombo", summary: "Run an Action Combo.", tag: "Action Combos",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireActionCombo(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/overlays/{id}/fire", scope: .control,
            operationId: "fireOverlay", summary: "Go live with an overlay.", tag: "Overlays",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireOverlay(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/overlays/{id}/dismiss", scope: .control,
            operationId: "dismissOverlay", summary: "Take an overlay down.", tag: "Overlays",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.dismissOverlay(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/alerts/fire", scope: .control,
            operationId: "fireAlert",
            summary: "Fire an alert preset (with token values) or an ad-hoc alert.",
            tag: "Alerts",
            requestSchema: .ref("FireAlertCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireAlert(context.decode(APIFireAlertCommand.self))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/alerts/dismiss", scope: .control,
            operationId: "dismissAlert", summary: "Take the live alert down.", tag: "Alerts",
            responseSchema: .ref("OK")
        ) { _ in
            await bridge.dismissAlert()
            return .ok
        })

        for action in [APITimerAction.play, .pause, .reset] {
            routes.append(APIRoute(
                "POST", "/v1/timers/{id}/\(action.rawValue)", scope: .control,
                operationId: "timer\(action.rawValue.capitalized)",
                summary: "\(action.rawValue.capitalized) a timer.", tag: "Timers",
                responseSchema: .ref("OK")
            ) { context in
                try await bridge.timerAction(id: context.pathParameter("id"), action: action)
                return .ok
            })
        }

        routes.append(APIRoute(
            "POST", "/v1/audio/playlists/{id}/fire", scope: .control,
            operationId: "fireAudioPlaylist",
            summary: "Fire a playlist onto its output target.", tag: "Audio",
            requestSchema: .ref("AudioFireCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APIAudioFireCommand.self)
            try await bridge.fireAudioPlaylist(
                id: context.pathParameter("id"), startAtEntryId: command.startAtEntryId
            )
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/audio/items/{id}/fire", scope: .control,
            operationId: "fireAudioItem",
            summary: "Play one audio library item (no playlist semantics).", tag: "Audio",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.fireAudioItem(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/audio/stop", scope: .control,
            operationId: "stopAudio",
            summary: "Stop one bus by playlist or item id (body empty = all).", tag: "Audio",
            requestSchema: .ref("AudioStopCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.stopAudio(context.decode(APIAudioStopCommand.self))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/audio/transport", scope: .control,
            operationId: "audioTransport",
            summary: "Audio transport: playPause, next, previous, seek.", tag: "Audio",
            requestSchema: .ref("AudioTransportCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.audioTransport(context.decode(APIAudioTransportCommand.self))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/transport/{id}", scope: .control,
            operationId: "mediaTransport",
            summary: "Video transport: pause, resume, toggle, reset, seek.", tag: "Transport",
            requestSchema: .ref("MediaTransportCommand"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.mediaTransport(
                id: context.pathParameter("id"),
                command: context.decode(APIMediaTransportCommand.self)
            )
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/output-presets/{id}/activate", scope: .control,
            operationId: "activateOutputPreset",
            summary: "Activate an output preset ('none' deactivates).", tag: "Outputs",
            responseSchema: .ref("OK")
        ) { context in
            let id = try context.pathParameter("id")
            try await bridge.activateOutputPreset(id: id == "none" ? nil : id)
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/services/{id}/select", scope: .control,
            operationId: "selectService",
            summary: "Make a service the run-of-show target (what advance walks).",
            tag: "Services",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.selectService(id: context.pathParameter("id"))
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/documents/{kind}", scope: .edit,
            operationId: "createDocument",
            summary: "Create a document from schema JSON (id optional — generated when absent).",
            tag: "Documents",
            requestSchema: .ref("Document"), responseSchema: .ref("Created")
        ) { context in
            let id = try await bridge.createDocument(kind: context.documentKind(), body: context.body)
            return .json(APICreatedResponse(id: id), status: 201)
        })

        routes.append(APIRoute(
            "PUT", "/v1/documents/{kind}/{id}", scope: .edit,
            operationId: "updateDocument",
            summary: "Replace a document's contents (writes through the CRDT document layer).",
            tag: "Documents",
            requestSchema: .ref("Document"), responseSchema: .ref("OK")
        ) { context in
            try await bridge.updateDocument(
                kind: context.documentKind(), id: context.pathParameter("id"), body: context.body
            )
            return .ok
        })

        routes.append(APIRoute(
            "DELETE", "/v1/documents/{kind}/{id}", scope: .edit,
            operationId: "deleteDocument", summary: "Delete a document.", tag: "Documents",
            responseSchema: .ref("OK")
        ) { context in
            try await bridge.deleteDocument(
                kind: context.documentKind(), id: context.pathParameter("id")
            )
            return .ok
        })

        routes.append(APIRoute(
            "POST", "/v1/services/{id}/items", scope: .edit,
            operationId: "addServiceItem",
            summary: "Add a library item to a service's run order.", tag: "Services",
            requestSchema: .ref("AddServiceItemCommand"), responseSchema: .ref("OK")
        ) { context in
            let command = try context.decode(APIAddServiceItemCommand.self)
            try await bridge.addServiceItem(
                serviceId: context.pathParameter("id"), refId: command.refId, index: command.index
            )
            return .ok
        })

        return routes
    }
}
