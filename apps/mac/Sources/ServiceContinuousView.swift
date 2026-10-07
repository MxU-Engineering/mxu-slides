import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct ServiceContinuousView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let serviceID: String

    let focusItemID: String?

    @Binding var focusScroll: PresentFocusScroll

    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = false
    @AppStorage("slideGrid.legibleText") private var legibleText = false
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback

    @Environment(\.runOnly) private var runOnly
    @FocusState private var focused: Bool

    @State private var deleteRequests = 0

    @State private var clipboardRequests = SlideClipboardRequests()

    @State private var mediaMenuState = MediaCueMenuState()
    @State private var playlistDropTarget: PlaylistDropTarget?

    @State private var viewportHeight: CGFloat = 0

    @State private var headerHeights: [String: CGFloat] = [:]

    static let scrollSpace = "presentScroll"

    static let contentSpace = "presentContent"

    private struct FirePosition {
        let itemID: String
        let presentation: Presentation
        let arrangementId: String?
        let occurrence: Int
        let slide: Slide
    }

    var body: some View {
        let _ = BodyMeter.tick(.serviceContinuous)
        let _ = model.listVersion
        if let service = try? model.service(serviceID) {
            let positions = firePositions(service)

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    GeometryReader { viewport in
                        ScrollView {

                            VStack(alignment: .leading, spacing: 0) {

                                let rows = presentRows(service)

                                let _ = PresentCardFrames.shared.show(rows)
                                ForEach(rows, id: \.presentRowIdentity) { item in
                                    itemSection(item, proxy: proxy)

                                        .background {
                                            GeometryReader { geo in
                                                let _ = PresentCardFrames.shared.note(
                                                    item.id, geo.frame(in: .named(Self.scrollSpace)))
                                                let _ = PresentCardFrames.shared.noteDoc(
                                                    item.id, geo.frame(in: .named(Self.contentSpace)))
                                                Color.clear
                                            }
                                        }
                                }
                            }

                            .padding([.horizontal, .bottom], 12)

                            .background(alignment: .topLeading) {
                                PresentScrollWatch().frame(width: 1, height: 1)
                            }
                            .coordinateSpace(name: Self.contentSpace)
                        }
                        .coordinateSpace(name: Self.scrollSpace)
                        .inputRegion("present")
                        .onAppear { viewportHeight = viewport.size.height }
                        .onChange(of: viewport.size.height) { _, height in
                            viewportHeight = height
                        }

                        .onChange(of: viewport.size.width) { _, _ in
                            PresentCardFrames.shared.keepPlace(because: "width")
                        }
                        .onChange(of: slidesAcross) { _, _ in
                            PresentCardFrames.shared.keepPlace(because: "slides across")
                        }
                    }
                    .onChange(of: focusItemID) { _, id in
                        scrollToFocus(id, reason: "selection", proxy: proxy, service: service)
                        pointNewSlide(at: id)
                    }

                    .onChange(of: focusScroll.reselects) { _, _ in
                        scrollToFocus(focusItemID, reason: "reselect", proxy: proxy, service: service)
                        pointNewSlide(at: focusItemID)
                    }
                    .onAppear {

                        scrollToFocus(focusItemID, reason: "appear", proxy: proxy, service: service)
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onPresentFireKeys {
                    fireStep($0, positions)
                    controls?.noteKeyboardFire()
                }

                .background(KeyboardFireFollow(controls: controls) { revealLive(service) })

                .onDeleteCommand { deleteRequests += 1 }
                .onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }
            }
            .onAppear { focused = true }

            .onChange(of: model.listVersion) {
                controls?.refreshNextSlide()
            }
            .mediaCueSheets(model: model, state: mediaMenuState)
        } else {
            ContentUnavailableView(
                "No Service", systemImage: "calendar",
                description: Text("Choose a service to present.")
            )
        }
    }

    private static let cardHeaderShape = UnevenRoundedRectangle(
        cornerRadii: .init(
            topLeading: CornerStandard.element, topTrailing: CornerStandard.element
        ),
        style: .continuous
    )
    private static let cardBodyShape = UnevenRoundedRectangle(
        cornerRadii: .init(
            bottomLeading: CornerStandard.element, bottomTrailing: CornerStandard.element
        ),
        style: .continuous
    )

    @ViewBuilder
    private func itemSection(_ item: ServiceItem, proxy: ScrollViewProxy) -> some View {
        switch item.itemKind {
        case .header:

            HStack(spacing: 8) {
                if !item.isHidden {
                    Text(item.name.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(headerTint(item) ?? Color.secondary)
                        .tracking(0.6)
                }
                Rectangle()
                    .fill((headerTint(item) ?? Color(nsColor: .separatorColor)).opacity(0.45))
                    .frame(height: 1)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .id(item.id)
        case .info:

            Section {
                EmptyView()
            } header: {
                CardRefresh(model: model) { unlinkedCard(item) }
            }
        case .presentation:
            stickySection(item) {
                CardRefresh(model: model) { presentationBodyFresh(item) }
            } header: {
                CardRefresh(model: model) { presentationHeaderFresh(item, proxy: proxy) }
            }
        case .media:
            stickySection(item) {
                CardRefresh(model: model) { mediaCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item, glyph: .media) {
                        if let media = model.media(item.refId) {
                            mediaContext(media)
                        }
                    }
                    .contextMenu { mediaQuickMenu(item) }

                    .id("mediaHeaderMenu|\(item.id)|\(model.media(item.refId) == nil)")
                }
            }
        case .audio:
            stickySection(item) {
                CardRefresh(model: model) { audioCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item, glyph: .audio) {
                        let isLive = controls?.state.liveAudio
                            .contains { $0.audioItemId == item.refId } ?? false
                        playStopChip(
                            isLive: isLive,
                            help: isLive ? "Stop" : "Play"
                        ) {
                            if isLive {
                                controls?.stopAudio(audioItemID: item.refId)
                            } else if let audioItem = model.audio(item.refId) {
                                controls?.fire(audioItem: audioItem)
                            }
                        }
                    }
                }
            }
        case .playlist:
            stickySection(item) {
                CardRefresh(model: model) { playlistCardBody(item) }
            } header: {
                CardRefresh(model: model) {
                    cardHeader(item, glyph: .audio) {
                        if let playlist = try? model.playlist(item.refId) {
                            let isLive = controls?.state.liveAudio
                                .contains { $0.playlistId == playlist.id } ?? false
                            Text("\(playlist.entries.count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            playStopChip(
                                isLive: isLive,
                                help: isLive ? "Stop the playlist" : "Play the playlist"
                            ) {
                                if isLive {
                                    controls?.stopAudio(playlistID: playlist.id)
                                } else {
                                    controls?.fire(playlist: playlist)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func playStopChip(
        isLive: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isLive ? "stop.fill" : "play.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(isLive ? "Stop" : "Play")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(isLive ? Color.green : .secondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(help)
    }

    @ViewBuilder
    private func playlistCardBody(_ item: ServiceItem) -> some View {
        if let playlist = try? model.playlist(item.refId) {
            let isLive = controls?.state.liveAudio
                .contains { $0.playlistId == playlist.id } ?? false

            VStack(spacing: 0) {

                if let player = controls?.audio.player(forPlaylist: playlist.id) {
                    AudioTransportControls(model: model, player: player) { EmptyView() }
                    AudioScrubBar(player: player, showsTimes: true)
                        .padding(.bottom, 6)
                }
                ForEach(playlist.entries, id: \.id) { track in
                    playlistTrackRow(track, in: playlist, isLive: isLive)
                }
                if !runOnly {
                    cardAddTrackRow(playlist)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardSurface, in: Self.cardBodyShape)
            .overlay(
                Self.cardBodyShape.strokeBorder(
                    isLive
                        ? Color.green.opacity(0.6)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
            )
            .overlay(alignment: .bottom) {

                if playlistDropTarget?.playlistID == playlist.id,
                   playlistDropTarget?.beforeEntryID == nil {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(height: 2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
            .dropDestination(for: String.self) { payloads, _ in
                !runOnly && dropOnPlaylist(playlist, payloads: payloads, before: nil)
            } isTargeted: { targeted in
                playlistDropTarget = targeted
                    ? PlaylistDropTarget(playlistID: playlist.id, beforeEntryID: nil)
                    : (playlistDropTarget?.beforeEntryID == nil ? nil : playlistDropTarget)
            }
            .modifier(BottomCutRounding(boundary: viewportHeight))
            .padding(.bottom, 12)
        }
    }

    struct PlaylistDropTarget: Equatable {
        let playlistID: String
        let beforeEntryID: String?
    }

    private func dropOnPlaylist(
        _ playlist: Playlist, payloads: [String], before entryID: String?
    ) -> Bool {
        playlistDropTarget = nil
        let changed = model.handlePlaylistDrop(
            playlist.id, payloads: payloads, beforeEntryID: entryID
        )
        if changed { controls?.audio.playlistDocumentChanged() }
        return changed
    }

    private func playlistTrackRow(
        _ track: PlaylistEntry, in playlist: Playlist, isLive: Bool
    ) -> some View {
        let isCurrent = controls?.audio.player(forPlaylist: playlist.id)?.currentEntryID == track.id
        return Button {
            controls?.fire(playlist: playlist, startAt: track.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "waveform" : "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(isCurrent ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: 14)
                Text(model.entry(track.refId)?.name ?? track.refId)
                    .font(.caption)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isCurrent, let player = controls?.audio.player(forPlaylist: playlist.id),
                   player.duration > 0 {
                    AudioTimecode(player: player)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let seconds = playlistTrackSeconds(track) {
                    Text(timecode(seconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isCurrent ? Color.green.opacity(0.10) : Color.clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .help("Play the playlist starting here")
        .contextMenu {
            if !runOnly {
                Button("Remove from Playlist", role: .destructive) {
                    model.removePlaylistEntry(playlist.id, entryID: track.id)
                    controls?.audio.playlistDocumentChanged()
                }
            }
        }
        .padding(.vertical, 1)

        .draggablePayload(runOnly ? nil : "pltrk::\(playlist.id)::\(track.id)")
        .dropDestination(for: String.self) { payloads, _ in
            guard !runOnly else { return false }
            return dropOnPlaylist(playlist, payloads: payloads, before: track.id)
        } isTargeted: { targeted in
            playlistDropTarget = targeted
                ? PlaylistDropTarget(playlistID: playlist.id, beforeEntryID: track.id)
                : (playlistDropTarget?.beforeEntryID == track.id ? nil : playlistDropTarget)
        }
        .overlay(alignment: .top) {
            if playlistDropTarget?.playlistID == playlist.id,
               playlistDropTarget?.beforeEntryID == track.id {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func cardAddTrackRow(_ playlist: Playlist) -> some View {

        let candidates = model.entries(in: (playlist.playlistKind ?? .audio) == .media ? .media : .audio)
        return Menu {
            ForEach(candidates, id: \.id) { candidate in
                Button(candidate.name) {
                    model.addToPlaylist(playlist.id, itemID: candidate.id)
                    controls?.audio.playlistDocumentChanged()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 14)
                Text("Add Track")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func playlistTrackSeconds(_ track: PlaylistEntry) -> Double? {
        switch track.refKind {
        case .audio: model.audio(track.refId)?.durationSeconds
        case .media: model.media(track.refId)?.durationSeconds
        }
    }

    private func audioCardBody(_ item: ServiceItem) -> some View {
        let isLive = controls?.state.liveAudio
            .contains { $0.audioItemId == item.refId } ?? false
        let player = controls?.audio.player(forAudioItem: item.refId)
        return HStack(spacing: 8) {
            Image(systemName: isLive ? "waveform" : "music.note")
                .font(.system(size: 9))
                .foregroundStyle(isLive ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 14)
            Text(item.name)
                .font(.caption)
                .foregroundStyle(isLive ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let player, player.duration > 0 {

                AudioScrubBar(player: player, showsTimes: true)
                    .frame(maxWidth: 320)
            } else if let seconds = model.audio(item.refId)?.durationSeconds {
                Text(timecode(seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: Self.cardBodyShape)
        .overlay(
            Self.cardBodyShape.strokeBorder(
                isLive
                    ? Color.green.opacity(0.6)
                    : Color(nsColor: .separatorColor).opacity(0.5),
                lineWidth: 1
            )
        )
        .modifier(BottomCutRounding(boundary: viewportHeight))
        .padding(.bottom, 12)
    }

    private func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private func presentationBodyFresh(_ item: ServiceItem) -> some View {

        if let presentation = model.presentation(item.refId) {
            presentationCardBody(
                item, presentation,

                model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            )
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    @ViewBuilder
    private func presentationHeaderFresh(_ item: ServiceItem, proxy: ScrollViewProxy) -> some View {

        if let presentation = model.presentation(item.refId) {
            let slides = model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            cardHeader(item, glyph: .presentations) {

                CardSlidePosition(controls: controls, itemID: item.id, slideCount: slides.count)
            } leading: {

                if presentation.sections?.isEmpty == false {
                    if runOnly {
                        if let name = activeArrangementName(item, presentation) {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ArrangementPicker(
                            model: model, presentation: presentation,
                            selection: Binding(
                                get: { item.arrangementId },
                                set: { arrangementID in
                                    model.setServiceItemArrangement(
                                        serviceID, itemID: item.id, arrangementID: arrangementID
                                    )
                                }
                            )
                        )
                    }
                }
                SongKeyChip(model: model, controls: controls, presentation: presentation)
                SlideShowChip(model: model, controls: controls, presentation: presentation)
            } accessory: {

                if presentation.sections?.isEmpty == false {
                    ArrangementStrip(
                        model: model, presentation: presentation,
                        selection: Binding(
                            get: { item.arrangementId },
                            set: { arrangementID in
                                model.setServiceItemArrangement(
                                    serviceID, itemID: item.id, arrangementID: arrangementID
                                )
                            }
                        ),
                        showsPicker: false,
                        onJump: { pill in
                            jumpToBlock(item, presentation, slides, pill: pill, proxy: proxy)
                        }
                    )
                }
            }

            .contextMenu {
                if !runOnly { arrangementMenu(item, presentation) }
            }
        } else {

            cardHeader(item, glyph: .presentations) { EmptyView() }
        }
    }

    private func cardHeader(
        _ item: ServiceItem, glyph: GlyphKind,
        @ViewBuilder detail: () -> some View,
        @ViewBuilder leading: () -> some View = { EmptyView() },
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Glyph(kind: glyph, size: 12)
                    .foregroundStyle(.secondary)
                Text(displayName(item))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                leading()
                Spacer(minLength: 8)
                detail()
            }

            accessory()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cardSurface, in: Self.cardHeaderShape)
        .overlay(
            Self.cardHeaderShape.strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
            )
        )
        .background(Color.basePlane)
        .id(item.id)
    }

    private func activeArrangementName(
        _ item: ServiceItem, _ presentation: Presentation
    ) -> String? {
        guard let id = item.arrangementId, !id.isEmpty else { return nil }
        return presentation.arrangements?.first { $0.id == id }?.name
    }

    private func jumpToBlock(
        _ item: ServiceItem, _ presentation: Presentation, _ slides: [Slide],
        pill: Int, proxy: ScrollViewProxy
    ) {
        let starts = SlideSceneBuilder.arrangementBlockStarts(
            for: presentation, arrangementId: item.arrangementId
        )
        guard starts.indices.contains(pill), starts[pill] < slides.count else { return }
        let headerFraction = viewportHeight > 0
            ? min(((headerHeights[item.id] ?? 44) + 12) / viewportHeight, 0.4) : 0
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(
                SlideGridBody.tileAnchor(contextID: item.id, index: starts[pill]),
                anchor: UnitPoint(x: 0, y: headerFraction)
            )
        }
    }

    @ViewBuilder
    private func arrangementMenu(_ item: ServiceItem, _ presentation: Presentation) -> some View {
        if let arrangements = presentation.arrangements, !arrangements.isEmpty {
            Menu("Arrangement") {
                Toggle("Default", isOn: Binding(
                    get: { item.arrangementId?.isEmpty ?? true },
                    set: { _ in
                        model.setServiceItemArrangement(
                            serviceID, itemID: item.id, arrangementID: nil
                        )
                    }
                ))
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(arrangement.name, isOn: Binding(
                        get: { item.arrangementId == arrangement.id },
                        set: { _ in
                            model.setServiceItemArrangement(
                                serviceID, itemID: item.id, arrangementID: arrangement.id
                            )
                        }
                    ))
                }
            }
        }
    }

    private func pointNewSlide(at itemID: String?) {
        if let itemID {
            NewSlideRouter.shared.route = NewSlideRoute(contextID: itemID)
        }
    }

    private func presentationCardBody(
        _ item: ServiceItem, _ presentation: Presentation, _ slides: [Slide]
    ) -> some View {
        let theme = model.theme(presentation.themeId)

        return VStack(alignment: .leading, spacing: 10) {
            SlideGridBody(
                    model: model, render: render, controls: controls,
                    presentation: presentation, theme: theme,
                    slides: slides,
                    arrangementId: item.arrangementId,
                    contextID: item.id,
                    roundedCorners: roundedCorners,
                    hideScopedBackgrounds: hideScopedBackgrounds,
                    legibleText: legibleText,
                    slidesAcross: slidesAcross,
                    deleteRequests: deleteRequests,
                    clipboardRequests: clipboardRequests,
                    pastesAtEnd: focusItemID == item.id,
                    newSlideContexts: ((try? model.service(serviceID))?.items ?? [])
                        .filter { $0.itemKind == .presentation }.map(\.id),
                    buildsRowsNearView: true,
                    marqueeMargin: 12
                )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: Self.cardBodyShape)
        .overlay(
            Self.cardBodyShape.strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
            )
        )
        .modifier(BottomCutRounding(boundary: viewportHeight))
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func mediaQuickMenu(_ item: ServiceItem) -> some View {

        Group {
            if !runOnly {
                MediaCueMenuItems(
                    model: model, actionRouter: controls?.actionRouter,
                    mediaID: item.refId, state: mediaMenuState,
                    fallbackName: item.name
                )
            }
        }
    }

    private func mediaCardBody(_ item: ServiceItem) -> some View {
        let media = model.media(item.refId)
        let isLive = controls?.isMediaLive(item.refId) ?? false
        let tileShape = RoundedRectangle.standard(
            roundedCorners ? CornerStandard.element : 0
        )

        let row = SlidesAcross.rows(count: 1, across: slidesAcross)[0]
        return HStack(alignment: .top, spacing: SlideGridMetrics.spacing) {
            PosterImage(model: model, mediaId: item.refId)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(tileShape)
                .overlay {
                    if isLive {
                        tileShape.strokeBorder(.green, lineWidth: 3)
                    } else {
                        tileShape.strokeBorder(.separator, lineWidth: 1)
                    }
                }

                .overlay {
                    if !isLive {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {

                    if let media { controls?.fire(mediaItem: media, context: .serviceItem(id: item.id)) }
                }

                .contextMenu { mediaQuickMenu(item) }

                .id("mediaTileMenu|\(item.id)|\(media == nil)")
                .frame(maxWidth: .infinity)
            ForEach(0 ..< row.fillers, id: \.self) { _ in
                Color.clear.frame(height: 0).frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: Self.cardBodyShape)
        .overlay(
            Self.cardBodyShape.strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
            )
        )
        .modifier(BottomCutRounding(boundary: viewportHeight))
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func mediaContext(_ media: MediaItem) -> some View {
        HStack(spacing: 4) {
            if media.inPoint != nil || media.outPoint != nil {
                Image(systemName: "scissors")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Trimmed")
            }
            if media.loops {
                Image(systemName: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Loops")
            }
            if let label = durationLabel(media) {
                Text(label)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func durationLabel(_ media: MediaItem) -> String? {
        guard media.mediaKind == .video, let total = media.durationSeconds else { return nil }
        let effective = max(0, (media.outPoint ?? total) - (media.inPoint ?? 0))
        let seconds = Int(effective.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func displayName(_ item: ServiceItem) -> String {
        model.entry(item.refId)?.name ?? item.name
    }

    private func headerTint(_ item: ServiceItem) -> Color? {
        item.colorHex.flatMap(ColorHex.color).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
    }

    private func presentRows(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.ordered(
            service.items.filter { $0.applies(toTime: nil) && (!$0.isHidden || $0.itemKind == .header) },
            by: nil)
    }

    private func firePositions(_ service: Service) -> [FirePosition] {
        var positions: [FirePosition] = []
        for item in model.runOfShow(service) where item.itemKind == .presentation {

            guard let presentation = model.presentation(item.refId) else { continue }
            let slides = model.arrangedSlides(presentation, arrangementId: item.arrangementId)
            for (index, slide) in slides.enumerated() {
                positions.append(FirePosition(
                    itemID: item.id, presentation: presentation,
                    arrangementId: item.arrangementId,
                    occurrence: index, slide: slide
                ))
            }
        }
        return positions
    }

    private func fireStep(_ delta: Int, _ positions: [FirePosition]) {
        guard let controls, !positions.isEmpty else { return }

        let settled = delta > 0 && NSEvent.modifierFlags.contains(.option)
        controls.advance(steps: delta, settled: settled) {
            let currentFlat = positions.firstIndex {
                $0.itemID == controls.liveContextID && $0.occurrence == controls.liveOccurrence
            }
            let next: Int
            if let currentFlat {
                next = currentFlat + delta
            } else {
                next = delta > 0 ? 0 : positions.count - 1
            }
            guard positions.indices.contains(next) else { return }
            let position = positions[next]
            controls.fire(
                slide: position.slide, in: position.presentation,
                arrangementId: position.arrangementId,
                contextID: position.itemID, occurrence: position.occurrence
            )
        }
    }
}

private struct PillDropDelegate: DropDelegate {
    let index: Int
    let width: () -> CGFloat
    let setDropIndex: (Int?) -> Void

    let perform: (Int, String) -> Bool

    private func target(for info: DropInfo) -> Int {
        info.location.x < width() / 2 ? index : index + 1
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setDropIndex(target(for: info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        setDropIndex(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertBefore = target(for: info)
        setDropIndex(nil)
        guard let provider = info.itemProviders(for: [.plainText, .text]).first
        else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            Task { @MainActor in
                _ = perform(insertBefore, String(payload))
            }
        }
        return true
    }
}

private struct BottomCutRounding: ViewModifier {

    let boundary: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geo in
                let overhang = boundary > 0
                    ? max(0, geo.frame(in: .named(ServiceContinuousView.scrollSpace)).maxY - boundary)
                    : 0
                UnevenRoundedRectangle(
                    cornerRadii: .init(
                        bottomLeading: CornerStandard.element,
                        bottomTrailing: CornerStandard.element
                    ),
                    style: .continuous
                )
                .frame(
                    height: max(CornerStandard.element * 2, geo.size.height - overhang),
                    alignment: .top
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

extension ServiceContinuousView {

    func unlinkedCard(_ item: ServiceItem) -> some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let duration = item.duration, duration > 0 {
                Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("Not Linked")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardSurface, in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )

        .padding(.bottom, 12)
        .background(Color.basePlane)

        .id(Self.anchor(unlinked: item.id))
    }

    private func stickySection<Body: View, Header: View>(
        _ item: ServiceItem,
        @ViewBuilder body: () -> Body,
        @ViewBuilder header: () -> Header
    ) -> some View {
        let headerHeight = headerHeights[item.id] ?? 44
        let headerView = header()
        let bodyView = body()
        return ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: headerHeight)
                bodyView
            }
            GeometryReader { geo in
                let frame = geo.frame(in: .named(Self.scrollSpace))
                let stick = max(0, min(-frame.minY, geo.size.height - headerHeight))
                headerView

                    .fixedSize(horizontal: false, vertical: true)
                    .background(headerHeightReader(item))
                    .frame(width: geo.size.width, alignment: .topLeading)
                    .offset(y: stick)
            }
            .zIndex(1)
        }
    }

    private func headerHeightReader(_ item: ServiceItem) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { if headerHeights[item.id] != geo.size.height { headerHeights[item.id] = geo.size.height } }
                .onChange(of: geo.size.height) { old, height in
                    if headerHeights[item.id] != height { headerHeights[item.id] = height }

                    if abs(height - old) > 300 {
                        DiagnosticsStore.shared.note(
                            "present.header", detail: "\"\(item.name)\" \(Int(old)) → \(Int(height)) pt")
                    }
                }
        }
    }

    static func anchor(unlinked itemID: String) -> String { "unlinked|" + itemID }

    static func anchor(for itemID: String, in service: Service) -> String {
        service.items.contains { $0.id == itemID && $0.itemKind == .info }
            ? anchor(unlinked: itemID) : itemID
    }

    private func scrollToFocus(
        _ itemID: String?, reason: String, proxy: ScrollViewProxy, service: Service
    ) {
        if let target = focusScroll.request(itemID) {
            DiagnosticsStore.shared.note("present.focus", detail: "scroll \(target) (\(reason))")
            InputTrailRecorder.shared.noteFocusScroll()
            proxy.scrollTo(Self.anchor(for: target, in: service), anchor: .top)
            PresentCardFrames.shared.holdCard(target)
            PresentCardFrames.shared.reportLanding(target: target, rows: presentRows(service))
        } else if let itemID {
            DiagnosticsStore.shared.note("present.focus", detail: "hold \(itemID) (\(reason), already there)")
        }
    }

    private func revealLive(_ service: Service) {
        if let itemID = controls?.liveContextID, let occurrence = controls?.liveOccurrence,
           presentRows(service).contains(where: { $0.id == itemID }) {
            PresentCardFrames.shared.reveal(itemID, slide: occurrence, headerHeight: headerHeights[itemID] ?? 44)
        }
    }
}

extension ServiceItem {

    var presentRowIdentity: String { id + "|" + itemKind.rawValue }
}

private struct CardRefresh<Content: View>: View {
    let model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        let _ = model.listVersion
        content()
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width
            maxX = max(maxX, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(
            width: width.isFinite ? width : maxX,
            height: subviews.isEmpty ? 0 : y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct ArrangementStrip: View {
    let model: AppModel
    let presentation: Presentation

    @Binding var selection: String?

    var showsPicker = true

    var onJump: ((Int) -> Void)?

    @Environment(\.runOnly) private var runOnly

    @State private var dropIndex: Int?

    @State private var pillWidths: [Int: CGFloat] = [:]

    private var sections: [PresentationSection] { presentation.sections ?? [] }
    private var arrangements: [Arrangement] { presentation.arrangements ?? [] }

    private var activeArrangement: Arrangement? {
        guard let id = selection, !id.isEmpty else { return nil }
        return arrangements.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if showsPicker {
                ArrangementPicker(model: model, presentation: presentation, selection: $selection)
            }

            WrapLayout(spacing: 4, lineSpacing: 4) {
                if let arrangement = activeArrangement {
                    arrangementPills(arrangement)
                    if !runOnly {
                        addBlockMenu(arrangement)
                    }
                } else {
                    baseOrderPills
                }
            }
            .padding(.vertical, 1)

            .padding(.leading, 5)
        }
    }

    private func setLive(_ arrangementID: String?) {
        selection = arrangementID
    }

    @ViewBuilder
    private var baseOrderPills: some View {
        let runs = baseRunSections
        ForEach(Array(runs.enumerated()), id: \.offset) { index, section in
            pill(section.name, section: section, prominent: false)
                .contentShape(Capsule())
                .onTapGesture { onJump?(index) }
        }
        if runs.isEmpty {
            Text("No sections")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var baseRunSections: [PresentationSection] {

        SlideSceneBuilder.arrangementBlockStarts(for: presentation).compactMap { start in
            sections.first { $0.id == presentation.slides[start].sectionId }
        }
    }

    @ViewBuilder
    private func arrangementPills(_ arrangement: Arrangement) -> some View {
        let count = arrangement.sectionIds.count
        ForEach(Array(arrangement.sectionIds.enumerated()), id: \.offset) { index, sectionId in
            pill(
                sectionName(sectionId),
                section: sections.first { $0.id == sectionId },
                prominent: true
            )

                .opacity(sectionIsEmpty(sectionId) ? 0.45 : 1)
                .help(
                    sectionIsEmpty(sectionId)
                        ? "\(sectionName(sectionId)) has no slides yet" : ""
                )
                .contentShape(Capsule())
                .onTapGesture { onJump?(index) }
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { pillWidths[index] = geo.size.width }
                            .onChange(of: geo.size.width) { _, width in
                                pillWidths[index] = width
                            }
                    }
                    .allowsHitTesting(false)
                )
                .overlay(alignment: .leading) {
                    if dropIndex == index { insertionBar.offset(x: -3) }
                }
                .overlay(alignment: .trailing) {

                    if index == count - 1, dropIndex == count {
                        insertionBar.offset(x: 3)
                    }
                }
                .draggablePayload(runOnly ? nil : "arrblock::\(presentation.id)::\(index)")

                .onDrop(of: [.plainText, .text], delegate: PillDropDelegate(
                    index: index,
                    width: { pillWidths[index] ?? 40 },
                    setDropIndex: { dropIndex = $0 },
                    perform: { insertBefore, payload in
                        guard !runOnly else { return false }
                        let applied = dropBlock(
                            payload, arrangement: arrangement, before: insertBefore
                        )

                        dropIndex = nil
                        return applied
                    }
                ))
                .contextMenu {
                    if !runOnly {
                        Button("Remove Section") {
                            model.updateArrangement(
                                presentation.id, arrangementID: arrangement.id
                            ) { $0.sectionIds.remove(at: index) }
                        }
                    }
                }
        }
    }

    private var insertionBar: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
    }

    private func sectionIsEmpty(_ sectionId: String) -> Bool {
        !presentation.slides.contains { $0.sectionId == sectionId }
    }

    private func addBlockMenu(_ arrangement: Arrangement) -> some View {
        Menu {
            ForEach(sections) { section in
                let slideCount = presentation.slides.count { $0.sectionId == section.id }
                Button(
                    "\(section.name)  —  \(slideCount == 1 ? "1 slide" : "\(slideCount) slides")"
                ) {
                    model.updateArrangement(
                        presentation.id, arrangementID: arrangement.id
                    ) { $0.sectionIds.append(section.id) }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a section")
    }

    private func dropBlock(
        _ payload: String, arrangement: Arrangement, before targetIndex: Int
    ) -> Bool {
        let parts = payload.components(separatedBy: "::")
        guard parts.count == 3, parts[0] == "arrblock", parts[1] == presentation.id,
              let from = Int(parts[2]), arrangement.sectionIds.indices.contains(from)
        else { return false }
        let to = targetIndex

        guard from != to, from + 1 != to else { return false }
        model.updateArrangement(presentation.id, arrangementID: arrangement.id) {
            guard $0.sectionIds.indices.contains(from) else { return }
            let block = $0.sectionIds.remove(at: from)
            let target = from < to ? to - 1 : to
            $0.sectionIds.insert(block, at: min(max(target, 0), $0.sectionIds.count))
        }
        return true
    }

    private func sectionName(_ id: String) -> String {
        sections.first { $0.id == id }?.name ?? "Deleted Section"
    }

    private func pill(_ name: String, section: PresentationSection?, prominent: Bool) -> some View {
        let hex = section?.resolvedColorHex(paletteColors: model.groupColors)
        let fill = hex.flatMap(GroupColor.color)
        return Text(name)
            .font(.caption.weight(.medium))
            .foregroundStyle(
                fill != nil
                    ? AnyShapeStyle(GroupColor.text(onHex: hex))
                    : AnyShapeStyle(prominent ? Color.primary : Color.secondary)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                fill.map { $0.opacity(prominent ? 1 : 0.55) }
                    ?? Color.primary.opacity(prominent ? 0.08 : 0.04),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1
                )
            )
    }
}

struct ArrangementPicker: View {
    let model: AppModel
    let presentation: Presentation
    @Binding var selection: String?

    @State private var renamingArrangement = false
    @State private var renameText = ""
    @Environment(\.runOnly) private var runOnly

    private var arrangements: [Arrangement] { presentation.arrangements ?? [] }

    private var activeArrangement: Arrangement? {
        guard let id = selection, !id.isEmpty else { return nil }
        return arrangements.first { $0.id == id }
    }

    private var chipTitle: String {
        let name = activeArrangement?.name ?? "Default"
        return name.count > 12 ? String(name.prefix(12)) + "…" : name
    }

    var body: some View {
        if runOnly {
            Text(chipTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            pickerMenu
        }
    }

    private var pickerMenu: some View {
        Menu {

            Toggle("Default", isOn: Binding(
                get: { selection?.isEmpty ?? true },
                set: { _ in selection = nil }
            ))
            if !arrangements.isEmpty {
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(arrangement.name, isOn: Binding(
                        get: { selection == arrangement.id },
                        set: { _ in selection = arrangement.id }
                    ))
                }
            }
            Divider()
            Button("New Arrangement") {

                model.addArrangement(presentation.id) { created in
                    selection = created.id
                }
            }
            if let arrangement = activeArrangement {
                Button("Rename\u{2026}") {
                    renameText = arrangement.name
                    renamingArrangement = true
                }
                Button("Delete \u{201C}\(arrangement.name)\u{201D}", role: .destructive) {
                    selection = nil
                    model.deleteArrangement(presentation.id, arrangementID: arrangement.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.number")
                    .font(.system(size: 9, weight: .semibold))
                Text(chipTitle)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(activeArrangement == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which arrangement plays here")
        .alert("Rename Arrangement", isPresented: $renamingArrangement) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let arrangement = activeArrangement, !trimmed.isEmpty {
                    model.updateArrangement(
                        presentation.id, arrangementID: arrangement.id
                    ) { $0.name = trimmed }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct CardSlidePosition: View {
    let controls: ServiceControls?
    let itemID: String
    let slideCount: Int

    var body: some View {
        Text(detail)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private var detail: String {
        if controls?.liveContextID == itemID, let occurrence = controls?.liveOccurrence {
            "Slide \(occurrence + 1) of \(slideCount)"
        } else {
            slideCount == 1 ? "1 slide" : "\(slideCount) slides"
        }
    }
}
