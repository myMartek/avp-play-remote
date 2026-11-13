import Foundation
import idevice

/// The install test itself: one connection to a device's own services, a package copied into its staging folder,
/// and the install asked of its installation service. The same code runs in the headset app (through the loopback
/// tunnel, to 10.7.0.1) and in the Mac command (over Wi-Fi, to the headset's address).
struct ProbeFailure: Error, CustomStringConvertible {
    let step: String
    let code: Int32
    let subCode: Int32
    let message: String
    var description: String { "\(step) failed: \(message) (code \(code), sub \(subCode))" }
}

/// A connection to a device's own services, made with a pairing file: over the loopback tunnel to the device this
/// runs on (10.7.0.1), or over Wi-Fi from a Mac. What the installing side needs of them: the installation service,
/// and the file service for the staging folder and for an app's Documents folder.
final class DeviceLink {
    private var pairing: OpaquePointer?
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    static func check(_ step: String, _ call: () -> UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error = call() else { return }
        let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? "no message"
        let failure = ProbeFailure(step: step, code: error.pointee.code, subCode: error.pointee.sub_code, message: message)
        idevice_error_free(error)
        throw failure
    }

    init(address: String, port: UInt16, pairingFile: String) throws {
        try Self.check("read the pairing file") { pairingFile.withCString { rp_pairing_file_read($0, &pairing) } }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &socketAddress.sin_addr) }) == 1 else {
            throw ProbeFailure(step: "parse the address", code: -1, subCode: 0, message: address)
        }
        try Self.check("open the tunnel to the device") {
            "AVPPlayRemote".withCString { hostname in
                withUnsafePointer(to: &socketAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        tunnel_create_rppairing(generic, socklen_t(MemoryLayout<sockaddr_in>.stride), hostname, pairing,
                                                nil, nil, &adapter, &handshake)
                    }
                }
            }
        }
    }

    deinit {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        if let pairing { rp_pairing_file_free(pairing) }
    }

    /// The device's general file area; a package has to lie in its `PublicStaging` folder to be installed.
    func files() throws -> DeviceFolder {
        var client: OpaquePointer?
        try Self.check("connect to the file service") { afc_client_connect_rsd(adapter, handshake, &client) }
        return DeviceFolder(client)
    }

    /// The Documents folder of an installed app (one signed for development, or one that shares its files).
    func documents(of bundleID: String) throws -> DeviceFolder {
        var arrest: OpaquePointer?
        try Self.check("connect to the app-folder service") { house_arrest_client_connect_rsd(adapter, handshake, &arrest) }
        var client: OpaquePointer?
        do {
            try Self.check("open the folder of \(bundleID)") { bundleID.withCString { house_arrest_vend_documents(arrest, $0, &client) } }
        } catch {
            house_arrest_client_free(arrest)
            throw error
        }
        // The folder's connection is the one the service was asked on: it is handed over, not freed here.
        return DeviceFolder(client, root: "Documents")
    }

    /// Installs the package at `staged` (a path in the staging folder). `progress` gets percentages.
    func install(staged: String, progress: @escaping (UInt64) -> Void) throws {
        var installer: OpaquePointer?
        try Self.check("connect to the installation service") { installation_proxy_connect_rsd(adapter, handshake, &installer) }
        defer { if let installer { installation_proxy_client_free(installer) } }
        final class Box {
            let call: (UInt64) -> Void
            init(_ call: @escaping (UInt64) -> Void) { self.call = call }
        }
        let box = Box(progress)
        try Self.check("install \(staged)") {
            staged.withCString { path in
                installation_proxy_install_with_callback(installer, path, nil, { progress, context in
                    guard let context else { return }
                    Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().call(progress)
                }, Unmanaged.passUnretained(box).toOpaque())
            }
        }
    }

    /// Every app the user has installed, by bundle identifier: its build and its version.
    func installedApps() throws -> [String: (build: String, version: String)] {
        var installer: OpaquePointer?
        try Self.check("connect to the installation service") { installation_proxy_connect_rsd(adapter, handshake, &installer) }
        defer { if let installer { installation_proxy_client_free(installer) } }
        var result: UnsafeMutableRawPointer?
        var count = 0
        try Self.check("list the installed apps") {
            "User".withCString { installation_proxy_get_apps(installer, $0, nil, 0, &result, &count) }
        }
        guard let result, count > 0 else { return [:] }
        let apps = result.assumingMemoryBound(to: plist_t?.self)
        defer { idevice_plist_array_free(apps, UInt(count)) }
        var found: [String: (build: String, version: String)] = [:]
        for index in 0 ..< count {
            func string(_ key: String) -> String? {
                var text: UnsafeMutablePointer<CChar>?
                if let node = plist_dict_get_item(apps[index], key) { plist_get_string_val(node, &text) }
                defer { if let text { plist_mem_free(text) } }
                return text.map { String(cString: $0) }
            }
            if let id = string("CFBundleIdentifier") {
                found[id] = (string("CFBundleVersion") ?? "", string("CFBundleShortVersionString") ?? "")
            }
        }
        return found
    }

    /// What the device says about an installed app, or nil if it lists none of that name.
    func installed(_ bundleID: String) throws -> InstallCore.Installed? {
        var installer: OpaquePointer?
        try Self.check("connect to the installation service") { installation_proxy_connect_rsd(adapter, handshake, &installer) }
        defer { if let installer { installation_proxy_client_free(installer) } }
        var result: UnsafeMutableRawPointer?
        var count = 0
        try Self.check("list \(bundleID)") {
            bundleID.withCString { identifier in
                var identifiers: [UnsafePointer<CChar>?] = [identifier]
                return identifiers.withUnsafeMutableBufferPointer {
                    installation_proxy_get_apps(installer, nil, $0.baseAddress, 1, &result, &count)
                }
            }
        }
        guard let result, count > 0 else { return nil }
        let apps = result.assumingMemoryBound(to: plist_t?.self)
        defer { idevice_plist_array_free(apps, UInt(count)) }
        func string(_ key: String) -> String? {
            var text: UnsafeMutablePointer<CChar>?
            if let node = plist_dict_get_item(apps[0], key) { plist_get_string_val(node, &text) }
            defer { if let text { plist_mem_free(text) } }
            return text.map { String(cString: $0) }
        }
        return InstallCore.Installed(version: string("CFBundleVersion") ?? "unknown", signer: string("SignerIdentity"))
    }
}

