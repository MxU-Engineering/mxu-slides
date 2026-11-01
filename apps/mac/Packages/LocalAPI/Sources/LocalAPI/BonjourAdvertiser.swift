import Foundation
import dnssd

public final class BonjourAdvertiser: @unchecked Sendable {
    public static let serviceType = "_mxu-slides._tcp"

    public static let stationKey = "stationHexId"
    public static let teamKey = "teamHexId"

    private let queue = DispatchQueue(label: "localapi.bonjour")
    private var serviceRef: DNSServiceRef?

    public init() {}

    deinit {
        stop()
    }

    public func start(name: String, port: UInt16, txt: [String: String] = [:]) {
        stop()
        var ref: DNSServiceRef?
        let record = Self.txtRecord(txt)
        let error = record.withUnsafeBytes { bytes in
            DNSServiceRegister(
                &ref, 0, 0,
                name, Self.serviceType, nil, nil,
                port.bigEndian, UInt16(record.count), bytes.baseAddress, nil, nil
            )
        }
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        serviceRef = ref
    }

    public func update(txt: [String: String]) {
        guard let ref = serviceRef else { return }
        let record = Self.txtRecord(txt)
        _ = record.withUnsafeBytes { bytes in
            DNSServiceUpdateRecord(ref, nil, 0, UInt16(record.count), bytes.baseAddress, 0)
        }
    }

    public func stop() {
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
    }

    static func txtRecord(_ pairs: [String: String]) -> Data {
        var data = Data()
        for key in pairs.keys.sorted() {
            let entry = Data("\(key)=\(pairs[key] ?? "")".utf8).prefix(255)
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data.isEmpty ? Data([0]) : data
    }

    static func txt(for info: APIServerInfo) -> [String: String] {
        var pairs: [String: String] = [:]
        pairs[stationKey] = info.stationHexId
        pairs[teamKey] = info.teamHexId
        return pairs
    }
}
