import Foundation
import NetworkExtension
import Security

/// Der Tunnel der App (Standalone/Tunnel): einschalten und warten, bis er steht.
enum Tunnel {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var providerIdentifier: String { (Bundle.main.bundleIdentifier ?? "") + ".Tunnel" }

    static func start() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerIdentifier
        } ?? NETunnelProviderManager()
        if manager.connection.status == .connected { return }
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerIdentifier
        configuration.serverAddress = L("This Apple Vision Pro", "Diese Apple Vision Pro")
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "AVP Play Remote"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // Eine eben gesicherte Konfiguration muss neu geladen werden, bevor sie verbinden kann.
        try await manager.loadFromPreferences()
        try manager.connection.startVPNTunnel()
        let deadline = Date().addingTimeInterval(20)
        while manager.connection.status != .connected {
            if manager.connection.status == .invalid { throw Failure(description: "the loopback tunnel's configuration is not valid") }
            guard Date() < deadline else { throw Failure(description: "the loopback tunnel did not come up within 20 seconds") }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}


/// Lässt von vielen Fortschrittsmeldungen nur die durch, die den Balken sichtbar bewegen.
final class Meter: @unchecked Sendable {
    private var last = -1.0
    func moved(_ value: Double) -> Bool {
        guard abs(value - last) >= 0.005 || value >= 1 else { return false }
        last = value
        return true
    }
}

/// Das Zugangstoken für Meta im Schlüsselbund dieser Brille. Es kommt mit der Übergabe vom Mac.
enum MetaToken {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.mymartek.avpplay.remote.meta",
        kSecAttrAccount as String: "default",
    ]

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
