import AppKit
import PresenterCore
import SwiftUI

struct FontFaceRows: View {
    @Binding var fontName: String

    var body: some View {
        let resolved = FontCatalog.resolve(fontName)
        let members = FontCatalog.members(of: resolved.family)

        LabeledContent("Font") {
            HStack(spacing: 6) {
                FontFamilyPicker(resolved: resolved, selection: familyBinding(resolved))
                    .layoutPriority(1)
                if !members.isEmpty {
                    Picker("Style", selection: faceBinding(resolved, members: members)) {
                        ForEach(members, id: \.postScriptName) { member in
                            Text(member.face).tag(member.postScriptName)
                        }
                    }
                    .labelsHidden()

                    .buttonStyle(.borderless)
                    .fixedSize()
                    .help("Style")
                }
            }
        }
    }

    private func familyBinding(_ resolved: FontCatalog.Resolved) -> Binding<String> {
        Binding(
            get: { resolved.family },
            set: { family in
                guard family != resolved.family,
                      let next = FontCatalog.member(in: family, matchingFace: resolved.face)
                else { return }
                fontName = next.postScriptName
            }
        )
    }

    private func faceBinding(_ resolved: FontCatalog.Resolved, members: [FontCatalog.Member]) -> Binding<String> {
        Binding(
            get: {

                members.first { $0.postScriptName == fontName }?.postScriptName
                    ?? FontCatalog.member(in: resolved.family, matchingFace: resolved.face)?.postScriptName
                    ?? members[0].postScriptName
            },
            set: { name in
                if name != fontName { fontName = name }
            }
        )
    }
}

private struct FontFamilyPicker: View {
    let resolved: FontCatalog.Resolved
    @Binding var selection: String

    @AppStorage(FontCatalog.recentsKey) private var recentsRaw = ""
    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button {
            query = ""
            open.toggle()
        } label: {

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(resolved.installed ? resolved.family : "\(resolved.family) (Missing)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary) 
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Font family — search, or pick from the last five used")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popup
        }
    }

    private var recents: [String] {
        FontMenuLogic.installedRecents(
            recentsRaw.split(separator: "\n").map(String.init),
            installed: FontCatalog.families)
    }

    private var popup: some View {
        let recentHits = FontMenuLogic.filter(recents, query: query)
        let allHits = FontMenuLogic.filter(FontCatalog.families, query: query)
        return VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField("Search fonts", text: $query)
                    .textFieldStyle(.plain)

                    .multilineTextAlignment(.leading)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = recentHits.first ?? allHits.first { pick(first) }
                    }
                    .onExitCommand { open = false }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            if allHits.isEmpty {
                ContentUnavailableView(
                    "No Fonts", systemImage: "textformat",
                    description: Text("Nothing matches “\(query)”."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    if recentHits.isEmpty {
                        ForEach(allHits, id: \.self) { family in row(family) }
                    } else {
                        Section("Recent") {
                            ForEach(recentHits, id: \.self) { family in row(family) }
                        }
                        Section("All Fonts") {
                            ForEach(allHits, id: \.self) { family in row(family) }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
        .font(.system(size: 12))
        .frame(width: 240, height: 320)
        .onAppear { searchFocused = true }
    }

    private func row(_ family: String) -> some View {
        Button {
            pick(family)
        } label: {
            HStack {
                Text(family)
                    .lineLimit(1)
                Spacer()
                if family == resolved.family {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
    }

    private func pick(_ family: String) {
        recentsRaw = FontMenuLogic
            .recents(adding: family, to: recentsRaw.split(separator: "\n").map(String.init))
            .joined(separator: "\n")
        selection = family
        open = false
    }
}

enum FontCatalog {

    static let recentsKey = "font.recentFamilies"

    struct Member: Hashable {
        let postScriptName: String
        let face: String
        let weight: Int
    }

    struct Resolved {
        let family: String
        let face: String
        let installed: Bool
    }

    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    static func resolve(_ name: String) -> Resolved {
        guard let font = NSFont(name: name, size: 12), let family = font.familyName else {
            return Resolved(family: name, face: "", installed: false)
        }
        let face = members(of: family).first { $0.postScriptName == font.fontName }?.face
            ?? (font.displayName.map { display in
                display.hasPrefix(family) ? display.dropFirst(family.count).trimmingCharacters(in: .whitespaces) : display
            } ?? "")
        return Resolved(family: family, face: face.isEmpty ? "Regular" : face, installed: true)
    }

    static func members(of family: String) -> [Member] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { entry in
            guard entry.count >= 3, let name = entry[0] as? String, let face = entry[1] as? String else {
                return nil
            }
            return Member(postScriptName: name, face: face, weight: (entry[2] as? Int) ?? 5)
        }
    }

    static func member(in family: String, matchingFace face: String) -> Member? {
        let all = members(of: family)
        return all.first { $0.face.caseInsensitiveCompare(face) == .orderedSame }
            ?? all.first { $0.face.caseInsensitiveCompare("Regular") == .orderedSame }
            ?? all.first { $0.weight == 5 }
            ?? all.first
    }
}
