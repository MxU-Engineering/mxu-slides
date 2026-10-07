import Testing
@testable import PresenterCore

struct StreamAudioSourceTests {
    private func preset() -> StreamRecordPreset {
        StreamRecordPreset(
            id: "p", name: "P", destinations: [],
            audioInputUid: "legacy-uid", audioIncludesProgram: true,
            audioInputId: "in-1", audioMixId: "mix-1")
    }

    @Test func programClearsEveryAudioField() {
        var value = preset()
        StreamAudioSource.program.apply(to: &value, includingProgram: true)
        #expect(value.audioMixId == nil)
        #expect(value.audioInputId == nil)
        #expect(value.audioInputUid == nil)
        #expect(value.audioIncludesProgram == nil)
    }

    @Test func mixReplacesInputAndCarriesAddProgram() {
        var value = preset()
        StreamAudioSource.mix("stream").apply(to: &value, includingProgram: true)
        #expect(value.audioMixId == "stream")
        #expect(value.audioInputId == nil)
        #expect(value.audioInputUid == nil)
        #expect(value.audioIncludesProgram == true)
    }

    @Test func inputReplacesMixWithoutAddProgram() {
        var value = preset()
        StreamAudioSource.input("pulpit").apply(to: &value, includingProgram: false)
        #expect(value.audioMixId == nil)
        #expect(value.audioInputId == "pulpit")
        #expect(value.audioInputUid == nil)
        #expect(value.audioIncludesProgram == nil)
    }

    @Test func storageValueRoundTrips() {
        for source in [StreamAudioSource.program, .mix("main"), .input("a:b")] {
            #expect(StreamAudioSource(storageValue: source.storageValue) == source)
        }
        #expect(StreamAudioSource(storageValue: "mix:") == .program)
        #expect(StreamAudioSource(storageValue: "junk") == .program)
    }
}
