import Foundation

/// Kleptons Vorlage für ein Spiel, dessen Programm schon für Apples Chips gebaut ist (ein „Mach-O-Gast“; das erste
/// ist Minecraft: Java Edition mit Vivecraft): `klepton-macho-<Ziel>-<Nummer>-<Commit>.zip` aus
/// `visionos/mktemplate.sh`. Darin liegt die App ohne das Spiel und `macho.json` – was dazukommt und wohin.
///
/// Das Spiel selbst kommt aus einem zweiten Archiv, den „Spielteilen“: Die baut AVP Play auf dem Mac des Nutzers
/// (etwa 45 Minuten, mit einem Compiler) und übergibt sie. Auf der Brille entsteht davon nichts; hier werden Vorlage
/// und Spielteile nur zusammengesetzt (`FinishMacho`), ohne APK, ohne Übersetzen.
struct MachoTemplate {
    let app: URL
    let entitlements: URL
    /// Die Nummer der Toolchain: der letzte Teil der Baunummer einer fertigen App.
    let version: Int
    let commit: String
    let contract: Contract

    /// `macho.json`, Format 1: Was hier nicht gelesen werden kann, wird nicht geraten.
    struct Contract {
        let target: String
        /// Die Bibliotheken des Spiels, ohne Endung; `from` und `to` mit `{name}`, unterhalb der jeweiligen App.
        let libraries: [String]
        let libraryFrom: String, libraryTo: String, libraryInstallName: String
        /// Der Ordner mit den Dateien des Spiels: Er kommt unverändert in die App.
        let payloadFrom: String, payloadTo: String, payloadTree: String
        let payloadRequires: [String]
        /// Die Lizenzhinweise: Bringt das Archiv eigene mit (ein Ordner mit `licenseIndex`), ersetzen sie die der Vorlage.
        let licenseFrom: [String], licenseIndex: String, licenseTo: String
        let infoFile: String
        /// Werte, die schon in der Vorlage stehen müssen (zur Prüfung), und die vier, die sagen, wessen App es ist.
        let infoRow: [String: String], infoWrite: [String: String]
        /// Was signiert wird, von innen nach außen.
        let sign: [String]
        /// Ist ein Icon in die Vorlage kompiliert, braucht es nichts. Sonst steht hier, wo das eigene des Spiels liegt.
        let iconCompiled: Bool
        let iconIndex: String, iconObject: String
        let iconNames: [String]

        init(_ object: [String: Any]) throws {
            func fail(_ what: String) -> FinishFailure { FinishFailure(description: "the template's macho.json has no usable \(what)") }
            guard object["format"] as? Int == 1, object["kind"] as? String == "macho" else {
                throw FinishFailure(description: "the template's macho.json is of a kind or format this app does not know")
            }
            guard let target = object["target"] as? String, MachoTemplate.isPlainName(target) else { throw fail("target") }
            guard let libraries = object["libraries"] as? [String: Any], let names = libraries["names"] as? [String], !names.isEmpty,
                  names.allSatisfy(MachoTemplate.isPlainName), let from = libraries["from"] as? String, let to = libraries["to"] as? String,
                  from.contains("{name}"), to.contains("{name}"), MachoTemplate.isInside(from), MachoTemplate.isInside(to),
                  libraries["architecture"] as? String == "arm64", libraries["platform"] as? String == "visionOS" else { throw fail("libraries") }
            guard let payload = object["payload"] as? [String: Any], let payloadFrom = payload["from"] as? String,
                  let payloadTo = payload["to"] as? String, MachoTemplate.isInside(payloadFrom), MachoTemplate.isInside(payloadTo),
                  let tree = payload["tree"] as? String, let requires = payload["requires"] as? [String],
                  requires.allSatisfy(MachoTemplate.isInside) else { throw fail("payload") }
            guard let licenses = object["licenses"] as? [String: Any], let licenseFrom = licenses["from"] as? [String],
                  let index = licenses["index"] as? String, let licenseTo = licenses["to"] as? String,
                  MachoTemplate.isPlainName(index), MachoTemplate.isInside(licenseTo) else { throw fail("licenses") }
            guard let info = object["info"] as? [String: Any], let file = info["file"] as? String, MachoTemplate.isInside(file),
                  let write = info["write"] as? [String: String] else { throw fail("info") }
            guard let sign = object["sign"] as? [String], sign.last == "." else { throw fail("sign") }
            self.target = target
            (self.libraries, libraryFrom, libraryTo) = (names, from, to)
            libraryInstallName = libraries["installName"] as? String ?? ""
            (self.payloadFrom, self.payloadTo, payloadTree, payloadRequires) = (payloadFrom, payloadTo, tree, requires)
            (self.licenseFrom, licenseIndex, self.licenseTo) = (licenseFrom, index, licenseTo)
            (infoFile, infoRow, infoWrite) = (file, info["row"] as? [String: String] ?? [:], write)
            self.sign = sign
            let icon = object["icon"] as? [String: Any] ?? [:], game = icon["game"] as? [String: Any] ?? [:]
            iconCompiled = icon["compiled"] as? Bool ?? false
            (iconIndex, iconObject) = (game["index"] as? String ?? "", game["object"] as? String ?? "")
            iconNames = game["names"] as? [String] ?? []
        }
    }

