import OutputEngine

extension OutputManager {

    func outputName(_ id: String) -> String {
        displays.first { $0.uuid == id }?.name
            ?? placeholderScreens.first { $0.id.uuidString == id }?.name
            ?? "Output"
    }
}