/// One folder tree on the device, reached through its file service.
final class DeviceFolder {
    private let client: OpaquePointer?
    private let root: String

    fileprivate init(_ client: OpaquePointer?, root: String = "") {
        self.client = client
        self.root = root
    }

    deinit { if let client { afc_client_free(client) } }

    private func full(_ path: String) -> String { root.isEmpty ? path : (path.isEmpty ? root : "\(root)/\(path)") }

    /// Makes the folder and the ones above it. A folder that is there already is not an error.
    func makeDirectories(_ path: String) {
        var built = ""
        for part in path.split(separator: "/") {
            built += built.isEmpty ? String(part) : "/\(part)"
            if let error = full(built).withCString({ afc_make_directory(client, $0) }) { idevice_error_free(error) }
        }
    }

    /// The size of the file at `path`, or nil if there is none.
    func size(of path: String) -> Int? {
        var info = AfcFileInfo()
        if let error = full(path).withCString({ afc_get_file_info(client, $0, &info) }) {
            idevice_error_free(error)
            return nil
        }
        defer { afc_file_info_free(&info) }
        return info.size
    }

    func exists(_ path: String) -> Bool { size(of: path) != nil }

    /// The names in the folder at `path`, without "." and "..".
    func list(_ path: String) throws -> [String] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        try DeviceLink.check("list \(path)") { full(path).withCString { afc_list_directory(client, $0, &entries, &count) } }
        // The few bytes of the listing are not handed back: the header does not say how.
        return (0 ..< count).compactMap { entries?[$0].map { String(cString: $0) } }.filter { $0 != "." && $0 != ".." }
    }

    func remove(_ path: String) {
        if let error = full(path).withCString({ afc_remove_path(client, $0) }) { idevice_error_free(error) }
    }

    /// How much room the device has left, in bytes.
    func freeBytes() throws -> Int {
        var info = AfcDeviceInfo()
        try DeviceLink.check("read the device's free space") { afc_get_device_info(client, &info) }
        defer { afc_device_info_free(&info) }
        return info.free_bytes
    }

    /// Copies a local file to `path`, in pieces of 4 MB, so that a game's gigabytes never sit in memory at once.
    /// `progress` gets the bytes written so far.
    func write(_ local: URL, to path: String, progress: ((Int) -> Void)? = nil) throws {
        let source = try FileHandle(forReadingFrom: local)
        defer { try? source.close() }
        makeDirectories((path as NSString).deletingLastPathComponent)
        var file: OpaquePointer?
        try DeviceLink.check("create \(path)") { full(path).withCString { afc_file_open(client, $0, AfcWrOnly, &file) } }
        var written = 0
        do {
            while true {
                let piece = try autoreleasepool { try source.read(upToCount: 4 << 20) ?? Data() }
                if piece.isEmpty { break }
                try DeviceLink.check("write \(path)") {
                    piece.withUnsafeBytes { afc_file_write(file, $0.bindMemory(to: UInt8.self).baseAddress, piece.count) }
                }
                written += piece.count
                progress?(written)
            }
        } catch {
            if let leftover = afc_file_close(file) { idevice_error_free(leftover) }
            throw error
        }
        try DeviceLink.check("close \(path)") { afc_file_close(file) }
    }

    /// Copies the file at `path` on the device to a local file, in pieces of 4 MB. `progress` gets the bytes read so far.
    func read(_ path: String, to local: URL, progress: ((Int) -> Void)? = nil) throws {
        var file: OpaquePointer?
        try DeviceLink.check("open \(path)") { full(path).withCString { afc_file_open(client, $0, AfcRdOnly, &file) } }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let target = try FileHandle(forWritingTo: local)
        defer { try? target.close() }
        var total = 0
        do {
            while true {
                var data: UnsafeMutablePointer<UInt8>?
                var count = 0
                try DeviceLink.check("read \(path)") { afc_file_read(file, &data, 4 << 20, &count) }
                guard let data, count > 0 else { break }
                try target.write(contentsOf: Data(bytes: data, count: count))
                afc_file_read_data_free(data, count)
                total += count
                progress?(total)
            }
        } catch {
            if let leftover = afc_file_close(file) { idevice_error_free(leftover) }
            throw error
        }
        try DeviceLink.check("close \(path)") { afc_file_close(file) }
    }

    func write(_ data: Data, to path: String) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try write(temporary, to: path)
    }
}

