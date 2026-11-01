import Foundation
import Network

public final class BonjourBrowser: @unchecked Sendable {
    public struct Peer: Sendable, Hashable {
        public var name: String
        public var stationHexId: String

        public var stationName: String?
        public var host: String
        public var port: UInt16
    }

    struct Candidate: Equatable {
        var name: String
        var stationHexId: String
        var stationName: String?
    }

    static let resolveTimeout: TimeInterval = 5

    private let ownStationHexId: String?
    private let queue = DispatchQueue(label: "localapi.bonjour.browse")
    private var browser: NWBrowser?

    private var resolved: [String: Peer] = [:]
    private var resolving: [String: NWConnection] = [:]
    private var continuation: AsyncStream<[Peer]>.Continuation?

    public init(ownStationHexId: String?) {
        self.ownStationHexId = ownStationHexId
    }

    deinit {
        browser?.cancel()
    }

    public func start() -> AsyncStream<[Peer]> {
        let (stream, continuation) = AsyncStream<[Peer]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        queue.async { [self] in
            stopOnQueue()
            self.continuation = continuation
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: BonjourAdvertiser.serviceType, domain: nil),
                using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.update(results)
            }
            self.browser = browser
            browser.start(queue: queue)
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        return stream
    }

    public func stop() {
        queue.async { [self] in stopOnQueue() }
    }

    private func stopOnQueue() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        resolved = [:]
        continuation?.finish()
        continuation = nil
    }

    static func candidate(
        name: String, txt: [String: String], ownStationHexId: String?
    ) -> Candidate? {
        guard let station = txt[BonjourAdvertiser.stationKey], !station.isEmpty,
              station != ownStationHexId
        else { return nil }
        return Candidate(name: name, stationHexId: station, stationName: txt[BonjourAdvertiser.nameKey].flatMap { $0.isEmpty ? nil : $0 })
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let record) = result.metadata,
                  let candidate = Self.candidate(
                    name: name, txt: record.dictionary, ownStationHexId: ownStationHexId)
            else { continue }
            seen.insert(name)
            let held = resolved[name]
            if held?.stationHexId != candidate.stationHexId || held?.stationName != candidate.stationName, resolving[name] == nil {
                resolve(result.endpoint, candidate)
            }
        }
        for name in Set(resolved.keys).subtracting(seen) { resolved[name] = nil }
        for (name, connection) in resolving where !seen.contains(name) {
            connection.cancel()
            resolving[name] = nil
        }
        publish()
    }

    private func resolve(_ endpoint: NWEndpoint, _ candidate: Candidate) {

        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        resolving[candidate.name] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    self.resolved[candidate.name] = Peer(
                        name: candidate.name, stationHexId: candidate.stationHexId, stationName: candidate.stationName,
                        host: Self.text(host), port: port.rawValue)
                    self.publish()
                }
                connection.cancel()
            case .failed, .cancelled:
                if self.resolving[candidate.name] === connection { self.resolving[candidate.name] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.resolveTimeout) { [weak connection] in
            connection?.cancel()
        }
    }

    private func publish() {
        continuation?.yield(resolved.values.sorted { ($0.name, $0.stationHexId) < ($1.name, $1.stationHexId) })
    }

    static func text(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%")[0]
        case .ipv6(let address):
            return "[\("\(address)".components(separatedBy: "%")[0])]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}
