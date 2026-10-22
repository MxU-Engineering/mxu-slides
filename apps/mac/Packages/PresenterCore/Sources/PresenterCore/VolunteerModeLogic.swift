import Foundation

public enum VolunteerModeLogic {

    public static let enabledKey = "present.volunteerModeEnabled"

    public enum Choice: String, CaseIterable, Sendable {
        case present, edit, scheduler, volunteer

        public var title: String {
            switch self {
            case .present: "Present"
            case .edit: "Edit"
            case .scheduler: "Scheduler"
            case .volunteer: "Volunteer"
            }
        }
    }

    public static func choices(enabled: Bool) -> [Choice] {
        enabled ? [.present, .edit, .scheduler, .volunteer] : [.present, .edit, .scheduler]
    }

    public static func selected(mode: String, volunteerOn: Bool) -> Choice {
        volunteerOn ? .volunteer : Choice(rawValue: mode) ?? .edit
    }

    public enum Action: Equatable, Sendable {
        case nothing
        case switchMode(String)
        case enterVolunteer

        case leaveVolunteer(then: String)
    }

    public static func picking(_ choice: Choice, volunteerOn: Bool) -> Action {
        if choice == .volunteer {
            volunteerOn ? .nothing : .enterVolunteer
        } else if volunteerOn {
            .leaveVolunteer(then: choice.rawValue)
        } else {
            .switchMode(choice.rawValue)
        }
    }
}
