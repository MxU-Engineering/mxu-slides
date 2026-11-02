import LocalAPI
import PresenterCore
import SwiftUI

struct FollowSettingsControl: View {
    @State private var choosing = false

    var body: some View {
        Button("Make This the Backup\u{2026}") { choosing = true }
            .disabled(FollowController.shared.me == nil)
            .sheet(isPresented: $choosing) {
                FollowPairingSheet(own: FollowController.shared.me)
            }
    }
}

struct BackupSideControl: View {
    var body: some View {
        let follow = FollowController.shared
        if let pairing = follow.pairing {
            HStack(spacing: 8) {
                if follow.inCharge {
                    Button("Hand Back") { Task { await follow.handBack() } }
                } else {
                    if follow.state == .gaveUp {
                        Button("Try Again") { follow.tryAgain() }
                    }
                    Button("Take Over") { Task { await follow.takeOver() } }
                }
                Menu("Options") {
                    Picker("While \(pairing.name) runs", selection: Binding(
                        get: { pairing.mirrors ?? true },
                        set: { mirrors in Task { await follow.setMirrors(mirrors) } })) {
                        Text("Show the same thing live").tag(true)
                        Text("Stay ready, show nothing").tag(false)
                    }
                    .pickerStyle(.inline)
                    Picker("If \(pairing.name) stops", selection: Binding(
                        get: { pairing.automatic ?? true },
                        set: { follow.setAutomatic($0) })) {
                        Text("Take over after 3 seconds").tag(true)
                        Text("Wait for Take Over").tag(false)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Stop Backing Up") { Task { await follow.unpair() } }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
    }
}

struct BoothSideControl: View {
    let api: LocalAPIController?
    @State private var settingUp = false
    @State private var forgetting: String?

    var body: some View {
        let follow = FollowController.shared
        Group {
            if follow.steppedDown != nil {
                Button("Take Back") { follow.takeBack() }
            } else if follow.backups.isEmpty {
                Button("Set Up a Backup\u{2026}") { settingUp = true }
            } else {
                Menu("Options") {
                    Button("Set Up Another Backup\u{2026}") { settingUp = true }
                    Divider()
                    ForEach(follow.backups, id: \.self) { name in
                        Button("Forget \(name)\u{2026}") { forgetting = name }
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
        .sheet(isPresented: $settingUp) { BackupCodeSheet(api: api, name: FollowController.shared.myName) }
        .confirmationDialog("Forget \(forgetting ?? "")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                if let forgetting { follow.forget(backup: forgetting) }
            }
        } message: {
            Text("It stops following this computer until it pairs again with this computer's code.")
        }
    }
}

struct BackupCodeSheet: View {
    let api: LocalAPIController?
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up a backup").font(.headline)
            Text("A second Mac on this network follows this one and can take over if it stops.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let api, api.running {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text("1.").foregroundStyle(.secondary)
                        Text("On the backup Mac, open MxU Slides › Settings › Backup.")
                    }
                    GridRow {
                        Text("2.").foregroundStyle(.secondary)
                        Text("Click Make This the Backup\u{2026} and pick \(name.isEmpty ? "this computer" : name).")
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("3.").foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Enter this code:")
                            Text(api.pairingCode).font(.title2.monospacedDigit().weight(.semibold))
                            Button("New Code") { api.newPairingCode() }
                                .controlSize(.small)
                        }
                    }
                }
            } else if let api {
                HStack {
                    Text("The backup reaches this computer through its API, which is off.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Turn On the API") { api.enabled = true }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(20)
        .frame(width: 440)
    }
}

struct FollowPairingSheet: View {
    let own: String?

    @Environment(\.dismiss) private var dismiss
    @State private var peers: [BonjourBrowser.Peer] = []
    @State private var picked: String?
    @State private var code = Self.qaCode
    @State private var working = false
    @State private var problem: String?
    @State private var unconnected: [String] = []

    @State private var automatic = true

    @State private var mirrors = true

    private static var qaCode: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["MXU_QA_FOLLOW_CODE"] ?? ""
        #else
        ""
        #endif
    }

    private var peer: BonjourBrowser.Peer? { peers.first { $0.stationHexId == picked } }
    private var name: String { peer.map(displayName) ?? "that computer" }

    private func displayName(_ peer: BonjourBrowser.Peer) -> String {
        peer.stationName ?? peer.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make this the backup").font(.headline)
            Text("This Mac shows what the main computer shows, or stays ready with clear screens. It answers its own triggers only after it takes over.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if peers.isEmpty {
                Label("Looking for MxU Slides on this network\u{2026} The other computer needs MxU Slides open with its API on.", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    GridRow {
                        Text("Computer").gridColumnAlignment(.trailing)
                        Picker("Computer", selection: $picked) {
                            ForEach(peers, id: \.stationHexId) { peer in
                                Text(displayName(peer)).tag(Optional(peer.stationHexId))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Code \(name) shows")
                        TextField("0000", text: $code)
                            .frame(width: 70)
                            .font(.body.monospacedDigit())
                    }
                    GridRow {
                        Text("While \(name) runs")
                        Picker("While \(name) runs", selection: $mirrors) {
                            Text("Show the same thing live").tag(true)
                            Text("Stay ready, show nothing").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("If \(name) stops")
                        Picker("If \(name) stops", selection: $automatic) {
                            Text("Take over after 3 seconds").tag(true)
                            Text("Wait for Take Over").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                checks
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Backing Up") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(peer == nil || code.count != 4 || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await browse() }
        .onAppear { unconnected = Follow.unconnectedScreens(in: UserDefaults.standard.dictionaryRepresentation()) }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            check("Copies \(name)'s library, output presets and stream presets here over the network.", ok: true)
            ForEach(unconnected, id: \.self) { screen in
                check("\(screen) isn't connected on this computer, so it won't show here. Connect it in Settings › Screens.", ok: false)
            }
        }
        .font(.caption)
    }

    private func check(_ text: String, ok: Bool) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: ok ? "checkmark" : "exclamationmark.triangle")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private func browse() async {
        let browser = BonjourBrowser(ownStationHexId: own)
        defer { browser.stop() }
        for await found in browser.start() {
            peers = found.sorted { $0.name < $1.name }
            if picked == nil || !peers.contains(where: { $0.stationHexId == picked }) { picked = peers.first?.stationHexId }
        }
    }

    private func pair() {
        guard let peer else { return }
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let refused = await FollowController.shared.pair(with: peer, name: displayName(peer), code: code, automatic: automatic, mirrors: mirrors) {
                problem = refused
                return
            }
            dismiss()
        }
    }
}
