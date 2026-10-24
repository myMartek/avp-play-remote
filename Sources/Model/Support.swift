import Foundation
import Network
import Security

/// Texte stehen wie in AVP Play zweisprachig im Programm: Deutsch, wenn das System Deutsch spricht, sonst Englisch.
func L(_ english: String, _ german: String) -> String {
    Language.german ? german : english
}

enum Language {
    static let german = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
    static var code: String { german ? "de" : "en" }
}

/// Die Schlüssel der gekoppelten Macs, im Schlüsselbund dieser App – je Mac ein Eintrag.
enum MacKeychain {
    static let service = "io.github.mymartek.avpplay.remote"

    struct Secret: Codable {
        var clientId: String
        var key: Data
    }

    static func read(serverId: String) -> Secret? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Secret.self, from: data)
    }

    @discardableResult
    static func write(_ secret: Secret, serverId: String) -> Bool {
        guard let data = try? JSONEncoder().encode(secret) else { return false }
        delete(serverId: serverId)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(serverId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Ein Mac, mit dem diese Vision Pro gekoppelt ist. Der Schlüssel liegt im Schlüsselbund.
struct KnownMac: Codable, Identifiable, Equatable {
    var serverId: String
    var name: String
    /// Die Adresse, unter der er zuletzt erreicht wurde – für den Fall, dass Bonjour ihn nicht zeigt.
    var host: String?
    var port: UInt16?
    var lastConnected: Date?
    var id: String { serverId }

    static let defaultsKey = "knownMacs"

    static func load() -> [KnownMac] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([KnownMac].self, from: data)) ?? []
    }

    static func save(_ macs: [KnownMac]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(macs), forKey: defaultsKey)
    }
}

/// Ein Mac, den Bonjour gerade im Netz zeigt.
struct FoundMac: Identifiable, Equatable {
    var name: String
    /// Aus dem TXT-Eintrag; fehlt, solange er nicht gelesen ist.
    var serverId: String?
    var pairPort: UInt16
    var endpoint: NWEndpointBox
    var id: String { serverId ?? name }
}

/// `NWEndpoint` mit Gleichheit über seine Beschreibung – für `Equatable`-Zustände.
struct NWEndpointBox: Equatable {
    let endpoint: NWEndpoint
    static func == (a: NWEndpointBox, b: NWEndpointBox) -> Bool { a.endpoint.debugDescription == b.endpoint.debugDescription }
}

/// Die Titelbilder, auf der Platte zwischengespeichert: Sie ändern sich selten, und über die Leitung sind sie das
/// Größte.
enum CoverDisk {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".jpg")
    }

    static func read(_ key: String) -> Data? { try? Data(contentsOf: url(key)) }
    static func write(_ data: Data, key: String) { try? data.write(to: url(key), options: .atomic) }
}

extension Int64 {
    var gigabytes: String { String(format: "%.1f GB", Double(self) / 1e9) }
}
