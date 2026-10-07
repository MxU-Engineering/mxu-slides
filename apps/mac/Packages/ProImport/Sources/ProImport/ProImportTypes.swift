import Foundation
import PresenterCore

public struct ProTimerPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case countdown(seconds: Double)
        case countdownToTime(hour: Int, minute: Int)
        case countUp(limitSeconds: Double)
    }

    public var proUUID: String

    public var newID: String
    public var name: String
    public var mode: Mode
}

public struct ProTimerSeed: Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ProInputPlan: Sendable, Equatable {

    public var newID: String
    public var name: String
    public var kind: CaptureSourceKind

    public var sourceId: String?
}

public struct ProInputSeed: Sendable, Equatable {
    public var id: String
    public var name: String
    public var sourceId: String?

    public init(id: String, name: String, sourceId: String?) {
        self.id = id
        self.name = name
        self.sourceId = sourceId
    }
}

public struct ProLookPlan: Sendable, Equatable {
    public struct ScreenLook: Sendable, Equatable {
        public var proScreenUUID: String

        public var enabledLayers: [String]

        public var slideThemeName: String?

        public var slideThemeId: String?

        public var maskProUUID: String?
    }

    public var proUUID: String
    public var name: String
    public var screenLooks: [ScreenLook]
}

public struct ProScreenPlan: Sendable, Equatable {

    public struct OutputCorrection: Sendable, Equatable {
        public struct Offset: Sendable, Equatable {
            public var x: Double
            public var y: Double

            public init(x: Double, y: Double) {
                self.x = x
                self.y = y
            }
        }

        public var topLeft: Offset?
        public var topRight: Offset?
        public var bottomLeft: Offset?
        public var bottomRight: Offset?
        public var brightness: Double = 0
        public var contrast: Double = 0
        public var gamma: Double = 0
        public var blackLevel: Double = 0
        public var redLevel: Double = 0
        public var greenLevel: Double = 0
        public var blueLevel: Double = 0

        public var rotationDegrees: Double = 0

        public init() {}

        public var isNeutral: Bool {
            func zero(_ offset: Offset?) -> Bool { offset == nil || (offset!.x == 0 && offset!.y == 0) }
            return zero(topLeft) && zero(topRight) && zero(bottomLeft) && zero(bottomRight)
                && brightness == 0 && contrast == 0 && gamma == 0 && blackLevel == 0
                && redLevel == 0 && greenLevel == 0 && blueLevel == 0
                && rotationDegrees == 0
        }
    }

    public struct EdgeBlendPlan: Sendable, Equatable {
        public var width: Double
        public var curve: Double
        public var intensity: Double?
        public var blackLift: Double?
    }

    public struct Slice: Sendable, Equatable {
        public var proUUID: String
        public var name: String
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var correction: OutputCorrection?
        public var blendLeft: EdgeBlendPlan?
        public var blendRight: EdgeBlendPlan?
        public var blendTop: EdgeBlendPlan?
        public var blendBottom: EdgeBlendPlan?
    }

    public struct MaskShape: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public var shapeKind: String
        public var cornerRadius: Double

        public var pathData: String?
    }

    public struct MaskPlan: Sendable, Equatable {

        public var proUUID: String
        public var name: String
        public var shapes: [MaskShape]
    }

    public struct Screen: Sendable, Equatable {
        public var proUUID: String
        public var name: String

        public var isConfidence: Bool
        public var width: Int
        public var height: Int

        public var correction: OutputCorrection?

        public var slices: [Slice] = []
    }

    public struct StageAssignment: Sendable, Equatable {
        public var screenProUUID: String

        public var layoutID: String
    }

    public var screens: [Screen]
    public var stageAssignments: [StageAssignment]

    public var masks: [MaskPlan] = []
}

extension ProPresenterImporter {
    public struct DocumentSummary: Sendable {
        public let sourceURL: URL

        public let presentationID: String?
        public let name: String
        public let warnings: [String]
        public let mediaImported: Int

        public var groupHotKeys: [String: String] = [:]

        public var skipped: ImportSkipReason?

        public var mediaWithheld = 0
    }

    public struct PlaylistBundleSummary: Sendable {

        public var services: [String] = []
        public var documents: [DocumentSummary] = []
        public var mediaImported = 0
        public var warnings: [String] = []

        public var failureReason: String?
    }

    public nonisolated static func proPresenterShowDirectory() -> URL? {
        guard let defaults = UserDefaults(suiteName: "com.renewedvision.propresenter"),
              let path = defaults.string(forKey: "applicationShowDirectory")
        else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}

extension ProWorkspaceImporter {
    public struct Result: Sendable {
        public var presentations: [ProPresenterImporter.DocumentSummary] = []
        public var themesImported: [String] = []
        public var overlaysImported: [String] = []
        public var alertsImported: [String] = []
        public var layoutsImported: [String] = []
        public var combosImported: [String] = []
        public var midiDevicesImported: [String] = []

        public var servicesImported: [String] = []

        public var schedulesImported: [String] = []
        public var mediaImported = 0

        public var mediaWithheld = 0

        public var mediaFoldersImported: [String] = []
        public var warnings: [String] = []

        public var screenPlan = ProScreenPlan(screens: [], stageAssignments: [])
        public var timerPlans: [ProTimerPlan] = []

        public var inputPlans: [ProInputPlan] = []

        public var lookPlans: [ProLookPlan] = []
        public var liveLookUUID: String?

        public var groupHotKeys: [String: String] = [:]

        public var skippedExisting = 0
        public var skippedEdited: [String] = []
    }
}
