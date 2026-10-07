import Foundation
import Testing
@testable import PresenterCore

@LibraryActor private func makeLibrary() throws -> (Library, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try Library(rootURL: root), root)
}

@Test func welcomeDeckIsAConsistentDocumentPair() {
    let deck = WelcomeDeck.makePresentation()
    #expect(deck.id == WelcomeDeck.presentationID && deck.slides.count == WelcomeDeck.pages.count)
    #expect(Set(deck.slides.map(\.id)).count == deck.slides.count, "slide ids are unique")
    for slide in deck.slides {
        #expect(slide.backgroundFill != nil && slide.objects.filter { $0.objectKind == .text }.count == 3, Comment(rawValue: slide.name))
    }
    #expect(!WelcomeDeck.pages.contains { ($0.title + $0.body).contains("MXU") || ($0.title + $0.body).contains("mxu ") })

    let service = WelcomeDeck.makeService(serviceDate: "2026-09-17")
    #expect(service.name == "Getting Started")
    #expect(service.items.map(\.refId) == [WelcomeDeck.presentationID])
    #expect(service.items.first?.itemKind == .presentation)
}

@LibraryActor @Test func restoreWelcomeDeckFillsOnlyWhatIsMissing() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    try library.restoreWelcomeDeck(serviceDate: "2026-09-17")
    #expect(try library.index.entries(of: .presentation).map(\.name) == ["Welcome to MxU Slides"])
    #expect(try library.index.entries(of: .service).map(\.name) == ["Getting Started"])

    let document = try library.open(Presentation.self, id: WelcomeDeck.presentationID)
    try document.update { $0.name = "My Tour" }
    try library.save(document)
    try library.delete(kind: .service, id: WelcomeDeck.serviceID)
    try library.restoreWelcomeDeck(serviceDate: "2026-09-18")
    #expect(try library.index.entries(of: .presentation).map(\.name) == ["My Tour"])
    #expect(try library.open(Service.self, id: WelcomeDeck.serviceID).value.serviceDate == "2026-09-18")
}

@LibraryActor @Test func onboardingIsOnlyForAnUntouchedWorkspace() throws {
    let (fresh, freshRoot) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: freshRoot) }
    #expect(try fresh.needsOnboarding(rootURL: freshRoot))
    #expect(try fresh.needsOnboarding(rootURL: freshRoot), "asking does not stamp a fresh workspace")
    Library.markOnboarded(rootURL: freshRoot)
    #expect(try !fresh.needsOnboarding(rootURL: freshRoot))

    let (used, usedRoot) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: usedRoot) }
    try used.create(Service(id: "svc1", name: "Sunday AM", serviceDate: "2026-07-05", items: []))
    #expect(try !used.needsOnboarding(rootURL: usedRoot))
    try used.delete(kind: .service, id: "svc1")
    #expect(try !used.needsOnboarding(rootURL: usedRoot))
}
