import Foundation
import Testing
@testable import PresenterCore

@Test func legacyDeviceEntryDecodesWithDefaults() throws {

    let data = Data(#"[{"uid":123,"name":"IAC Bus"}]"#.utf8)
    let entries = try JSONDecoder().decode([MIDIDeviceEntry].self, from: data)
    let entry = try #require(entries.first)
    #expect(entry.isEnabled)
    #expect(entry.effectiveDirection == .output)
    #expect(entry.wantsOutput)
    #expect(!entry.wantsInput)
}

@Test func outputTargetsDistinguishBroadcastFromSilence() {

    #expect([MIDIDeviceEntry]().outputTargetUIDs == nil)
    let silenced = [
        MIDIDeviceEntry(uid: 1, name: "A", enabled: false),
        MIDIDeviceEntry(uid: 2, name: "B", direction: .input),
    ]
    #expect(silenced.outputTargetUIDs == [])
    let mixed = [
        MIDIDeviceEntry(uid: 1, name: "A"),
        MIDIDeviceEntry(uid: 2, name: "B", direction: .both),
        MIDIDeviceEntry(uid: 3, name: "C", enabled: false),
    ]
    #expect(mixed.outputTargetUIDs == [1, 2])
}

@Test func inputSourcesUseSourceUidAndNeverBroadcast() {
    #expect([MIDIDeviceEntry]().inputSourceUIDs.isEmpty)
    let entries = [
        MIDIDeviceEntry(uid: 1, name: "Keys", sourceUid: 11, direction: .both),
        MIDIDeviceEntry(uid: 2, name: "Pad", direction: .input),
        MIDIDeviceEntry(uid: 3, name: "Off", sourceUid: 33, enabled: false, direction: .input),
        MIDIDeviceEntry(uid: 4, name: "OutOnly"),
    ]
    #expect(entries.inputSourceUIDs == [11, 2])
}

@Test func connectedStateChecksTheEndpointsTheDirectionNeeds() {
    let both = MIDIDeviceEntry(uid: 1, name: "Keys", sourceUid: 11, direction: .both)
    #expect(both.isConnected(destinations: [1], sources: [11]))
    #expect(!both.isConnected(destinations: [1], sources: []))
    let output = MIDIDeviceEntry(uid: 1, name: "Keys", sourceUid: 11)
    #expect(output.isConnected(destinations: [1], sources: []))
}

@Test func mapDefaultsWearProPresenterNumbers() {
    let map = MIDICommandMap()
    #expect(map.note(for: .clearAll) == 0)
    #expect(map.note(for: .clearMedia) == 2)
    #expect(map.note(for: .nextSlide) == 12)
    #expect(map.note(for: .triggerSlide) == 19)
    #expect(map.note(for: .triggerActionCombo) == 29)
    #expect(map.note(for: .clearAlerts) == 28)

    #expect(map.note(for: .selectService) == 17)
    #expect(map.note(for: .selectServiceItem) == 18)
    #expect(map.note(for: .selectMediaPlaylist) == 20)
    #expect(map.note(for: .triggerMedia) == 21)
    #expect(map.note(for: .selectAudioPlaylist) == 22)
    #expect(map.note(for: .triggerAudio) == 23)
    #expect(map.note(for: .toggleOverlay) == 24)
    #expect(map.note(for: .selectOverlayFolder) == 32)

    #expect(map.note(for: .selectActionComboFolder) == 31)

    #expect(map.note(for: .fireAlert) == 33)
    #expect(map.note(for: .clearSignage) == 34)

    let notes = MIDICommand.allCases.map(\.defaultNote)
    #expect(Set(notes).count == notes.count)

    #expect(MIDICommand.allCases.filter(\.usesVelocityIndex).count == 15)
}

@Test func deviceChannelFilterDefaultsToOmni() throws {

    let legacy = try JSONDecoder().decode(
        [MIDIDeviceEntry].self,
        from: Data(#"[{"uid":1,"name":"Keys","direction":"input"}]"#.utf8)
    )
    #expect(legacy[0].channel == nil)
    #expect(legacy[0].acceptsChannel(ofStatus: 0x90))
    #expect(legacy[0].acceptsChannel(ofStatus: 0x9F))

    let pinned = MIDIDeviceEntry(uid: 1, name: "Keys", direction: .input, channel: 3)
    #expect(pinned.acceptsChannel(ofStatus: 0x92))
    #expect(!pinned.acceptsChannel(ofStatus: 0x90))
}

@Test func mapStoresOnlyOverridesAndResolvesByNote() throws {
    var map = MIDICommandMap()
    map.setNote(64, for: .clearAll)
    #expect(map.notes == ["clearAll": 64])
    #expect(map.command(forNote: 64) == .clearAll)
    #expect(map.command(forNote: 0) == nil)

    map.setNote(MIDICommand.clearAll.defaultNote, for: .clearAll)
    #expect(map.notes.isEmpty)

    map.setNote(100, for: .nextSlide)
    map.channel = 5
    let decoded = try JSONDecoder().decode(
        MIDICommandMap.self, from: JSONEncoder().encode(map))
    #expect(decoded == map)
}

@Test func resolveFiresOnNoteOnOnly() throws {
    let map = MIDICommandMap()

    let hit = try #require(map.resolve(status: 0x90, data1: 12, data2: 100))
    #expect(hit.command == .nextSlide)
    #expect(hit.velocity == 100)

    #expect(map.resolve(status: 0x90, data1: 12, data2: 0) == nil)
    #expect(map.resolve(status: 0x80, data1: 12, data2: 100) == nil)
    #expect(map.resolve(status: 0xB0, data1: 12, data2: 100) == nil)

    #expect(map.resolve(status: 0x90, data1: 99, data2: 100) == nil)
}

@Test func resolveHonorsTheChannelFilter() {
    var map = MIDICommandMap()
    map.channel = 3
    #expect(map.resolve(status: 0x92, data1: 12, data2: 1)?.command == .nextSlide)
    #expect(map.resolve(status: 0x90, data1: 12, data2: 1) == nil)
    map.channel = nil
    #expect(map.resolve(status: 0x9F, data1: 12, data2: 1)?.command == .nextSlide)
}

@Test func noteNamesMatchProPresenterOctaves() {
    #expect(MIDICommandMap.noteName(0) == "C-2")
    #expect(MIDICommandMap.noteName(12) == "C-1")
    #expect(MIDICommandMap.noteName(19) == "G-1")
    #expect(MIDICommandMap.noteName(30) == "F#0")
    #expect(MIDICommandMap.noteName(127) == "G8")
}

@Test func channelMessageParserWalksPacketsLikeAWire() {

    let plain = MIDIParse.channelMessages(in: [0x90, 12, 100, 0x80, 12, 0])
    #expect(plain == [
        MIDIParse.ChannelMessage(status: 0x90, data1: 12, data2: 100),
        MIDIParse.ChannelMessage(status: 0x80, data1: 12, data2: 0),
    ])

    let running = MIDIParse.channelMessages(in: [0x90, 12, 100, 13, 90])
    #expect(running.count == 2)
    #expect(running[1] == MIDIParse.ChannelMessage(status: 0x90, data1: 13, data2: 90))

    let clocked = MIDIParse.channelMessages(in: [0xF8, 0x90, 0xF8, 12, 100, 0xF8])
    #expect(clocked == [MIDIParse.ChannelMessage(status: 0x90, data1: 12, data2: 100)])

    let mixed = MIDIParse.channelMessages(
        in: [0xF0, 1, 2, 3, 0xF7, 0xC0, 5, 0x90, 12, 100])
    #expect(mixed == [
        MIDIParse.ChannelMessage(status: 0xC0, data1: 5, data2: 0),
        MIDIParse.ChannelMessage(status: 0x90, data1: 12, data2: 100),
    ])

    #expect(MIDIParse.channelMessages(in: [0x90, 12]).isEmpty)
}

