import Foundation

// Was die unverändert übernommenen Dateien `Recipe.swift`, `FetchPlan.swift`, `StagePlan.swift`, `AssetFiles.swift`
// und `ContentStore.swift` aus AVP Play sonst noch brauchen (tools/sync-meta.sh). Hier stehen nur die kleinen Typen
// und Prüfungen, auf die sie sich stützen, im Wortlaut von AVP Play (core/Sources/AVPPlayCore: L10n.swift,
// Trees.swift, GameServers.swift, Workshop.swift, DeviceControl.swift, Fetcher.swift, MetaListing.swift) – damit
// jedes Rezept, das AVP Play liest, hier genauso gelesen und geprüft wird.

/// Ein Text in den Sprachen des Programms; im Rezept ein einzelner Text oder `{"en": …, "de": …}`.
public struct LocalizedText: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var values: [String: String]

    public init(_ single: String) { values = ["": single] }
    public init(en: String, de: String) { values = ["en": en, "de": de] }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = ["": single]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1, let single = values[""] { try container.encode(single) } else { try container.encode(values) }
    }

    public var text: String {
        values[Language.code] ?? values[""] ?? values["en"] ?? values.sorted { $0.key < $1.key }.first?.value ?? ""
    }
    public var description: String { text }
}

/// Ein Ordnerbestand eines Spiels, das kein APK ist. Auf der Brille gibt es solche Spiele nicht; das Rezept muss
/// sich trotzdem lesen lassen.
public struct RecipeTree: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case game
        case sysroot
        case xrizer
        case data
    }

    public struct Marker: Codable, Sendable, Hashable {
        public var path: String
        public var size: Int64?
        public var sha256: String
    }

    public var name: String
    public var role: Role
    public var source: FileSource
    public var markers: [Marker]
    public var dest: String?
    public var only: [String]?
}

public struct GameServer: Codable, Sendable, Equatable, Identifiable {
    public var address: String
    public var name: String
    public var id: String { address }
}

public struct ServerListSupport: Codable, Sendable, Equatable {
    public var dest: String
    public var file: String
    public var defaultPort: Int?
    public var builtin: [GameServer]?
}

public enum GameServerStore {
    public static func normalize(_ text: String, defaultPort: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let host = parts.first, !host.isEmpty, host.count <= 80,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              host.first != "-", host.first != ".", host.last != "." else { return nil }
        let port = parts.count == 2 ? Int(parts[1]) : defaultPort
        guard let port, (1...65535).contains(port) else { return nil }
        return "\(host):\(port)"
    }

    public static func cleanName(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
            .trimmingCharacters(in: .whitespaces).prefix(60).description
    }
}

public struct WorkshopSupport: Codable, Sendable, Hashable {
    public var app: String
    public var dest: String

    public var isSane: Bool { Workshop.isId(app) && !dest.isEmpty && Recipe.isSafeRelativePath(dest) }
}

public enum Workshop {
    static func isId(_ s: String) -> Bool { (1...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
}

public struct InstalledApp: Sendable, Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let version: String?
    public let bundleVersion: String?
}

/// Wo geladene Dateien liegen: auf der Brille im privaten Bereich der App.
public enum StoreLocation {
    public static func current() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Standalone/games")
    }
}

public enum Fetcher {
    /// Ob Meta diese Datei einem Konto vorenthalten darf, ohne dass etwas nicht stimmt: nur eine weitere Datei
    /// eines ungeprüften Entwurfs – Metas Dateiliste nennt dort auch kostenpflichtige Zusatzinhalte, ohne sie zu
    /// kennzeichnen. Das APK, die Haupt-Datendatei und alles, wofür ein Rezept eine Prüfsumme kennt, gehören zum
    /// Spiel selbst.
    public static func mayBeWithheld(_ file: RecipeFile) -> Bool {
        file.source == nil && file.role == "content-bundle" && file.sha256 == nil
    }
}

