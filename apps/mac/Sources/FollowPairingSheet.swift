import LocalAPI
import MxUAPI
import PresenterCore
import SwiftUI

struct FollowSettingsControl: View {
    let station: StationSyncController?
    let documentSync: DocumentSyncController?
    @State private var choosing = false

    var body: some View {
        let follow = FollowController.shared
        if follow.pairing != nil, let station {
            Button("Stop Backing Up") { Task { await follow.unpair(station: station) } }
        } else {
            Button("Back Up Another Computer\u{2026}") { choosing = true }
                .disabled(station?.stationHexId == nil || documentSync == nil || EmulationController.isEmulating)
                .sheet(isPresented: $choosing) {
                    if let station, let documentSync {
                        FollowPairingSheet(station: station, documentSync: documentSync)
                    }
                }
        }
    }
}

struct FollowPairingCodeControl: View {
    let api: LocalAPIController?

    var body: some View {
        if let api, api.running {
            HStack(spacing: 8) {
                Text(api.pairingCode).font(.title3.monospacedDigit().weight(.semibold))
                Button("New Code") { api.newPairingCode() }
            }
        } else {
            Text("Turn on the API in Network & API first.").foregroundStyle(.secondary)
        }
    }
}

struct FollowPairingSheet: View {
    let station: StationSyncController
    let documentSync: DocumentSyncController

    @Environment(\.dismiss) private var dismiss
    @State private var peers: [BonjourBrowser.Peer] = []
    @State private var stations: [String: MxUAPIClient.Station] = [:]
    @State private var picked: String?
    @State private var code = Self.qaCode
    @State private var working = false
    @State private var problem: String?
    @State private var unconnected: [String] = []

    @State private var automatic = true

    private static var qaCode: String {
        #if DEBUG
        ProcessInfo.processInfo.environment["MXU_QA_FOLLOW_CODE"] ?? ""
        #else
        ""
        #endif
    }

    private var peer: BonjourBrowser.Peer? { peers.first { $0.stationHexId == picked } }
    private var booth: MxUAPIClient.Station? { picked.flatMap { stations[$0] } }
    private var name: String { peer.map(displayName) ?? "that computer" }

    private func displayName(_ peer: BonjourBrowser.Peer) -> String {
        stations[peer.stationHexId]?.name ?? peer.name
    }

    private var switchesSetup: Bool { booth?.workspaceHexId != nil && booth?.workspaceHexId != station.workspaceHexId }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Back up another computer").font(.headline)
            Text("This computer shows everything the other one shows, fire for fire, on its own screens. Its own triggers wait until it takes over.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if peers.isEmpty {
                Label("Looking for your team's computers on this network\u{2026} The other computer needs MxU Slides open with its API on.", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Computer", selection: $picked) {
                    ForEach(peers, id: \.stationHexId) { peer in
                        Text(displayName(peer)).tag(Optional(peer.stationHexId))
                    }
                }
                .frame(maxWidth: 300)
                HStack(spacing: 8) {
                    Text("Code \(name) shows")
                    TextField("0000", text: $code)
                        .frame(width: 70)
                        .font(.body.monospacedDigit())
                }
                checks
                Picker("If \(name) stops", selection: $automatic) {
                    Text("Take over after 3 seconds").tag(true)
                    Text("Wait for Take Over").tag(false)
                }
                .frame(maxWidth: 380)
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
        .task { await loadStations() }
        .onAppear { unconnected = Follow.unconnectedScreens(in: UserDefaults.standard.dictionaryRepresentation()) }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if switchesSetup {
                check("Runs \(name)'s setup. MxU Slides reopens to finish.", ok: true)
            } else if booth != nil {
                check("Runs \(name)'s setup already.", ok: true)
            }
            if booth != nil {
                check("Downloads what \(name) downloads.", ok: true)
            }
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
        guard let team = MxUAccountController.shared.user?.teamHexId else { return }
        let browser = BonjourBrowser(teamHexId: team, ownStationHexId: station.stationHexId)
        defer { browser.stop() }
        for await found in browser.start() {
            peers = found.sorted { $0.name < $1.name }
            if picked == nil || !peers.contains(where: { $0.stationHexId == picked }) { picked = peers.first?.stationHexId }
        }
    }

    private func loadStations() async {
        guard let client = MxUAccountController.shared.client, let all = try? await client.stations() else { return }
        stations = Dictionary(all.map { ($0.hexId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func pair() {
        guard let peer, let team = MxUAccountController.shared.user?.teamHexId else { return }
        let booth = booth
        let switchesSetup = switchesSetup
        working = true
        problem = nil
        Task {
            defer { working = false }
            if let refused = await FollowController.shared.pair(with: peer, name: displayName(peer), code: code, automatic: automatic, teamHexId: team, station: station) {
                problem = refused
                return
            }
            if let booth {

                _ = await station.setOffline(booth.offline.map { OfflineSetLogic.Entry(kind: $0.kind, ref: $0.ref, library: $0.library) })
                if switchesSetup, let workspace = booth.workspaceHexId, let refused = await documentSync.runWorkspace(workspace) {
                    problem = "Paired, but this computer couldn't switch to \(displayName(peer))'s setup: \(refused)"
                    return
                }
            }
            dismiss()
        }
    }
}
