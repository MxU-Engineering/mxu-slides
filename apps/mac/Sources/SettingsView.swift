import PresenterCore
import SlideScene
import SwiftUI

struct AppSettingsView: View {

    var model: AppModel?
    let controls: ServiceControls?

    var layout: PresentLayoutController?

    var api: LocalAPIController?

    var outputPresets: OutputPresetsController? = nil

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue
    @AppStorage("present.continuous") private var continuousPresent = true
    @AppStorage("slideGrid.roundedCorners") private var roundedCorners = true
    @AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = true
    @AppStorage("slideGrid.transparencyGrid") private var transparencyGrid = true
    @AppStorage(SlidesAcross.key) private var slidesAcross = SlidesAcross.fallback
    @AppStorage(ServiceControls.nextSkipsBlanksKey) private var nextSkipsBlanks = true
    @AppStorage(SlideSceneBuilder.emptyRepeatsOnceKey) private var emptyRepeatsOnce = false
    @AppStorage(EditSidebarLogic.settingKey) private var hideSidebarOnEdit = false
    @AppStorage(VolunteerModeLogic.enabledKey) private var volunteerModeEnabled = false

    @State private var category: SettingsCategory = .general
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            nav
                .frame(width: 176)
            Divider()

            if query.isEmpty, category == .streamRecord, let model, let controls {
                StreamRecordPane(model: model, controls: controls)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.isEmpty, category == .bible {
                BibleAPISettingsPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.isEmpty {
                SettingsCategoryPane(
                    category: category,
                    rows: allRows.filter { $0.category == category },
                    model: model, controls: controls)
                    .id(category)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity, minHeight: 640, idealHeight: 640, maxHeight: .infinity)
        .background(SettingsWindowFrame())
        .background(Color.basePlane)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
        .onAppear {
            if let pending = SettingsRouter.shared.pending {
                category = pending
                SettingsRouter.shared.pending = nil
            }
        }
        .onChange(of: SettingsRouter.shared.pending) { _, pending in
            if let pending {
                category = pending
                SettingsRouter.shared.pending = nil
            }
        }
    }

    private func enterVolunteer(applying saved: PresentLayout?) {
        let settingsWindow = NSApp.keyWindow
        if let savedModules = saved?.volunteerModules {
            layout?.setRunOnlyModules(savedModules)
        }
        layout?.enterRunOnly(applying: saved.map { saved in
            { layout?.apply(saved, openWindow: openWindow, dismissWindow: dismissWindow) }
        })
        settingsWindow?.close()
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .padding(.bottom, 10)
            ForEach(SettingsCategory.allCases) { entry in
                navRow(entry)
            }
            Spacer()
        }
        .padding(12)
    }

    private func navRow(_ entry: SettingsCategory) -> some View {
        let selected = query.isEmpty && category == entry
        return Button {
            query = ""
            category = entry
        } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 16)
                Text(entry.title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                selected ? Color.primary.opacity(0.08) : .clear,
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var searchResults: some View {
        let rows = visibleRows
        if rows.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Form {
                ForEach(SettingsCategory.allCases) { entry in
                    let matches = rows.filter { $0.category == entry }
                    if !matches.isEmpty {
                        Section(entry.title) {
                            ForEach(matches) { spec in
                                if spec.stacked || spec.id == "streamRecord.pane" {
                                    LabeledContent {
                                        Button("Show") { query = ""; category = entry }
                                    } label: {
                                        Text(spec.title)
                                        if let caption = spec.caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                                    }
                                } else {
                                    SettingsFormRow(spec: spec)
                                }
                            }
                        }
                    }
                }
            }
            .settingsForm()
        }
    }

    private var visibleRows: [SettingsRowSpec] {
        let all = allRows
        guard !query.isEmpty else { return all.filter { $0.category == category } }
        let needle = query.lowercased()
        return all.filter { $0.searchText.contains(needle) }
    }

