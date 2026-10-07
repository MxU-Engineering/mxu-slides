import PresenterCore
import SwiftUI

struct MediaPlaylistsModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly
    @Environment(\.signage) private var signage
    @Environment(\.mediaPlaylists) private var mediaPlaylists

    @State private var editingPlaylist: EditingPlaylist?
    @State private var hoveredPlaylistID: String?
    @State private var renamingPlaylist: LibraryIndex.Entry?
    @State private var renameText = ""

    private struct EditingPlaylist: Identifiable {
        let id: String
    }

    var body: some View {
        let playlists = model.playlists(in: .media)
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                if !runOnly {
                    Button {
                        if let id = model.createPlaylist(in: .media) {
                            editingPlaylist = EditingPlaylist(id: id)
                        }
                    } label: {
                        Image(systemName: "plus").moduleHeaderGlyph()
                    }
                    .buttonStyle(.plain)
                    .help("New media playlist")
                }
            }
            signageNowRows()
            if playlists.isEmpty {
                Text("Playlists gather media for signage loops and quick fires — add one with +, fill it from the library's Add to Playlist menu or by dropping media here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(playlists, id: \.id) { entry in
                playlistRow(entry)
            }
        }
        .popover(item: $editingPlaylist) { editing in
            if let entry = model.indexEntry(editing.id) {
                InspectorView(model: model, entry: entry)
                    .frame(width: 340, height: 420)
            }
        }
        .alert(
            "Rename Playlist",
            isPresented: Binding(
                get: { renamingPlaylist != nil },
                set: { if !$0 { renamingPlaylist = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let entry = renamingPlaylist { model.rename(entry, to: renameText) }
                renamingPlaylist = nil
            }
            Button("Cancel", role: .cancel) { renamingPlaylist = nil }
        }
    }

    @ViewBuilder
    private func signageNowRows() -> some View {
        if let signage {
            let live = signage.channels.compactMap { channel -> (String, String, String, String)? in
                guard let playlistID = channel.playlistId, !playlistID.isEmpty else { return nil }
                let playlist = model.indexEntry(playlistID)?.name ?? "Playlist"
                let screens = signage.screenNames(showing: channel.id)
                return (channel.id, channel.name, playlist,
                        screens.isEmpty ? "no screens" : screens.joined(separator: ", "))
            }
            ForEach(live, id: \.0) { channelID, channelName, playlistName, screens in
                HStack(spacing: 6) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.green)
                    Text("\(channelName) — \(playlistName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(screens)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Clear") {
                        signage.assign(playlistID: nil, toSignage: channelID)
                    }
                    .buttonStyle(CardButtonStyle())
                    .help("Clear this signage — its screens go dark until new content is assigned")
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Color.green.opacity(0.10),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
            }
        }
    }

    private func playlistRow(_ entry: LibraryIndex.Entry) -> some View {
        let isWalking = mediaPlaylists?.isWalking(entry.id) ?? false
        let isLive = isWalking
            || (signage?.channels ?? []).contains { $0.playlistId == entry.id }
        return HStack(spacing: 6) {
            Text(entry.name)
                .font(.caption)
                .foregroundStyle(isLive ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)

            if isWalking {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.green)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { mediaPlaylists?.stop() }
                    .help("Stop the playlist and clear its content")
            } else if hoveredPlaylistID == entry.id {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { mediaPlaylists?.play(playlistID: entry.id) }
                    .help("Fire this playlist to the room — Auto Advance walks it when enabled in settings")
            }
            if hoveredPlaylistID == entry.id, !runOnly {

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { editingPlaylist = EditingPlaylist(id: entry.id) }
                    .help("Playlist settings & items")
            }

            QuietMenuChip(title: "Signage") {
                ForEach(signage?.channels ?? [], id: \.id) { channel in
                    Button(channel.playlistId == entry.id
                        ? "✓ \(channel.name)" : channel.name
                    ) {
                        signage?.assign(
                            playlistID: channel.playlistId == entry.id ? nil : entry.id,
                            toSignage: channel.id
                        )
                    }
                }
                if signage?.channels.isEmpty ?? true {
                    Text("No signages yet — create them in Screen Configuration")
                }
            }
            .help("Make this playlist a Digital Signage's content — every screen sourced to that signage follows")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
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
        .contextMenu {
            if !runOnly {
                Button("Settings…") { editingPlaylist = EditingPlaylist(id: entry.id) }

                Button("Rename…") {
                    renameText = entry.name
                    renamingPlaylist = entry
                }
                Divider()
                Button("Delete", role: .destructive) { model.delete(entry) }
            }
        }

        .dropDestination(for: String.self) { payloads, _ in
            guard !runOnly else { return false }
            let mediaIDs = payloads.filter { model.entry($0)?.kind == .media }
            guard !mediaIDs.isEmpty else { return false }
            for id in mediaIDs {
                model.addToPlaylist(entry.id, itemID: id)
            }
            return true
        }
    }
}
