import PresenterCore
import SwiftUI

struct ChordEditorSheet: View {
    let model: AppModel
    let presentationID: String
    @Environment(\.dismiss) private var dismiss

    @State private var editingChip: ChipID?
    @State private var editingText = ""
    @FocusState private var focusedChip: ChipID?

    @State private var draggingChip: ChipID?
    @State private var dragColumn: Int?

    struct ChipID: Hashable {
        var rowID: String
        var index: Int
    }

    struct Row: Identifiable {
        var id: String
        var slideID: String
        var objectID: String

        var header: String?
        var line: Int
        var text: String

        var chords: [ChordPlacement]
    }

    private static let chordInk = Color(red: 1.0, green: 0.72, blue: 0.15)
    private static let lyricFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private static let charWidth: CGFloat = ("M" as NSString).size(
        withAttributes: [.font: lyricFont]
    ).width

    var body: some View {
        let _ = model.listVersion
        VStack(spacing: 0) {
            header
            Divider()
            if let presentation = model.presentation(presentationID) {
                let rows = Self.rows(of: presentation)
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No Lyrics", systemImage: "music.note.list",
                        description: Text("Add text to the slides first — chords anchor to lyric lines.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                if let header = row.header {
                                    Text(header)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 14)
                                }
                                rowView(row)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ContentUnavailableView("Presentation not found", systemImage: "questionmark.square.dashed")
            }
        }
        .frame(minWidth: 940, minHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.presentation(presentationID)?.name ?? "Chords")
                .font(.headline)
            Picker("Key", selection: musicKeyBinding()) {
                Text("None").tag("")
                Divider()
                ForEach(Self.keyNames, id: \.self) { Text($0).tag($0) }
                ForEach(Self.keyNames, id: \.self) { Text($0 + "m").tag($0 + "m") }
            }
            .fixedSize()
            .help("The key these chords are written in — display keys transpose from here")
            Text("Chords are stored in this key; pick a display key in Present or the inspector.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export ChordPro…") {
                if let presentation = model.presentation(presentationID) { model.exportChordPro(presentation) }
            }
            .help("Save this song as a ChordPro file, chords as edited here")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private static let keyNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    private func musicKeyBinding() -> Binding<String> {
        Binding(
            get: { model.presentation(presentationID)?.musicKey ?? "" },
            set: { value in

                model.updatePresentationField(
                    presentationID, \.musicKey, key: "musicKey", to: value.isEmpty ? nil : value,
                    undoLabel: "Set Key")
                if value.isEmpty {
                    model.updatePresentationField(
                        presentationID, \.displayKey, key: "displayKey", to: nil, undoLabel: "Set Key")
                }
            }
        )
    }