@Test func explicitBindingWinsEvenWhenEndpointAbsent() {
    let device = MIDIDevice(id: "d1", name: "Lyrics MIDI")
    let resolved = MIDIDeviceResolver.resolve(
        devices: [device],
        bindings: ["d1": MIDIDeviceBinding(destinationUID: 99, sourceUID: 98)],
        destinations: [MIDIEndpoint(uid: 5, name: "Lyrics MIDI")],
        sources: []
    )

    #expect(resolved[0].destinationUID == 99)
    #expect(resolved[0].sourceUID == 98)
}

@Test func autoBindMatchesEndpointNamesThenItemName() {

    let imported = MIDIDevice(
        id: "d1", name: "Lyrics MIDI",
        sourceNames: ["Lyrics Strip"], destinationNames: ["Bus 1"]
    )

    let handmade = MIDIDevice(id: "d2", name: "Bus 1")
    let destinations = [MIDIEndpoint(uid: 1, name: "bus 1"), MIDIEndpoint(uid: 2, name: "Other")]
    let sources = [MIDIEndpoint(uid: 3, name: "Lyrics Strip")]
    let resolved = MIDIDeviceResolver.resolve(
        devices: [imported, handmade], bindings: [:],
        destinations: destinations, sources: sources
    )
    #expect(resolved[0].destinationUID == 1)
    #expect(resolved[0].sourceUID == 3)
    #expect(resolved[1].destinationUID == 1)
    #expect(resolved[1].sourceUID == nil)
}

