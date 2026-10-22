import AudioEngine
import PresenterCore
import SwiftUI

struct AudioMixerModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly
    @Environment(\.openSettings) private var openSettings
    @State private var audioInventory = AudioInputInventory.shared
    @State private var mixInventory = AudioMixInventory.shared
    @State private var outputInventory = AudioOutputInventory.shared
    @State private var groupStore = MixerGroupStore.shared

    @AppStorage("mixer.scope") private var scope = 3

    var body: some View {
        let audio = controls.audio
        let mixer = controls.mixer
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                Button {
                    audio.isMuted.toggle()
                } label: {
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .moduleHeaderGlyph(
                            audio.isMuted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary)
                        )
                }
                .buttonStyle(.plain)
                .help(audio.isMuted ? "Unmute playback buses" : "Mute playback buses")
                if !runOnly {

                    Button {
                        if scope == 1 || scope == 3 {
                            mixInventory.create()
                        } else {
                            SettingsRouter.shared.pending = .avInputs
                            openSettings()
                        }
                    } label: {
                        Image(systemName: "plus").moduleHeaderGlyph()
                    }
                    .buttonStyle(.plain)
                    .help(scope == 0 ? "Add inputs in Settings"
                        : scope == 2 ? "Add outputs in Settings"
                        : "New mix")
                }
            }
            ChipPicker(
                options: [(0, "Inputs"), (1, "Mixes"), (2, "Outputs"), (3, "All")],
                selection: $scope
            )

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 4) {

                    if scope == 0 || scope == 3 {
                        videoAudioStrip(audio)
                        ForEach(audio.players) { player in
                            busStrip(player, audio: audio, mixer: mixer)
                        }

                        let trackChannels = model.trackChannels
                        if trackChannels.count == 1, let only = trackChannels.first {
                            trackStrip(only, mixer: mixer)
                        } else if !trackChannels.isEmpty {
                            tracksGroup(trackChannels, mixer: mixer)
                        }

                        ForEach(inputRows) { row in
                            switch row {
                            case .single(let entry):
                                inputStrip(entry, audio: audio, mixer: mixer)
                            case .group(let uid, let name, let members):
                                deviceGroup(
                                    uid: uid, name: name, members: members,
                                    audio: audio, mixer: mixer)
                            }
                        }
                    }
                    if scope == 3 { consoleDivider() }

                    if scope == 1 || scope == 3 {

                        ForEach(mixRows) { row in
                            switch row {
                            case .mix(let mix):
                                mixStrip(mix, audio: audio, mixer: mixer)
                            case .folder(let folder, let members):
                                mixFolder(folder, members: members, audio: audio, mixer: mixer)
                            }
                        }
                    }
                    if scope == 3 { consoleDivider() }

                    if scope == 2 || scope == 3 {

                        ForEach(outputRows) { row in
                            switch row {
                            case .single(let output):
                                outputStrip(output, mixer: mixer)
                            case .group(let uid, let name, let members):
                                outputGroup(uid: uid, name: name, members: members, mixer: mixer)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)

                .consoleScrolling()
            }
        }
        .onAppear { mixer.setMetering(true) }
        .onDisappear { mixer.setMetering(false) }
        .task {
            while !Task.isCancelled {
                controls.mixer.refreshMeters()
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private enum InputRow: Identifiable {
        case single(AudioInputInventory.Entry)
        case group(uid: String, name: String, members: [AudioInputInventory.Entry])

        var id: String {
            switch self {
            case .single(let entry): "entry:\(entry.id)"
            case .group(let uid, _, _): "device:\(uid)"
            }
        }
    }

    private var inputRows: [InputRow] {
        let entries = audioInventory.entries
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let uid = entry.uid, !uid.isEmpty else { continue }
            counts[uid, default: 0] += 1
        }
        var rows: [InputRow] = []
        var grouped: Set<String> = []
        for entry in entries {
            guard let uid = entry.uid, !uid.isEmpty, counts[uid, default: 0] >= 2 else {
                rows.append(.single(entry))
                continue
            }
            guard !grouped.contains(uid) else { continue }
            grouped.insert(uid)
            let name = AudioDeviceList.inputDevice(uid: uid)?.name ?? "Missing Device"
            rows.append(.group(
                uid: uid, name: name, members: entries.filter { $0.uid == uid }))
        }
        return rows
    }

    private func deviceGroup(
        uid: String, name: String, members: [AudioInputInventory.Entry],
        audio: AudioController, mixer: AudioMixerController
    ) -> some View {
        let expanded = groupStore.isExpanded(uid)
        return HStack(alignment: .top, spacing: 4) {
            deviceStrip(uid: uid, name: name, members: members, mixer: mixer)
            if expanded {
                ForEach(members) { entry in

                    inputStrip(
                        entry, audio: audio, mixer: mixer,
                        displayName: compactedName(entry.name, deviceName: name))
                }
            }
        }

        .padding(2)
        .background(
            expanded ? Color.primary.opacity(0.04) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private func compactedName(_ name: String, deviceName: String) -> String? {
        let prefix = deviceName + " "
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return String(name.dropFirst(prefix.count))
    }

    private func deviceStrip(
        uid: String, name: String, members: [AudioInputInventory.Entry],
        mixer: AudioMixerController
    ) -> some View {
        let expanded = groupStore.isExpanded(uid)
        let anyLive = members.contains { mixer.isLive(input: $0.id) }
        return ConsoleStrip(
            name: name,
            live: anyLive,
            tint: .teal,
            topSlot: .blank,
            bottomSlot: .static("\(members.count) channels"),
            gain: Binding(
                get: { AudioMixerController.deviceTrim(uid) },
                set: { mixer.setDeviceTrim($0, uid: uid) }
            ),
            muted: Binding(
                get: { AudioMixerController.deviceMuted(uid) },
                set: { mixer.setDeviceMuted($0, uid: uid) }
            ),

            meter: mixer.displayLevels["device:\(uid)"],
            colorKey: "device:\(uid)",
            defaultColorName: "Teal",
            extraMenu: {
                AnyView(Button("Configure Inputs…") {
                    SettingsRouter.shared.pending = .avInputs
                    openSettings()
                })
            }
        ) {
            Button {
                groupStore.toggle(uid)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(expanded ? "Fold" : "\(members.count)")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 15)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.4), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Fold the device's channels into one strip"
                           : "Show every channel strip (\(members.count))")
        }
    }

    private func tracksGroup(_ channels: [TrackChannel], mixer: AudioMixerController) -> some View {
        let expanded = groupStore.isExpanded(Self.tracksGroupKey)
        return HStack(alignment: .top, spacing: 4) {
            ConsoleStrip(
                name: "Tracks",
                live: controls.tracks.isPlaying,
                tint: .purple,
                topSlot: .blank,
                bottomSlot: .static("\(channels.count) channels"),
                gain: Binding(get: { TracksController.trim }, set: { TracksController.setTrim($0) }),
                muted: Binding(get: { TracksController.trimMuted }, set: { TracksController.setTrimMuted($0) }),

                meter: mixer.displayLevels[AudioMixerController.tracksMeterKey],
                meterAppliesGain: false,
                colorKey: "tracks",
                defaultColorName: "Purple",
                extraMenu: { AnyView(self.makeTrackMixesButton(channels)) }
            ) {
                Button {
                    groupStore.toggle(Self.tracksGroupKey)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(expanded ? "Fold" : "\(channels.count)")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.separator.opacity(0.4), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Fold the track channels into one strip" : "Show every track channel (\(channels.count))")
            }
            if expanded {
                ForEach(channels) { channel in
                    trackStrip(channel, mixer: mixer)
                }
            }
        }
        .padding(2)
        .background(
            expanded ? Color.primary.opacity(0.04) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    static let tracksGroupKey = "tracks"

    private func trackStrip(_ channel: TrackChannel, mixer: AudioMixerController) -> some View {
        let route = TracksController.mixId(channel)
        return ConsoleStrip(
            name: channel.name,
            live: false,
            topSlot: sendsSlot(channel: "track:\(channel.id)", routedMix: route ?? "", mixer: mixer),
            bottomSlot: trackRouteSlot(channel, current: route),
            gain: Binding(get: { TracksController.gain(channel.id) }, set: { TracksController.setGain($0, for: channel.id) }),
            muted: Binding(get: { TracksController.muted(channel.id) }, set: { TracksController.setMuted($0, for: channel.id) }),
            pan: Binding(get: { TracksController.pan(channel.id) }, set: { TracksController.setPan($0, for: channel.id) }),
            meter: mixer.displayLevels["track:\(channel.id)"],
            meterAppliesGain: true,
            colorKey: "track:\(channel.id)",
            defaultColorName: "Purple",
            extraMenu: { AnyView(self.makeTrackMixesButton(self.model.trackChannels)) }
        ) {
            if channel.trackRole != .music {

                Text(channel.trackRole == .click ? "CLICK" : "GUIDE")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
                    .help("\(channel.trackRole == .click ? "Click" : "Guide") starts on no mix, so it never reaches the house unasked; its Main send waits at zero")
            }
        }
    }

    private func trackRouteSlot(_ channel: TrackChannel, current: String?) -> ConsoleSlot {
        .menu(current.flatMap { mixInventory.entry(id: $0)?.name } ?? "No Mix", accent: current == nil && channel.trackRole != .music, content: {
            AnyView(Group {
                Toggle("No Mix", isOn: Binding(
                    get: { current == nil },
                    set: { _ in TracksController.setMix(nil, for: channel.id) }
                ))
                ForEach(self.mixInventory.entries) { mix in
                    Toggle(mix.name, isOn: Binding(
                        get: { current == mix.id },
                        set: { _ in TracksController.setMix(mix.id, for: channel.id) }
                    ))
                }
            })
        })
    }

    private func makeTrackMixesButton(_ channels: [TrackChannel]) -> some View {
        Button("Make a Mix for Every Track Channel") {
            let folder = mixInventory.folder(named: "Tracks")
            for channel in channels {
                let mix = mixInventory.entries.first { $0.name == channel.name && $0.folderId == folder.id } ?? {

                    let made = mixInventory.create(name: channel.name)
                    mixInventory.setPrimary(mixId: made.id, token: AudioMixInventory.noOutputID)
                    return made
                }()
                mixInventory.move(mix.id, toFolder: folder.id)
                TracksController.setMix(mix.id, for: channel.id)
            }
        }
        .disabled(runOnly || channels.isEmpty)
    }

    private func inputStrip(
        _ entry: AudioInputInventory.Entry, audio: AudioController,
        mixer: AudioMixerController, displayName: String? = nil
    ) -> some View {
        let live = mixer.isLive(input: entry.id)
        let auto = mixer.autoEnabledByVideoInput(entry.id)
        return ConsoleStrip(
            name: displayName ?? entry.name,
            live: live,
            topSlot: sendsSlot(channel: "input:\(entry.id)",
                               routedMix: mixer.mixId(forInput: entry.id), mixer: mixer),
            bottomSlot: routeSlot(current: mixer.mixId(forInput: entry.id)) {
                mixer.setMix(forInput: entry.id, mixId: $0)
            },
            gain: Binding(
                get: { mixer.gain(forInput: entry.id) },
                set: { mixer.setGain($0, forInput: entry.id) }
            ),
            muted: Binding(
                get: { mixer.isMuted(input: entry.id) },
                set: { mixer.setMuted($0, forInput: entry.id) }
            ),
            pan: Binding(
                get: { mixer.pan(forInput: entry.id) },
                set: { mixer.setPan($0, forInput: entry.id) }
            ),
            meter: mixer.displayLevels[entry.id],
            meterAppliesGain: true,

            onRename: { audioInventory.rename(id: entry.id, to: $0) },
            renameValue: entry.name,
            colorKey: "input:\(entry.id)",
            defaultColorName: "Teal",
            extraMenu: {
                AnyView(Button("Configure Inputs…") {
                    SettingsRouter.shared.pending = .avInputs
                    openSettings()
                })
            }
        ) {

            Button {
                mixer.setManuallyEnabled(
                    !mixer.isManuallyEnabled(input: entry.id), forInput: entry.id)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(live ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
                    .background(
                        live ? Color.green.opacity(0.14) : Color.primary.opacity(0.04),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                live ? Color.green.opacity(0.5) : Color.separator.opacity(0.4),
                                lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.isAssigned)
            .help(auto ? "On air with its video input" : (live ? "Turn off — take the input off air" : "Turn on — put the input on air"))
        }
    }

    private func busStrip(
        _ player: AudioPlayer, audio: AudioController, mixer: AudioMixerController
    ) -> some View {
        let playlistID = player.playlistID
        return ConsoleStrip(
            name: player.displayName,
            live: player.isPlaying,
            topSlot: playlistID.map { id in
                sendsSlot(channel: "playlist:\(id)",
                          routedMix: audio.playlistMixId(id) ?? AudioMixInventory.mainID,
                          mixer: mixer)
            } ?? .blank,
            bottomSlot: playlistID.map { id in
                routeSlot(current: audio.playlistMixId(id) ?? AudioMixInventory.mainID) {
                    audio.setPlaylistMix(id, mixId: $0)
                }
            } ?? .static("Main"),
            gain: Binding(
                get: { player.busGain },
                set: { audio.setGain($0, for: player) }
            ),
            muted: Binding(
                get: { player.busMuted },
                set: { audio.setMuted($0, for: player) }
            ),

            meter: mixer.playerLevels[player.targetKey],
            meterAppliesGain: true,
            colorKey: playlistID.map { "playlist:\($0)" } ?? "single-item",
            defaultColorName: "Teal"
        ) { EmptyView() }
    }

    private func videoAudioStrip(_ audio: AudioController) -> some View {
        ConsoleStrip(
            name: "In-App Videos",
            live: false,
            topSlot: sendsSlot(channel: "video", routedMix: audio.mediaMixId,
                               mixer: controls.mixer),
            bottomSlot: routeSlot(current: audio.mediaMixId) { audio.setMediaMix($0) },
            gain: Binding(
                get: { audio.mediaAudioGain },
                set: { audio.mediaAudioGain = $0 }
            ),
            muted: Binding(
                get: { audio.mediaAudioMuted },
                set: { audio.mediaAudioMuted = $0 }
            ),
            meter: controls.mixer.displayLevels[AudioMixerController.videoMeterKey],
            colorKey: "video",
            defaultColorName: "Teal"
        ) { EmptyView() }
    }

    private func mixStrip(
        _ mix: AudioMixInventory.Entry, audio: AudioController,
        mixer: AudioMixerController
    ) -> some View {
        ConsoleStrip(
            name: mix.name,
            live: false,
            tint: .blue,
            topSlot: mixSendsSlot(mix, mixer: mixer),
            bottomSlot: mixRouteSlot(mix),
            gain: Binding(
                get: { audio.mixGain(mix.id) },
                set: { audio.setMixGain($0, mixID: mix.id) }
            ),
            muted: Binding(
                get: { audio.mixMuted(mix.id) },
                set: { audio.setMixMuted($0, mixID: mix.id) }
            ),
            meter: mixer.busLevels[mix.id],
            onRename: (mix.isMain || runOnly) ? nil : { newName in
                mixInventory.rename(id: mix.id, to: newName)
            },
            colorKey: "mix:\(mix.id)",
            defaultColorName: "Blue",
            extraMenu: {
                self.runOnly
                    ? AnyView(EmptyView())
                    : AnyView(Group {
                        Menu("Move to Folder") {
                            ForEach(self.mixInventory.folders) { folder in
                                Button(folder.name) { self.mixInventory.move(mix.id, toFolder: folder.id) }
                                    .disabled(mix.folderId == folder.id)
                            }
                            if !self.mixInventory.folders.isEmpty { Divider() }
                            Button("New Folder") {
                                let folder = self.mixInventory.folder(named: self.newFolderName())
                                self.mixInventory.move(mix.id, toFolder: folder.id)
                                self.groupStore.toggle("folder:\(folder.id)")
                            }
                            if mix.folderId != nil {
                                Button("Out of the Folder") { self.mixInventory.move(mix.id, toFolder: nil) }
                            }
                        }
                        if !mix.isMain {
                            Button("Remove Mix") { self.mixInventory.remove(mix) }
                        }
                    })
            }
        ) { EmptyView() }
    }

    private enum OutputRow: Identifiable {
        case single(AudioOutputInventory.Entry)
        case group(uid: String, name: String, members: [AudioOutputInventory.Entry])

        var id: String {
            switch self {
            case .single(let output): "output:\(output.id)"
            case .group(let uid, _, _): "outdevice:\(uid)"
            }
        }
    }

    private var outputRows: [OutputRow] {
        let entries = outputInventory.entries
        let real = { (entry: AudioOutputInventory.Entry) -> String? in
            guard let uid = entry.deviceUID, !entry.isDeviceless else { return nil }
            return uid
        }
        var counts: [String: Int] = [:]
        for entry in entries { if let uid = real(entry) { counts[uid, default: 0] += 1 } }
        var rows: [OutputRow] = []
        var grouped: Set<String> = []
        for entry in entries {
            guard let uid = real(entry), counts[uid, default: 0] >= 2 else {
                rows.append(.single(entry))
                continue
            }
            guard grouped.insert(uid).inserted else { continue }
            let name = AudioDeviceList.outputDevices().first { $0.uid == uid }?.name ?? "Missing Device"
            rows.append(.group(uid: uid, name: name, members: entries.filter { real($0) == uid }))
        }
        return rows
    }

    private func outputGroup(
        uid: String, name: String, members: [AudioOutputInventory.Entry], mixer: AudioMixerController
    ) -> some View {
        let key = "outdevice:\(uid)"
        let expanded = groupStore.isExpanded(key)
        return HStack(alignment: .top, spacing: 4) {
            FoldCard(
                name: name, symbol: "hifispeaker.2", count: members.count, expanded: expanded,
                peak: members.compactMap { mixer.outputLevels[$0.id]?.peak }.max() ?? 0,
                toggle: { groupStore.toggle(key) }, rename: nil, remove: nil)
            if expanded {
                ForEach(members) { output in
                    outputStrip(output, mixer: mixer)
                }
            }
        }
        .padding(2)
        .background(
            expanded ? Color.orange.opacity(0.05) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private enum MixRow: Identifiable {
        case mix(AudioMixInventory.Entry)
        case folder(AudioMixInventory.Folder, members: [AudioMixInventory.Entry])

        var id: String {
            switch self {
            case .mix(let mix): "mix:\(mix.id)"
            case .folder(let folder, _): "folder:\(folder.id)"
            }
        }
    }

    private var mixRows: [MixRow] {
        let entries = mixInventory.entries
        let folders = mixInventory.folders
        var rows: [MixRow] = []
        var placed: Set<String> = []
        for mix in entries {
            guard let id = mix.folderId, let folder = folders.first(where: { $0.id == id }) else {
                rows.append(.mix(mix))
                continue
            }
            guard placed.insert(id).inserted else { continue }
            rows.append(.folder(folder, members: entries.filter { $0.folderId == id }))
        }
        for folder in folders where !placed.contains(folder.id) {
            rows.append(.folder(folder, members: []))
        }
        return rows
    }

    private func newFolderName() -> String {
        let names = Set(mixInventory.folders.map(\.name))
        var number = 1
        while names.contains("Folder \(number)") { number += 1 }
        return "Folder \(number)"
    }

    private func mixFolder(
        _ folder: AudioMixInventory.Folder, members: [AudioMixInventory.Entry],
        audio: AudioController, mixer: AudioMixerController
    ) -> some View {
        let key = "folder:\(folder.id)"
        let expanded = groupStore.isExpanded(key)
        return HStack(alignment: .top, spacing: 4) {
            FoldCard(
                name: folder.name, symbol: expanded ? "folder" : "folder.fill", count: members.count, expanded: expanded,
                peak: members.compactMap { mixer.busLevels[$0.id]?.peak }.max() ?? 0,
                toggle: { groupStore.toggle(key) },
                rename: runOnly ? nil : { mixInventory.renameFolder(id: folder.id, to: $0) },
                remove: runOnly ? nil : { mixInventory.removeFolder(id: folder.id) })
            if expanded {
                ForEach(members) { mix in
                    mixStrip(mix, audio: audio, mixer: mixer)
                }
            }
        }
        .padding(2)
        .background(
            expanded ? Color.blue.opacity(0.05) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private func mixRouteSlot(_ mix: AudioMixInventory.Entry) -> ConsoleSlot {
        .menu(mixRouteTitle(mix), content: {
            AnyView(Group {
                Toggle("System Default", isOn: Binding(
                    get: {
                        self.mixInventory.primaryToken(mixId: mix.id)
                            == AudioMixInventory.defaultOutputID
                    },
                    set: { _ in
                        self.mixInventory.setPrimary(
                            mixId: mix.id, token: AudioMixInventory.defaultOutputID)
                    }
                ))
                ForEach(self.outputInventory.entries) { output in
                    Toggle(output.name, isOn: Binding(
                        get: { self.mixInventory.primaryToken(mixId: mix.id) == output.id },
                        set: { _ in
                            self.mixInventory.setPrimary(mixId: mix.id, token: output.id)
                        }
                    ))
                }
                Toggle("No Output (virtual)", isOn: Binding(
                    get: { AudioMixInventory.isVirtual(mix.outputIds) },
                    set: { _ in
                        self.mixInventory.setPrimary(
                            mixId: mix.id, token: AudioMixInventory.noOutputID)
                    }
                ))
                Divider()
                Button("Manage Outputs…") {
                    SettingsRouter.shared.pending = .avInputs
                    self.openSettings()
                }
            })
        })
    }

    private func mixRouteTitle(_ mix: AudioMixInventory.Entry) -> String {
        let token = mixInventory.primaryToken(mixId: mix.id)
        if token == AudioMixInventory.noOutputID { return "Virtual" }
        if token == AudioMixInventory.defaultOutputID { return "Default" }
        return outputInventory.entry(id: token)?.name ?? "Missing"
    }

    private func mixSendsSlot(
        _ mix: AudioMixInventory.Entry, mixer: AudioMixerController
    ) -> ConsoleSlot {
        let primary = mixInventory.primaryToken(mixId: mix.id)
        let sends = Array(mix.outputIds.dropFirst()).filter {
            outputInventory.entry(id: $0) != nil
        }
        let virtual = AudioMixInventory.isVirtual(mix.outputIds)
        let title = sends.isEmpty ? "+ send"
            : (sends.count == 1
                ? (outputInventory.entry(id: sends[0])?.name ?? "1 send")
                : "\(sends.count) sends")
        return .popover(title, accent: !sends.isEmpty, quiet: sends.isEmpty, content: {
            AnyView(VStack(alignment: .leading, spacing: 8) {
                Text("SENDS")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                if virtual {
                    Text("Virtual mix — route it to an output to add sends.")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(self.outputInventory.entries.filter { $0.id != primary }) { output in
                        let active = sends.contains(output.id)
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(output.name, isOn: Binding(
                                get: { active },
                                set: { _ in
                                    self.mixInventory.toggleSecondary(
                                        mixId: mix.id, outputId: output.id)
                                }
                            ))
                            .font(.caption)
                            if active {
                                HStack(spacing: 6) {
                                    MiniFader(value: Binding(
                                        get: { mixer.sendLevel(mixId: mix.id, outputId: output.id) },
                                        set: { mixer.setSendLevel($0, mixId: mix.id, outputId: output.id) }
                                    ))
                                    Text("\(Int(mixer.sendLevel(mixId: mix.id, outputId: output.id) * 100))%")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, alignment: .trailing)
                                }
                                .padding(.leading, 18)
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stream Feed")
                        .font(.caption)
                    HStack(spacing: 6) {
                        MiniFader(value: Binding(
                            get: { mixer.streamGain(mixId: mix.id) },
                            set: { mixer.setStreamGain($0, mixId: mix.id) }
                        ))
                        Text("\(Int(mixer.streamGain(mixId: mix.id) * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Text("Level sent to streams and recordings tapping this mix — outputs never ride it.")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 240))
        })
    }

    private func outputStrip(
        _ output: AudioOutputInventory.Entry, mixer: AudioMixerController
    ) -> some View {
        ConsoleStrip(
            name: output.name,
            live: false,
            tint: .orange,
            topSlot: .blank,
            bottomSlot: .menu(outputDeviceCaption(output), content: {
                AnyView(self.outputDeviceMenu(output))
            }),
            gain: Binding(
                get: { mixer.outputGain(output.id) },
                set: { mixer.setOutputGain($0, outputId: output.id) }
            ),
            muted: Binding(
                get: { mixer.outputMuted(output.id) },
                set: { mixer.setOutputMuted($0, outputId: output.id) }
            ),
            meter: mixer.outputLevels[output.id],
            colorKey: "output:\(output.id)",
            defaultColorName: "Orange",
            extraMenu: {
                AnyView(Button("Configure Outputs…") {
                    SettingsRouter.shared.pending = .avInputs
                    openSettings()
                })
            }
        ) { EmptyView() }
    }

    @ViewBuilder
    private func outputDeviceMenu(_ output: AudioOutputInventory.Entry) -> some View {
        Button("System Default") {
            outputInventory.assignDevice(id: output.id, deviceUID: nil, channelOffset: 0)
        }
        Button("No Device") {
            outputInventory.assignDevice(
                id: output.id, deviceUID: AudioOutputInventory.noDeviceUID, channelOffset: 0)
        }
        ForEach(AudioDeviceList.outputDevices()) { device in
            if device.channelCount > 2 {
                Menu(device.name) {
                    ForEach(
                        Array(stride(from: 0, to: device.channelCount - 1, by: 2)),
                        id: \.self
                    ) { offset in
                        Button("Channels \(offset + 1)-\(offset + 2)") {
                            outputInventory.assignDevice(
                                id: output.id, deviceUID: device.uid, channelOffset: offset)
                        }
                    }
                    Divider()

                    Menu("One Channel (mono)") {
                        ForEach(0 ..< device.channelCount, id: \.self) { channel in
                            Button("Channel \(channel + 1)") {
                                outputInventory.assignDevice(
                                    id: output.id, deviceUID: device.uid, channelOffset: 0, monoChannel: channel)
                            }
                        }
                    }
                }
            } else {
                Button(device.name) {
                    outputInventory.assignDevice(
                        id: output.id, deviceUID: device.uid, channelOffset: 0)
                }
            }
        }
    }

    private func outputDeviceCaption(_ output: AudioOutputInventory.Entry) -> String {
        if output.isDeviceless { return "No Device" }
        guard let uid = output.deviceUID else { return "Default" }
        guard let device = AudioDeviceList.outputDevices().first(where: { $0.uid == uid })
        else { return "Missing" }
        return device.channelCount > 2 || output.monoChannel != nil
            ? "\(device.name) \(outputInventory.channelWords(output))"
            : device.name
    }

    private func sendsSlot(
        channel: String, routedMix: String, mixer: AudioMixerController
    ) -> ConsoleSlot {

        let sends = mixer.channelSends(channel).filter { mixId, _ in
            mixId != routedMix && mixInventory.entry(id: mixId) != nil
        }
        let addable = mixInventory.entries.filter {
            $0.id != routedMix && sends[$0.id] == nil
        }
        let title = sends.isEmpty ? "+ send"
            : (sends.count == 1
                ? (mixInventory.entry(id: sends.keys.first ?? "")?.name ?? "1 send")
                : "\(sends.count) sends")
        _ = addable
        return .popover(title, accent: !sends.isEmpty, quiet: sends.isEmpty, content: {
            AnyView(self.sendsPopover(channel: channel, routedMix: routedMix, mixer: mixer))
        })
    }

    private func sendsPopover(
        channel: String, routedMix: String, mixer: AudioMixerController
    ) -> some View {
        let sends = mixer.channelSends(channel)
        return VStack(alignment: .leading, spacing: 8) {
            Text("SENDS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            ForEach(mixInventory.entries.filter { $0.id != routedMix }) { mix in
                let active = sends[mix.id] != nil
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(mix.name, isOn: Binding(
                        get: { active },
                        set: { on in
                            mixer.setChannelSend(channel, mixId: mix.id, gain: on ? 0.7 : nil)
                        }
                    ))
                    .font(.caption)
                    if active {
                        HStack(spacing: 6) {
                            MiniFader(value: Binding(
                                get: { mixer.channelSends(channel)[mix.id] ?? 0.7 },
                                set: { mixer.setChannelSend(channel, mixId: mix.id, gain: $0) }
                            ))
                            Text("\(Int((mixer.channelSends(channel)[mix.id] ?? 0.7) * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        .padding(.leading, 18)
                    }
                }
            }
            Text("Sends feed another mix post-fader, on top of the channel's route.")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240)
    }

    private func routeSlot(
        current: String, set: @escaping (String) -> Void
    ) -> ConsoleSlot {
        .menu(mixInventory.entry(id: current)?.name ?? "Main", content: {
            AnyView(ForEach(self.mixInventory.entries) { mix in
                Toggle(mix.name, isOn: Binding(
                    get: { current == mix.id },
                    set: { _ in set(mix.id) }
                ))
            })
        })
    }

    private func sendLevelMenu(
        title: String, level: @escaping () -> Float, set: @escaping (Float) -> Void
    ) -> some View {
        Menu("\(title) — \(Int(level() * 100))%") {
            ForEach([1.0, 0.85, 0.7, 0.5, 0.3, 0.15, 0.0], id: \.self) { stop in
                Toggle("\(Int(stop * 100))%", isOn: Binding(
                    get: { abs(level() - Float(stop)) < 0.03 },
                    set: { _ in set(Float(stop)) }
                ))
            }
        }
    }

    private func consoleDivider() -> some View {
        Rectangle()
            .fill(Color.separator.opacity(0.5))
            .frame(width: 1)
            .padding(.vertical, 8)
    }
}

enum ConsoleSlot {
    case blank
    case `static`(String)
    case menu(String, accent: Bool = false, quiet: Bool = false,
              content: () -> AnyView)

    case popover(String, accent: Bool = false, quiet: Bool = false,
                 content: () -> AnyView)
}

private struct SlotChip: View {
    let slot: ConsoleSlot
    @State private var showingPopover = false
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        ZStack {
            switch slot {
            case .blank:
                Color.clear
            case .static(let title):
                pill(title, accent: false, quiet: false)
            case .menu(let title, let accent, let quiet, _) where runOnly,
                 .popover(let title, let accent, let quiet, _) where runOnly:
                pill(title, accent: accent, quiet: quiet)
            case .menu(let title, let accent, let quiet, let content):

                Menu {
                    content()
                } label: {
                    pill(title, accent: accent, quiet: quiet)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            case .popover(let title, let accent, let quiet, let content):
                Button {
                    showingPopover.toggle()
                } label: {
                    pill(title, accent: accent, quiet: quiet)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                    content()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .clipped()
    }

    private func pill(_ title: String, accent: Bool, quiet: Bool) -> some View {
        ZStack {
            RoundedRectangle.standard(CornerStandard.element)
                .fill(Color.primary.opacity(quiet ? 0.03 : 0.06))
            Text(title)
                .font(.system(size: 7))
                .lineLimit(1)
                .foregroundStyle(quiet ? AnyShapeStyle(.tertiary)
                    : accent ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 3)
        }
    }
}

private struct ConsoleStrip<Footer: View>: View {
    let name: String
    let live: Bool
    let tint: Color
    let topSlot: ConsoleSlot
    let bottomSlot: ConsoleSlot
    let gain: Binding<Float>
    let muted: Binding<Bool>

    let pan: Binding<Float>?

    let meter: MeterBallistics?

    let meterAppliesGain: Bool

    let onRename: ((String) -> Void)?

    let renameValue: String?

    let colorKey: String?
    let defaultColorName: String

    let extraMenu: () -> AnyView
    @ViewBuilder let footer: () -> Footer
    @State private var editingName = false
    @State private var draftName = ""

    @State private var peakHold = PeakHold()
    @State private var tickHold = PeakHold(holdSeconds: 1)
    @State private var editingGain = false
    @State private var gainDraft = ""
    @State private var colorStore = StripColorStore.shared
    @Environment(\.moduleViewportHeight) private var viewportHeight
    @Environment(\.runOnly) private var runOnly

    private var displayedPeak: Float {
        let raw = meter?.peak ?? 0
        guard meterAppliesGain else { return raw }
        return muted.wrappedValue ? 0 : min(raw * gain.wrappedValue, 1)
    }

    private var signalPresent: Bool {
        meter != nil && (meter?.peak ?? 0) > 0.001
    }

    private var faderHeight: CGFloat {
        MixerStripLayout.faderHeight(
            viewportHeight: viewportHeight,
            scrollerHeight: ConsoleScrolling.scrollerHeight)
    }

    init(
        name: String, live: Bool, tint: Color = .green,
        topSlot: ConsoleSlot = .blank, bottomSlot: ConsoleSlot = .blank,
        gain: Binding<Float>, muted: Binding<Bool>,
        pan: Binding<Float>? = nil, meter: MeterBallistics?,
        meterAppliesGain: Bool = false,
        onRename: ((String) -> Void)? = nil,
        renameValue: String? = nil,
        colorKey: String? = nil,
        defaultColorName: String = "Gray",
        extraMenu: @escaping () -> AnyView = { AnyView(EmptyView()) },
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.name = name
        self.live = live
        self.tint = tint
        self.topSlot = topSlot
        self.bottomSlot = bottomSlot
        self.gain = gain
        self.muted = muted
        self.pan = pan
        self.meter = meter
        self.meterAppliesGain = meterAppliesGain
        self.onRename = onRename
        self.renameValue = renameValue
        self.colorKey = colorKey
        self.defaultColorName = defaultColorName
        self.extraMenu = extraMenu
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 3) {
            SlotChip(slot: topSlot)
            SlotChip(slot: bottomSlot)

            Group {
                if let pan {
                    MiniPan(value: pan)
                } else {
                    Color.clear
                }
            }
            .frame(height: 10)

            HStack(spacing: 4) {
                LevelLabel(
                    decibels: AudioLevel.decibels(gain.wrappedValue),
                    style: .gain)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let db = AudioLevel.decibels(gain.wrappedValue)
                        gainDraft = db <= -60 ? "" : String(format: "%.1f", db)
                        editingGain = true
                    }
                    .help("Fader level — click to type a dB value")
                    .popover(isPresented: $editingGain, arrowEdge: .bottom) {
                        GainEntryPopover(draft: $gainDraft) {
                            if let entered = AudioLevel.faderGain(entry: gainDraft) {
                                gain.wrappedValue = entered
                            }
                            editingGain = false
                        }
                    }
                if meter != nil {
                    LevelLabel(decibels: peakHold.decibels, style: .peak)
                        .contentShape(Rectangle())
                        .onTapGesture { peakHold.reset() }
                        .help("Highest peak since reset — click to reset")
                }
            }
            .frame(height: 10)
            HStack(spacing: 2) {
                VerticalFader(value: gain)
                MeterScale()
                VerticalMeter(
                    peak: displayedPeak, heldPeakDecibels: tickHold.decibels,
                    signalPresent: signalPresent)
            }
            .frame(height: faderHeight)
            .onChange(of: displayedPeak, initial: true) {
                peakHold.update(displayedPeak)
                tickHold.update(
                    displayedPeak, at: Date().timeIntervalSinceReferenceDate)
            }
            Button {
                muted.wrappedValue.toggle()
            } label: {
                Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 8))
                    .foregroundStyle(muted.wrappedValue ? Color.orange : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted.wrappedValue ? "Unmute" : "Mute")
            ZStack {
                Color.clear
                footer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 15)

            Text(name)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(live ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 20, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard onRename != nil else { return }
                    draftName = renameValue ?? name
                    editingName = true
                }

                .help(onRename != nil
                    ? "\(renameValue ?? name) — double-click to rename"
                    : renameValue ?? name)
                .popover(isPresented: $editingName, arrowEdge: .bottom) {
                    StripRenamePopover(draft: $draftName) {
                        onRename?(draftName)
                        editingName = false
                    }
                }
            if let colorKey {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colorStore.color(for: colorKey, defaultName: defaultColorName))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(4)
        .frame(width: 58)
        .background(
            live ? tint.opacity(0.08) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .contextMenu {
            if !runOnly {
                if onRename != nil {
                    Button("Rename…") {
                        draftName = renameValue ?? name
                        editingName = true
                    }
                }
                if let colorKey {
                    Menu("Color") {
                        ForEach(StripColorStore.palette, id: \.name) { entry in
                            Toggle(entry.name, isOn: Binding(
                                get: {
                                    (colorStore.overrideName(for: colorKey)
                                        ?? defaultColorName) == entry.name
                                },
                                set: { _ in colorStore.set(colorKey, name: entry.name) }
                            ))
                        }
                        Divider()
                        Button("Section Default") { colorStore.set(colorKey, name: nil) }
                    }
                }
                extraMenu()
            }
        }
    }
}

private struct MiniPan: View {
    let value: Binding<Float>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let pan = CGFloat(min(max(value.wrappedValue, -1), 1))
            let travel = max(1, width - 5)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 3)
                Rectangle()
                    .fill(Color.primary.opacity(0.25))
                    .frame(width: 1, height: 7)
                    .offset(x: width / 2 - 0.5)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(pan == 0
                        ? Color.primary.opacity(0.55)
                        : Color.accentColor.opacity(0.9))
                    .frame(width: 5, height: 10)
                    .shadow(radius: 0.5)
                    .offset(x: travel * (pan + 1) / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 2).onEnded { value.wrappedValue = 0 }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = drag.location.x / max(1, width)
                        var pan = Float(fraction * 2 - 1)
                        if abs(pan) < 0.08 { pan = 0 }  
                        value.wrappedValue = min(max(pan, -1), 1)
                    }
            )
        }
        .help(panCaption)
    }

    private var panCaption: String {
        let pan = value.wrappedValue
        guard pan != 0 else { return "Pan — center. Double-click resets." }
        return "Pan — \(Int((abs(pan) * 100).rounded()))% \(pan < 0 ? "left" : "right")"
    }
}

private struct MiniFader: View {
    let value: Binding<Float>

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            let level = CGFloat(AudioLevel.faderFraction(gain: value.wrappedValue))
            let travel = max(1, width - 7)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(0, travel * level + 3.5), height: 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.9))
                    .frame(width: 7, height: 14)
                    .shadow(radius: 0.5)
                    .offset(x: travel * level)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = drag.location.x / max(1, width)
                        value.wrappedValue = AudioLevel.faderGain(
                            fraction: Float(min(max(fraction, 0), 1)))
                    }
            )
        }
        .frame(height: 16)
    }
}

private struct VerticalFader: View {
    let value: Binding<Float>

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height

            let level = CGFloat(AudioLevel.faderFraction(gain: value.wrappedValue))

            let travel = max(1, height - 7)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 4)
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 4, height: max(0, travel * level + 3.5))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 14, height: 7)
                    .shadow(radius: 0.5)
                    .offset(y: -(travel * level))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = 1 - drag.location.y / max(1, height)
                        value.wrappedValue = AudioLevel.faderGain(
                            fraction: Float(min(max(fraction, 0), 1)))
                    }
            )
        }
        .frame(width: 18)
    }
}

private struct LevelLabel: View {
    enum Style { case gain, peak }
    let decibels: Float
    let style: Style

    var body: some View {
        Text(decibels <= -90 ? "-∞" : String(format: "%.1f", decibels))
            .font(.system(size: 7.5, weight: .medium).monospacedDigit())
            .foregroundStyle(
                style == .peak && decibels > -1
                    ? AnyShapeStyle(Color.orange)
                    : style == .peak
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.tertiary))
            .frame(maxWidth: .infinity)
    }
}