enum InstallCore {
    /// Where a package has to lie for the installation service to take it.
    static let stagingFolder = "PublicStaging"

    /// What the device says about an installed app.
    struct Installed {
        let version: String
        /// The name on the certificate the app is signed with, or nil if the device does not say.
        let signer: String?
    }

    /// Copies a package to the device, has it installed and returns what the device then reports for `bundleID`.
    /// `log` gets one line per step, with how long the step took.
    @discardableResult
    static func run(address: String, port: UInt16, pairingFile: String, package: URL, bundleID: String,
                    log: @escaping (String) -> Void) throws -> Installed {
        var started = Date()
        func done(_ text: String) {
            log(String(format: "ok   %@ (%.2f s)", text, Date().timeIntervalSince(started)))
            started = Date()
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: package.path))?[.size] as? Int ?? 0
        log("     package \(package.lastPathComponent), \(size) bytes; device \(address):\(port)")

        let link = try DeviceLink(address: address, port: port, pairingFile: pairingFile)
        done("tunnel to the device's services")
        let files = try link.files()
        done("file service")
        let staged = "\(stagingFolder)/\(package.lastPathComponent)"
        try files.write(package, to: staged)
        done("package copied to \(staged)")

        var last: UInt64 = .max
        try link.install(staged: staged) { progress in
            if progress != last, progress % 10 == 0 || progress == 100 { log("     installing: \(progress) %") }
            last = progress
        }
        done("the device took the install")

        guard let installed = try link.installed(bundleID) else {
            throw ProbeFailure(step: "list \(bundleID)", code: -1, subCode: 0,
                               message: "the install was accepted, but the device does not list the app")
        }
        done("the device lists \(bundleID), build \(installed.version), signed by \(installed.signer ?? "(not said)")")
        files.remove(staged)
        return installed
    }
}