    private var allRows: [SettingsRowSpec] {
        var rows: [SettingsRowSpec] = [
            SettingsRowSpec(
                id: "bible.apiBible",
                title: "Online Bible translations",
                caption: "Connect API.Bible or ESV and choose translations for Bible.",
                keywords: "bible scripture NIV NLT ESV Crossway API credentials translations",
                control: AnyView(EmptyView()), stacked: true
            ),
            SettingsRowSpec(
                id: "appearance.scheme",
                title: "Appearance",
                caption: "Dark is the booth default.",
                keywords: "theme dark light system color scheme",
                control: AnyView(
                    Picker("", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                )
            ),
            SettingsRowSpec(
                id: "present.mediaTransition",
                title: "Media transition",
                caption: "How backgrounds and media come in.",
                keywords: "transition dissolve fade blur media default cut clear background foreground",
                control: AnyView(DefaultTransitionControl(
                    kindKey: "transition.media.kind", durationKey: "transition.media.duration",
                    fallbackKind: TransitionKind.dissolve.rawValue, fallbackDuration: 0.7
                ))
            ),
            SettingsRowSpec(
                id: "present.slideTransition",
                title: "Slide transition",
                caption: "How the words change. Cut is safest for lyrics.",
                keywords: "transition dissolve fade slide default cut lyrics",
                control: AnyView(DefaultTransitionControl(
                    kindKey: "transition.slide.kind", durationKey: "transition.slide.duration",
                    fallbackKind: "", fallbackDuration: 0.5
                ))
            ),

            SettingsRowSpec(
                id: "edit.hideSidebar",
                title: "Hide the sidebar when entering Edit",
                caption: "Present gets it back when you return.",
                keywords: "sidebar hide edit mode library service panel collapse",
                control: AnyView(Toggle("", isOn: $hideSidebarOnEdit).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.defaultAnimations",
                title: "Default animations",
                caption: "What Apply Default In and Out use.",
                keywords: "animation default in out fade timeline animate steps",
                control: AnyView(DefaultAnimationsControl(model: model))
            ),
            SettingsRowSpec(
                id: "present.continuous",
                title: "Continuous service view",
                caption: "The whole service scrolls as one list.",
                keywords: "scroll run order single item",
                control: AnyView(Toggle("", isOn: $continuousPresent).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.slidesAcross",
                title: "Slides across",
                caption: "How many slides per row.",
                keywords: "slide grid columns across per row thumbnails size zoom",
                control: AnyView(SlidesAcrossControl(count: $slidesAcross).frame(width: 190))
            ),
            SettingsRowSpec(
                id: "present.roundedCorners",
                title: "Rounded corners",
                caption: "Slide thumbnails in Present.",
                keywords: "slide grid thumbnails corners",
                control: AnyView(Toggle("", isOn: $roundedCorners).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.transparencyGrid",
                title: "Transparency grid",
                caption: "A checkerboard where the slide is see-through.",
                keywords: "transparency grid checkerboard alpha thumbnails photoshop",
                control: AnyView(Toggle("", isOn: $transparencyGrid).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.scopedBackgrounds",
                title: "Backgrounds only on declaring slide",
                caption: "Later thumbnails drop a shared background.",
                keywords: "slide grid backgrounds cue thumbnails",
                control: AnyView(Toggle("", isOn: $hideScopedBackgrounds).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.clearAllAudio",
                title: "Clear All clears",
                caption: "Unticked stays up through Clear All.",
                keywords: "clear all audio panic walk-in music inputs camera video input skip keep",
                control: AnyView(ClearAllChecklist()),
                stacked: true
            ),
            SettingsRowSpec(
                id: "present.emptyRepeatsOnce",
                title: "Show a repeated chord-only section once",
                caption: "An Interlude played twice shows once.",
                keywords: "repeat repeated duplicate interlude instrumental turnaround chords blank empty section skip once arrangement",
                control: AnyView(Toggle("", isOn: Binding(
                    get: { emptyRepeatsOnce },
                    set: {
                        emptyRepeatsOnce = $0

                        controls?.refreshNextSlide()
                    }
                )).settingsToggle())
            ),
            SettingsRowSpec(
                id: "present.nextSkipsBlanks",
                title: "Confidence NEXT skips blank slides",
                caption: "NEXT shows the next slide with words.",
                keywords: "confidence monitor next blank empty slide stage skip",
                control: AnyView(Toggle("", isOn: Binding(
                    get: { nextSkipsBlanks },
                    set: {
                        nextSkipsBlanks = $0

                        controls?.refreshNextSlide()
                    }
                )).settingsToggle())
            ),
        ]
        if let layout {
            rows.append(SettingsRowSpec(
                id: "present.layouts",
                title: "Present layouts",
                caption: "Save and switch panel arrangements.",
                keywords: "layout workspace arrangement save panels windows dock",
                control: AnyView(PresentLayoutMenuControl(layout: layout) { saved in
                    enterVolunteer(applying: saved)
                })
            ))

            rows.append(SettingsRowSpec(
                id: "present.runOnly",
                title: "Volunteer Mode",
                caption: "Adds Volunteer to the mode switcher.",
                keywords: "volunteer mode run only simple kiosk switcher",
                control: AnyView(Toggle("", isOn: $volunteerModeEnabled).settingsToggle())
            ))
            rows.append(SettingsRowSpec(
                id: "present.volunteerTabs",
                title: "Tabs volunteers keep",
                caption: "The Service Controls tabs Volunteer Mode shows.",
                keywords: "volunteer tabs service controls modules timers combos alerts",
                control: AnyView(VolunteerTabsControl(layout: layout))
            ))
        }
        rows.append(contentsOf: groupsRows)
        rows.append(contentsOf: audioRows)
        rows.append(
            SettingsRowSpec(
                id: "screens.configuration",
                title: "Screen Configuration",
                caption: "Screens, outputs and layer routing.",
                keywords: "outputs displays routing placeholder ndi screens",
                control: AnyView(OpenScreenConfigurationButton(count: controls?.render.outputs.placeholderScreens.count))
            )
        )
        if let outputPresets {
            rows.append(SettingsRowSpec(
                id: "screens.outputPresets",
                title: "Output presets",
                caption: "Which screens show what. Switch them from the header.",
                keywords: "output presets screens looks switch",
                control: AnyView(EditOutputPresetsButton(presets: outputPresets))
            ))
        }
        rows.append(contentsOf: streamRecordRows)
        rows.append(SettingsRowSpec(
            id: "avInputs.cameras",
            title: "Video inputs",
            caption: "Cameras, capture cards and NDI sources.",
            keywords: "camera capture device uvc continuity blackmagic live input video refresh",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "avInputs.audio",
            title: "Audio inputs",
            caption: "Interfaces and board feeds.",
            keywords: "audio input microphone interface usb board mix feed sound stream record source channels",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "avInputs.outputs",
            title: "Audio outputs",
            caption: "Named outputs for the Mixer.",
            keywords: "audio output speaker device dante interface patch stereo pair mix send",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "midi.devices",
            title: "MIDI devices",
            caption: "Devices MIDI sends to and listens to.",
            keywords: "midi device destination source input output port note control change iac lighting console enable disable direction",
            control: AnyView(EmptyView()),
            stacked: true
        ))
        rows.append(SettingsRowSpec(
            id: "midi.map",
            title: "Input map",
            caption: "What incoming notes trigger.",
            keywords: "midi input map note trigger command clear slide advance timer combo channel propresenter overlay prop playlist media audio music alert message select index",
            control: AnyView(MIDIMapManager())
        ))

        if let timecode = controls?.timecode {
            rows.append(SettingsRowSpec(
                id: "timecode.follow",
                title: "Follow timecode",
                caption: "Songs with a timecode start play from it here.",
                keywords: "timecode ltc smpte playback ableton follow lyrics automate timeline song start",
                control: AnyView(Toggle("", isOn: Binding(
                    get: { timecode.follows }, set: { timecode.setFollows($0) })).settingsToggle())
            ))
            rows.append(SettingsRowSpec(
                id: "timecode.audio",
                title: "Timecode plays audio",
                caption: "For when this Mac is the audio source.",
                keywords: "timecode ltc audio lane layer backing track sound effects spoken word generator chase play music",
                control: AnyView(Toggle("", isOn: Binding(
                    get: { timecode.playsAudio }, set: { timecode.setPlaysAudio($0) })).settingsToggle())
            ))
            rows.append(SettingsRowSpec(
                id: "timecode.input",
                title: "Input",
                caption: "LTC on an audio channel or MTC over MIDI. Never played out.",
                keywords: "timecode ltc mtc smpte midi input device channel blackhole loopback audio interface iac ableton quarter frame",
                control: AnyView(TimecodeInputControl(follower: timecode))
            ))
            rows.append(SettingsRowSpec(
                id: "timecode.signal",
                title: "Signal",
                caption: nil,
                keywords: "timecode ltc level meter frame rate fps locked lost drop frame",
                control: AnyView(TimecodeSignalReadout(follower: timecode))
            ))
            rows.append(SettingsRowSpec(
                id: "timecode.offset",
                title: "Offset",
                caption: "Moves incoming timecode later or earlier.",
                keywords: "timecode ltc offset latency delay frames early late",
                control: AnyView(TimecodeOffsetControl(follower: timecode))
            ))
        }

        rows.append(SettingsRowSpec(
            id: "network.ndi",
            title: "NDI network",
            caption: "The network NDI uses. Pin it to the wired one.",
            keywords: "ndi network interface adapter nic vlan ethernet wifi wired discovery pin bind",
            control: AnyView(NDINetworkScopeControl())
        ))
        rows.append(contentsOf: apiRows)
        return rows
            .sorted { SettingsLayout.order(ofRow: $0.id) < SettingsLayout.order(ofRow: $1.id) }
    }

    private var groupsRows: [SettingsRowSpec] {
        guard let model else { return [] }
        return [
            SettingsRowSpec(
                id: "groups.palette",
                title: "Groups",
                caption: "Song section names and their colors.",
                keywords: "group section verse chorus bridge color label pill arrangement palette propresenter hot key",

                control: AnyView(Text("\(model.groupPalette.groups.count)").foregroundStyle(.secondary))
            ),
        ]
    }

    private var streamRecordRows: [SettingsRowSpec] {
        [
            SettingsRowSpec(
                id: "streamRecord.pane",
                title: "Stream & Record",
                caption: "Where you stream to, and what streams and records.",
                keywords: "stream record preset destination rtmp rtmps srt hls youtube facebook key bitrate go live sunday record only visibility",
                control: AnyView(Button("Show") { query = ""; category = .streamRecord })
            ),
        ]
    }

    private var apiRows: [SettingsRowSpec] {
        guard let api else { return [] }
        return [
            SettingsRowSpec(
                id: "api.enabled",
                title: "Serve the API",
                caption: "The REST and WebSocket API on this Mac.",
                keywords: "api rest websocket http server remote companion stream deck automation bonjour",
                control: AnyView(LocalAPIEnableToggle(api: api))
            ),
            SettingsRowSpec(
                id: "api.port",
                title: "Port",
                caption: "Changing the port restarts the server.",
                keywords: "api port number network",
                control: AnyView(LocalAPIPortField(api: api))
            ),

            SettingsRowSpec(
                id: "api.address",
                title: "Connect at",
                caption: "Point any app or device that uses the API here.",
                keywords: "api address ip port connect companion stream deck remote host default key",
                control: AnyView(LocalAPIAddressRow(api: api))
            ),
            SettingsRowSpec(
                id: "api.tokens",
                title: "Access keys",
                caption: "Every client needs one.",
                keywords: "api tokens keys auth bearer secret scope watch operate manage revoke password required",
                control: AnyView(LocalAPITokensButton(api: api))
            ),
            SettingsRowSpec(
                id: "api.docs",
                title: "API reference",
                caption: "Every endpoint, with examples. Works offline.",
                keywords: "api reference docs documentation openapi explorer examples endpoints developer",
                control: AnyView(LocalAPIContractRow(api: api))
            ),
        ]
    }

    private var audioRows: [SettingsRowSpec] {
        guard let audio = controls?.audio else { return [] }
        return [
            SettingsRowSpec(
                id: "audio.fadeEnabled",
                title: "Fade in and out",
                caption: "Play, pause and Clear Music ease in and out.",
                keywords: "audio fade transport ease",
                control: AnyView(
                    Toggle("", isOn: Binding(
                        get: { audio.fadeEnabled },
                        set: { audio.fadeEnabled = $0 }
                    ))
                    .settingsToggle()
                )
            ),
            SettingsRowSpec(
                id: "audio.fadeSeconds",
                title: "Fade time",
                caption: nil,
                keywords: "audio fade seconds duration",
                control: AnyView(
                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { audio.fadeSeconds },
                                set: { audio.fadeSeconds = $0 }
                            ),
                            in: 0 ... 5, step: 0.25
                        )
                        .controlSize(.small)
                        .frame(width: 140)
                        .disabled(!audio.fadeEnabled)
                        Text("\(audio.fadeSeconds.formatted())s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                )
            ),
        ]
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable {

    case general

    case present

    case edit

    case screens

    case avInputs
    case streamRecord

    case midi

    case keyboard
    case bible
    case api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .present: "Present"
        case .edit: "Edit"
        case .avInputs: "Audio & Video"
        case .midi: "Connections"
        case .keyboard: "Shortcuts"
        case .screens: "Screens"
        case .streamRecord: "Stream & Record"

        case .bible: "Bible"
        case .api: "Network & API"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .present: "play.rectangle"
        case .edit: "pencil"
        case .avInputs: "camera"
        case .midi: "point.3.connected.trianglepath.dotted"
        case .keyboard: "keyboard"
        case .screens: "display"
        case .streamRecord: "record.circle"
        case .bible: "book.closed"
        case .api: "network"
        }
    }
}

@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var pending: SettingsCategory?

    var pendingStreamTab: StreamRecordPane.Tab?
    var pendingStreamPresetID: String?
    private init() {}

    func openStreamRecord(tab: StreamRecordPane.Tab, presetID: String? = nil) {
        pendingStreamTab = tab
        pendingStreamPresetID = presetID
        pending = .streamRecord
    }

    var pendingTrackChannel: String?

    func openTrackChannel(_ id: String) {
        pendingTrackChannel = id
        pending = .avInputs
    }
}

struct SettingsRowSpec: Identifiable {
    let id: String
    let title: String
    let caption: String?
    let keywords: String
    let control: AnyView

    var stacked: Bool = false

    var help: String? { Self.help[id] }

    static let help: [String: String] = [
        "api.address": "Enter this address and port in whatever connects to the API, then sign in with an access key from the row below.",
        "api.docs": "A browsable page of every endpoint with descriptions and copyable examples, served by this Mac.",
        "api.enabled": "Serves the documented REST + WebSocket API on this Mac and announces it on the local network.",
        "api.tokens": "Required: nothing connects without one. Create a key here and paste it into the client. Each key grants Watch, Operate, or Manage access.",
        "appearance.scheme": "One scheme across Present and Edit.",
        "audio.fadeEnabled": "All music.",
        "avInputs.audio": "Each picks its device and channels, routes to a mix, and can stream, record, or go on air from the Mixer.",
        "avInputs.cameras": "Added inputs run warm from launch and appear in Live Input pickers, so slides never wait on a camera spinning up.",
        "avInputs.outputs": "The output patch bay: named outputs assigned to a device and stereo pair. Mixes send to outputs in the Mixer; hardware lives only here.",
        "timecode.follow": "Each song's timeline has a timecode start (the clock on its timeline row) and \"This song plays from timecode\". Incoming timecode plays the song whose window holds it; outside every song the screen holds. With two Macs in a room, follow on one.",
        "timecode.audio": "Songs' Music layers (backing tracks, sound effects, spoken word) and their tracks (stems) play from incoming timecode and stay with it: they start where timecode says, re-cue when it jumps, and stop when it stops. Leave off when Playback or Ableton is playing the music and sending the timecode.",
        "timecode.input": "Route Playback's SMPTE bus (or Ableton's LTC clip) to a spare input, or a channel of BlackHole or Loopback on this Mac. The frame rate is detected.",
        "midi.devices": "Each one can send, listen, or both, and switches off without being forgotten. With none added, MIDI Out reaches every destination on this Mac.",
        "midi.map": "Clears, slides, videos, overlays, media, music, timers, alerts, Action Combos. ProPresenter's stock numbers out of the box; every assignment is editable.",
        "network.ndi": "NDI discovers and carries video on this network, inputs and screen outputs alike. Pin it to the wired production network when this Mac also joins Wi-Fi on another VLAN. Applies immediately; live feeds re-tune.",
        "present.clearAllAudio": "Walk-in music or a live camera can stay up through Clear All; its own Clear button still takes it down. Also on a right-click of the header's Clear.",
        "present.continuous": "The whole run order scrolls as one surface; arrows advance across items.",
        "present.defaultAnimations": "What Apply Default In / Apply Default Out write on the timeline's presence-bar ends. A preset's Set as Default In/Out changes it too.",
        "present.emptyRepeatsOnce": "When a song plays the same section twice in a row and it has only chords or nothing on it, Present shows it once. Off, every repeat the order calls for is a slide to click. Sections with words, media or a different set of chords always play.",
        "present.layouts": "Save and switch whole arrangements: panels, sizes and windows.",
        "present.mediaTransition": "Backgrounds and foreground media enter (and leave on Clear) with this unless the item sets its own. The header's transition chips change the same setting.",
        "present.nextSkipsBlanks": "Blank slides parked as clears are ignored: NEXT shows the first upcoming slide that has text.",
        "present.runOnly": "Volunteers run slides, clears and the tabs below, with editing hidden. No passcode: Present or Edit in the mode switcher leaves it.",
        "present.scopedBackgrounds": "Thumbnails after the declaring slide drop the shared background.",
        "present.slideTransition": "How the slide layer changes between slides. The header's transition chips change the same setting.",
        "present.slidesAcross": "How many slide thumbnails share a row in Present: a fixed count, never a fit to the window or the sidebars.",
        "present.transparencyGrid": "Checkerboard shows wherever nothing opaque covers the slide, where lower layers would show through on glass.",
        "streamRecord.pane": "Destinations are the places you can stream to; presets say which ones, what streams, and what records.",
    ]

    var category: SettingsCategory {
        SettingsLayout.page(ofRow: id).flatMap(SettingsCategory.init(rawValue:)) ?? .general
    }

    var searchText: String {
        "\(title) \(caption ?? "") \(help ?? "") \(keywords) \(category.title)".lowercased()
    }
}

private struct SettingsRowView: View {
    let spec: SettingsRowSpec

    var body: some View {

        Group {
            if spec.stacked {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    spec.control
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    header
                    Spacer(minLength: 16)
                    spec.control
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.title)
                .font(.system(size: 11, weight: .medium))
            if let caption = spec.caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct OpenScreenConfigurationButton: View {

    let count: Int?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            if let count {
                Text("\(count) screen\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Button("Open\u{2026}") {
                openWindow(id: "outputs")
            }
        }
    }
}

private struct EditOutputPresetsButton: View {
    let presets: OutputPresetsController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            Text("\(presets.presets.count)").foregroundStyle(.secondary)
            Button("Edit\u{2026}") {
                ScreenConfigRouter.shared.pendingPresetID = presets.activePresetID ?? presets.presets.first?.id ?? ""
                openWindow(id: "outputs")
            }
        }
    }
}

private struct PresentLayoutMenuControl: View {
    let layout: PresentLayoutController

    let onPickRunOnly: (PresentLayout) -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingSave = false
    @State private var showingRename = false
    @State private var nameDraft = ""

    var body: some View {
        let active = layout.activeLayoutID.flatMap { layout.layout(id: $0) }
        Menu {
            ForEach(layout.layouts) { saved in
                Toggle(saved.name, isOn: Binding(
                    get: { layout.activeLayoutID == saved.id },
                    set: { _ in apply(saved) }
                ))
            }
            if !layout.layouts.isEmpty { Divider() }
            Button("Save Current as Layout…") {
                nameDraft = ""
                showingSave = true
            }
            if let active {
                Button("Update “\(active.name)”") {
                    layout.updateLayout(id: active.id)
                }
                Button("Rename…") {
                    nameDraft = active.name
                    showingRename = true
                }

                Picker("Volunteer Layout", selection: Binding(
                    get: { active.runOnly },
                    set: { layout.setLayoutRunOnly(id: active.id, $0) }
                )) {
                    Text("Yes").tag(true)
                    Text("No").tag(false)
                }
                Divider()
                Button("Delete “\(active.name)”", role: .destructive) {
                    layout.deleteLayout(id: active.id)
                }
            }
        } label: {

            Text(active?.name ?? "None")
                .lineLimit(1)
        }
        .fixedSize()
        .alert("Save Layout", isPresented: $showingSave) {
            TextField("Name", text: $nameDraft)
            Button("Save") { layout.saveLayout(named: nameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Captures the current arrangement — panels, sizes, and windows.")
        }
        .alert("Rename Layout", isPresented: $showingRename) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let id = layout.activeLayoutID {
                    layout.renameLayout(id: id, to: nameDraft)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func apply(_ saved: PresentLayout) {
        if saved.runOnly {
            onPickRunOnly(saved)
        } else {
            layout.apply(saved, openWindow: openWindow, dismissWindow: dismissWindow)
        }
    }
}

private struct SettingsWindowFrame: NSViewRepresentable {
    static let autosaveName = "settings.window"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private func configure(_ window: NSWindow?) {
        if let window, window.frameAutosaveName != Self.autosaveName {
            window.styleMask.insert(.resizable)
            window.setFrameUsingName(Self.autosaveName)
            window.setFrameAutosaveName(Self.autosaveName)
        }
    }
}

private struct VolunteerTabsControl: View {
    let layout: PresentLayoutController

    var body: some View {
        let chosen = Set(layout.suggestedRunOnlyModules)
        Menu {
            ForEach(ServiceControlsModule.defaultOrder, id: \.self) { module in
                Toggle(module.title, isOn: Binding(
                    get: { chosen.contains(module) },
                    set: { on in
                        let next = on ? chosen.union([module]) : chosen.subtracting([module])

                        if !next.isEmpty {
                            layout.setRunOnlyModules(ServiceControlsModule.defaultOrder.filter(next.contains))
                        }
                    }
                ))
            }
        } label: {
            Text(chosen.count == ServiceControlsModule.defaultOrder.count ? "All tabs" : "\(chosen.count) tab\(chosen.count == 1 ? "" : "s")")
        }
        .fixedSize()
    }
}

extension Toggle {

    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .labelsHidden()
    }
}

struct DefaultAnimationsControl: View {
    let model: AppModel?

    private static let choices: [StepAnimation] = [.fade, .move, .scale, .wipe, .blur]

    var body: some View {
        if let model {
            VStack(alignment: .trailing, spacing: 6) {
                row("In", step: model.animationDefaultIn, kind: .in, model: model)
                row("Out", step: model.animationDefaultOut, kind: .out, model: model)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, step: AnimationStep, kind: AnimationKind, model: AppModel) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Picker("", selection: Binding(
                get: { step.animation },
                set: { choice in write(kind, model) { $0.animation = choice } }
            )) {
                ForEach(Self.choices, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                if !Self.choices.contains(step.animation) {
                    Text(step.animation.rawValue.capitalized).tag(step.animation)
                }
            }
            .labelsHidden()
            .fixedSize()
            Picker("", selection: Binding(
                get: { SlideEditorModel.AnimationSpeed.of(step.durationSeconds) },
                set: { speed in
                    if let seconds = speed.seconds {
                        write(kind, model) { $0.durationSeconds = seconds }
                    }
                }
            )) {
                ForEach([.quick, .normal, .slow] as [SlideEditorModel.AnimationSpeed], id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
                if SlideEditorModel.AnimationSpeed.of(step.durationSeconds) == .custom {
                    Text(String(format: "%.1fs", step.durationSeconds))
                        .tag(SlideEditorModel.AnimationSpeed.custom)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func write(_ kind: AnimationKind, _ model: AppModel, _ mutate: (inout AnimationStep) -> Void) {
        var step = kind == .out ? model.animationDefaultOut : model.animationDefaultIn
        mutate(&step)
        if kind == .out {
            model.setAnimationDefault(out: step)
        } else {
            model.setAnimationDefault(in: step)
        }
    }
}

struct DefaultTransitionControl: View {
    let kindKey: String
    let durationKey: String
    var fallbackKind = ""
    var fallbackDuration = 0.5

    @State private var kindRaw = ""
    @State private var duration = 0.5

    var body: some View {
        controls
            .onAppear {
                kindRaw = UserDefaults.standard.string(forKey: kindKey) ?? fallbackKind

                duration = UserDefaults.standard.object(forKey: durationKey) as? Double ?? fallbackDuration
            }

    }

    private var storedKind: Binding<String> {
        Binding(
            get: { kindRaw },
            set: { v in
                kindRaw = v
                UserDefaults.standard.set(v, forKey: kindKey)
            }
        )
    }

    private var storedDuration: Binding<Double> {
        Binding(
            get: { duration },
            set: { v in
                duration = v
                UserDefaults.standard.set(v, forKey: durationKey)
            }
        )
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: storedKind) {
                Text("Cut").tag("")
                Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                Text("Film Burn").tag(TransitionKind.filmBurn.rawValue)
            }
            .labelsHidden()
            .fixedSize()
            if !kindRaw.isEmpty {
                Stepper(
                    TransitionEdit.label(seconds: duration),
                    value: storedDuration, in: TransitionEdit.typedRange, step: TransitionEdit.durationStep
                )
                .font(.caption.monospacedDigit())
                .controlSize(.small)
            }
        }
    }
}