@Test func resolvedItemsKeepBroadcastVersusSilenceAndDirections() {

    #expect([ResolvedMIDIDevice]().outputTargetUIDs == nil)
    let unbound = ResolvedMIDIDevice(device: MIDIDevice(id: "d1", name: "X"))
    #expect([unbound].outputTargetUIDs == Set())
    #expect([unbound].inputSourceUIDs == Set())

    var input = MIDIDevice(id: "d2", name: "Pad")
    input.direction = .input
    let bound = MIDIDeviceResolver.resolve(
        devices: [input], bindings: ["d2": MIDIDeviceBinding(destinationUID: 7, sourceUID: 8)],
        destinations: [], sources: []
    )
    #expect(bound.outputTargetUIDs == Set())  
    #expect(bound.inputSourceUIDs == [8])

    var disabled = MIDIDevice(id: "d3", name: "Off")
    disabled.enabled = false
    let off = MIDIDeviceResolver.resolve(
        devices: [disabled], bindings: ["d3": MIDIDeviceBinding(destinationUID: 9, sourceUID: 9)],
        destinations: [], sources: []
    )
    #expect(off.outputTargetUIDs == Set())
    #expect(off.inputSourceUIDs == Set())
}

@Test func discoveredMergesEndpointPairsByName() {

    let merged = MIDIDeviceResolver.discovered(
        destinations: [
            MIDIEndpoint(uid: 1, name: "Lightkey Output"),
            MIDIEndpoint(uid: 2, name: "Console"),
        ],
        sources: [
            MIDIEndpoint(uid: 3, name: "Console"),
            MIDIEndpoint(uid: 4, name: "Lightkey Input"),
        ]
    )
    #expect(merged.map(\.name) == ["Lightkey Output", "Console", "Lightkey Input"])
    #expect(merged[0].sourceUid == nil)
    #expect(merged[1].uid == 2)
    #expect(merged[1].sourceUid == 3)
    #expect(merged[2].sourceUid == 4)
    #expect(merged[2].direction == .input)
}

@Test func noteNamesSpeakLightkeysOctaveConvention() {
    #expect(MIDINote.name(0) == "C-2")
    #expect(MIDINote.name(1) == "C#-2")
    #expect(MIDINote.name(60) == "C3")
    #expect(MIDINote.name(127) == "G8")
    #expect(MIDINote.name(-5) == "C-2")   
    #expect(MIDINote.name(200) == "G8")
}

@Test func midiOutTargetResolvesThroughItemsAndNeverFallsBackToBroadcast() {
    var output = MIDIDevice(id: "lk", name: "Lightkey")
    output.direction = .output
    let items = MIDIDeviceResolver.resolve(
        devices: [output],
        bindings: ["lk": MIDIDeviceBinding(destinationUID: 7)],
        destinations: [MIDIEndpoint(uid: 7, name: "Lightkey Output")],
        sources: []
    )

    #expect(MIDIOutTarget.resolve(deviceId: nil, items: items) == .settingsSelection)
    #expect(MIDIOutTarget.resolve(deviceId: "", items: items) == .settingsSelection)
    #expect(MIDIOutTarget.resolve(deviceId: "lk", items: items) == .device(7))

    #expect(MIDIOutTarget.resolve(deviceId: "gone", items: items) == .skip("device missing"))
    var off = output
    off.enabled = false
    let offItems = [ResolvedMIDIDevice(device: off, destinationUID: 7)]
    #expect(MIDIOutTarget.resolve(deviceId: "lk", items: offItems) == .skip("device off"))
    var input = MIDIDevice(id: "lk", name: "Lightkey")
    input.direction = .input
    let inputItems = [ResolvedMIDIDevice(device: input, sourceUID: 3)]
    #expect(MIDIOutTarget.resolve(deviceId: "lk", items: inputItems) == .skip("device is input-only"))
    let unbound = [ResolvedMIDIDevice(device: output)]
    #expect(MIDIOutTarget.resolve(deviceId: "lk", items: unbound) == .skip("port not present"))
}

@Test func resolvedItemChannelFilterMatchesEntrySemantics() {
    var device = MIDIDevice(id: "d1", name: "X")
    device.channel = 2
    let resolved = ResolvedMIDIDevice(device: device)
    #expect(resolved.acceptsChannel(ofStatus: 0x91))   
    #expect(!resolved.acceptsChannel(ofStatus: 0x90))  
    #expect(ResolvedMIDIDevice(device: MIDIDevice(id: "d2", name: "Y")).acceptsChannel(ofStatus: 0x9F))
}