/// Der Entwurf eines Rezepts für ein Spiel, das kein fertiges Rezept hat: aus dem, was Meta für einen Build nennt.
public enum DraftRecipe {
    public static func identifier(appId: String) -> String { "store-\(appId)" }
    public static func genericTarget(appId: String) -> String { "x\(appId)" }

    /// Steht als Ziel der Haupt-Datendatei im Entwurf. Wo ein Spiel sie sucht, hängt von seiner Engine ab; der Ort
    /// wird eingesetzt, sobald das APK da ist.
    public static let obbPlaceholder = "@obb"
    /// Steht als Ziel der weiteren Dateien, wenn der Paketname des Spiels noch nicht bekannt ist.
    public static let packageFolderPlaceholder = "@package-obb"

    /// Der Ordner, in dem eine Quest die weiteren Dateien eines Spiels ablegt.
    public static func packageFolder(package: String) -> String { "android-files/Android/obb/\(package)" }

    public static func needsPackage(_ dest: String?) -> Bool {
        dest == packageFolderPlaceholder || dest == packageFolder(package: "")
    }

    public static func make(appId: String, title: String, package: String, build: CatalogBuild, files: [ListedFile],
                            target: String, minCommit: String) throws -> Recipe {
        guard let apk = files.first(where: { $0.kind == "APK" }) else { throw MetaError.missingAppId }
        let androidObb = package.isEmpty ? packageFolderPlaceholder : packageFolder(package: package)
        var list = [RecipeFile(name: apk.name, role: "apk", id: apk.id, size: nil, sha256: nil, required: true, dest: "",
                               localName: "\(target).apk", locale: nil, source: nil)]
        var seen: Set<String> = [apk.name]
        for file in files where file.kind != "APK" && seen.insert(file.name).inserted {
            let isMain = file.kind == "OBB"
            // Weitere Dateien liegen auf einer Quest immer unter Android/obb/<Paket>; den Ort der Haupt-Datendatei
            // setzt die Toolchain ein.
            let dest = isMain ? obbPlaceholder : androidObb
            list.append(RecipeFile(name: file.name, role: isMain ? "main-obb" : "content-bundle", id: file.id, size: nil, sha256: nil,
                                   required: true, dest: dest, localName: nil, locale: nil, source: nil))
        }
        let recipe = Recipe(schema: Recipe.supportedSchema, id: identifier(appId: appId), title: title, package: package,
                            versionName: build.version, versionCode: build.versionCode, store: .init(appId: appId),
                            toolchain: .init(target: target, minCommit: minCommit), files: list, addons: nil,
                            status: .init(playability: "untested", download: "listed", notes: nil), icon: nil, trees: nil)
        try recipe.validate()
        return recipe
    }

    /// Ein Rezept nur aus dem, was schon da liegt – für Dateien, die der Mac mitgegeben hat, und für ein installiertes
    /// Spiel, von dem nur seine APK bekannt ist. Es nennt keine Kennungen bei Meta: Geladen werden kann danach nichts.
    public static func local(appId: String, title: String, target: String, versionCode: Int, files: [(name: String, kind: String)]) -> Recipe {
        let list = files.map { file -> RecipeFile in
            switch file.kind {
            case "APK":
                return RecipeFile(name: file.name, role: "apk", id: "", size: nil, sha256: nil, required: true, dest: "",
                                  localName: "\(target).apk", locale: nil, source: nil)
            case "OBB":
                return RecipeFile(name: file.name, role: "main-obb", id: "", size: nil, sha256: nil, required: true, dest: obbPlaceholder,
                                  localName: nil, locale: nil, source: nil)
            default:
                return RecipeFile(name: file.name, role: "content-bundle", id: "", size: nil, sha256: nil, required: true,
                                  dest: packageFolderPlaceholder, localName: nil, locale: nil, source: nil)
            }
        }
        return Recipe(schema: Recipe.supportedSchema, id: identifier(appId: appId), title: title, package: "", versionName: "",
                      versionCode: versionCode, store: .init(appId: appId), toolchain: .init(target: target, minCommit: ""), files: list,
                      addons: nil, status: .init(playability: "untested", download: "local", notes: nil), icon: nil, trees: nil)
    }
}
