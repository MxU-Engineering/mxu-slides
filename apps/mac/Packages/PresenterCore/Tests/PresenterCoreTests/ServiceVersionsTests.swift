import Foundation
import Testing

@testable import PresenterCore

@Suite struct ServiceVersionsTests {
    private func row(_ id: String, ref: String = "", hex: String? = nil) -> ServiceItem {
        ServiceItem(id: id, itemKind: .presentation, name: id, refId: ref, mxuItemHexId: hex)
    }

    private func main() -> Service {
        Service(id: "plan-p", name: "Sunday", serviceDate: "2026-10-04", items: [
            row("a", ref: "deck-a", hex: "ha"), row("b", ref: "deck-b", hex: "hb"),
            row("c", ref: "deck-c", hex: "hc"), row("d", ref: "deck-d", hex: "hd"),
        ])
    }

    @discardableResult
    private func north(_ service: inout Service) -> String {
        ServiceVersions.create(name: "North Campus", in: &service, id: "north")
    }

    private func editNorth(_ service: inout Service, _ mutate: (inout Service) -> Void) -> Service {
        ServiceVersions.edit(&service, versionID: "north", mutate)
        return ServiceVersions.apply(service.versions![0], to: service)
    }

    @Test func aNewVersionRunsMain() {
        var service = main()
        north(&service)
        #expect(ServiceVersions.apply(service.versions![0], to: service).items == main().items)
    }

    @Test func editsWhileRunningAVersionLandInItAndLeaveMainAlone() {
        var service = main()
        north(&service)
        let seen = editNorth(&service) { run in
            run.items[1].refId = "deck-north"          
            run.items[2].arrangementId = "acoustic"    
            run.items.removeAll { $0.id == "d" }       
            run.items.insert(row("x", ref: "deck-x"), at: 1) 
            run.items.move(fromOffsets: [0], toOffset: 4)    
        }
        #expect(seen.items.map(\.id) == ["x", "b", "c", "a", "d"])
        #expect(seen.items.map(\.refId) == ["deck-x", "deck-north", "deck-c", "deck-a", "deck-d"])
        #expect(seen.items[2].arrangementId == "acoustic")
        #expect(seen.items[4].hiddenInPresenter == true, "a removed Main row is skipped, so Unhide brings it back")
        #expect(service.items == main().items, "Main is untouched")
    }

    @Test func sharedRowFieldsAndServiceFieldsStillReachMain() {
        var service = main()
        north(&service)
        _ = editNorth(&service) { run in
            run.name = "Sunday AM"
            run.items[0].colorHex = "#FF0000FF"
            run.items[0].refId = "deck-north"
        }
        #expect(service.name == "Sunday AM")
        #expect(service.items[0].colorHex == "#FF0000FF")
        #expect(service.items[0].refId == "deck-a")
    }

    @Test func aVersionKeepsItsChangesWhenMainChangesAndFollowsMainsNewAndGoneRows() {
        var service = main()
        north(&service)
        _ = editNorth(&service) { $0.items[1].refId = "deck-north" }

        service.items[1].arrangementId = "full-band"
        service.items[1].refId = "deck-b2"
        service.items.removeAll { $0.id == "c" }
        service.items.insert(row("e", ref: "deck-e"), at: 2)
        let seen = ServiceVersions.apply(service.versions![0], to: service)
        #expect(seen.items.map(\.id) == ["a", "b", "e", "d"])
        #expect(seen.items[1].refId == "deck-north", "the version's swap wins")
        #expect(seen.items[1].arrangementId == "full-band", "fields it did not change follow Main")
    }

    @Test func movesSurviveASecondEditAndUseMainDropsARowsChanges() {
        var service = main()
        north(&service)
        _ = editNorth(&service) { $0.items.move(fromOffsets: [3], toOffset: 0) }
        let seen = editNorth(&service) { $0.items[2].refId = "deck-north" }
        #expect(seen.items.map(\.id) == ["d", "a", "b", "c"])
        #expect(ServiceVersions.changedItemIDs(service.versions![0]) == ["d", "b"])
        ServiceVersions.useMain(itemID: "b", versionID: "north", in: &service)
        #expect(ServiceVersions.apply(service.versions![0], to: service).items[2].refId == "deck-b")
    }

    @Test func aComputerRunsTheVersionNamingItElseTheOneItPickedLastElseMain() {
        var service = main()
        north(&service)
        ServiceVersions.create(name: "Chapel", in: &service, id: "chapel")
        #expect(ServiceVersions.running(service, machineID: "booth", rememberedName: nil) == nil)
        #expect(ServiceVersions.running(service, machineID: "laptop", rememberedName: "north campus")?.id == "north")
        ServiceVersions.choose("chapel", in: &service, computer: ServiceVersionStation(id: "laptop", name: "Laptop"))
        #expect(ServiceVersions.running(service, machineID: "laptop", rememberedName: "North Campus")?.id == "chapel")
        #expect(service.versions?[1].stations?.map(\.name) == ["Laptop"], "every computer sees who runs it")
        ServiceVersions.choose(nil, in: &service, computer: ServiceVersionStation(id: "laptop", name: "Laptop"))
        #expect(service.versions?.allSatisfy { $0.stations == nil } == true)
    }

    @Test func theSyncGuardsKeepEveryVersionsDecksAndMedia() {
        var service = main()
        north(&service)
        _ = editNorth(&service) { run in
            run.items.append(ServiceItem(id: "m", itemKind: .media, name: "Loop", refId: "media-north"))
            run.items[0].refId = "deck-north"
        }
        #expect(UpcomingUse.references(of: service).isSuperset(of: ["deck-a", "deck-north", "media-north"]))
        #expect(MediaReferences.ids(in: service) == ["media-north"])
    }
}

@LibraryActor @Suite struct ServiceVersionsMergeTests {
    @Test func aVersionMadeOnOneComputerMergesWithMainEditedOnAnother() throws {
        let seed = Service(id: "shared-p", name: "Sunday", serviceDate: "", items: [])
        let booth = try TypedDocument(seed, seed: .init(id: seed.id))
        _ = try booth.update { $0.items = [ServiceItem(id: "a", itemKind: .presentation, name: "a", refId: "deck-a")] }
        let laptop = try TypedDocument(seed, seed: .init(id: seed.id))
        try laptop.merge(booth)
        _ = try laptop.update { service in
            ServiceVersions.create(name: "North Campus", in: &service, id: "north")
            ServiceVersions.edit(&service, versionID: "north") { $0.items[0].refId = "deck-north" }
            ServiceVersions.choose("north", in: &service, computer: ServiceVersionStation(id: "laptop", name: "Laptop"))
        }
        _ = try booth.update { $0.items.append(ServiceItem(id: "b", itemKind: .presentation, name: "b", refId: "deck-b")) }
        try booth.merge(laptop)
        let merged = booth.value
        #expect(merged.items.map(\.refId) == ["deck-a", "deck-b"], "the booth still runs Main")
        let north = try #require(merged.versions?.first)
        #expect(ServiceVersions.apply(north, to: merged).items.map(\.refId) == ["deck-north", "deck-b"])
        #expect(ServiceVersions.running(merged, machineID: "booth", rememberedName: nil) == nil)
    }
}

@Suite struct ServiceVersionsSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func editsRouteIntoTheRunningVersion() throws {
        let model = try source("AppModel.swift")
        #expect(model.contains("modify(Service.self, id: id) { ServiceVersions.edit(&$0, versionID: versionID, mutate) }"))
        #expect(model.contains("return runningVersion(of: main).map { ServiceVersions.apply($0, to: main) } ?? main"))
    }
}