    /// Ein Name ohne Pfad: keine Schrägstriche, nicht „.“ oder „..“.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// Ein Pfad, der in seinem Ordner bleibt.
    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    /// „klepton-macho-<Ziel>-<Nummer>-<Commit>.zip“ → Ziel und Nummer, ohne die Datei zu öffnen.
    static func named(_ file: String) -> (target: String, version: Int, stamp: String)? {
        guard file.hasPrefix("klepton-macho-"), file.hasSuffix(".zip") else { return nil }
        let parts = file.dropFirst("klepton-macho-".count).dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, let version = Int(parts[parts.count - 2]) else { return nil }
        let target = parts.dropLast(2).joined(separator: "-")
        return target.isEmpty ? nil : (target, version, "\(version)-\(parts[parts.count - 1])")
    }

    /// Nur der Vertrag einer Vorlage, ohne die App auszupacken: um vorab zu sagen, ob Spielteile dazu passen.
    static func contract(of archive: URL) throws -> Contract {
        guard let data = try Zip.data(of: "macho.json", in: archive),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FinishFailure(description: "\(archive.lastPathComponent) has no macho.json: not a template for this kind of game")
        }
        return try Contract(object)
    }

    static func open(_ archive: URL, in folder: URL) throws -> MachoTemplate {
        try? FileManager.default.removeItem(at: folder)
        try Zip.unpack(archive, to: folder)
        func json(_ name: String) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [String: Any] else {
                throw FinishFailure(description: "the template's \(name) is not readable")
            }
            return object
        }
        let facts = try json("template.json"), described = try json("macho.json")
        guard let app = facts["app"] as? String, isInside(app), let version = facts["version"] as? Int, let commit = facts["commit"] as? String else {
            throw FinishFailure(description: "the template does not say which toolchain it is")
        }
        let contract = try Contract(described)
        guard facts["macho"] as? String == contract.target, described["app"] as? String == app else {
            throw FinishFailure(description: "the template's two descriptions do not name the same app")
        }
        let entitlements = described["entitlements"] as? String ?? "Klepton.entitlements"
        guard isPlainName(entitlements) else { throw FinishFailure(description: "the template's macho.json has no usable entitlements") }
        return MachoTemplate(app: folder.appendingPathComponent(app), entitlements: folder.appendingPathComponent(entitlements),
                             version: version, commit: commit, contract: contract)
    }
}

