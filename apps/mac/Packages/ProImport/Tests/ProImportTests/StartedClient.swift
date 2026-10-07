import Foundation
import PresenterCore

@MainActor func started(_ library: Library) async throws -> LibraryClient {
    let client = LibraryClient(rootURL: await library.store.rootURL)
    try await client.start().value
    return client
}

@LibraryActor func onLibraryActor<T: Sendable>(_ body: @LibraryActor () throws -> T) throws -> T {
    try body()
}
