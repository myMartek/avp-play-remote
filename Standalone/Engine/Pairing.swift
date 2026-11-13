import dnssd
import Foundation
import idevice

/// Pairs this app with the headset it runs on, so that it can use the headset's own services (DeviceLink).
///
/// An Apple Vision Pro pairs as an Apple TV does: while Settings › General › Remote Devices is open, it offers a
/// pairing service in the local network. A host connects and asks to pair, the headset shows a code, and the host
/// sends the code back. Here the host is this app. The result is a pairing file: this host's keys, and what the
/// headset told about itself.
enum PairingCore {
    static let serviceType = "_remotepairing-manual-pairing._tcp"

    struct Found {
        /// The port the headset's pairing service listens on, if it offers one.
        var port: UInt16?
        /// The system refused the search: the app may not look into the local network.
        var denied = false
    }

    /// Looks for the headset's pairing service and reads its port. Blocks for up to `timeout`; call it off the main
    /// thread. The service is there only while Remote Devices is open in Settings.
    static func find(timeout: TimeInterval) -> Found {
        let search = Search()
        let retained = Unmanaged.passRetained(search)
        defer { retained.release() }
        var browse: DNSServiceRef?
        let started = DNSServiceBrowse(&browse, 0, 0, serviceType, "local.", { _, flags, interface, error, name, type, domain, context in
            guard let context else { return }
            let search = Unmanaged<Search>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError else { return search.note(error) }
            guard flags & kDNSServiceFlagsAdd != 0, let name, let type, let domain, search.open else { return }
            // The SRV record names the port.
            var resolve: DNSServiceRef?
            let asked = DNSServiceResolve(&resolve, 0, interface, name, type, domain, { _, _, _, error, _, _, port, _, _, context in
                guard let context else { return }
                let search = Unmanaged<Search>.fromOpaque(context).takeUnretainedValue()
                guard error == kDNSServiceErr_NoError else { return search.note(error) }
                search.finish(UInt16(bigEndian: port))
            }, context)
            guard asked == kDNSServiceErr_NoError, let resolve else { return search.note(asked) }
            search.keep(resolve)
        }, retained.toOpaque())
        guard started == kDNSServiceErr_NoError, let browse else { return Found(denied: Int(started) == Int(kDNSServiceErr_PolicyDenied)) }
        DNSServiceSetDispatchQueue(browse, search.queue)
        _ = search.done.wait(timeout: .now() + timeout)
        return search.queue.sync {
            search.open = false
            DNSServiceRefDeallocate(browse)
            search.resolving.forEach { DNSServiceRefDeallocate($0) }
            search.resolving = []
            return Found(port: search.port, denied: search.failure.map { Int($0) } == Int(kDNSServiceErr_PolicyDenied))
        }
    }

    /// What one search holds. Everything but `done` is touched on `queue` only: the callbacks run there.
    private final class Search: @unchecked Sendable {
        let queue = DispatchQueue(label: "pairing-service-search")
        let done = DispatchSemaphore(value: 0)
        var open = true
        var port: UInt16?
        var failure: DNSServiceErrorType?
        var resolving: [DNSServiceRef] = []

        func note(_ error: DNSServiceErrorType) { failure = error }

        func keep(_ reference: DNSServiceRef) {
            resolving.append(reference)
            DNSServiceSetDispatchQueue(reference, queue)
        }

        func finish(_ found: UInt16) {
            guard open, port == nil, found != 0 else { return }
            port = found
            done.signal()
        }
    }

    /// Pairs with the service at `address`:`port` and returns the pairing file. Blocks until the pairing is done.
    /// `code` is called once the headset shows its code and has to return what the person read there; nil gives up
    /// (the headset then refuses the pairing).
    ///
    /// The headset resets a connection that comes from itself, so the address has to be the far end of the app's
    /// loopback tunnel.
    static func pair(address: String, port: UInt16, hostName: String, code: @escaping () -> String?) throws -> Data {
        var file: OpaquePointer?
        try DeviceLink.check("make a pairing file") { hostName.withCString { rp_pairing_file_generate($0, &file) } }
        defer { if let file { rp_pairing_file_free(file) } }

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &socketAddress.sin_addr) }) == 1 else {
            throw ProbeFailure(step: "parse the address", code: -1, subCode: 0, message: address)
        }
        let answer = Answer(code)
        let retained = Unmanaged.passRetained(answer)
        defer { retained.release() }
        try DeviceLink.check("pair with the headset") {
            hostName.withCString { name in
                withUnsafePointer(to: &socketAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        rppairing_pair_network(generic, socklen_t(MemoryLayout<sockaddr_in>.stride), name, file, { context in
                            guard let context else { return nil }
                            return Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue().give()
                        }, retained.toOpaque(), nil)
                    }
                }
            }
        }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        try DeviceLink.check("write the pairing file") { rp_pairing_file_to_bytes(file, &bytes, &length) }
        defer { idevice_data_free(bytes, length) }
        guard let bytes, length > 0 else { throw ProbeFailure(step: "write the pairing file", code: -1, subCode: 0, message: "empty") }
        return Data(bytes: bytes, count: Int(length))
    }

    /// Holds the code as the C string the library reads. The library borrows it, so it lives as long as this does.
    private final class Answer {
        private let ask: () -> String?
        private var text: UnsafeMutablePointer<CChar>?

        init(_ ask: @escaping () -> String?) { self.ask = ask }
        deinit { free(text) }

        func give() -> UnsafePointer<CChar>? {
            guard let code = ask() else { return nil }
            free(text)
            text = strdup(code)
            return UnsafePointer(text)
        }
    }
}