/// Die Spielteile, wie AVP Play sie auf dem Mac baut: ein Archiv in der Form eines App-Pakets, mit genau einer App
/// unter `Payload/`. Gelesen wird nur, was der Vertrag der Vorlage nennt.
struct GameParts {
    /// „Payload/<Name>.app/“
    let root: String
    /// Was ausgepackt wird, in Bytes: die Bibliotheken, der Ordner des Spiels, die Lizenzhinweise.
    let bytes: Int64
    /// Der Ordner mit den Lizenzhinweisen im Archiv (mit „/“ am Ende), wenn es eigene mitbringt.
    let licenses: String?
    let entries: [Zip.Entry]

    /// Prüft, ob das Archiv alles hat, was die Vorlage verlangt – ohne etwas auszupacken. So scheitert ein Auftrag,
    /// bevor er ein knappes Gigabyte schreibt.
    static func inspect(_ archive: URL, for contract: MachoTemplate.Contract) throws -> GameParts {
        let entries = try Zip.entries(in: archive)
        let apps = Set(entries.compactMap { entry -> String? in
            let parts = entry.name.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            return parts.count >= 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") ? String(parts[1]) : nil
        })
        guard apps.count == 1, let app = apps.first else {
            throw FinishFailure(description: "the game parts hold \(apps.count) apps; exactly one is expected")
        }
        let root = "Payload/\(app)/"
        let names = Set(entries.map(\.name))
        for name in contract.libraries {
            let path = root + contract.libraryFrom.replacingOccurrences(of: "{name}", with: name)
            guard names.contains(path) else { throw FinishFailure(description: "the game parts have no \(name)") }
        }
        let payload = root + contract.payloadFrom + "/"
        for need in contract.payloadRequires {
            guard entries.contains(where: { matches($0.name, pattern: payload + need) }) else {
                throw FinishFailure(description: "the game parts' files have no \(need)")
            }
        }
        // „../../Licenses“ von der App aus ist „Licenses“ im Archiv.
        var licenses: String?
        for candidate in contract.licenseFrom {
            guard let folder = resolve(root + candidate) else { continue }
            if names.contains(folder + contract.licenseIndex) { licenses = folder; break }
        }
        let libraries = Set(contract.libraries.map { root + contract.libraryFrom.replacingOccurrences(of: "{name}", with: $0) })
        let bytes = entries.reduce(Int64(0)) { sum, entry in
            let wanted = libraries.contains(entry.name) || entry.name.hasPrefix(payload) || (licenses.map { entry.name.hasPrefix($0) } ?? false)
            return sum + (wanted ? Int64(entry.size) : 0)
        }
        return GameParts(root: root, bytes: bytes, licenses: licenses, entries: entries)
    }