private struct MeterScale: View {
    private static let marks: [Float] = [0, -6, -12, -18, -24, -30, -40, -50, -60]

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ForEach(Self.marks, id: \.self) { decibels in
                let fraction = CGFloat(AudioLevel.meterFraction(decibels: decibels))
                Text(String(Int(-decibels)))
                    .font(.system(size: 5.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, alignment: .trailing)
                    .position(
                        x: 6,
                        y: min(max(height - height * fraction, 3), height - 3)
                    )
            }
        }
        .frame(width: 12)
    }
}

private struct VerticalMeter: View {

    let peak: Float
    let heldPeakDecibels: Float

    var signalPresent: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let fill = CGFloat(AudioLevel.meterFraction(peak))
            let held = CGFloat(AudioLevel.meterFraction(decibels: heldPeakDecibels))
            let hot = heldPeakDecibels > -1
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(hot ? Color.orange : Color.green)
                    .frame(height: max(0, height * fill))
                if held > 0.01 {
                    Rectangle()
                        .fill(hot ? Color.orange : Color.green.opacity(0.8))
                        .frame(height: 1.5)
                        .offset(y: -(height * held - 1))
                }
                if signalPresent {
                    Circle()
                        .fill(Color.green.opacity(0.6))
                        .frame(width: 3, height: 3)
                        .offset(y: 5)
                }
            }

            .animation(.linear(duration: 0.07), value: fill)
        }
        .frame(width: 4)
    }
}

