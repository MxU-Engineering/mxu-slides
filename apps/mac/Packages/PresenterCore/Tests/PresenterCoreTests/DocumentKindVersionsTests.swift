import Observation
import Testing
@testable import PresenterCore

@Test func bumpMovesOnlyItsOwnKind() {
    for bumped in DocumentKind.allCases {
        let versions = DocumentKindVersions()
        versions.bump(bumped)
        for kind in DocumentKind.allCases {
            #expect(versions[kind] == (kind == bumped ? 1 : 0))
        }
    }
}

@Test func bumpAllMovesEveryKind() {
    let versions = DocumentKindVersions()
    versions.bumpAll()
    for kind in DocumentKind.allCases {
        #expect(versions[kind] == 1)
    }
}

@Test func untrackedReadsTheEpochWithoutSubscribing() {
    final class Flag: @unchecked Sendable { var fired = false }
    let versions = DocumentKindVersions()
    versions.bump(.presentation)
    versions.bumpAll()
    for kind in DocumentKind.allCases {
        #expect(versions.untracked(kind) == versions[kind])
    }
    let flag = Flag()
    withObservationTracking { _ = versions.untracked(.presentation) } onChange: { flag.fired = true }
    versions.bump(.presentation)
    #expect(!flag.fired)
    withObservationTracking { _ = versions[.presentation] } onChange: { flag.fired = true }
    versions.bump(.presentation)
    #expect(flag.fired)
}