    /// Löst „a/b/../c“ auf; `nil`, wenn der Pfad das Archiv verließe. Mit „/“ am Ende.
    static func resolve(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else if part != "." {
                parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/") + "/"
    }

    /// Ob `name` unter `pattern` liegt oder es ist. Ein „*“ im Muster steht für beliebige Zeichen ohne „/“.
    static func matches(_ name: String, pattern: String) -> Bool {
        let wanted = pattern.split(separator: "/"), have = name.split(separator: "/")
        guard have.count >= wanted.count else { return false }
        for (piece, part) in zip(wanted, have) where !glob(String(part), String(piece)) { return false }
        return true
    }

    private static func glob(_ text: String, _ pattern: String) -> Bool {
        guard pattern.contains("*") else { return text == pattern }
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(text)
        for (index, piece) in pieces.enumerated() {
            if index == 0 {
                guard rest.hasPrefix(piece) else { return false }
                rest = rest.dropFirst(piece.count)
            } else if index == pieces.count - 1 {
                return piece.isEmpty || (rest.count >= piece.count && rest.hasSuffix(piece))
            } else if !piece.isEmpty {
                guard let found = rest.range(of: piece) else { return false }
                rest = rest[found.upperBound...]
            }
        }
        return true
    }

    /// Das eigene Icon des Spiels aus seinen Dateien, wenn die Vorlage keines hat: Der Vertrag nennt die Liste der
    /// Dateien des Spiels (`index`), die Namen, nach denen darin zu suchen ist, und wo eine Datei nach ihrer
    /// Prüfsumme liegt. Zurück kommen die Kandidaten in der Reihenfolge des Vertrags.
    static func iconCandidates(in archive: URL, parts: GameParts, contract: MachoTemplate.Contract) -> [Data] {
        guard !contract.iconIndex.isEmpty, !contract.iconObject.isEmpty,
              let index = parts.entries.first(where: { !$0.name.hasSuffix("/") && matches($0.name, pattern: parts.root + contract.iconIndex) && $0.size < 8 << 20 }),
              let data = try? Zip.data(of: index.name, in: archive),
              let objects = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["objects"] as? [String: Any] else { return [] }
        var found: [Data] = []
        for name in contract.iconNames {
            guard let hash = (objects[name] as? [String: Any])?["hash"] as? String, hash.count >= 2, hash.allSatisfy(\.isHexDigit) else { continue }
            let pattern = parts.root + contract.iconObject.replacingOccurrences(of: "{hash:2}", with: String(hash.prefix(2)))
                .replacingOccurrences(of: "{hash}", with: hash)
            guard let entry = parts.entries.first(where: { matches($0.name, pattern: pattern) && $0.size > 0 && $0.size < 8 << 20 }),
                  let picture = try? Zip.data(of: entry.name, in: archive) else { continue }
            found.append(picture)
        }
        return found
    }
}

/// Setzt aus der Vorlage und den Spielteilen die App zusammen, so wie `macho.json` es sagt: die Bibliotheken nach
/// `Frameworks/`, der Ordner des Spiels unverändert hinein, die Lizenzhinweise, vier Werte der Info.plist. Das
/// Ergebnis ist unsigniert; `SignCore` signiert es (alles unter `Frameworks/` zuerst, dann die App).
///
/// Nichts davon hält eine Datei als Ganzes im Speicher: Die Archive werden Stück für Stück ausgepackt.
enum FinishMacho {
    struct Request {
        var bundleID: String
        /// Die Fassung des Spiels, wie AVP Play sie führt („26.3“ und 260301).
        var versionName: String
        var versionCode: Int
        /// Das Team, wenn es schon feststeht. Sonst setzt `SignCore.sign` den einen Wert, der daran hängt.
        var team: String?
        /// Das Icon als einfache Dateien, wenn die Vorlage keines hat (wie bei `Finish.Request`).
        var pictures: [String: Data] = [:]
        var iconNames: [String] = []
    }

    struct Finished {
        /// Der Ordner mit `Payload/<App>`: was signiert und gepackt wird.
        let root: URL
        let bundleID: String
        let version: String
        let build: String
        let libraries: Int
        let bytes: Int64
    }

