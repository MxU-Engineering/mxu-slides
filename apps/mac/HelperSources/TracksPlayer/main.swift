import AudioEngine
import Foundation

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--socket"), flag + 1 < arguments.count else { exit(64) }
let server = TracksPlayerServer(socketPath: arguments[flag + 1], engine: MultitrackEngine())
do {

    guard try server.start() else { exit(0) }
} catch {
    exit(1)
}
dispatchMain()
