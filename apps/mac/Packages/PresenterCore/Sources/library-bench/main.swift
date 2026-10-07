import Darwin
import Foundation
import PresenterCore

var songCount = 1000
var editCount = 200
var keepLibrary = false
var forkOnly = false
var deckPath: String?
var args = ArraySlice(CommandLine.arguments.dropFirst())
while let arg = args.popFirst() {
    switch arg {
    case "--songs": songCount = args.popFirst().flatMap { Int($0) } ?? songCount
    case "--edits": editCount = args.popFirst().flatMap { Int($0) } ?? editCount
    case "--keep": keepLibrary = true
    case "--fork-only": forkOnly = true
    case "--deck": deckPath = args.popFirst()
    default:
        print("unknown argument: \(arg)")
        exit(2)
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let rngSeed: UInt64 = 0x4D78_5501  

let titleOpeners = ["Amazing", "Great", "Living", "Endless", "Boundless", "Blessed", "Holy", "Mighty", "Faithful", "Glorious"]
let titleSubjects = ["Grace", "Love", "Hope", "Light", "King", "Savior", "Redeemer", "Fortress", "Anchor", "Cornerstone"]
let lyricLines = [
    "Amazing grace how sweet the sound",
    "That saved a wretch like me",
    "I once was lost but now am found",
    "Was blind but now I see",
    "How great Thou art how great Thou art",
    "Then sings my soul my Savior God to Thee",
    "On Christ the solid rock I stand",
    "All other ground is sinking sand",
    "Great is Thy faithfulness morning by morning",
    "All I have needed Thy hand hath provided",
]

func makeSong(number: Int, using rng: inout SplitMix64) -> Presentation {
    let title = "\(titleOpeners.randomElement(using: &rng)!) \(titleSubjects.randomElement(using: &rng)!) \(number)"
    let sections = ["Verse 1", "Verse 2", "Chorus", "Verse 3", "Bridge", "Chorus (Reprise)", "Tag"]
    let slidesPerSection = Int.random(in: 1...3, using: &rng)
    var slides: [Slide] = []
    for section in sections.prefix(Int.random(in: 4...sections.count, using: &rng)) {
        for i in 1...slidesPerSection {
            let lines = (0..<Int.random(in: 2...4, using: &rng))
                .map { _ in lyricLines.randomElement(using: &rng)! }
                .joined(separator: "\n")
            slides.append(Slide(
                id: "song\(number)-\(section)-\(i)",
                name: slidesPerSection == 1 ? section : "\(section) \(i)",
                objects: [
                    SlideObject(id: "song\(number)-\(section)-\(i)-lyrics", objectKind: .text, name: "Lyrics", text: lines),
                    SlideObject(
                        id: "song\(number)-\(section)-\(i)-bg", objectKind: .shape,
                        name: "Background", text: "",
                        fill: ObjectFill(fillKind: .media)),
                ]
            ))
        }
    }
    return Presentation(id: "song-\(number)", name: title, presentationKind: .song, themeId: "theme-\(number % 20 + 1)", slides: slides)
}

func makeBigDeck() -> Presentation {
    Presentation(
        id: "big-deck", name: "Big deck", presentationKind: .deck, themeId: "",
        slides: (0..<183).map { n in
            Slide(
                id: "big-s\(n)", name: "Slide \(n)",
                objects: [
                    SlideObject(
                        id: "big-s\(n)-text", objectKind: .text, name: "Lyrics",
                        text: "Line \(n) of the song, sung once and then again\nA second line for slide \(n)",
                        x: 120, y: 80, width: 1680, height: 900),
                    SlideObject(
                        id: "big-s\(n)-bg", objectKind: .shape, name: "Background", text: "",
                        x: 0, y: 0, width: 1920, height: 1080, fill: ObjectFill(fillKind: .solid, colorHex: "#102030")),
                ])
        })
}

func physicalFootprint() -> Int64 {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Int64(usage.ri_phys_footprint) : 0
}

struct Samples {
    var values: [Double] = []  
    mutating func record(_ ms: Double) { values.append(ms) }
    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[rank]
    }
    var max: Double { values.max() ?? 0 }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
    func summary() -> String {
        String(
            format: "p50 %6.2fms   p95 %6.2fms   max %6.2fms   mean %6.2fms",
            percentile(0.5), percentile(0.95), max, mean
        )
    }
}

func measure<T>(_ work: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try work()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    return (result, elapsed)
}

func directorySize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

@LibraryActor func measureLoads(_ bytes: Data) throws -> (samples: Samples, id: String, slides: Int) {
    var loads = Samples()
    var id = ""
    var slides = 0
    for _ in 0..<7 {
        let (document, ms) = try measure { try TypedDocument<Presentation>(data: bytes) }
        loads.record(ms)
        id = document.value.id
        slides = document.value.slides.count
    }
    return (loads, id, slides)
}

@LibraryActor func measureForks(_ bytes: Data) throws -> Samples {
    let canonical = try TypedDocument<Presentation>(data: bytes)
    var forks = Samples()
    for _ in 0..<7 {
        let (_, ms) = measure { canonical.document.fork() }
        forks.record(ms)
    }
    return forks
}

@LibraryActor func footprintPerLoad(_ bytes: Data, held: Int) throws -> Double {
    let beforeLoads = physicalFootprint()
    var loaded: [TypedDocument<Presentation>] = []
    for _ in 0..<held {
        loaded.append(try TypedDocument<Presentation>(data: bytes))
    }
    let perLoad = Double(physicalFootprint() - beforeLoads) / Double(held)
    withExtendedLifetime(loaded.count) {}
    return perLoad
}

@LibraryActor func bigDeckBytes() throws -> Data {
    try TypedDocument(makeBigDeck()).save()
}

@LibraryActor func seedDeck(_ bytes: Data, into engine: LibraryEngine) throws {
    _ = try engine.save(try TypedDocument<Presentation>(data: bytes))
}

@MainActor func measureFork(at root: URL) async throws {
    let bytes = if let deckPath { try Data(contentsOf: URL(fileURLWithPath: deckPath)) } else { try await bigDeckBytes() }
    let (loads, id, slides) = try await measureLoads(bytes)
    let engine = LibraryEngine(rootURL: root.appendingPathComponent("editor", isDirectory: true))
    _ = try await engine.bootstrap()
    try await seedDeck(bytes, into: engine)
    var checkouts = Samples()
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        let checkout = try await engine.checkout(Presentation.self, id: id)
        checkouts.record(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        await engine.release(token: checkout.token)
    }
    let forks = try await measureForks(bytes)

    let held = 8
    let beforeForks = physicalFootprint()
    var sessions: [EditorCheckout<Presentation>] = []
    for _ in 0..<held {
        sessions.append(try await engine.checkout(Presentation.self, id: id))
    }
    let perFork = Double(physicalFootprint() - beforeForks) / Double(held)
    let perLoad = try await footprintPerLoad(bytes, held: held)

    print(String(format: "fork: deck    %d slides, %.0f KB on disk", slides, Double(bytes.count) / 1024))
    print("fork: load    \(loads.summary())")
    print("fork: fork    \(forks.summary())")
    print("fork: checkout \(checkouts.summary())")
    print(String(
        format: "fork: memory  %.0f KB per fork, %.0f KB per load (%d of each held)",
        perFork / 1024, perLoad / 1024, held))
    print(String(format: "fork: ratio   checkout p50 / load p50 = %.3f", checkouts.percentile(0.5) / loads.percentile(0.5)))
    withExtendedLifetime(sessions.count) {}
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mxu-library-bench-\(ProcessInfo.processInfo.processIdentifier)")

@MainActor func cleanUp() {
    if keepLibrary {
        print("\nlibrary kept at \(root.path)")
    } else {
        try? FileManager.default.removeItem(at: root)
    }
}

if forkOnly {
    do {
        try await measureFork(at: root)
        cleanUp()
        exit(0)
    } catch {
        print("benchmark failed: \(error)")
        cleanUp()
        exit(2)
    }
}

print("library-bench — \(songCount) songs, \(editCount) sampled edits")
print("root: \(root.path)\n")

@LibraryActor func measureLibrary(at root: URL, songCount: Int, editCount: Int) throws -> (scoped: Samples, sustained: Samples) {
    var rng = SplitMix64(state: rngSeed)
    let library = try Library(rootURL: root)

    var totalSlides = 0
    let (_, populateMs) = try measure {
        for t in 1...20 {
            try library.create(Theme(
                id: "theme-\(t)", name: "Theme \(t)", fontFamily: "Helvetica Neue",
                fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000"
            ))
        }
        for w in 1...52 {
            let items = (0..<5).map { i in
                ServiceItem(
                    id: "svc\(w)-item\(i)", itemKind: .presentation,
                    name: "Song \(i)", refId: "song-\(Int.random(in: 1...songCount, using: &rng))"
                )
            }
            try library.create(Service(id: "svc-\(w)", name: "Sunday Week \(w)", serviceDate: "2026-W\(w)", items: items))
        }
        for n in 1...songCount {
            let song = makeSong(number: n, using: &rng)
            totalSlides += song.slides.count
            try library.create(song)
        }
    }
    let librarySize = directorySize(root)
    print(String(
        format: "populate      %5d docs (%d slides)      %8.0fms   (%.2fms/doc, %.1f MB on disk)",
        songCount + 72, totalSlides, populateMs, populateMs / Double(songCount + 72),
        Double(librarySize) / 1_048_576
    ))

    let (_, reopenMs) = try measure { _ = try Library(rootURL: root) }
    print(String(format: "open          existing index               %8.2fms", reopenMs))
    let (_, rebuildMs) = try measure { try library.rebuildIndex() }
    print(String(format: "rebuild index %5d docs decoded            %8.0fms", songCount + 72, rebuildMs))

    var searchSamples = Samples()
    for opener in titleOpeners {
        let (_, ms) = try measure { _ = try library.index.search(String(opener.prefix(4)).lowercased()) }
        searchSamples.record(ms)
    }
    print("search        \(searchSamples.summary())")

    var openSamples = Samples()
    var scopedSamples = Samples()
    var fullSamples = Samples()
    var persistSamples = Samples()
    var undoSamples = Samples()
    for _ in 0..<editCount {
        let id = "song-\(Int.random(in: 1...songCount, using: &rng))"
        let (doc, openMs) = try measure { try library.open(Presentation.self, id: id) }
        openSamples.record(openMs)

        let slideIndex = Int.random(in: 0..<doc.value.slides.count, using: &rng)
        let newLine = lyricLines.randomElement(using: &rng)!
        let path = [
            AnyCodingKey("slides"), AnyCodingKey(UInt64(slideIndex)),
            AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
        ]
        let (_, scopedMs) = try measure {
            try doc.update(\.slides[slideIndex].objects[0], at: path) { $0.text += "\n" + newLine }
        }
        scopedSamples.record(scopedMs)

        let (_, fullMs) = try measure {
            try doc.update { $0.slides[slideIndex].name += " *" }
        }
        fullSamples.record(fullMs)

        let (_, persistMs) = try measure { try library.save(doc) }
        persistSamples.record(persistMs)

        let (_, undoMs) = try measure { try doc.undo() }
        undoSamples.record(undoMs)
    }
    print("edit: open    \(openSamples.summary())")
    print("apply scoped  \(scopedSamples.summary())")
    print("apply full    \(fullSamples.summary())")
    print("edit: persist \(persistSamples.summary())")
    print("edit: undo    \(undoSamples.summary())")

    let heavy = try library.open(Presentation.self, id: "song-1")
    var sustained = Samples()
    for i in 0..<100 {
        let slideIndex = i % heavy.value.slides.count
        let path = [
            AnyCodingKey("slides"), AnyCodingKey(UInt64(slideIndex)),
            AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
        ]
        let (_, ms) = try measure {
            try heavy.update(\.slides[slideIndex].objects[0], at: path) { $0.text += " \(i)" }
        }
        sustained.record(ms)
    }
    var undoWalk = Samples()
    while heavy.canUndo {
        let (_, ms) = try measure { try heavy.undo() }
        undoWalk.record(ms)
    }
    print("sustained     \(sustained.summary())")
    print("undo walk     \(undoWalk.summary())")

    return (scopedSamples, sustained)
}

do {
    let (scopedSamples, sustained) = try await measureLibrary(at: root, songCount: songCount, editCount: editCount)

    print("")
    try await measureFork(at: root)

    let gate = 16.0
    let scopedP95 = scopedSamples.percentile(0.95)
    let sustainedP95 = sustained.percentile(0.95)
    let pass = scopedP95 < gate && sustainedP95 < gate
    print(String(
        format: "\nGATE edits apply <%.0fms: scoped p95 %.2fms, sustained p95 %.2fms → %@",
        gate, scopedP95, sustainedP95, pass ? "PASS" : "FAIL"
    ))
    cleanUp()
    exit(pass ? 0 : 1)
} catch {
    print("benchmark failed: \(error)")
    cleanUp()
    exit(2)
}
