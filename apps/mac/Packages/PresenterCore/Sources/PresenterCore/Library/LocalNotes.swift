import Foundation

public enum LocalNotes {
    public static let origin = "local"

    public static func note(name: String, body: NoteBody?, id: String = "note-" + UUID().uuidString) -> NoteDocument {
        NoteDocument(id: id, name: name, origin: origin, body: body ?? NoteBody(blocks: [], plainText: ""))
    }

    public static func pastedName(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return first.map { $0.count > 60 ? String($0.prefix(59)) + "…" : $0 } ?? "Untitled Note"
    }
}
