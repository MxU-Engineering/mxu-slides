import Foundation

public struct MultitrackRouting: Codable, Equatable, Sendable {
    public struct Channel: Codable, Equatable, Sendable {
        public var id: String

        public var gain: Float

        public var pan: Float
        public var muted: Bool

        public var sends: [String: Float]

        public init(id: String, gain: Float = 1, pan: Float = 0, muted: Bool = false, sends: [String: Float] = [:]) {
            self.id = id; self.gain = gain; self.pan = pan; self.muted = muted; self.sends = sends
        }
    }

    public struct Mix: Codable, Equatable, Sendable {
        public var id: String
        public var gain: Float
        public var muted: Bool

        public var outputs: [Output]

        public var feeds: Bool

        public init(id: String, gain: Float = 1, muted: Bool = false, outputs: [Output] = [], feeds: Bool = false) {
            self.id = id; self.gain = gain; self.muted = muted; self.outputs = outputs; self.feeds = feeds
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public var channels: [Int]
        public var level: Float

        public init(channels: [Int], level: Float = 1) {
            self.channels = channels; self.level = level
        }
    }

    public var channels: [Channel]
    public var mixes: [Mix]

    public var trim: Float
    public var muted: Bool

    public init(channels: [Channel] = [], mixes: [Mix] = [], trim: Float = 1, muted: Bool = false) {
        self.channels = channels; self.mixes = mixes; self.trim = trim; self.muted = muted
    }

    public var feedMixIds: [String] { mixes.filter(\.feeds).map(\.id) }
}

struct MultitrackMatrix: Sendable {
    let stems: Int
    let deviceChannels: Int
    let feedMixIds: [String]
    var destinations: Int { deviceChannels + 2 * feedMixIds.count }
    private(set) var gains: [Float]

    func gain(stem: Int, side: Int, destination: Int) -> Float {
        gains[(stem * 2 + side) * destinations + destination]
    }

    init(_ routing: MultitrackRouting, stemChannels: [String], deviceChannels: Int) {
        stems = stemChannels.count
        self.deviceChannels = deviceChannels
        feedMixIds = routing.feedMixIds
        let destinations = deviceChannels + 2 * feedMixIds.count
        gains = [Float](repeating: 0, count: stemChannels.count * 2 * destinations)
        guard !routing.muted else { return }
        let channels = Dictionary(routing.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mixes = Dictionary(routing.mixes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (stem, channelId) in stemChannels.enumerated() {
            guard let channel = channels[channelId], !channel.muted else { continue }
            let base = routing.trim * channel.gain
            let pan = min(max(channel.pan, -1), 1)
            let sides = [base * min(1, 1 - pan), base * min(1, 1 + pan)]
            for (mixId, level) in channel.sends {
                guard let mix = mixes[mixId], !mix.muted else { continue }
                let reach = level * mix.gain
                for output in mix.outputs {
                    switch output.channels.count {
                    case 1 where output.channels[0] < deviceChannels:

                        for side in 0 ..< 2 {
                            add(stem, side, output.channels[0], sides[side] * reach * output.level * 0.5, destinations)
                        }
                    case 2 where output.channels.allSatisfy({ $0 < deviceChannels }):
                        for side in 0 ..< 2 {
                            add(stem, side, output.channels[side], sides[side] * reach * output.level, destinations)
                        }
                    default:
                        continue
                    }
                }
                if let feed = feedMixIds.firstIndex(of: mixId) {
                    for side in 0 ..< 2 {
                        add(stem, side, deviceChannels + feed * 2 + side, sides[side] * reach, destinations)
                    }
                }
            }
        }
    }

    private mutating func add(_ stem: Int, _ side: Int, _ destination: Int, _ value: Float, _ destinations: Int) {
        gains[(stem * 2 + side) * destinations + destination] += value
    }
}
