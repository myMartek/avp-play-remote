import Foundation
import ImageIO

// Was `MetaClient.swift` aus AVP Play sonst noch braucht. Die Datei selbst ist eine unveränderte Kopie
// (tools/sync-meta.sh); hier stehen nur die wenigen kleinen Typen und Prüfungen, auf die sie sich stützt, im
// Wortlaut von AVP Play (core/Sources/AVPPlayCore: Catalog.swift, MetaListing.swift, Ownership.swift, Recipe.swift,
// Redaction.swift).

public enum CatalogGame {
    public static func isIdentifier(_ s: String) -> Bool { (5...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
    static func isPlain(_ s: String) -> Bool { !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
}

public enum SteamCatalogGame {
    /// Eine Steam-App-ID, wie der Dienst sie annimmt: Ziffern ohne führende Null, höchstens zehn.
    public static func isIdentifier(_ s: String) -> Bool {
        (1...10).contains(s.count) && s.first != "0" && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

public struct CatalogBuild: Codable, Sendable, Equatable {
    public var buildId: String
    public var version: String
    public var versionCode: Int
    public var fileName: String?

    var isSane: Bool { CatalogGame.isIdentifier(buildId) && version.count <= 80 && CatalogGame.isPlain(version) && versionCode >= 0 }
}

/// Eine Datei, die Meta für einen Build nennt.
public struct ListedFile: Sendable, Equatable {
    public let name: String
    public let id: String
    /// `APK`, `OBB` oder `ASSET`.
    public let kind: String
    /// Die Größe als Text – zum Anzeigen, nicht zum Prüfen.
    public let sizeText: String
}

public struct LibraryApp: Codable, Sendable, Equatable {
    public var appId: String
    public var title: String
    public var grant: String?
    public init(appId: String, title: String, grant: String? = nil) {
        self.appId = appId
        self.title = title
        self.grant = grant
    }
}

/// Entfernt Zugangsdaten aus Text, bevor er angezeigt oder protokolliert wird.
public enum Redaction {
    private static let patterns: [NSRegularExpression] = [
        // Meta-Tokens (Präfix OCA oder FRL, danach lang und alphanumerisch)
        try! NSRegularExpression(pattern: #"(OCA|FRL)[A-Za-z0-9_|.\-]{16,}"#),
        try! NSRegularExpression(pattern: #"(?i)(access_token=)[^&"\s]+"#),
        try! NSRegularExpression(pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#),
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for (i, re) in patterns.enumerated() {
            let template = i == 0 ? "<REDACTED>" : "$1<REDACTED>"
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

/// Von AVP Plays `AppIcon` braucht `StoreArt.swift` nur die eine Prüfung, ob Daten ein lesbares Bild sind.
enum AppIcon {
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
