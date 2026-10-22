import PresenterCore
import SwiftUI

struct UnmatchedStemsSheet: View {
    let plan: TimelineTracks.StemPlan
    let channels: [TrackChannel]
    let done: (TimelineTracks.StemResolution?) -> Void

    @State private var picks: [String: String] = [:]
    @State private var names: [String: String] = [:]

    @AppStorage("tracks.import.remember") private var remember = true

    private static let new = "new"

    var body: some View {

        let matched = Set(plan.assignments.values)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.unmatched.count == 1 ? "1 file matches no track" : "\(plan.unmatched.count) files match no track")
                    .font(.headline)
                if let matchedLine {
                    Text(matchedLine).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(plan.unmatched) { file in
                        let pick = picks[file.fileName] ?? Self.new
                        let taken = matched.union(
                            plan.unmatched.filter { $0.fileName != file.fileName }.compactMap { picks[$0.fileName] })
                        GridRow {
                            Text((file.fileName as NSString).deletingPathExtension)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 150, alignment: .leading)
                                .help(file.fileName)
                            Picker("", selection: Binding(get: { pick }, set: { picks[file.fileName] = $0 })) {
                                Text("New Track").tag(Self.new)
                                Divider()
                                ForEach(channels.filter { !taken.contains($0.id) || $0.id == pick }) { channel in
                                    Text(channel.name).tag(channel.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            TextField("Name", text: Binding(
                                get: { names[file.fileName] ?? file.proposed.name },
                                set: { names[file.fileName] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                                .opacity(pick == Self.new ? 1 : 0)
                                .disabled(pick != Self.new)
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            Toggle("Remember for next time", isOn: $remember)
                .help("Next time you import a file with the same name, it goes on the track you picked. Change this in Settings › Audio & Video › Tracks.")
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { done(TimelineTracks.resolve(plan, choices: choices, remember: remember)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var matchedLine: String? {
        let names = plan.assignments.keys.map { ($0 as NSString).deletingPathExtension }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        switch names.count {
        case 0: return nil
        case 1...3: return "\(ListFormatter.localizedString(byJoining: names)) \(names.count == 1 ? "goes on its track" : "go on their tracks")."
        default: return "The other \(names.count) go on their tracks."
        }
    }

    private var choices: [String: TimelineTracks.StemChoice] {
        Dictionary(uniqueKeysWithValues: plan.unmatched.map { file in
            let pick = picks[file.fileName] ?? Self.new
            return (file.fileName, pick == Self.new
                ? .new(name: names[file.fileName] ?? file.proposed.name) : .existing(pick))
        })
    }
}
