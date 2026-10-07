import AudioEngine
import PresenterCore
import SwiftUI

struct AudioModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    @State private var editingPlaylist: EditingPlaylist?
    @State private var showingFadePopover = false
    @State private var showingCrossfadePopover = false
    @State private var hoveredPlaylistID: String?
    @State private var expandedPlaylists: Set<String> = []

    private struct TrackDropTarget: Equatable {
        let playlistID: String
        let beforeEntryID: String?
    }
    @State private var trackDropTarget: TrackDropTarget?

    private struct EditingPlaylist: Identifiable {
        let id: String
    }

    var body: some View {
        let audio = controls.audio
        let playlists = model.playlists(in: .audio)
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                compactFadeButton(audio)
                compactCrossfadeButton(audio)
                Button {
                    audio.isMuted.toggle()
                } label: {
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .moduleHeaderGlyph(
                            audio.isMuted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary)
                        )
                }
                .buttonStyle(.plain)
                .help(audio.isMuted ? "Unmute (all buses)" : "Mute (all buses)")
                if !runOnly {
                    Button {
                        if let id = model.createPlaylist(in: .audio) {
                            editingPlaylist = EditingPlaylist(id: id)
                        }
                    } label: {
                        Image(systemName: "plus").moduleHeaderGlyph()
                    }
                    .buttonStyle(.plain)
                    .help("New music playlist")
                }
            }
            ForEach(audio.players.filter { $0.playlistID == nil }) { player in
                nowPlaying(player)
                AudioTransportControls(model: model, player: player) { EmptyView() }
            }
            ForEach(playlists, id: \.id) { entry in
                playlistBlock(entry, audio: audio)
            }
        }
        .popover(item: $editingPlaylist) { editing in
            if let entry = model.indexEntry(editing.id) {
                InspectorView(model: model, entry: entry)
                    .frame(width: 340, height: 420)

                    .onChange(of: model.listVersion) {
                        audio.playlistDocumentChanged()
                    }
                    .onDisappear {
                        audio.playlistDocumentChanged()
                    }
            }
        }
    }

    @ViewBuilder
    private func playlistBlock(_ entry: LibraryIndex.Entry, audio: AudioController) -> some View {
        let isLive = controls.state.liveAudio.contains { $0.playlistId == entry.id }
        let expanded = expandedPlaylists.contains(entry.id)

        if let player = audio.player(forPlaylist: entry.id) {
            nowPlaying(player)
            AudioTransportControls(model: model, player: player) { EmptyView() }
        }

        Button {
            withAnimation(.easeOut(duration: 0.12)) {
                if expanded {
                    expandedPlaylists.remove(entry.id)
                } else {
                    expandedPlaylists.insert(entry.id)
                }
            }
        } label: {
            HStack(spacing: 6) {

                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if expanded {
                                expandedPlaylists.remove(entry.id)
                            } else {
                                expandedPlaylists.insert(entry.id)
                            }
                        }
                    }
                    .help("Show tracks")

                Text(entry.name)
                    .font(.caption)
                    .foregroundStyle(isLive ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if hoveredPlaylistID == entry.id, !runOnly {

                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingPlaylist = EditingPlaylist(id: entry.id)
                        }
                        .help("Playlist settings & tracks")
                }

                HStack(spacing: 3) {
                    Image(systemName: isLive ? "stop.fill" : "play.fill")
                        .font(.system(size: 7, weight: .semibold))
                    Text(isLive ? "Stop" : "Play")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(isLive ? Color.green : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isLive {

                        controls.stopAudio(playlistID: entry.id)
                    } else if let playlist = try? model.playlist(entry.id) {
                        controls.fire(playlist: playlist)
                    }
                }
                .help(isLive ? "Stop the playlist" : "Play the playlist")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isLive ? Color.green.opacity(0.12) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )

        .draggablePayload(runOnly ? nil : entry.id)
        .onHover { inside in
            hoveredPlaylistID = inside
                ? entry.id
                : (hoveredPlaylistID == entry.id ? nil : hoveredPlaylistID)
        }

        .contextMenu { playlistMenu(entry: entry, isLive: isLive, audio: audio) }

        .dropDestination(for: String.self) { payloads, _ in
            guard !runOnly else { return false }
            let accepted: PlaylistRefKind =
                ((try? model.playlist(entry.id))?.playlistKind ?? .audio) == .media
                    ? .media : .audio
            let droppable = payloads.filter { id in
                guard let dropped = model.indexEntry(id)
                else { return false }
                return (dropped.kind == .audio && accepted == .audio)
                    || (dropped.kind == .media && accepted == .media)
            }
            guard !droppable.isEmpty else { return false }
            for id in droppable {
                model.addToPlaylist(entry.id, itemID: id)
            }
            audio.playlistDocumentChanged()
            return true
        }
        if expanded, let playlist = try? model.playlist(entry.id) {
            trackList(playlist, isLivePlaylist: isLive, audio: audio)
        }
    }

    private func trackList(
        _ playlist: Playlist, isLivePlaylist: Bool, audio: AudioController
    ) -> some View {

        let player = audio.player(forPlaylist: playlist.id)
        return VStack(spacing: 0) {
            ForEach(playlist.entries, id: \.id) { track in
                let isCurrent = player?.currentEntryID == track.id
                Button {
                    controls.fire(playlist: playlist, startAt: track.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCurrent ? "waveform" : "music.note")
                            .font(.system(size: 8))
                            .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 12)
                        Text(model.indexEntry(track.refId)?.name ?? track.refId)
                            .font(.caption2)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let seconds = trackSeconds(track) {
                            Text(timecode(seconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isCurrent ? Color.green.opacity(0.08) : Color.clear,
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .help("Play the playlist starting here")
                .contextMenu {
                    if !runOnly {

                        Button("Edit in Library") {
                            model.openInEditor(entryID: track.refId)
                            appModeRaw = AppMode.edit.rawValue
                        }
                        Divider()
                        Button("Remove from Playlist", role: .destructive) {
                            model.removePlaylistEntry(playlist.id, entryID: track.id)
                            audio.playlistDocumentChanged()
                        }
                    }
                }
                .padding(.vertical, 0.5)

                .draggablePayload(runOnly ? nil : "pltrk::\(playlist.id)::\(track.id)")
                .dropDestination(for: String.self) { payloads, _ in
                    !runOnly && dropOnTracks(playlist, payloads: payloads, before: track.id, audio: audio)
                } isTargeted: { targeted in
                    trackDropTarget = targeted
                        ? TrackDropTarget(playlistID: playlist.id, beforeEntryID: track.id)
                        : (trackDropTarget?.beforeEntryID == track.id ? nil : trackDropTarget)
                }
                .overlay(alignment: .top) {
                    if trackDropTarget?.playlistID == playlist.id,
                       trackDropTarget?.beforeEntryID == track.id {
                        ControlBoardInsertionLine()
                    }
                }
            }
            if !runOnly {
                addTrackRow(playlist, audio: audio)

                    .dropDestination(for: String.self) { payloads, _ in
                        dropOnTracks(playlist, payloads: payloads, before: nil, audio: audio)
                    } isTargeted: { targeted in
                        trackDropTarget = targeted
                            ? TrackDropTarget(playlistID: playlist.id, beforeEntryID: "end")
                            : (trackDropTarget?.beforeEntryID == "end" ? nil : trackDropTarget)
                    }
                    .overlay(alignment: .top) {
                        if trackDropTarget?.playlistID == playlist.id,
                           trackDropTarget?.beforeEntryID == "end" {
                            ControlBoardInsertionLine()
                        }
                    }
            }
        }
        .padding(.leading, 14)
    }

    private func addTrackRow(_ playlist: Playlist, audio: AudioController) -> some View {

        let candidates = model.entries(in: (playlist.playlistKind ?? .audio) == .media ? .media : .audio)
        return Menu {
            ForEach(candidates, id: \.id) { candidate in
                Button(candidate.name) {
                    model.addToPlaylist(playlist.id, itemID: candidate.id)
                    audio.playlistDocumentChanged()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .medium))
                    .frame(width: 12)
                Text("Add Track")
                    .font(.caption2)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func dropOnTracks(
        _ playlist: Playlist, payloads: [String], before entryID: String?,
        audio: AudioController
    ) -> Bool {
        trackDropTarget = nil
        guard !runOnly else { return false }
        let changed = model.handlePlaylistDrop(
            playlist.id, payloads: payloads, beforeEntryID: entryID
        )
        if changed { audio.playlistDocumentChanged() }
        return changed
    }

    private func trackSeconds(_ track: PlaylistEntry) -> Double? {
        switch track.refKind {
        case .audio: model.audio(track.refId)?.durationSeconds
        case .media: model.media(track.refId)?.durationSeconds
        }
    }

    @ViewBuilder
    private func playlistMenu(
        entry: LibraryIndex.Entry, isLive: Bool, audio: AudioController
    ) -> some View {
        if runOnly {
            EmptyView()
        } else if let playlist = try? model.playlist(entry.id) {
            let syncIfLive = { audio.playlistDocumentChanged() }
            Picker("Repeat", selection: Binding(
                get: { (try? model.playlist(entry.id))?.playbackMode ?? .playAll },
                set: { mode in
                    model.updatePlaylist(entry.id) { $0.playbackMode = mode }
                    syncIfLive()
                }
            )) {
                Text("Off").tag(PlaybackMode.playAll)
                Text("Loop Playlist").tag(PlaybackMode.loopPlaylist)
                Text("Loop Single").tag(PlaybackMode.loopSingle)
            }
            Picker("Shuffle", selection: Binding(
                get: { (try? model.playlist(entry.id))?.shuffle ?? false },
                set: { on in
                    model.updatePlaylist(entry.id) { $0.shuffle = on }
                    syncIfLive()
                }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            crossfadeOverridePicker("Crossfade", playlistID: entry.id, audio: audio)
            Divider()

            Picker("Mix", selection: Binding(
                get: { audio.playlistMixId(entry.id) ?? AudioMixInventory.mainID },
                set: { audio.setPlaylistMix(entry.id, mixId: $0) }
            )) {
                ForEach(audio.mixes.entries) { mix in
                    Text(mix.name).tag(mix.id)
                }
            }
            Divider()
            Button("Edit Playlist…") {
                editingPlaylist = EditingPlaylist(id: entry.id)
            }
            Button("Add to Service") { model.addToCurrentService(entry) }
            Divider()
            Button("Delete", role: .destructive) {
                if isLive { controls.stopAudio(playlistID: entry.id) }
                model.delete(entry)
            }
        }
    }

    private func nowPlaying(_ player: AudioPlayer) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(player.isPlaying ? Color.green : .secondary)
                Text(player.currentTrackName ?? "—")
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let position = player.passPosition {
                    Text("\(position.index)/\(position.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if player.duration > 0 {
                    AudioTimecode(player: player)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 24)

            AudioScrubBar(player: player)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private func compactFadeButton(_ audio: AudioController) -> some View {
        Button {
            showingFadePopover.toggle()
        } label: {
            headerFadeLabel(
                kind: .fade,
                active: audio.fadeEnabled,
                value: audio.fadeEnabled ? PlaylistCrossfade.label(audio.fadeSeconds) : "Off"
            )
        }
        .buttonStyle(.plain)
        .help("Fade on play, pause, and stop")
        .popover(isPresented: $showingFadePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fade on play, pause, and stop")
                    .font(.caption.weight(.semibold))
                Toggle("Fade in/out", isOn: Binding(
                    get: { audio.fadeEnabled },
                    set: { audio.fadeEnabled = $0 }
                ))
                .font(.caption)
                HStack(spacing: 8) {
                    Glyph(kind: .fade, size: 12)
                        .foregroundStyle(.secondary)
                    DrawnSlider(
                        value: Binding(
                            get: { audio.fadeSeconds },
                            set: { audio.fadeSeconds = $0 }
                        ),
                        range: 0 ... 5, step: 0.25,
                        label: { "\($0.formatted())s" }
                    )
                    .disabled(!audio.fadeEnabled)
                    .opacity(audio.fadeEnabled ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func compactCrossfadeButton(_ audio: AudioController) -> some View {
        Button {
            showingCrossfadePopover.toggle()
        } label: {
            headerFadeLabel(
                kind: .crossfade,
                active: audio.crossfadeSeconds > 0,
                value: PlaylistCrossfade.label(audio.crossfadeSeconds)
            )
        }
        .buttonStyle(.plain)
        .help("Crossfade between songs")
        .popover(isPresented: $showingCrossfadePopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Crossfade between songs")
                    .font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    Glyph(kind: .crossfade, size: 12)
                        .foregroundStyle(.secondary)
                    DrawnSlider(
                        value: Binding(
                            get: { audio.crossfadeSeconds },
                            set: { audio.crossfadeSeconds = $0 }
                        ),
                        range: 0 ... PlaylistCrossfade.maximumSeconds, step: 0.5,
                        label: PlaylistCrossfade.label
                    )
                }
                let live = audio.players.filter { $0.playlistID != nil }
                if !live.isEmpty {
                    Divider()
                    ForEach(live) { player in
                        if let playlistID = player.playlistID {
                            let override = (try? model.playlist(playlistID))?.crossfadeSeconds
                            HStack(spacing: 8) {
                                Text(
                                    override.map { "\(player.displayName) overrides: \(PlaylistCrossfade.label($0))" }
                                        ?? "\(player.displayName) follows this"
                                )
                                .font(.caption)
                                .lineLimit(1)
                                Spacer(minLength: 4)
                                crossfadeOverridePicker("", playlistID: playlistID, audio: audio)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .fixedSize()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 240)
        }
    }

    private func headerFadeLabel(kind: GlyphKind, active: Bool, value: String) -> some View {
        HStack(spacing: 4) {
            Glyph(kind: kind, size: 13)

            ZStack(alignment: .leading) {
                Text("12.5s").hidden()
                Text(value)
            }
            .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(active ? Color.green : .secondary)
        .padding(.horizontal, 5)

        .frame(height: 24)
        .contentShape(Rectangle())
    }

    private func crossfadeOverridePicker(
        _ title: String, playlistID: String, audio: AudioController
    ) -> some View {
        let current = (try? model.playlist(playlistID))?.crossfadeSeconds
        return Picker(title, selection: Binding<Double?>(
            get: { (try? model.playlist(playlistID))?.crossfadeSeconds },
            set: { seconds in
                model.updatePlaylist(playlistID) { $0.crossfadeSeconds = seconds }
                audio.playlistDocumentChanged()
            }
        )) {
            Text("Use default (\(PlaylistCrossfade.label(audio.crossfadeSeconds)))").tag(Double?.none)
            Text("Off").tag(Double?.some(0))
            ForEach(PlaylistCrossfade.presets, id: \.self) { seconds in
                Text(PlaylistCrossfade.label(seconds)).tag(Double?.some(seconds))
            }
            if let current, current > 0, !PlaylistCrossfade.presets.contains(current) {
                Text(PlaylistCrossfade.label(current)).tag(Double?.some(current))
            }
        }
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct DrawnSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: (Double) -> String

    @State private var live: Double?

    var body: some View {
        HStack(spacing: 8) {
            track
                .frame(width: 140)
            Text(label(live ?? value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let span = max(range.upperBound - range.lowerBound, 0.001)
            let shown = live ?? value
            let fraction = min(max(CGFloat((shown - range.lowerBound) / span), 0), 1)
            let capWidth: CGFloat = 8
            let travel = max(1, width - capWidth)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: max(0, travel * fraction + capWidth / 2), height: 4)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.primary.opacity(0.92))
                    .frame(width: capWidth, height: 16)
                    .shadow(radius: 0.5)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = range.lowerBound
                            + Double(min(max(drag.location.x / max(1, width), 0), 1)) * span
                        let snapped = step > 0 ? (raw / step).rounded() * step : raw
                        live = min(max(snapped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        if let live, live != value { value = live }
                        live = nil
                    }
            )
        }
        .frame(height: 18)
    }
}
