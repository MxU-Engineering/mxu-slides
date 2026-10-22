import Foundation

public struct MultitrackRouting: Codable, Equatable, Sendable {
    public struct Channel: Codable, Equatable, Sendable {
        public var id: String

        public var gain: Float

        public var pan: Float
        public var muted: Bool

        public var sends: [String: Float]

        public var mono: Bool

        public init(
            id: String, gain: Float = 1, pan: Float = 0, muted: Bool = false, sends: [String: Float] = [:],
            mono: Bool = false
        ) {
            self.id = id; self.gain = gain; self.pan = pan; self.muted = muted; self.sends = sends; self.mono = mono
        }

        enum CodingKeys: String, CodingKey { case id, gain, pan, muted, sends, mono }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            gain = try c.decode(Float.self, forKey: .gain)
            pan = try c.decode(Float.self, forKey: .pan)
            muted = try c.decode(Bool.self, forKey: .muted)
            sends = try c.decode([String: Float].self, forKey: .sends)

            mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false
        }
    }

    public struct Mix: Codable, Equatable, Sendable {
        public var id: String
        public var gain: Float
        public var muted: Bool

        public var outputs: [Output]

        public var feedSlot: Int?

        public init(id: String, gain: Float = 1, muted: Bool = false, outputs: [Output] = [], feedSlot: Int? = nil) {
            self.id = id; self.gain = gain; self.muted = muted; self.outputs = outputs; self.feedSlot = feedSlot
        }
    }

    public struct Output: Codable, Equatable, Sendable {
        public var channels: [Int]
        public var level: Float

        public var delayMs: Double

        public init(channels: [Int], level: Float = 1, delayMs: Double = 0) {
            self.channels = channels; self.level = level; self.delayMs = delayMs
        }

        enum CodingKeys: String, CodingKey { case channels, level, delayMs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            channels = try c.decode([Int].self, forKey: .channels)
            level = try c.decode(Float.self, forKey: .level)
            delayMs = try c.decodeIfPresent(Double.self, forKey: .delayMs) ?? 0
        }
    }

    public var channels: [Channel]
    public var mixes: [Mix]

    public var trim: Float
    public var muted: Bool

    public init(channels: [Channel] = [], mixes: [Mix] = [], trim: Float = 1, muted: Bool = false) {
        self.channels = channels; self.mixes = mixes; self.trim = trim; self.muted = muted
    }

    public var feedMixIds: [String] { mixes.filter { $0.feedSlot != nil }.map(\.id) }

    func delayFrames(deviceChannels: Int, sampleRate: Double) -> [Int] {
        var frames = [Int](repeating: 0, count: deviceChannels)
        for output in mixes.flatMap(\.outputs) where output.delayMs > 0 {
            let delay = Int((min(output.delayMs, 2000) / 1000 * sampleRate).rounded())
            for channel in output.channels where channel >= 0 && channel < deviceChannels {
                frames[channel] = max(frames[channel], delay)
            }
        }
        return frames
    }
}

public extension MultitrackRouting {

    struct ConsoleMix: Equatable, Sendable {
        public var id: String
        public var gain: Float
        public var muted: Bool
        public var landings: [(deviceUID: String, output: Output)]

        public init(id: String, gain: Float = 1, muted: Bool = false, landings: [(deviceUID: String, output: Output)]) {
            self.id = id; self.gain = gain; self.muted = muted; self.landings = landings
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.gain == rhs.gain && lhs.muted == rhs.muted
                && lhs.landings.map(\.deviceUID) == rhs.landings.map(\.deviceUID)
                && lhs.landings.map(\.output) == rhs.landings.map(\.output)
        }
    }

    static func resolve(
        channels: [Channel], mixes: [ConsoleMix], trim: Float, muted: Bool, fallbackDevice: String
    ) -> (routing: MultitrackRouting, deviceUID: String) {
        let reached = Set(channels.filter { !$0.muted }.flatMap { $0.sends.filter { $0.value > 0 }.keys })
        var tally: [String: Int] = [:]
        for mix in mixes where reached.contains(mix.id) && !mix.muted {
            for landing in mix.landings { tally[landing.deviceUID, default: 0] += 1 }
        }
        let device = tally.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? fallbackDevice
        let routing = MultitrackRouting(
            channels: channels,
            mixes: mixes.map { mix in
                Mix(id: mix.id, gain: mix.gain, muted: mix.muted,
                    outputs: mix.landings.filter { $0.deviceUID == device }.map(\.output))
            },
            trim: trim, muted: muted)
        return (routing, device)
    }

    var reachedMixIds: Set<String> {
        guard !muted else { return [] }
        return Set(channels.filter { !$0.muted }.flatMap { $0.sends.filter { $0.value > 0 }.keys })
    }

    static func assignSlots(_ wanted: Set<String>, held: [String: Int]) -> [String: Int] {
        var slots = held
        for mix in wanted.sorted() where slots[mix] == nil {
            let taken = Set(slots.values)
            if let free = (0 ..< TracksShare.slots).first(where: { !taken.contains($0) }) {
                slots[mix] = free
            } else if let idle = slots.filter({ !wanted.contains($0.key) }).min(by: { $0.value < $1.value }) {
                slots[idle.key] = nil
                slots[mix] = idle.value
            }
        }
        return slots
    }

    func feeding(_ wanted: Set<String>, slots: [String: Int]) -> MultitrackRouting {
        var routing = self
        for index in routing.mixes.indices {
            let id = routing.mixes[index].id
            routing.mixes[index].feedSlot = wanted.contains(id) ? slots[id] : nil
        }
        return routing
    }
}

struct MultitrackMatrix: Sendable {
    let stems: Int
    let deviceChannels: Int
    let feedMixIds: [String]

    let feedSlots: [Int]
    var destinations: Int { deviceChannels + 2 * feedMixIds.count }
    private(set) var gains: [Float]

    func gain(stem: Int, side: Int, destination: Int) -> Float {
        gains[(stem * 2 + side) * destinations + destination]
    }

    init(_ routing: MultitrackRouting, stemChannels: [String], deviceChannels: Int) {
        stems = stemChannels.count
        self.deviceChannels = deviceChannels
        feedMixIds = routing.feedMixIds
        feedSlots = routing.mixes.compactMap(\.feedSlot)
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

            let fold: [[Float]] = channel.mono ? [[0.5, 0.5], [0.5, 0.5]] : [[1, 0], [0, 1]]

            func land(_ side: Int, _ destination: Int, _ level: Float) {
                for from in 0 ..< 2 where fold[from][side] != 0 {
                    add(stem, from, destination, fold[from][side] * sides[side] * level, destinations)
                }
            }
            for (mixId, level) in channel.sends {
                guard let mix = mixes[mixId], !mix.muted else { continue }
                let reach = level * mix.gain
                for output in mix.outputs {
                    switch output.channels.count {
                    case 1 where output.channels[0] < deviceChannels:

                        for side in 0 ..< 2 { land(side, output.channels[0], reach * output.level * 0.5) }
                    case 2 where output.channels.allSatisfy({ $0 < deviceChannels }):
                        for side in 0 ..< 2 { land(side, output.channels[side], reach * output.level) }
                    default:
                        continue
                    }
                }
                if let feed = feedMixIds.firstIndex(of: mixId) {
                    for side in 0 ..< 2 { land(side, deviceChannels + feed * 2 + side, reach) }
                }
            }
        }
    }

    private mutating func add(_ stem: Int, _ side: Int, _ destination: Int, _ value: Float, _ destinations: Int) {
        gains[(stem * 2 + side) * destinations + destination] += value
    }
}
