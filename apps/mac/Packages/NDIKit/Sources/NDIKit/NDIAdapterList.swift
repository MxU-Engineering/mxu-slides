import Foundation
import SystemConfiguration

public struct NDIAdapter: Equatable, Identifiable, Sendable {
    public let bsdName: String
    public let displayName: String
    public let ipv4: String

    public var id: String { bsdName }
}

public enum NDIAdapterList {

    public static func current() -> [NDIAdapter] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        let friendly = friendlyNames()
        var adapters: [NDIAdapter] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: pointer.pointee.ifa_name)
            guard !adapters.contains(where: { $0.bsdName == name }) else { continue }
            adapters.append(NDIAdapter(
                bsdName: name,
                displayName: friendly[name] ?? name,
                ipv4: String(cString: host)))
        }
        return adapters.sorted { $0.bsdName < $1.bsdName }
    }

    public static func fingerprint(_ adapters: [NDIAdapter]) -> String {
        adapters.map { "\($0.bsdName)=\($0.ipv4)" }.sorted().joined(separator: ",")
    }

    private static func friendlyNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            names[bsd] = display
        }
        return names
    }
}
