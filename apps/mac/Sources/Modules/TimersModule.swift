import PresenterCore
import SlideScene
import SwiftUI

struct TimersModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    @State private var showingTargetPicker = false
    @State private var showingCustomCountdown = false
    @State private var pickerHour12 = 11
    @State private var pickerMinute = 0
    @State private var pickerIsPM = false
    @State private var editHours = 0
    @State private var editMinutes = 10
    @State private var editSeconds = 0
    @State private var expandedTimers: Set<String> = []

    @State private var editingFolders: Set<String> = []

    @State private var timerDropBefore: String??

    @State private var folderDropTarget: String?

    @State private var searching = false
    @State private var searchQuery = ""

    var body: some View {
        let station = controls.timers
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                if !station.timers.isEmpty {
                    ModuleSearchButton(isSearching: $searching, query: $searchQuery)
                }
                if !runOnly {
                    addTimerMenu(station)
                }
            }
            if searching {
                ModuleSearchField(query: $searchQuery, isSearching: $searching)
            }
            if station.timers.isEmpty {
                Text("Timers show on the confidence layout.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            if searching, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let ids = station.board.filteredTimerIDs(matching: searchQuery) {
                    station.snapshot(id: $0)?.name
                }
                VStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        if let timer = station.snapshot(id: id) {
                            timerRow(timer, station: station)
                        }
                    }
                    if ids.isEmpty {
                        Text("No timers match.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if !station.board.nodes.isEmpty {
                VStack(spacing: 4) {
                    ForEach(station.board.nodes, id: \.id) { node in
                        switch node {
                        case .timer(let id):
                            if let timer = station.snapshot(id: id) {
                                timerRow(timer, station: station)
                            }
                        case .folder(let folder):
                            folderBlock(folder, station: station)
                        }
                    }

                    Color.clear
                        .frame(height: 6)
                        .dropDestination(for: String.self) { payloads, _ in
                            dropNode(payloads, before: nil, station: station)
                        } isTargeted: { targeted in
                            timerDropBefore = targeted
                                ? .some(nil)
                                : (timerDropBefore == .some(nil) ? nil : timerDropBefore)
                        }
                        .overlay(alignment: .top) {
                            if timerDropBefore == .some(nil) { timerInsertionLine }
                        }
                }
            }
        }
        .popover(isPresented: $showingTargetPicker, arrowEdge: .bottom) {
            targetPickerContent(station)
        }
        .popover(isPresented: $showingCustomCountdown, arrowEdge: .bottom) {
            customCountdownContent(station)
        }
    }

    @ViewBuilder
    private func folderBlock(_ folder: TimerBoard.Folder, station: TimersController) -> some View {
        let members = station.snapshots(ids: folder.timerIDs)
        let editing = editingFolders.contains(folder.id)
        VStack(spacing: 0) {
            Button {
                if !runOnly {
                    station.setFolderCollapsed(id: folder.id, !folder.collapsed)
                }
            } label: {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    folderRowStrip(folder, members: members, at: context.date)
                }
            }
            .buttonStyle(.plain)
            if editing, !runOnly {
                FolderInlineEditor(folder: folder, station: station) {
                    editingFolders.remove(folder.id)
                }
            }
        }
        .background(
            members.contains(where: \.isLive)
                ? Color.green.opacity(0.06) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    folderDropTarget == folder.id
                        ? Color(nsColor: .controlAccentColor).opacity(0.8)
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
        .draggablePayload((runOnly || folder.id == ServiceTrackingTimers.folderID) ? nil : "mxufolder::" + folder.id)

        .dropDestination(for: String.self) { payloads, _ in
            folderDropTarget = nil
            guard !runOnly, let payload = payloads.first else { return false }
            if payload.hasPrefix("mxutimer::") {
                guard folder.id != ServiceTrackingTimers.folderID else { return false }
                station.moveTimer(
                    id: String(payload.dropFirst("mxutimer::".count)),
                    intoFolder: folder.id
                )
                return true
            }
            if payload.hasPrefix("mxufolder::") {
                let id = String(payload.dropFirst("mxufolder::".count))
                guard id != folder.id else { return false }
                station.moveFolder(id: id, beforeNode: folder.id)
                return true
            }
            return false
        } isTargeted: { targeted in
            folderDropTarget = targeted
                ? folder.id
                : (folderDropTarget == folder.id ? nil : folderDropTarget)
        }
        .contextMenu {
            if !runOnly, folder.id != ServiceTrackingTimers.folderID {
                Button(editing ? "Done Editing" : "Edit…") {
                    if editing {
                        editingFolders.remove(folder.id)
                    } else {
                        editingFolders.insert(folder.id)
                    }
                }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    station.removeFolder(id: folder.id)
                }
            }
        }
        if !folder.collapsed {
            VStack(spacing: 4) {
                ForEach(members) { timer in
                    timerRow(timer, station: station)
                }
                if members.isEmpty {
                    Text("Drag timers onto the folder name.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 14)
        }
    }

    private func folderRowStrip(
        _ folder: TimerBoard.Folder, members: [TimerSnapshot], at date: Date
    ) -> some View {
        let featured = TimerBoard.featured(in: members, at: date)
        let tint: Color = TimerBoard.rollupWarning(of: members, at: date)
            .map(Self.warningColor)
            ?? (members.contains(where: \.isLive) ? .green : .secondary)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 12)
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(folder.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(members.contains(where: \.isLive) ? .primary : .secondary)
                .lineLimit(1)
            Text("\(folder.timerIDs.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            if let featured {
                Text(featured.displayString(at: date))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    private var timerInsertionLine: some View {
        ControlBoardInsertionLine()
    }

    private func dropNode(
        _ payloads: [String], before targetID: String?, station: TimersController
    ) -> Bool {
        timerDropBefore = nil
        guard !runOnly, let payload = payloads.first else { return false }
        if payload.hasPrefix("mxutimer::") {
            let id = String(payload.dropFirst("mxutimer::".count))
            guard id != targetID, !ServiceTrackingTimers.isPermanent(id) else { return false }
            station.moveTimer(id: id, beforeNode: targetID)
            return true
        }
        if payload.hasPrefix("mxufolder::") {
            let id = String(payload.dropFirst("mxufolder::".count))
            guard id != targetID else { return false }
            station.moveFolder(id: id, beforeNode: targetID)
            return true
        }
        return false
    }

    private func addTimerMenu(_ station: TimersController) -> some View {
        Menu {
            Section("Countdown") {
                ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        station.addCountdown(minutes: minutes)
                    }
                }
                Button("Custom…") {
                    editHours = 0
                    editMinutes = 10
                    editSeconds = 0
                    showingCustomCountdown = true
                }
            }
            Button("Countdown to Time…") {

                let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
                let minute = (parts.minute ?? 0) < 30 ? 30 : 0
                let hour24 = minute == 0 ? ((parts.hour ?? 0) + 1) % 24 : (parts.hour ?? 0)
                pickerHour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
                pickerMinute = minute
                pickerIsPM = hour24 >= 12
                showingTargetPicker = true
            }
            Button("Count Up Timer") { station.addCountUp() }
            Divider()
            Button("New Folder") { station.addFolder() }
        } label: {

            Image(systemName: "plus").moduleHeaderGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a timer — it shows on the confidence layout")
    }

    private func customCountdownContent(_ station: TimersController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Countdown length")
                .font(.caption.weight(.medium))
            HStack(spacing: 4) {
                timeField("HH", value: $editHours, max: 99)
                Text(":").foregroundStyle(.secondary)
                timeField("MM", value: $editMinutes, max: 59)
                Text(":").foregroundStyle(.secondary)
                timeField("SS", value: $editSeconds, max: 59)
            }
            Button("Add Timer") {
                station.addCountdown(
                    seconds: TimeInterval(editHours * 3600 + editMinutes * 60 + editSeconds)
                )
                showingCustomCountdown = false
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func locked(_ timerID: String) -> Bool {
        runOnly || ServiceTrackingTimers.isPermanent(timerID)
    }

    private func timerRow(_ timer: TimerSnapshot, station: TimersController) -> some View {
        let expanded = expandedTimers.contains(timer.id)
        return VStack(spacing: 0) {
            Button {
                if !runOnly { toggleExpanded(timer.id) }
            } label: {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    timerRowStrip(timer, at: context.date, expanded: expanded, station: station)
                }
            }
            .buttonStyle(.plain)
            if expanded, !runOnly {

                if let (subject, face) = ServiceTrackingTimers.subjectAndFace(of: timer.id) {
                    Text(ServiceTrackingTimers.description(subject, face) + " Follows Service Tracking; not editable.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                } else {
                    TimerInlineEditor(timer: timer, station: station) {
                        expandedTimers.remove(timer.id)
                    }
                }
            }
        }
        .background(
            timer.isLive ? Color.green.opacity(0.06) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .draggablePayload(locked(timer.id) ? nil : "mxutimer::" + timer.id)
        .dropDestination(for: String.self) { payloads, _ in
            dropNode(payloads, before: timer.id, station: station)
        } isTargeted: { targeted in
            timerDropBefore = targeted
                ? .some(timer.id)
                : (timerDropBefore == .some(timer.id) ? nil : timerDropBefore)
        }
        .overlay(alignment: .top) {
            if timerDropBefore == .some(timer.id) { timerInsertionLine }
        }
        .contextMenu {
            if !locked(timer.id) {
                Button(expanded ? "Collapse" : "Edit…") { toggleExpanded(timer.id) }
                if timer.mode == .countdown {
                    Picker("Duration", selection: Binding(
                        get: { Int(timer.durationSeconds / 60) },
                        set: { station.setDuration(id: timer.id, seconds: TimeInterval($0 * 60)) }
                    )) {
                        ForEach(durationChoices(current: Int(timer.durationSeconds / 60)), id: \.self) { minutes in
                            Text("\(minutes) minutes").tag(minutes)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { station.remove(id: timer.id) }
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            if expandedTimers.contains(id) {
                expandedTimers.remove(id)
            } else {
                expandedTimers.insert(id)
            }
        }
    }

    private func timerRowStrip(
        _ timer: TimerSnapshot, at date: Date, expanded: Bool, station: TimersController
    ) -> some View {

        let idle = ServiceTrackingTimers.isPermanent(timer.id) && timer.isIdle
        let tint: Color = idle ? .secondary : timer.activeWarning(at: date).map(Self.warningColor)
            ?? (timer.isLive ? .green : .secondary)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(idle ? "--:--" : timer.displayString(at: date))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                Text(timer.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if timer.mode != .countdownToTime, !ServiceTrackingTimers.isPermanent(timer.id) {
                    Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(timer.isRunning ? Color.green : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { station.toggle(id: timer.id) }
                        .help(timer.isRunning ? "Pause" : "Start")
                }
                if !ServiceTrackingTimers.isPermanent(timer.id) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { station.reset(id: timer.id) }
                        .help(timer.mode == .countdownToTime ? "Re-arm to the next occurrence" : "Reset")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            if let progress = timer.progress(at: date) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(tint.opacity(timer.isLive ? 0.9 : 0.45))
                            .frame(width: max(3, geo.size.width * progress))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            } else {
                Spacer().frame(height: 4)
            }
        }
    }

    private func durationChoices(current: Int) -> [Int] {
        let standard = [5, 10, 15, 20, 30, 45, 60]
        return standard.contains(current) || current == 0
            ? standard
            : (standard + [current]).sorted()
    }

    private func timeField(_ label: String, value: Binding<Int>, max: Int) -> some View {
        TimerTimeField(label: label, value: value, max: max)
    }

    static func warningColor(_ warning: TimerWarning) -> Color {
        guard let c = ColorHex.color(warning.colorHex) else { return .orange }
        return Color(red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    private func targetPickerContent(_ station: TimersController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Countdown to")
                .font(.caption.weight(.medium))
            WallClockFields(hour12: $pickerHour12, minute: $pickerMinute, isPM: $pickerIsPM)
            Button("Add Timer") {
                station.addCountdownToTime(
                    hour: (pickerHour12 % 12) + (pickerIsPM ? 12 : 0),
                    minute: pickerMinute
                )
                showingTargetPicker = false
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct FolderInlineEditor: View {
    let folder: TimerBoard.Folder
    let station: TimersController

    let dismiss: () -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("NAME")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { apply() }
                Button(action: apply) {
                    Text("Apply")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
                .help("Apply (or press Return)")
            }
            HStack {
                Text("Deleting a folder keeps its timers.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()

                Button {
                    dismiss()
                    station.removeFolder(id: folder.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete folder — timers return to the top level")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 8)
        }
        .task(id: folder.id) { name = folder.name }
    }

    private func apply() {
        if name != folder.name { station.renameFolder(id: folder.id, to: name) }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

struct TimerInlineEditor: View {
    let timer: TimerSnapshot
    let station: TimersController

    let dismiss: () -> Void

    @State private var name = ""
    @State private var hours = 0
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var targetHour12 = 11
    @State private var targetMinute = 0
    @State private var targetIsPM = false
    @State private var hasLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("NAME")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { apply() }
            }
            switch timer.mode {
            case .countdown:
                HStack(spacing: 6) {
                    Text("LENGTH")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    timeFields
                    Spacer(minLength: 4)
                    applyChip
                }
            case .countdownToTime:
                HStack(spacing: 6) {
                    Text("UNTIL")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    WallClockFields(hour12: $targetHour12, minute: $targetMinute, isPM: $targetIsPM, onCommit: apply)
                    Spacer(minLength: 4)
                    applyChip
                }
            case .countUp:
                HStack(spacing: 6) {
                    Toggle("Count to", isOn: $hasLimit)
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .font(.caption)
                        .onChange(of: hasLimit) { _, on in
                            if !on { station.setLimit(id: timer.id, seconds: 0) }
                        }
                        .help("Off = runs until paused; on = warning and overrun read against the limit")
                    if hasLimit {
                        timeFields
                        Spacer(minLength: 4)
                        applyChip
                    } else {
                        Spacer(minLength: 4)
                    }
                }
            }

            if timer.mode != .countUp || timer.durationSeconds > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("WARNINGS")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                        Spacer()
                        Button {
                            var warnings = timer.warnings
                            warnings.append(TimerWarning(
                                remainingSeconds: 60, colorHex: TimerWarning.amberHex
                            ))
                            station.setWarnings(id: timer.id, warnings)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add a warning level")
                    }
                    ForEach(Array(timer.warnings.enumerated()), id: \.offset) { index, warning in
                        WarningEditorRow(
                            timer: timer, station: station,
                            index: index, warning: warning
                        )
                    }
                    if timer.warnings.isEmpty {
                        Text("No warnings — the timer stays its running color.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack {
                Spacer()

                Button {
                    dismiss()
                    station.remove(id: timer.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete timer")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 8)
        }
        .task(id: timer.id) { seed() }
    }

    private var timeFields: some View {
        HStack(spacing: 3) {
            TimerTimeField(label: "HH", value: $hours, max: 99, onCommit: apply)
            Text(":").font(.caption).foregroundStyle(.tertiary)
            TimerTimeField(label: "MM", value: $minutes, max: 59, onCommit: apply)
            Text(":").font(.caption).foregroundStyle(.tertiary)
            TimerTimeField(label: "SS", value: $seconds, max: 59, onCommit: apply)
        }
    }

    private var applyChip: some View {
        Button(action: apply) {
            Text("Apply")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
        )
        .help("Apply (or press Return in a field)")
    }

    private func seed() {
        name = timer.name
        switch timer.mode {
        case .countdown, .countUp:
            let total = Int(timer.durationSeconds)
            hours = total / 3600
            minutes = (total / 60) % 60
            seconds = total % 60
            hasLimit = timer.mode == .countdown || timer.durationSeconds > 0
        case .countdownToTime:
            let parts = Calendar.current.dateComponents(
                [.hour, .minute], from: timer.targetTime ?? Date()
            )
            let hour24 = parts.hour ?? 0
            targetHour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            targetMinute = parts.minute ?? 0
            targetIsPM = hour24 >= 12
        }
    }

    private func apply() {
        if name != timer.name { station.rename(id: timer.id, to: name) }
        let total = TimeInterval(hours * 3600 + minutes * 60 + seconds)
        switch timer.mode {
        case .countdown:
            if total != timer.durationSeconds {
                station.setDuration(id: timer.id, seconds: total)
            }
        case .countUp:
            let limit = hasLimit ? total : 0
            if limit != timer.durationSeconds {
                station.setLimit(id: timer.id, seconds: limit)
            }
        case .countdownToTime:
            let hour24 = (targetHour12 % 12) + (targetIsPM ? 12 : 0)
            let current = timer.targetTime.map {
                Calendar.current.dateComponents([.hour, .minute], from: $0)
            }
            if current?.hour != hour24 || current?.minute != targetMinute {
                station.setTarget(id: timer.id, hour: hour24, minute: targetMinute)
            }
        }

        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct WarningEditorRow: View {
    let timer: TimerSnapshot
    let station: TimersController
    let index: Int
    let warning: TimerWarning

    @State private var minutes = 0
    @State private var seconds = 0

    private static let palette: [(name: String, hex: String)] = [
        ("Amber", TimerWarning.amberHex),
        ("Red", TimerWarning.redHex),
        ("Orange", "#FF8A3DFF"),
        ("Yellow", "#FFE04AFF"),
        ("Green", "#34C759FF"),
        ("Blue", "#3B82F6FF"),
        ("Purple", "#A855F7FF"),
        ("White", "#FFFFFFFF"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Text("AT")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            TimerTimeField(label: "MM", value: $minutes, max: 999, onCommit: commit)
            Text(":").font(.caption).foregroundStyle(.tertiary)
            TimerTimeField(label: "SS", value: $seconds, max: 59, onCommit: commit)
            Text("left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Menu {
                ForEach(Self.palette, id: \.hex) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { warning.colorHex == entry.hex },
                        set: { _ in update { $0.colorHex = entry.hex } }
                    ))
                }
            } label: {
                RoundedRectangle.standard(CornerStandard.element)
                    .fill(TimersModule.warningColor(warning))
                    .frame(width: 22, height: 14)
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Warning color")
            Spacer(minLength: 4)
            Button {
                var warnings = timer.warnings
                warnings.remove(at: index)
                station.setWarnings(id: timer.id, warnings)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this warning level")
        }
        .task(id: "\(timer.id)-\(index)-\(warning.remainingSeconds)") {
            let total = Int(warning.remainingSeconds)
            minutes = total / 60
            seconds = total % 60
        }
    }

    private func commit() {
        update { $0.remainingSeconds = TimeInterval(minutes * 60 + seconds) }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func update(_ change: (inout TimerWarning) -> Void) {
        var warnings = timer.warnings
        guard warnings.indices.contains(index) else { return }
        change(&warnings[index])
        station.setWarnings(id: timer.id, warnings)
    }
}

struct WallClockFields: View {
    @Binding var hour12: Int
    @Binding var minute: Int
    @Binding var isPM: Bool
    var onCommit: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            TextField("H", value: Binding(
                get: { hour12 },
                set: { hour12 = Swift.max(1, Swift.min(12, $0)) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 34)
            .onSubmit { onCommit?() }
            Text(":").font(.caption).foregroundStyle(.tertiary)
            TextField("MM", value: Binding(
                get: { minute },
                set: { minute = Swift.max(0, Swift.min(59, $0)) }
            ), format: IntegerFormatStyle<Int>().precision(.integerLength(2...2)))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 34)
            .onSubmit { onCommit?() }

            Menu {
                Toggle("AM", isOn: Binding(get: { !isPM }, set: { _ in isPM = false }))
                Toggle("PM", isOn: Binding(get: { isPM }, set: { _ in isPM = true }))
            } label: {
                Text(isPM ? "PM" : "AM")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
            )
        }
    }
}

struct TimerTimeField: View {
    let label: String
    @Binding var value: Int
    let max: Int
    var onCommit: (() -> Void)?

    var body: some View {
        TextField(label, value: Binding(
            get: { value },
            set: { value = Swift.max(0, Swift.min(max, $0)) }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.caption.monospacedDigit())
        .multilineTextAlignment(.center)
        .frame(width: 40)
        .onSubmit { onCommit?() }
    }
}
