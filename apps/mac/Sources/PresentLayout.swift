import Foundation

struct PresentLayout: Codable, Equatable, Identifiable {
    struct PoppedModule: Codable, Equatable {

        var module: String

        var frame: String?
    }

    struct PoppedPreview: Codable, Equatable {

        var target: String
        var frame: String?
    }


    var id: String
    var name: String

    var selectedModule: String
    var poppedOut: [PoppedModule]

    var previewPopped: Bool = false
    var previewFrame: String?

    var openPreviews: [PoppedPreview]?

    var rightRailWidth: Double
    var rightSplit: Double
    var sidebarWidth: Double
    var sidebarVisible: Bool

    var rightRailHidden: Bool?

    var serviceControlsWindowOpen: Bool?
    var serviceControlsWindowFrame: String?

    var runOnly: Bool

    var runOnlyModules: [String]?

    var volunteerModules: [ServiceControlsModule]? {
        runOnlyModules?.compactMap(ServiceControlsModule.init(rawValue:))
    }

    var previewWindows: [PoppedPreview] {
        if let openPreviews { return openPreviews }
        return previewPopped ? [PoppedPreview(target: "", frame: previewFrame)] : []
    }
}
