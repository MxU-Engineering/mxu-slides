import PresenterCore
import SlideScene
import SwiftUI

struct SchedulerView: View {
    let model: AppModel
    let controls: ServiceControls?

    @Environment(\.scheduler) private var scheduler
    @State private var selectedTriggerID: String?
    @State private var dropTargetID: String?

    @State private var lineTargetID: String?

    private func draggingPayload(anyOf prefixes: [String]) -> Bool {
        guard let payload = NSPasteboard(name: .drag).string(forType: .string)
        else { return false }
        return prefixes.contains { payload.hasPrefix($0) }
    }
    @State private var boardDropTargeted = false
    @State private var renamingFolder: ScheduleFolder?
    @State private var folderRenameText = ""
    @State private var showHistory = false
    @State private var snoozeSheetTrigger: SnoozeTarget?

    @State private var endDateSheetTrigger: SnoozeTarget?

    struct SnoozeTarget: Identifiable {
        let triggerID: String
        let name: String
        var id: String { triggerID }
    }

    var body: some View {
        HStack(spacing: CornerStandard.panelInset) {
            boardCard
                .frame(width: 380)
            detailCard
                .frame(maxWidth: .infinity)
        }
        .padding(.top, CornerStandard.panelInset)
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Name", text: $folderRenameText)
            Button("Rename") {
                if let folder = renamingFolder {
                    let name = folderRenameText
                    model.updateSchedulerBoard {
                        $0.renameFolder(id: folder.id, to: name)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showHistory) {
            SchedulerHistorySheet(model: model, scheduler: scheduler) { copyID in
                selectedTriggerID = copyID
                showHistory = false
            }
        }
        .sheet(item: $snoozeSheetTrigger) { target in
            SnoozeSheet(name: target.name) { until in
                snooze(target.triggerID, until: until)
            }
        }
        .sheet(item: $endDateSheetTrigger) { target in
            EndDateSheet(name: target.name) { until in
                model.updateScheduleTrigger(target.triggerID) {
                    $0.enabledUntil = ScheduleConditionFormat.localString(from: until)
                }
                scheduler?.sweep()
            }
        }
    }

    private var boardCard: some View {
        VStack(spacing: 0) {
            SidebarSectionHeader("Scheduler", glyph: .services) {
                onChip
            }
            statusRow
            ScrollView {
                LazyVStack(spacing: 4) {
                    boardNodes
                    if board.nodes.isEmpty {
                        Text("No triggers yet. Add one, or drag a library or Service Controls item here.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }

            .dropDestination(for: String.self) { payloads, _ in
                boardDropTargeted = false
                guard let payload = payloads.first else { return false }
                return handleBoardDrop(payload)
            } isTargeted: { boardDropTargeted = $0 }
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        boardDropTargeted && dropTargetID == nil
                            ? Color(nsColor: .controlAccentColor).opacity(0.5)
                            : Color.clear,
                        lineWidth: 1.5
                    )
                    .padding(4)
            )
            Divider().opacity(0.4)
            footerRow
        }
        .floatingPanel()
    }

    private var onChip: some View {
        let isOn = scheduler?.enabled == true
        return Button {
            scheduler?.enabled.toggle()
        } label: {
            Text(isOn ? "On" : "Off")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isOn ? Color.green : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isOn ? Color.green.opacity(0.1) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isOn
                            ? Color.green.opacity(0.35)
                            : Color(nsColor: .separatorColor).opacity(0.5),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Turn the Scheduler on or off on THIS machine — nothing fires while off")
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if scheduler?.enabled != true {
                Text("Off — triggers author normally, nothing fires.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            } else if let next = scheduler?.nextFire {
                Text("Next: \(next.name)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(next.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text("No upcoming time triggers.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            addMenu
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var addMenu: some View {
        Menu {
            Button("New Trigger") { addTrigger() }
            Divider()
            Button("New Folder") {
                let folderID = UUID().uuidString
                model.updateSchedulerBoard { $0.addFolder(named: "New Folder", id: folderID) }
            }
        } label: {

            Image(systemName: "plus")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(10)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a trigger or a folder")
    }

    @ViewBuilder
    private var footerRow: some View {
        let recent = Array((scheduler?.history ?? []).prefix(3))
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if recent.isEmpty {
                    Text("No firings yet.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(recent) { record in
                        HStack(spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if record.outcome != .fired {
                                Text(record.outcome == .late ? "late" : "missed")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color.orange)
                            }
                            Text(record.at, format: .dateTime.hour().minute().second())
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Button("History") { showHistory = true }
                .buttonStyle(.plain)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help("Every run on this machine, and archived one-time triggers")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func spentLabel(triggerID: String, due: Date) -> some View {
        let missed = (scheduler?.history ?? []).contains {
            $0.triggerID == triggerID && $0.at >= due && $0.outcome == .missed
        }
        let time = due.formatted(.dateTime.hour().minute())
        return Text(missed ? "Missed \(time)" : time)
            .font(.system(size: 8, weight: missed ? .medium : .regular).monospacedDigit())
            .foregroundStyle(missed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
    }

    private func activeTriggerCount(_ folder: ScheduleFolder) -> Int {
        folder.triggerIds.filter { (try? model.scheduleTrigger($0))?.archived != true }.count
    }

    private var board: SchedulerBoard { model.schedulerBoard }

    @ViewBuilder
    private var boardNodes: some View {
        ForEach(board.nodes, id: \.self) { nodeID in
            if let folder = board.folder(id: nodeID) {
                folderSection(folder)
            } else {
                triggerRow(nodeID, inFolder: nil)
            }
        }
    }

    @ViewBuilder
    private func folderSection(_ folder: ScheduleFolder) -> some View {
        let enabled = folder.enabled ?? true
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folder.collapsed ?? false ? 0 : 90))
                Glyph(kind: .folder, size: 12)
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(enabled ? .primary : .tertiary)

                Text("\(activeTriggerCount(folder))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                enableChip(isOn: enabled, effective: scheduler?.enabled == true) {
                    model.updateSchedulerBoard { $0.setFolderEnabled(id: folder.id, !enabled) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                model.updateSchedulerBoard {
                    $0.setFolderCollapsed(id: folder.id, !(folder.collapsed ?? false))
                }
            }
        }
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    dropTargetID == folder.id
                        ? Color(nsColor: .controlAccentColor).opacity(0.8) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .draggablePayload("mxutrigfolder::" + folder.id)
        .dropDestination(for: String.self) { payloads, _ in
            dropTargetID = nil
            guard let payload = payloads.first else { return false }
            if payload.hasPrefix("mxutrigger::") {
                let id = String(payload.dropFirst("mxutrigger::".count))
                model.updateSchedulerBoard { $0.moveTrigger(id: id, intoFolder: folder.id) }
                return true
            }
            if payload.hasPrefix("mxutrigfolder::") {
                let id = String(payload.dropFirst("mxutrigfolder::".count))
                guard id != folder.id else { return false }
                model.updateSchedulerBoard { $0.moveFolder(id: id, beforeNode: folder.id) }
                return true
            }
            return false
        } isTargeted: { targeted in

            let line = draggingPayload(anyOf: ["mxutrigfolder::"])
            if targeted, line {
                lineTargetID = folder.id
                if dropTargetID == folder.id { dropTargetID = nil }
            } else if targeted {
                dropTargetID = folder.id
                if lineTargetID == folder.id { lineTargetID = nil }
            } else {
                if dropTargetID == folder.id { dropTargetID = nil }
                if lineTargetID == folder.id { lineTargetID = nil }
            }
        }
        .overlay(alignment: .top) {
            if lineTargetID == folder.id { ControlBoardInsertionLine() }
        }
        .contextMenu {
            Menu("Enabled") {
                Picker("Enabled", selection: Binding(
                    get: { folder.enabled ?? true },
                    set: { value in
                        model.updateSchedulerBoard { $0.setFolderEnabled(id: folder.id, value) }
                    }
                )) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Button("Rename\u{2026}") {
                folderRenameText = folder.name
                renamingFolder = folder
            }
            Button("Duplicate") {
                model.duplicateScheduleFolder(folder.id)
            }
            Divider()
            Button("Delete Folder", role: .destructive) {
                model.updateSchedulerBoard { $0.removeFolder(id: folder.id) }
            }
        }
        if !(folder.collapsed ?? false) {
            VStack(spacing: 4) {
                ForEach(folder.triggerIds, id: \.self) { id in
                    triggerRow(id, inFolder: folder)
                }
                if folder.triggerIds.isEmpty {
                    Text("Drag triggers onto the folder name.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.leading, 14)
        }
    }

    @ViewBuilder
    private func triggerRow(_ id: String, inFolder folder: ScheduleFolder?) -> some View {

        if let trigger = try? model.scheduleTrigger(id), trigger.archived != true {
            let enabled = trigger.enabled ?? true
            let folderOn = folder.map { $0.enabled ?? true } ?? true
            let snoozedUntil = ScheduleMath.snoozeExpiry(trigger, at: Date(), calendar: .current)

            let plannedEnd = ScheduleMath.plannedEnd(trigger, calendar: .current)
            let ended = plannedEnd.map { Date() >= $0 } ?? false
            let selected = selectedTriggerID == id
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trigger.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            enabled && folderOn && snoozedUntil == nil && !ended
                                ? .primary : .tertiary)
                        .lineLimit(1)
                    Text(conditionSummary(trigger))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let preview = captureSourcePreview(trigger) {
                        Text(preview.text)
                            .font(.system(size: 9))
                            .foregroundStyle(preview.isProblem ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    enableChip(
                        isOn: enabled && snoozedUntil == nil && !ended,
                        effective: folderOn && scheduler?.enabled == true
                    ) {

                        model.updateScheduleTrigger(id) {
                            if enabled && snoozedUntil == nil && !ended {
                                $0.enabled = false
                            } else {
                                $0.enabled = nil
                                $0.disabledUntil = nil
                                if ended { $0.enabledUntil = nil }
                            }
                        }
                    }
                    if ended, let plannedEnd {

                        Text("ended \(plannedEnd.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else if let snoozedUntil {

                        let sameDay = Calendar.current.isDate(snoozedUntil, inSameDayAs: Date())
                        Text(sameDay
                            ? "until \(snoozedUntil.formatted(.dateTime.hour().minute()))"
                            : "until \(snoozedUntil.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else if let next = scheduler?.upcoming[id] {
                        Text(next, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else if let due = ScheduleMath.spentOneOffDue(
                        for: trigger, asOf: Date(), calendar: .current)
                    {
                        spentLabel(triggerID: id, due: due)
                    }

                    if !ended, let plannedEnd {
                        Text("ends \(plannedEnd.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                selected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        dropTargetID == id
                            ? Color(nsColor: .controlAccentColor).opacity(0.8)
                            : (selected
                                ? Color(nsColor: .separatorColor).opacity(0.8) : Color.clear),
                        lineWidth: selected || dropTargetID == id ? 1 : 0
                    )
            )
            .onTapGesture { selectedTriggerID = id }
            .draggablePayload("mxutrigger::" + id)
            .dropDestination(for: String.self) { payloads, _ in
                dropTargetID = nil
                lineTargetID = nil
                guard let payload = payloads.first else { return false }
                return handleTriggerDrop(payload, onto: id)
            } isTargeted: { targeted in

                let line = draggingPayload(anyOf: ["mxutrigger::", "mxutrigfolder::"])
                if targeted, line {
                    lineTargetID = id
                    if dropTargetID == id { dropTargetID = nil }
                } else if targeted {
                    dropTargetID = id
                    if lineTargetID == id { lineTargetID = nil }
                } else {
                    if dropTargetID == id { dropTargetID = nil }
                    if lineTargetID == id { lineTargetID = nil }
                }
            }
            .overlay(alignment: .top) {
                if lineTargetID == id { ControlBoardInsertionLine() }
            }
            .contextMenu {
                Button("Run Now") { scheduler?.runNow(triggerID: id) }
                Menu("Enabled") {
                    Picker("Enabled", selection: Binding(
                        get: { trigger.enabled ?? true },
                        set: { value in
                            model.updateScheduleTrigger(id) { $0.enabled = value ? nil : false }
                        }
                    )) {
                        Text("On").tag(true)
                        Text("Off").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()

                    if let due = ScheduleMath.nextDue(for: trigger, after: Date(), calendar: .current) {
                        Button("Skip Next Fire (\(due.formatted(.dateTime.weekday(.abbreviated).hour().minute())))") {
                            snooze(id, until: due.addingTimeInterval(1))
                        }
                    }
                    Button("Off Until…") {
                        snoozeSheetTrigger = SnoozeTarget(triggerID: id, name: trigger.name)
                    }
                    if ScheduleMath.snoozed(trigger, at: Date(), calendar: .current) {
                        Button("Resume Now") {
                            model.updateScheduleTrigger(id) { $0.disabledUntil = nil }
                        }
                    }
                    Divider()

                    Button("On Until…") {
                        endDateSheetTrigger = SnoozeTarget(triggerID: id, name: trigger.name)
                    }
                    if let plannedEnd = ScheduleMath.plannedEnd(trigger, calendar: .current) {
                        Button("Clear End Date (\(plannedEnd.formatted(.dateTime.month(.abbreviated).day())))") {
                            model.updateScheduleTrigger(id) { $0.enabledUntil = nil }
                        }
                    }
                }
                Button("Duplicate") {

                    if let copyID = model.duplicateScheduleTrigger(id) {
                        selectedTriggerID = copyID
                    }
                }
                Divider()
                Button("Delete Trigger", role: .destructive) {
                    if selectedTriggerID == id { selectedTriggerID = nil }
                    model.deleteScheduleTrigger(id)
                }
            }
        }
    }

    private func captureSourcePreview(_ trigger: ScheduleTrigger) -> ServiceControls.CaptureSourcePreview? {
        guard let controls else { return nil }
        for action in trigger.actions where action.kind == .captureStart {
            guard let presetID = action.capturePresetId else { continue }
            if let preview = controls.captureSourcePreview(presetID: presetID) {
                return preview
            }
        }
        return nil
    }

    private func snooze(_ id: String, until date: Date) {
        model.updateScheduleTrigger(id) {
            $0.disabledUntil = ScheduleConditionFormat.localString(from: date)
        }
        scheduler?.sweep()
    }

    private func enableChip(
        isOn: Bool, effective: Bool, toggle: @escaping () -> Void
    ) -> some View {
        let live = isOn && effective
        return Button(action: toggle) {
            Text(isOn ? "On" : "Paused")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(live ? Color.green : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    live ? Color.green.opacity(0.1) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func addTrigger(with action: SlideAction? = nil, name: String? = nil) {
        let id = model.createScheduleTrigger(
            name: name ?? "New Trigger",
            actions: action.map { [$0] } ?? []
        )
        selectedTriggerID = id
    }

    private func handleBoardDrop(_ payload: String) -> Bool {
        guard let action = action(fromDropPayload: payload) else { return false }
        addTrigger(with: action, name: dropName(payload))
        return true
    }

    private func handleTriggerDrop(_ payload: String, onto triggerID: String) -> Bool {
        if payload.hasPrefix("mxutrigger::") {
            let id = String(payload.dropFirst("mxutrigger::".count))
            guard id != triggerID else { return false }
            model.updateSchedulerBoard { $0.moveTrigger(id: id, beforeNode: triggerID) }
            return true
        }
        if payload.hasPrefix("mxutrigfolder::") {
            let id = String(payload.dropFirst("mxutrigfolder::".count))
            model.updateSchedulerBoard { $0.moveFolder(id: id, beforeNode: triggerID) }
            return true
        }
        guard let action = action(fromDropPayload: payload) else { return false }
        model.updateScheduleTrigger(triggerID) { $0.actions.append(action) }
        selectedTriggerID = triggerID
        return true
    }

    private func action(fromDropPayload payload: String) -> SlideAction? {
        func make(_ kind: SlideActionKind, _ fill: (inout SlideAction) -> Void) -> SlideAction {
            var action = SlideAction(id: UUID().uuidString, kind: kind)
            fill(&action)
            return action
        }
        if payload.hasPrefix("mxutimer::") {
            let id = String(payload.dropFirst("mxutimer::".count))
            return make(.timerStart) { $0.timerId = id }
        }

        guard !payload.contains("::"), !payload.hasPrefix("folder:"),
              let entry = model.indexEntry(payload)
        else { return nil }
        switch entry.kind {
        case .media: return make(.fireMedia) { $0.mediaId = entry.id }
        case .presentation: return make(.firePresentation) { $0.presentationId = entry.id }
        case .actionCombo: return make(.fireCombo) { $0.comboId = entry.id }
        case .alertPreset: return make(.fireAlert) { $0.alertId = entry.id }
        case .streamRecordPreset: return make(.captureStart) { $0.capturePresetId = entry.id }
        case .outputPreset: return make(.switchOutputPreset) { $0.presetId = entry.id }
        default:
            DiagnosticsStore.shared.note("scheduler.drop.unmapped", detail: entry.kind.rawValue)
            return nil
        }
    }

    private func dropName(_ payload: String) -> String? {
        if payload.hasPrefix("mxutimer::") {
            let id = String(payload.dropFirst("mxutimer::".count))
            return controls?.timers.snapshot(id: id).map { "Start \($0.name)" }
        }
        guard let entry = model.indexEntry(payload) else { return nil }
        return entry.name
    }

    @ViewBuilder
    private var detailCard: some View {
        VStack(spacing: 0) {
            if let id = selectedTriggerID, let trigger = try? model.scheduleTrigger(id) {
                SidebarSectionHeader("Trigger", glyph: .combos) {
                    Button("Run Now") { scheduler?.runNow(triggerID: id) }
                        .buttonStyle(CardButtonStyle())
                        .help("Fires this trigger's actions immediately — gates ignored")
                }
                TriggerDetailEditor(model: model, controls: controls, triggerID: id, trigger: trigger)
            } else {
                SidebarSectionHeader("Trigger", glyph: .combos)
                Spacer()
                Text("Select a trigger, or drag a library item onto the board.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .floatingPanel()
    }
}

private struct SchedulerHistorySheet: View {
    let model: AppModel
    let scheduler: SchedulerController?

    let onDuplicated: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var archived: [ScheduleTrigger] {
        model.scheduleTriggers
            .compactMap { try? model.scheduleTrigger($0.id) }
            .filter { $0.archived == true }
            .sorted { spentDate($0) > spentDate($1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scheduler History")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider().opacity(0.4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sectionHeader("Archived")
                    if archived.isEmpty {
                        emptyNote("One-time triggers land here after they run.")
                    } else {
                        ForEach(archived) { trigger in
                            archivedRow(trigger)
                        }
                    }
                    sectionHeader("Runs on this machine")
                        .padding(.top, 10)
                    let log = scheduler?.history ?? []
                    if log.isEmpty {
                        emptyNote("No firings yet.")
                    } else {
                        ForEach(log) { record in
                            runRow(record)
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 460, height: 480)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 4)
    }

    private func archivedRow(_ trigger: ScheduleTrigger) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(spentDate(trigger).formatted(
                    .dateTime.year().month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Duplicate to Active") {

                if let copyID = model.duplicateScheduleTrigger(trigger.id) {
                    onDuplicated(copyID)
                }
            }
            .buttonStyle(CardButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .contextMenu {
            Button("Delete Trigger", role: .destructive) {
                model.deleteScheduleTrigger(trigger.id)
            }
        }
    }

    private func runRow(_ record: SchedulerController.RunRecord) -> some View {
        HStack(spacing: 6) {
            Text(record.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if record.source == .manual {
                Text("run now")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if record.outcome != .fired {
                Text(record.outcome == .late ? "late" : "missed")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            Text(record.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func spentDate(_ trigger: ScheduleTrigger) -> Date {
        ScheduleMath.spentOneOffDue(
            for: trigger, asOf: .distantFuture, calendar: .current) ?? .distantPast
    }
}

private struct TriggerDetailEditor: View {
    let model: AppModel
    let controls: ServiceControls?
    let triggerID: String
    let trigger: ScheduleTrigger

    var body: some View {
        Form {
            Section {
                TextField("Name", text: Binding(
                    get: { trigger.name },
                    set: { value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        model.updateScheduleTrigger(triggerID) { $0.name = trimmed }
                    }
                ))
                TextField("Notes", text: Binding(
                    get: { trigger.notes ?? "" },
                    set: { value in
                        model.updateScheduleTrigger(triggerID) {
                            $0.notes = value.isEmpty ? nil : value
                        }
                    }
                ))

                Toggle("Ends", isOn: Binding(
                    get: { trigger.enabledUntil != nil },
                    set: { on in
                        model.updateScheduleTrigger(triggerID) {
                            $0.enabledUntil = on
                                ? ScheduleConditionFormat.localString(
                                    from: Calendar.current.date(
                                        bySettingHour: 23, minute: 59, second: 0,
                                        of: Calendar.current.date(
                                            byAdding: .day, value: 7, to: Date()) ?? Date()
                                    ) ?? Date())
                                : nil
                        }
                    }
                ))
                if trigger.enabledUntil != nil {
                    DatePicker("Ends At", selection: Binding(
                        get: {
                            ScheduleMath.plannedEnd(trigger, calendar: .current) ?? Date()
                        },
                        set: { date in
                            model.updateScheduleTrigger(triggerID) {
                                $0.enabledUntil = ScheduleConditionFormat.localString(from: date)
                            }
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                }
            }
            Section("Conditions") {
                if trigger.conditions.count > 1 {

                    LabeledContent("Fire when") {
                        ChipPicker(
                            options: [
                                (ScheduleConditionLogic.any, "Any matches"),
                                (ScheduleConditionLogic.all, "All match"),
                            ],
                            selection: Binding(
                                get: { trigger.conditionLogic ?? .any },
                                set: { value in
                                    model.updateScheduleTrigger(triggerID) {

                                        $0.conditionLogic = value == .any ? nil : value
                                    }
                                }
                            )
                        )
                    }
                }
                ForEach(trigger.conditions) { condition in
                    ConditionEditor(
                        model: model, controls: controls,
                        triggerID: triggerID, condition: condition
                    )
                    .contextMenu {
                        Button("Remove Condition", role: .destructive) {
                            model.updateScheduleTrigger(triggerID) {
                                $0.conditions.removeAll { $0.id == condition.id }
                            }
                        }
                    }
                }
                Menu("Add Condition\u{2026}") {
                    Button("Weekly") {
                        append(ScheduleCondition(
                            id: UUID().uuidString, kind: .weekly,
                            days: [1], timeOfDay: "09:00"))
                    }
                    Button("One Time") {
                        append(ScheduleCondition(
                            id: UUID().uuidString, kind: .oneTime,
                            date: ScheduleConditionFormat.localString(
                                from: Date().addingTimeInterval(3600))))
                    }
                    Button("Timer Reaches") {
                        append(ScheduleCondition(
                            id: UUID().uuidString, kind: .timerReaches,
                            timerId: controls?.timers.timers.first?.id, timerSeconds: 0))
                    }
                }
            }
            Section("Actions") {
                ActionListEditor(model: model, actions: Binding(
                    get: { trigger.actions },
                    set: { value in
                        model.updateScheduleTrigger(triggerID) { $0.actions = value }
                    }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func append(_ condition: ScheduleCondition) {
        model.updateScheduleTrigger(triggerID) { $0.conditions.append(condition) }
    }
}

private struct ConditionEditor: View {
    let model: AppModel
    let controls: ServiceControls?
    let triggerID: String
    let condition: ScheduleCondition

    private static let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(kindLabel.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer(minLength: 2)
                Button {
                    model.updateScheduleTrigger(triggerID) {
                        $0.conditions.removeAll { $0.id == condition.id }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove condition")
            }
            parameters
        }
    }

    private var kindLabel: String {
        switch condition.kind {
        case .weekly: "Weekly"
        case .oneTime: "One Time"
        case .timerReaches: "Timer Reaches"
        }
    }

    @ViewBuilder
    private var parameters: some View {
        switch condition.kind {
        case .weekly:
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { weekday in
                    let selected = (condition.days ?? []).contains(weekday)
                    Button {
                        update { current in
                            var days = Set(current.days ?? [])
                            if selected { days.remove(weekday) } else { days.insert(weekday) }
                            current.days = days.sorted()
                        }
                    } label: {
                        Text(Self.dayLetters[weekday - 1])
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(width: 22, height: 22)
                            .background(
                                selected ? Color.primary.opacity(0.08) : Color.clear,
                                in: Circle()
                            )
                            .overlay {
                                if selected {
                                    Circle().strokeBorder(
                                        Color(nsColor: .separatorColor).opacity(0.5),
                                        lineWidth: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                SecondsTimePicker(date: Binding(
                    get: {
                        ScheduleConditionFormat.timeOfDayDate(condition.timeOfDay ?? "09:00")
                    },
                    set: { date in
                        update { $0.timeOfDay = ScheduleConditionFormat.timeOfDay(from: date) }
                    }
                ))
            }
        case .oneTime:
            SecondsTimePicker(
                date: Binding(
                    get: {
                        condition.date.flatMap {
                            ScheduleMath.parseLocalDate($0, calendar: .current)
                        } ?? Date()
                    },
                    set: { date in
                        update { $0.date = ScheduleConditionFormat.localString(from: date) }
                    }
                ),
                includesDate: true
            )
        case .timerReaches:
            Picker("Timer", selection: Binding(
                get: { condition.timerId ?? "" },
                set: { value in update { $0.timerId = value.isEmpty ? nil : value } }
            )) {
                Text("Choose\u{2026}").tag("")
                ForEach(controls?.timers.timers ?? [], id: \.id) { timer in
                    Text(timer.name).tag(timer.id)
                }
            }
            LabeledContent("At") {
                HStack(spacing: 4) {
                    let seconds = Int(condition.timerSeconds ?? 0)
                    TimerTimeField(label: "min", value: Binding(
                        get: { seconds / 60 },
                        set: { value in
                            update { $0.timerSeconds = Double(value * 60 + seconds % 60) }
                        }
                    ), max: 999)
                    Text(":").foregroundStyle(.tertiary)
                    TimerTimeField(label: "sec", value: Binding(
                        get: { seconds % 60 },
                        set: { value in
                            update { $0.timerSeconds = Double((seconds / 60) * 60 + value) }
                        }
                    ), max: 59)
                    Text(timerHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var timerHint: String {
        guard let id = condition.timerId,
              let snapshot = controls?.timers.snapshot(id: id)
        else { return "" }
        return switch snapshot.mode {
        case .countdown, .countdownToTime: "remaining"
        case .countUp: "elapsed"
        }
    }

    private func update(_ mutate: @escaping @Sendable (inout ScheduleCondition) -> Void) {
        let conditionID = condition.id
        model.updateScheduleTrigger(triggerID) { trigger in
            guard let index = trigger.conditions.firstIndex(where: { $0.id == conditionID })
            else { return }
            mutate(&trigger.conditions[index])
        }
    }
}

struct SecondsTimePicker: NSViewRepresentable {
    @Binding var date: Date
    var includesDate = false

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = includesDate
            ? [.yearMonthDay, .hourMinuteSecond] : .hourMinuteSecond
        picker.datePickerMode = .single
        picker.controlSize = .small
        picker.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.binding = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $date) }

    final class Coordinator: NSObject {
        var binding: Binding<Date>
        init(binding: Binding<Date>) { self.binding = binding }
        @objc func changed(_ sender: NSDatePicker) {
            binding.wrappedValue = sender.dateValue
        }
    }
}

private struct SnoozeSheet: View {
    let name: String
    let pause: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var until = Calendar.current.date(
        bySettingHour: 8, minute: 0, second: 0,
        of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    ) ?? Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Off Until: \(name)")
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Form {
                Section {
                    DatePicker(
                        "Back on", selection: $until, in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } footer: {
                    Text("The trigger pauses now and re-arms by itself at this moment. Fires it sleeps through are skipped, never replayed late.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Pause") {
                    pause(until)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 400, height: 240)
    }
}

private struct EndDateSheet: View {
    let name: String
    let end: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var until = Calendar.current.date(
        bySettingHour: 23, minute: 59, second: 0,
        of: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    ) ?? Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("On Until: \(name)")
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Form {
                Section {
                    DatePicker(
                        "Ends", selection: $until, in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } footer: {
                    Text("The trigger runs normally until this moment, then stops for good. Its last fire moves it to Scheduler History, where Duplicate to Active brings it back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Set End Date") {
                    end(until)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 400, height: 250)
    }
}

enum ScheduleConditionFormat {

    static func timeOfDayDate(_ raw: String) -> Date {
        let calendar = Calendar.current
        guard let parsed = parseTime(raw) else { return Date() }
        return calendar.date(
            bySettingHour: parsed.hour, minute: parsed.minute, second: parsed.second, of: Date()
        ) ?? Date()
    }

    static func timeOfDay(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let base = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
        let second = parts.second ?? 0
        return second > 0 ? base + String(format: ":%02d", second) : base
    }

    static func seconds(in raw: String?) -> Int {
        guard let raw else { return 0 }
        let time = raw.split(separator: "T").last.map(String.init) ?? raw
        let parts = time.split(separator: ":")
        guard parts.count == 3, let second = Int(parts[2]) else { return 0 }
        return second
    }

    static func localString(from date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(
            format: "%04d-%02d-%02dT%02d:%02d",
            parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1,
            parts.hour ?? 0, parts.minute ?? 0)
        let second = parts.second ?? 0
        return second > 0 ? base + String(format: ":%02d", second) : base
    }

    private static func parseTime(_ raw: String) -> (hour: Int, minute: Int, second: Int)? {
        let parts = raw.split(separator: ":")
        guard (2 ... 3).contains(parts.count),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return nil }
        return (hour, minute, parts.count == 3 ? Int(parts[2]) ?? 0 : 0)
    }
}

extension SchedulerView {

    fileprivate func conditionSummary(_ trigger: ScheduleTrigger) -> String {
        guard !trigger.conditions.isEmpty else { return "No conditions" }
        let parts = trigger.conditions.map { condition -> String in
            switch condition.kind {
            case .weekly:
                let days = (condition.days?.isEmpty == false)
                    ? condition.days!.compactMap { day -> String? in
                        guard (1...7).contains(day) else { return nil }
                        return Calendar.current.shortWeekdaySymbols[day - 1]
                    }.joined(separator: " ")
                    : "Every day"
                let time = condition.timeOfDay.map { raw in
                    let date = ScheduleConditionFormat.timeOfDayDate(raw)
                    return ScheduleConditionFormat.seconds(in: raw) > 0
                        ? date.formatted(.dateTime.hour().minute().second())
                        : date.formatted(.dateTime.hour().minute())
                } ?? "any time"
                return "\(days) \(time)"
            case .oneTime:
                guard let raw = condition.date,
                      let date = ScheduleMath.parseLocalDate(raw, calendar: .current)
                else { return "One time: not set" }
                return ScheduleConditionFormat.seconds(in: raw) > 0
                    ? date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
                    : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            case .timerReaches:
                let name = condition.timerId.flatMap {
                    controls?.timers.snapshot(id: $0)?.name
                } ?? "missing timer"
                let seconds = Int(condition.timerSeconds ?? 0)
                return "\(name) reaches \(seconds / 60):\(String(format: "%02d", seconds % 60))"
            }
        }

        let summary = parts.joined(
            separator: trigger.conditionLogic == .all ? " & " : " · ")
        let actionCount = trigger.actions.count
        return actionCount == 0
            ? summary + " · no actions"
            : summary + " · \(actionCount) action\(actionCount == 1 ? "" : "s")"
    }
}