private struct GainEntryPopover: View {
    @Binding var draft: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("dB", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
            .padding(10)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit(commit)
    }
}

private struct StripRenamePopover: View {
    @Binding var draft: String
    let commit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .frame(width: 200)
            .padding(10)
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit(commit)
    }
}

private struct FoldCard: View {
    let name: String
    let symbol: String
    let count: Int
    let expanded: Bool
    let peak: Float
    let toggle: () -> Void
    let rename: ((String) -> Void)?
    let remove: (() -> Void)?
    @Environment(\.runOnly) private var runOnly
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 6) {
            Button(action: toggle) {
                VStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                    Text(name)
                        .font(.system(size: 9, weight: .medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text("\(count)")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Image(systemName: expanded ? "chevron.left" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Fold \(name)" : "Show \(name) (\(count))")
            VerticalMeter(peak: peak, heldPeakDecibels: -120)
                .frame(width: 5)
                .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle.standard(CornerStandard.element))
        .contextMenu {
            if !runOnly, let rename {
                Button("Rename\u{2026}") {
                    draft = name
                    renaming = true
                }
            }
            if !runOnly, let remove {
                Button("Remove Folder (keeps its mixes)", action: remove)
            }
        }
        .popover(isPresented: $renaming) {
            StripRenamePopover(draft: $draft) {
                rename?(draft)
                renaming = false
            }
        }
    }
}

@MainActor
@Observable
final class MixerGroupStore {
    static let shared = MixerGroupStore()

    private var expanded: [String: Bool]
    private static let defaultsKey = "mixer.expandedDevices"

    private init() {
        expanded = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: Bool]) ?? [:]
    }

    func isExpanded(_ uid: String) -> Bool {
        expanded[uid] ?? false
    }

    func toggle(_ uid: String) {
        expanded[uid] = !isExpanded(uid)
        UserDefaults.standard.set(expanded, forKey: Self.defaultsKey)
    }
}

@MainActor
@Observable
final class StripColorStore {
    static let shared = StripColorStore()

    static let palette: [(name: String, color: Color)] = [
        ("Teal", .teal), ("Blue", .blue), ("Purple", .purple),
        ("Pink", .pink), ("Red", .red), ("Orange", .orange),
        ("Yellow", .yellow), ("Green", .green), ("Gray", .gray),
    ]

    static func color(named name: String) -> Color {
        palette.first { $0.name == name }?.color ?? .gray
    }

    private var overrides: [String: String]
    private static let defaultsKey = "mixer.stripColors"

    private init() {
        overrides = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: String]) ?? [:]
    }

    func color(for key: String, defaultName: String) -> Color {
        Self.color(named: overrides[key] ?? defaultName)
    }

    func overrideName(for key: String) -> String? {
        overrides[key]
    }

    func set(_ key: String, name: String?) {
        overrides[key] = name
        UserDefaults.standard.set(overrides, forKey: Self.defaultsKey)
    }
}
