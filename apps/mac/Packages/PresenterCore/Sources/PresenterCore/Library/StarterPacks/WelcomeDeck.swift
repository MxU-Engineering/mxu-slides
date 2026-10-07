import Foundation

public enum WelcomeDeck {
    public static let presentationID = "welcome.presentation"
    public static let serviceID = "welcome.service"
    public static let serviceItemID = "welcome.service.item"
    public static let presentationName = "Welcome to MxU Slides"
    public static let serviceName = "Getting Started"

    struct Page: Equatable {
        var key: String
        var kicker: String
        var title: String
        var body: String
    }

    static let pages: [Page] = [
        Page(key: "welcome", kicker: "Getting Started", title: "Welcome to MxU Slides",
             body: "This deck is a two-minute tour. Click this slide to take it live, then press the Right Arrow or Space for the next one."),
        Page(key: "live", kicker: "Step 1", title: "Click a slide to go live",
             body: "Whatever you click shows on your audience screen. Left and Right Arrow move through the deck, and the Clear controls take layers back off the screen."),
        Page(key: "screens", kicker: "Step 2", title: "Pick your screens",
             body: "Window › Screen Configuration assigns each display a role: Audience for the room, Confidence for the stage. With one display, the Output Preview shows what the room would see."),
        Page(key: "services", kicker: "Step 3", title: "Build a service",
             body: "A service is your run order, like a ProPresenter playlist. This deck lives in the Getting Started service. File › New Service starts your own; drag presentations and media in from the library."),
        Page(key: "edit", kicker: "Step 4", title: "Edit and restyle",
             body: "Switch to Edit to change words, fonts and layout. Themes restyle a whole presentation at once; four starter themes and their overlays are already in your library."),
        Page(key: "import", kicker: "Step 5", title: "Bring what you have",
             body: "File › Import brings in a ProPresenter workspace, single ProPresenter files, PowerPoint decks and lyrics. Imports never overwrite what is already here without asking."),
        Page(key: "feedback", kicker: "Beta", title: "Tell us what broke",
             body: "Help › Report a Problem saves your note with diagnostics to Downloads. Help › Show Welcome reopens setup, and this deck is yours to delete."),
    ]

    private static let backdrop = "#0B1220FF"
    private static let ink = "#FFFFFFFF"
    private static let accent = "#3B82F6FF"
    private static let quiet = "#CBD5E1FF"

    private static func text(
        _ id: String, _ name: String, _ string: String, y: Double, height: Double,
        font: String, size: Double, color: String, tracking: Double = 0, uppercase: Bool = false,
        valign: TextVerticalAlignment = .middle, lineHeight: Double = 1
    ) -> SlideObject {
        SlideObject(
            id: id, objectKind: .text, name: name, text: string, x: 200, y: y, width: 1520, height: height,
            textStyle: TextStyle(
                fontName: font, fontSize: size, colorHex: color, tracking: tracking,
                lineHeightMultiple: lineHeight, horizontalAlignment: .left, verticalAlignment: valign,
                textTransform: uppercase ? .uppercase : nil, insetLeft: 0, insetRight: 0
            )
        )
    }

    static func makeSlide(_ page: Page) -> Slide {
        let base = "\(presentationID).\(page.key)"
        let rule = SlideObject(
            id: "\(base).rule", objectKind: .shape, name: "Rule", text: "", x: 200, y: 325, width: 160, height: 4,
            shapeKind: .rectangle, fill: ObjectFill(fillKind: .solid, colorHex: accent)
        )
        return Slide(
            id: base, name: page.title,
            objects: [
                text("\(base).kicker", "Kicker", page.kicker, y: 250, height: 60,
                     font: "HelveticaNeue", size: 32, color: accent, tracking: 4, uppercase: true),
                rule,
                text("\(base).title", "Title", page.title, y: 350, height: 170,
                     font: "HelveticaNeue-Bold", size: 104, color: ink),
                text("\(base).body", "Body", page.body, y: 540, height: 330,
                     font: "HelveticaNeue", size: 46, color: quiet, valign: .top, lineHeight: 1.3),
            ],
            backgroundFill: ObjectFill(fillKind: .solid, colorHex: backdrop)
        )
    }

    public static func makePresentation() -> Presentation {

        Presentation(
            id: presentationID, name: presentationName, presentationKind: .deck, themeId: "",
            slides: pages.map(makeSlide)
        )
    }

    public static func makeService(serviceDate: String) -> Service {
        Service(
            id: serviceID, name: serviceName, serviceDate: serviceDate,
            items: [ServiceItem(id: serviceItemID, itemKind: .presentation, name: presentationName, refId: presentationID)]
        )
    }
}

extension Library {

    public func restoreWelcomeDeck(serviceDate: String) throws {
        if try index.entry(id: WelcomeDeck.presentationID) == nil {
            try create(WelcomeDeck.makePresentation())
        }
        if try index.entry(id: WelcomeDeck.serviceID) == nil {
            try create(WelcomeDeck.makeService(serviceDate: serviceDate))
        }
    }

    public func needsOnboarding(rootURL: URL) throws -> Bool {
        let marker = Self.onboardedMarker(rootURL: rootURL)
        var needed = false
        if !FileManager.default.fileExists(atPath: marker.path) {
            let untouched = try store.ids(of: .presentation).isEmpty && store.ids(of: .service).isEmpty
            if untouched {
                needed = true
            } else {
                Self.markOnboarded(rootURL: rootURL)
            }
        }
        return needed
    }

    nonisolated public static func needsOnboarding(rootURL: URL, snapshot: IndexSnapshot) -> Bool {
        let marked = FileManager.default.fileExists(atPath: onboardedMarker(rootURL: rootURL).path)
        let untouched = snapshot.entries(of: .presentation).isEmpty && snapshot.entries(of: .service).isEmpty
        if !marked, !untouched {
            markOnboarded(rootURL: rootURL)
        }
        return !marked && untouched
    }

    nonisolated public static func markOnboarded(rootURL: URL) {
        FileManager.default.createFile(atPath: onboardedMarker(rootURL: rootURL).path, contents: nil)
    }

    nonisolated private static func onboardedMarker(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".onboarded-v1")
    }
}

extension LibraryClient {

    @discardableResult
    public func restoreWelcomeDeck(serviceDate: String) async throws -> [LibraryBatch] {
        let index = try await settledSnapshot()
        var created: [LibraryBatch] = []
        if index.entry(id: WelcomeDeck.presentationID) == nil {
            created.append(try await create(WelcomeDeck.makePresentation()).value)
        }
        if index.entry(id: WelcomeDeck.serviceID) == nil {
            created.append(try await create(WelcomeDeck.makeService(serviceDate: serviceDate)).value)
        }
        return created
    }
}