    /// `progress` hört, wie viel von den Spielteilen ausgepackt ist (0…1).
    static func run(_ request: Request, template: MachoTemplate, parts archive: URL, work: URL, log: (String) -> Void,
                    progress: ((Double) -> Void)? = nil) throws -> Finished {
        let files = FileManager.default
        let contract = template.contract
        let parts = try GameParts.inspect(archive, for: contract)
        try? files.removeItem(at: work)
        let root = work.appendingPathComponent("app"), payload = root.appendingPathComponent("Payload")
        try files.createDirectory(at: payload, withIntermediateDirectories: true)
        let app = payload.appendingPathComponent(template.app.lastPathComponent)
        // Die Vorlage ist für diesen einen Auftrag ausgepackt: Sie wird verschoben, nicht kopiert.
        try files.moveItem(at: template.app, to: app)
        // In der Vorlage darf nichts vom Spiel stecken; was dort läge, käme nicht aus den Spielteilen.
        guard !files.fileExists(atPath: app.appendingPathComponent(contract.payloadTo).path) else {
            throw FinishFailure(description: "the template already holds game files")
        }

        // 1. Wohin jede Datei der Spielteile gehört.
        var places: [String: String] = [:]      // Name im Archiv → Pfad in der App
        for name in contract.libraries {
            places[parts.root + contract.libraryFrom.replacingOccurrences(of: "{name}", with: name)] =
                contract.libraryTo.replacingOccurrences(of: "{name}", with: name)
        }
        let from = parts.root + contract.payloadFrom + "/"
        let licenseFolder = app.appendingPathComponent(contract.licenseTo)
        if parts.licenses != nil { try? files.removeItem(at: licenseFolder) }
        let total = max(parts.bytes, 1)
        try Zip.extract(archive, written: { progress?(min(1, Double($0) / Double(total))) }) { entry in
            var inside: String?
            if let place = places[entry.name] {
                inside = place
            } else if entry.name.hasPrefix(from) {
                inside = contract.payloadTo + "/" + entry.name.dropFirst(from.count)
            } else if let licenses = parts.licenses, entry.name.hasPrefix(licenses) {
                inside = contract.licenseTo + "/" + entry.name.dropFirst(licenses.count)
            }
            guard let inside else { return nil }
            let cleaned = inside.hasSuffix("/") ? String(inside.dropLast()) : inside
            guard MachoTemplate.isInside(cleaned) else {
                throw FinishFailure(description: "the game parts name a path outside the app: \(entry.name)")
            }
            return app.appendingPathComponent(inside)
        }

        // 2. Die Bibliotheken: jede ein Programm für die Vision Pro, unter dem Namen, unter dem die App sie lädt.
        for name in contract.libraries {
            let library = app.appendingPathComponent(contract.libraryTo.replacingOccurrences(of: "{name}", with: name))
            let facts = try MachO.facts(of: library)
            guard facts.arm64, facts.platform == MachO.visionOS else {
                throw FinishFailure(description: "\(name) is not built for the Vision Pro (64-bit ARM, visionOS)")
            }
            let wanted = contract.libraryInstallName.replacingOccurrences(of: "{name}", with: name)
            guard wanted.isEmpty || facts.installName == wanted else {
                throw FinishFailure(description: "\(name) is named \(facts.installName ?? "nothing") inside, not \(wanted)")
            }
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        }
        log("     libraries: \(contract.libraries.count) → \((contract.libraryTo as NSString).deletingLastPathComponent)/")

        // 3. Der Ordner des Spiels: für dieses Ziel gebaut, und vollständig.
        let folder = app.appendingPathComponent(contract.payloadTo)
        let tree = (try? String(contentsOf: folder.appendingPathComponent("tree"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contract.payloadTree.isEmpty || tree == contract.payloadTree else {
            throw FinishFailure(description: "the game parts are laid out for \(tree ?? "nothing"), not for \(contract.payloadTree)")
        }
        let stamp = (try? String(contentsOf: folder.appendingPathComponent("payload-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("     game files: \(stamp.prefix(12)) → \(contract.payloadTo)")
        if let licenses = parts.licenses {
            guard files.fileExists(atPath: licenseFolder.appendingPathComponent(contract.licenseIndex).path) else {
                throw FinishFailure(description: "the licence notices of the game parts did not arrive")
            }
            log("     licence notices: the game parts' own (\(licenses.dropLast()))")
        }

        // 4. Info.plist: Die Werte des Spiels stehen schon darin; geschrieben wird, wessen App es ist.
        let infoFile = app.appendingPathComponent(contract.infoFile)
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoFile), format: nil) as? [String: Any] else {
            throw FinishFailure(description: "the template's Info.plist is not readable")
        }
        for (key, value) in contract.infoRow where plist[key] as? String != value {
            throw FinishFailure(description: "the template's Info.plist does not hold the value its description names for \(key)")
        }
        let version = Stamp.short(request.versionName)
        let build = "\(max(0, request.versionCode)).\(template.version)"
        let values = ["bundleId": request.bundleID, "team": request.team ?? "", "version": version, "build": build]
        for (key, pattern) in contract.infoWrite {
            var value = pattern
            for (name, text) in values { value = value.replacingOccurrences(of: "{\(name)}", with: text) }
            guard !value.contains("{") else { throw FinishFailure(description: "the template asks for a value this app does not know: \(pattern)") }
            plist[key] = value
        }
        // Ohne kompiliertes Icon: das eigene des Spiels als einfache Dateien, wie bei den Spielen aus dem Store.
        if !contract.iconCompiled, !request.iconNames.isEmpty {
            for (name, data) in request.pictures { try data.write(to: app.appendingPathComponent(name)) }
            let icons: [String: Any] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": request.iconNames]]
            plist["CFBundleIcons"] = icons
            plist["CFBundleIcons~ipad"] = icons
            plist["CFBundleIconName"] = nil
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: infoFile)
        log("     \(plist["CFBundleDisplayName"] ?? plist["CFBundleName"] ?? contract.target) \(version) (\(build))")
        return Finished(root: root, bundleID: request.bundleID, version: version, build: build, libraries: contract.libraries.count, bytes: parts.bytes)
    }

    /// Was signiert wird, in der Reihenfolge des Vertrags, als Pfade in der App: zum Nachsehen und für einen
    /// Signierer, der jede Datei einzeln signiert. `SignCore` signiert das Paket als Ganzes und hält dieselbe
    /// Reihenfolge ein (innen zuerst).
    static func signOrder(app: URL, contract: MachoTemplate.Contract) -> [String] {
        var order: [String] = []
        for pattern in contract.sign {
            if pattern == "." { order.append("."); continue }
            let folder = (pattern as NSString).deletingLastPathComponent, name = (pattern as NSString).lastPathComponent
            let found = ((try? FileManager.default.contentsOfDirectory(atPath: app.appendingPathComponent(folder).path)) ?? []).sorted()
            order += found.filter { GameParts.matches($0, pattern: name) }.map { folder.isEmpty ? $0 : "\(folder)/\($0)" }
        }
        return order
    }
}

/// Das Wenige, das von einer Mach-O-Datei gelesen wird: für welche Plattform sie gebaut ist und wie sie heißt.
enum MachO {
    static let visionOS: UInt32 = 11

    struct Facts {
        let arm64: Bool
        let platform: UInt32?
        let installName: String?
    }

    static func facts(of file: URL) throws -> Facts {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 32), header.count == 32 else {
            throw FinishFailure(description: "\(file.lastPathComponent) is not a program")
        }
        func u32(_ data: Data, _ at: Int) -> UInt32 {
            let base = data.startIndex + at
            return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
        }
        guard u32(header, 0) == 0xFEED_FACF else {
            throw FinishFailure(description: "\(file.lastPathComponent) is not a 64-bit program for one kind of chip")
        }
        let arm64 = u32(header, 4) == 0x0100_000C
        let count = Int(u32(header, 16)), size = Int(u32(header, 20))
        guard size > 0, size < 1 << 20, let commands = try handle.read(upToCount: size), commands.count == size else {
            throw FinishFailure(description: "\(file.lastPathComponent) is cut off")
        }
        var platform: UInt32?, installName: String?
        var at = 0
        for _ in 0 ..< count {
            guard at + 8 <= size else { break }
            let command = u32(commands, at), length = Int(u32(commands, at + 4))
            guard length >= 8, at + length <= size else { break }
            if command == 0x32, length >= 12 {                      // LC_BUILD_VERSION
                platform = u32(commands, at + 8)
            } else if command == 0x0D, length >= 24 {               // LC_ID_DYLIB
                let offset = Int(u32(commands, at + 8))
                if offset < length {
                    let bytes = commands[(commands.startIndex + at + offset) ..< (commands.startIndex + at + length)]
                    installName = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            at += length
        }
        return Facts(arm64: arm64, platform: platform, installName: installName)
    }
}
