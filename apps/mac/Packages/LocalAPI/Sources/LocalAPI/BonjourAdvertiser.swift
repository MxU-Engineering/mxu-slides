import Foundation
import dnssd

public final class BonjourAdvertiser: @unchecked Sendable {
    public static let serviceType = "_mxu-slides._tcp"

    private let queue = DispatchQueue(label: "localapi.bonjour")
    private var serviceRef: DNSServiceRef?

    public init() {}

    deinit {
        stop()
    }

    public func start(name: String, port: UInt16) {
        stop()
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(
            &ref, 0, 0,
            name, Self.serviceType, nil, nil,
            port.bigEndian, 0, nil, nil, nil
        )
        guard error == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        serviceRef = ref
    }

    public func stop() {
        if let ref = serviceRef {
            DNSServiceRefDeallocate(ref)
            serviceRef = nil
        }
    }
}