    static func rows(of presentation: Presentation) -> [Row] {
        let sectionNames = Dictionary(
            (presentation.sections ?? []).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [Row] = []
        var slideNumber = 0
        for slide in presentation.slides {
            guard let object = slide.objects.first(where: {
                $0.objectKind == .text && !$0.text.isEmpty
            }) ?? slide.objects.first(where: { $0.objectKind == .text }) else { continue }
            slideNumber += 1
            let chordsByLine = Dictionary(grouping: object.chords ?? [], by: \.line)
            let lines = object.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let section = slide.sectionId.flatMap { sectionNames[$0] }
                rows.append(Row(
                    id: "\(slide.id)-\(index)",
                    slideID: slide.id,
                    objectID: object.id,
                    header: index == 0
                        ? [section, "Slide \(slideNumber)"].compactMap(\.self).joined(separator: " · ")
                        : nil,
                    line: index,
                    text: line,
                    chords: (chordsByLine[index] ?? []).sorted { $0.column < $1.column }
                ))
            }
        }
        return rows
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 16) {
            chordCanvasLine(row)
            Divider()
            ChordProRow(projected: Self.bracketedLine(row)) { commitBracketedLine($0, row: row) }
                .frame(width: 320)
        }
    }

    private func chordCanvasLine(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {

                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: 24)
                    .onTapGesture(coordinateSpace: .local) { location in
                        addChord(at: location.x, row: row)
                    }
                ForEach(Array(row.chords.enumerated()), id: \.offset) { index, chord in
                    chip(chord, id: ChipID(rowID: row.id, index: index), row: row)
                }
            }
            Text(row.text.isEmpty ? " " : row.text)
                .font(Font(Self.lyricFont))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chip(_ chord: ChordPlacement, id: ChipID, row: Row) -> some View {
        let column = (draggingChip == id ? dragColumn : nil) ?? chord.column
        let x = CGFloat(min(column, max(row.text.count, 0))) * Self.charWidth
        if editingChip == id {
            TextField("", text: $editingText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Self.chordInk)
                .frame(width: max(56, CGFloat(editingText.count + 2) * 8))
                .focused($focusedChip, equals: id)
                .onSubmit { commitChipEdit(row: row, index: id.index) }
                .onExitCommand {
                    editingChip = nil
                    focusedChip = nil
                }
                .onChange(of: focusedChip) { _, focus in

                    if focus != id, editingChip == id { commitChipEdit(row: row, index: id.index) }
                }
                .offset(x: x)
        } else {
            ChipLabel(symbol: chord.symbol, ink: Self.chordInk) {
                editingText = chord.symbol
                editingChip = id
                focusedChip = id
            } onDelete: {
                writeChords(row: row) { chords in
                    chords.remove(at: id.index)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        draggingChip = id
                        dragColumn = snappedColumn(
                            base: chord.column, translation: value.translation.width, row: row
                        )
                    }
                    .onEnded { value in
                        let column = snappedColumn(
                            base: chord.column, translation: value.translation.width, row: row
                        )
                        draggingChip = nil
                        dragColumn = nil
                        writeChords(row: row) { chords in
                            chords[id.index].column = column
                        }
                    }
            )
            .offset(x: x)
        }
    }

    private func snappedColumn(base: Int, translation: CGFloat, row: Row) -> Int {
        let moved = CGFloat(base) + translation / Self.charWidth
        return min(max(0, Int(moved.rounded())), max(row.text.count, 0))
    }

    private func addChord(at x: CGFloat, row: Row) {
        let column = min(max(0, Int((x / Self.charWidth).rounded())), max(row.text.count, 0))
        let line = row.line
        let place: @Sendable (inout [ChordPlacement]) -> Void = { chords in
            chords.append(ChordPlacement(line: line, column: column, symbol: ""))
            chords.sort { ($0.column, $0.symbol) < ($1.column, $1.symbol) }
        }

        var placed = row.chords
        place(&placed)
        let newIndex = placed.firstIndex { $0.column == column && $0.symbol.isEmpty } ?? 0
        writeChords(row: row, place)
        editingText = ""
        let chip = ChipID(rowID: row.id, index: newIndex)
        editingChip = chip
        focusedChip = chip
    }

    private func commitChipEdit(row: Row, index: Int) {
        let symbol = editingText.trimmingCharacters(in: .whitespaces)
        editingChip = nil
        focusedChip = nil
        writeChords(row: row) { chords in
            guard chords.indices.contains(index) else { return }
            if symbol.isEmpty {

                chords.remove(at: index)
            } else {
                chords[index].symbol = symbol
            }
        }
    }

    static func bracketedLine(_ row: Row) -> String {
        let rebased = row.chords.map {
            ChordPlacement(line: 0, column: $0.column, symbol: $0.symbol)
        }
        return ChordMath.bracketed(row.text, chords: rebased)
    }

    private func commitBracketedLine(_ text: String, row: Row) {
        let extracted = ChordMath.extractLine(text.components(separatedBy: "\n").first ?? text)
        model.updateSlide(presentationID: presentationID, slideID: row.slideID, undoLabel: "Edit Chords") { slide in
            if let object = slide.objects.firstIndex(where: { $0.id == row.objectID }) {
                var lines = slide.objects[object].text.components(separatedBy: "\n")
                if lines.indices.contains(row.line) {
                    lines[row.line] = extracted.text
                    slide.objects[object].text = lines.joined(separator: "\n")

                    var chords = (slide.objects[object].chords ?? []).filter { $0.line != row.line }
                    chords.append(contentsOf: extracted.chords.map {
                        ChordPlacement(line: row.line, column: $0.column, symbol: $0.symbol)
                    })
                    chords.sort { ($0.line, $0.column) < ($1.line, $1.column) }
                    slide.objects[object].chords = chords.isEmpty ? nil : chords
                }
            }
        }
    }

    private func writeChords(row: Row, _ mutate: @escaping @Sendable (inout [ChordPlacement]) -> Void) {
        model.updateSlide(presentationID: presentationID, slideID: row.slideID, undoLabel: "Edit Chords") { slide in
            if let object = slide.objects.firstIndex(where: { $0.id == row.objectID }) {
                let all = slide.objects[object].chords ?? []
                var line = all.filter { $0.line == row.line }.sorted { $0.column < $1.column }
                mutate(&line)
                var chords = all.filter { $0.line != row.line }
                chords.append(contentsOf: line.map {
                    ChordPlacement(line: row.line, column: $0.column, symbol: $0.symbol)
                })
                chords.sort { ($0.line, $0.column) < ($1.line, $1.column) }
                slide.objects[object].chords = chords.isEmpty ? nil : chords
            }
        }
    }
}

private struct ChipLabel: View {
    let symbol: String
    let ink: Color
    let onTap: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text(symbol.isEmpty ? "•" : symbol)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(ink)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

private struct ChordProRow: View {
    let projected: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .focused($focused)
            .onAppear { draft = projected }
            .onChange(of: projected) { _, value in

                if !focused { draft = value }
            }
            .onSubmit { commit(draft) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != projected { commit(draft) }
            }
    }
}
