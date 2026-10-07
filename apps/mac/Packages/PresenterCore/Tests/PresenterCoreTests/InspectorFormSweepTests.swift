import Foundation
import Testing

@Suite struct InspectorFormSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func objectInspectorNeverUsesAGroupedForm() throws {
        let lines = try String(
            contentsOf: appSources.appendingPathComponent("SlideObjectInspector.swift"), encoding: .utf8
        ).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var forms = 0
        var cards = 0
        var violations: [String] = []

        var pickerDepth: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let inPickerMenu = pickerDepth != nil
            if pickerDepth == nil, line.contains("InspectorPicker(") { pickerDepth = 0 }
            if pickerDepth != nil {
                for character in line {
                    if character == "{" { pickerDepth! += 1 }
                    if character == "}" { pickerDepth! -= 1 }
                }
                if pickerDepth! <= 0, line.contains("}") { pickerDepth = nil }
            }
            if trimmed == "InspectorForm {" { forms += 1 }
            if trimmed.hasPrefix("InspectorSection(") || trimmed.hasPrefix("InspectorSection {") { cards += 1 }
            if trimmed == "Form {" || trimmed.hasPrefix(".formStyle(") {
                violations.append("\(index + 1): \(trimmed)")
            }

            if trimmed.hasPrefix("Picker(\""), !trimmed.hasPrefix("Picker(\"\", selection: $tab)") {
                violations.append("\(index + 1): \(trimmed)")
            }

            let rowLevelSection = trimmed.contains("Section(\"") || trimmed.hasSuffix(" Section {") || trimmed == "Section {"
            if !inPickerMenu, rowLevelSection, !trimmed.contains("InspectorSection"), !trimmed.hasPrefix("//") {
                violations.append("\(index + 1): \(trimmed)")
            }
        }
        #expect(forms == 2, "the slide and object inspectors are InspectorForms (\(forms))")
        #expect(cards >= 20, "sections are InspectorSection cards (\(cards))")
        #expect(violations.isEmpty, "grouped-Form spellings in the inspector: \(violations)")
    }
}
