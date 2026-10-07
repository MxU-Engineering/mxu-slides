import SwiftUI

struct AudioScrubBar: View {
    let player: AudioPlayer

    var showsTimes = false

    var body: some View {
        ScrubBar(
            elapsed: player.elapsed,
            duration: player.duration,
            isPlaying: player.isPlaying,
            showsTimes: showsTimes
        ) { seconds, _ in
            player.seek(to: seconds)
        }
    }
}

struct AudioTimecode: View {
    let player: AudioPlayer

    var body: some View {
        Text("\(Self.timecode(player.elapsed)) / \(Self.timecode(player.duration))")
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
