import Foundation

struct FinishFailure: Error, CustomStringConvertible {
    let description: String
}

/// Klepton's app template (visionos/mktemplate.sh), unpacked: the app with no game in it, and what the toolchain
/// knows about games.
struct Template {
    let app: URL
    let entitlements: URL
    /// The toolchain's number: the last part of a finished app's build number.
    let version: Int
    let commit: String
    private let targets: [String: Any]
    /// Set in a template that carries a game's mods (klepton-mods-….zip): what that game has to be.
    let mods: Mods?

    /// The mods of one game version (visionos/build/mods.json, ports/scotland2/tools/stage_avp_mods.py --template):
    /// they hook the game at measured places, so the game's files have to be exactly the ones measured.
    struct Mods {
        let name: String, target: String, versionName: String
        let versionCode: Int
        /// On unless the user switches the mods off.
        let defaultOn: Bool
        /// SHA-256 of the game's files, by name: its libraries, and global-metadata.dat.
        let gameFiles: [String: String]
        /// Per library of the game (without ".so"): its SHA-256, the entries that get a gate, and how deep.
        let libraries: [String: (sha256: String, targets: [[String: Any]], depth: Int)]
        /// Libraries the mods bring themselves (without ".so"); the game's own copy stays out.
        let replaced: Set<String>

        init?(_ object: [String: Any]) {
            guard object["schema"] as? Int == 1, let profile = object["profile"] as? [String: Any], let name = profile["name"] as? String,
                  let target = profile["target"] as? String, let versionName = profile["versionName"] as? String,
                  let versionCode = profile["versionCode"] as? Int, let gameFiles = object["gameFiles"] as? [String: String],
                  let rows = object["libraries"] as? [String: [String: Any]] else { return nil }
            var libraries: [String: (sha256: String, targets: [[String: Any]], depth: Int)] = [:]
            for (library, row) in rows {
                guard let sha = row["sha256"] as? String, let targets = row["targets"] as? [[String: Any]] else { return nil }
                libraries[library] = (sha, targets, row["originalEntryDepth"] as? Int ?? 0)
            }
            (self.name, self.target, self.versionName, self.versionCode) = (name, target, versionName, versionCode)
            (self.gameFiles, self.libraries) = (gameFiles, libraries)
            defaultOn = profile["defaultOn"] as? Bool ?? false
            replaced = Set(object["replaced"] as? [String] ?? [])
        }

        /// Reads only this from a template archive, without unpacking the app.
        static func read(from archive: URL) -> Mods? {
            guard let data = try? Zip.data(of: "mods.json", in: archive),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Mods(object)
        }
    }

    static func open(_ archive: URL, in folder: URL) throws -> Template {
        try? FileManager.default.removeItem(at: folder)
        try Zip.unpack(archive, to: folder)
        func json(_ name: String) throws -> [String: Any] {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name))) as? [String: Any] else {
                throw FinishFailure(description: "the template's \(name) is not readable")
            }
            return object
        }
        let facts = try json("template.json")
        guard let app = facts["app"] as? String, let version = facts["version"] as? Int, let commit = facts["commit"] as? String else {
            throw FinishFailure(description: "the template does not say which toolchain it is")
        }
        var mods: Mods?
        if facts["mods"] as? Bool == true {
            guard let described = Mods(try json("mods.json")) else { throw FinishFailure(description: "the template's mods.json is not readable") }
            mods = described
        }
        return Template(app: folder.appendingPathComponent(app), entitlements: folder.appendingPathComponent("Klepton.entitlements"),
                        version: version, commit: commit, targets: try json("targets.json"), mods: mods)
    }

    /// The row of a game the toolchain's table has, or nil.
    func known(_ target: String) -> [String: Any]? { (targets["targets"] as? [String: Any])?[target] as? [String: Any] }

    private var generic: [String: Any] { targets["generic"] as? [String: Any] ?? [:] }
    /// The Info.plist values of a store title outside the table: what is known about this title, else the defaults.
    func storeInfo(_ target: String) -> [String: String] {
        ((targets["store"] as? [String: Any])?[target] ?? generic["info"]) as? [String: String] ?? [:]
    }
    func storeObb(_ target: String) -> String? { (generic["obb"] as? [String: String])?[target] }
    /// Libraries a game ships that are never translated: the runtime takes their place, or they are left out.
    var skippedLibraries: Set<String> {
        Set((generic["replacedLibraries"] as? [String] ?? []) + (generic["excludedLibraries"] as? [String] ?? []))
    }
}

/// Makes an app for one game out of the template, without a compiler: the game's libraries are translated into it,
/// and its Info.plist says which game it is. What AVP Play does on a Mac with targets.py, mkguest.sh and
/// gen_xcodeproj.py. The result is unsigned; SignCore signs it.
enum Finish {
    struct Request {
        /// Where the game's code comes from: its APK, or a folder that already holds its `.so` files.
        var apk: URL?
        var libraries: URL?
        /// A name from the toolchain's table ("sourcevr-hl2"), or the store's app id for a title outside it.
        var target: String?
        var appID: String?
        var title: String
        var bundleID: String
        /// Needed when there is no APK to read them from.
        var versionName: String?
        var versionCode: String?
        /// Info.plist values the user's settings decide (room measuring, game language, render scale): they win over
        /// the row's.
        var settings: [String: String] = [:]
        /// Test switches to add to the row's own (KLTestOn), like MetalFX upscaling.
        var switches: [String] = []
        /// Pictures to put into the app as plain files, by file name: the start image (`StartHero.png`, which the app
        /// loads by name) and the icon in several sizes.
        var pictures: [String: Data] = [:]
        /// The base names of the icon files among `pictures` ("AppIcon60x60" for "AppIcon60x60@2x.png").
        var iconNames: [String] = []
        /// The third number of the build (AVP Play's AppStamp.build): 4 and 8 × the resolution step for a build with
        /// MetalFX upscaling switched on. 256 for the mods is added here, when the template carries them.
        var buildExtra = 0
    }

    struct Finished {
        /// The folder holding `Payload/<app>`: what gets signed and packed.
        let root: URL
        let target: String
        let bundleID: String
        let build: String
        /// The game's row: where its data goes in the app's container.
        let tree: String, apkName: String, obb: String, kind: String
        /// The manifest as text, and the small version file: both go into the container beside the assets.
        let manifest: String?, apktoolYml: String?
        let package: String?
        let libraries: [String]
    }

    /// targets.py, _generic_row: for a title outside the table, the engine decides the entry library and where the
    /// OBB is looked for.
    static func genericRow(libraries names: Set<String>, package: String?, manifest: String?) -> (kind: String, entry: String, obb: String) {
        let androidObb = package.map { "Android/obb/\($0)" } ?? "obb"
        if names.contains("libUE4") { return ("ue4", "libUE4", androidObb) }
        if names.contains("libUnreal") { return ("ue4", "libUnreal", androidObb) }
        if !names.isDisjoint(with: ["libil2cpp", "libunity", "libmono", "libmonobdwgc-2.0"]) { return ("unity", "libmain", "obb") }
        if names.contains("libSDL2") { return ("sdl2", "libmain", "obb") }
        let native = manifest.flatMap { firstMatch(#"android:name="android\.app\.lib_name"\s+android:value="([A-Za-z0-9_.+-]+)""#, in: $0) }
        return ("native", native.map { "lib\($0)" } ?? "libmain", androidObb)
    }

    /// Where a game's data belongs in its container, read from the APK alone – before anything is built: the
    /// package name and the OBB folder below `android-files`. `nil` for the libraries: not a 64-bit ARM game.
    static func places(apk: URL, target: String?, appID: String, template: Template) throws -> (package: String?, obb: String, arm64: Bool) {
        guard let binary = try Zip.data(of: "AndroidManifest.xml", in: apk) else {
            throw FinishFailure(description: "\(apk.lastPathComponent) has no AndroidManifest.xml: not an Android package")
        }
        let decoded = try AXML.decode(binary)
        let prefix = "lib/arm64-v8a/"
        let names = Set(try Zip.names(in: apk).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".so") && !$0.dropFirst(prefix.count).contains("/") }
            .map { String($0.dropFirst(prefix.count).dropLast(3)) })
        if let name = target, let known = template.known(name) {
            return (decoded.package, known["obb"] as? String ?? "obb", !names.isEmpty)
        }
        let row = genericRow(libraries: names, package: decoded.package, manifest: decoded.text)
        return (decoded.package, template.storeObb("x\(appID)") ?? row.obb, !names.isEmpty)
    }

    static func run(_ request: Request, template: Template, work: URL, log: (String) -> Void) throws -> Finished {
        let files = FileManager.default
        try? files.removeItem(at: work)
        let root = work.appendingPathComponent("app"), payload = root.appendingPathComponent("Payload")
        try files.createDirectory(at: payload, withIntermediateDirectories: true)
        let app = payload.appendingPathComponent(template.app.lastPathComponent)
        try files.copyItem(at: template.app, to: app)

        // 1. The game's code and its manifest.
        var librariesFolder = request.libraries
        var manifest: String?, package: String?, versionCode = request.versionCode, versionName = request.versionName
        if let apk = request.apk {
            guard let binary = try Zip.data(of: "AndroidManifest.xml", in: apk) else {
                throw FinishFailure(description: "\(apk.lastPathComponent) has no AndroidManifest.xml: not an Android package")
            }
            let decoded = try AXML.decode(binary)
            (manifest, package) = (decoded.text, decoded.package)
            versionCode = decoded.versionCode ?? versionCode
            versionName = decoded.versionName ?? versionName
            let unpacked = work.appendingPathComponent("apk")
            let prefix = "lib/arm64-v8a/"
            try Zip.unpack(apk, to: unpacked) { $0.hasPrefix(prefix) && $0.hasSuffix(".so") && !$0.dropFirst(prefix.count).contains("/") }
            librariesFolder = unpacked.appendingPathComponent(prefix)
        }
        guard let librariesFolder, let shipped = try? files.contentsOfDirectory(atPath: librariesFolder.path), !shipped.isEmpty else {
            throw FinishFailure(description: "the game has no 64-bit ARM libraries")
        }
        let names = Set(shipped.filter { $0.hasSuffix(".so") }.map { String($0.dropLast(3)) })

        // 2. Which game, and its row.
        let target: String
        var entry: String, obb: String, kind: String, info: [String: String], tree: String, apkName: String
        var listed: [String]?
        var row: [String: String] = [:]     // KLTarget… for a title outside the table
        if let name = request.target, let known = template.known(name) {
            target = name
            entry = known["entry"] as? String ?? "libmain"
            obb = known["obb"] as? String ?? "obb"
            kind = known["kind"] as? String ?? "unity"
            tree = known["tree"] as? String ?? name
            apkName = known["apk"] as? String ?? "\(name).apk"
            info = known["info"] as? [String: String] ?? [:]
            listed = known["libraries"] as? [String]
        } else {
            guard let id = request.appID, id.count >= 5, id.count <= 24, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw FinishFailure(description: "neither a game the toolchain knows nor a store app id")
            }
            target = "x\(id)"
            (kind, entry, obb) = genericRow(libraries: names, package: package, manifest: manifest)
            obb = template.storeObb(target) ?? obb
            (tree, apkName) = (target, "\(target).apk")
            info = template.storeInfo(target)
            row = ["KLTarget": target, "KLTargetEntry": entry, "KLTargetObb": obb, "KLTargetKind": kind]
        }
        if row.isEmpty { row = ["KLTarget": target] }
        log("     \(target): \(kind), starts at \(entry), OBB in \(obb)")

        // 3. The libraries to translate: the ones the row names, else every real ELF library the game ships except
        //    those the runtime replaces (Makefile, guestlibs-list).
        let libraries = try listed ?? names.subtracting(template.skippedLibraries).filter { name in
            let handle = try FileHandle(forReadingFrom: librariesFolder.appendingPathComponent("\(name).so"))
            defer { try? handle.close() }
            return handle.readData(ofLength: 4) == Data([0x7F, 0x45, 0x4C, 0x46])
        }.sorted()
        guard libraries.contains(entry) else {
            throw FinishFailure(description: "the game has no \(entry).so to start at: not a game this runtime can run")
        }
        // With the mods (stage_avp_mods.py): the game has to be exactly the version its hooks were measured on.
        if let mods = template.mods {
            guard target == mods.target, versionCode == "\(mods.versionCode)" else {
                throw FinishFailure(description: "the mods in this template are for \(mods.target) \(mods.versionName), not for \(target) \(versionName ?? "")")
            }
            for (name, expected) in mods.gameFiles {
                let data: Data?
                if name == "global-metadata.dat" {
                    data = try request.apk.flatMap { try Zip.data(of: "assets/bin/Data/Managed/Metadata/\(name)", in: $0) }
                } else {
                    data = try? Data(contentsOf: librariesFolder.appendingPathComponent(name), options: .mappedIfSafe)
                }
                guard let data, Hashing.sha256(of: data) == expected.lowercased() else {
                    throw FinishFailure(description: "\(name) is not the one of \(mods.versionName); the mods need exactly that version")
                }
            }
        }
        // ...and the mods bring some libraries themselves (the C++ runtime): the game's own copy stays out.
        let translated = libraries.filter { !(template.mods?.replaced.contains($0) ?? false) }
        try Translate.run(Guest(sources: librariesFolder, target: target, libraries: translated, expected: [:]),
                          into: app, scratch: work, log: log)
        // The game's own libraries get their hook gates now, before anything is signed (prepare_hooks.py).
        if let mods = template.mods {
            var entries = 0
            for (name, profile) in mods.libraries {
                let binary = app.appendingPathComponent("Frameworks/\(name).framework/\(name)")
                let prepared = try HookPrepare.run(elf: Data(contentsOf: librariesFolder.appendingPathComponent("\(name).so"), options: .mappedIfSafe),
                                                   macho: Data(contentsOf: binary), elfSHA256: profile.sha256, targets: profile.targets,
                                                   originalEntryDepth: profile.depth)
                try prepared.write(to: binary)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                entries += profile.targets.count
            }
            log("     mods: \(mods.versionName), \(entries) game entries prepared")
        }

        // 4. Info.plist: which game this is, and the settings its row asks for.
        let infoFile = app.appendingPathComponent("Info.plist")
        guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoFile), format: nil) as? [String: Any] else {
            throw FinishFailure(description: "the template's Info.plist is not readable")
        }
        let extra = request.buildExtra + (template.mods != nil ? 256 : 0)
        let build = "\(versionCode ?? "0").\(template.version)" + (extra > 0 ? ".\(extra)" : "")
        let title = String(request.title.filter { !$0.isNewline }.prefix(60)).trimmingCharacters(in: .whitespaces)
        plist["CFBundleIdentifier"] = request.bundleID
        plist["CFBundleDisplayName"] = title.isEmpty ? target : title
        plist["CFBundleName"] = title.isEmpty ? target : title
        plist["CFBundleShortVersionString"] = shortVersion(versionName ?? "")
        plist["CFBundleVersion"] = build
        for (key, value) in row { plist[key] = value }
        for (key, value) in info { plist[key] = value }
        for (key, value) in request.settings { plist[key] = value }
        if !request.switches.isEmpty {
            let own = (plist["KLTestOn"] as? String ?? "").split(separator: ",").map(String.init)
            plist["KLTestOn"] = (own + request.switches.filter { !own.contains($0) }).joined(separator: ",")
        }
        // The template has no compiled asset catalog (that takes Xcode), so the icon is named as plain files.
        for (name, data) in request.pictures { try data.write(to: app.appendingPathComponent(name)) }
        if !request.iconNames.isEmpty {
            let icons: [String: Any] = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": request.iconNames]]
            plist["CFBundleIcons"] = icons
            plist["CFBundleIcons~ipad"] = icons
            plist["CFBundleIconName"] = nil
        }
        plist["KLApkName"] = apkName
        plist["KLObbRel"] = obb
        plist["KLTree"] = ""            // the in-app data page is for rows that name their OBB; none finished here does
        plist["KLOvrpGuestVersion"] = ovrPluginVersion(in: librariesFolder) ?? ""
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: infoFile)
        log("     \(plist["CFBundleDisplayName"] ?? "") \(plist["CFBundleShortVersionString"] ?? "") (\(build)), OVRPlugin \((plist["KLOvrpGuestVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none")")

        if request.apk != nil { try? files.removeItem(at: work.appendingPathComponent("apk")) }
        return Finished(root: root, target: target, bundleID: request.bundleID, build: build, tree: tree, apkName: apkName,
                        obb: obb, kind: kind, manifest: manifest,
                        apktoolYml: manifest == nil ? nil : "versionInfo:\n  versionCode: \(versionCode ?? "")\n  versionName: \(versionName ?? "")\n",
                        package: package, libraries: libraries)
    }

    /// AVP Play's AppStamp.short: the game's version cut to three numbers ("1.40.8_7379" → "1.40.8").
    static func shortVersion(_ name: String) -> String {
        var tokens: [String] = [], current = ""
        for character in name {
            if character.isASCII, character.isNumber || character == "." {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        for token in tokens {
            let parts = token.split(separator: ".").map(String.init).prefix(3)
            if !parts.isEmpty, parts.allSatisfy({ $0.count <= 9 }) { return parts.joined(separator: ".") }
        }
        return "1.0"
    }

    /// targets.py, ovrp_guest_version: the one NUL-delimited "1.<minor ≥ 20>.<patch>" in the game's libOVRPlugin.so.
    static func ovrPluginVersion(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("libOVRPlugin.so"), options: .mappedIfSafe) else { return nil }
        var found = Set<String>()
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            let count = bytes.count
            while index + 6 < count {
                // A candidate starts with NUL '1' '.'
                guard bytes[index] == 0, bytes[index + 1] == 0x31, bytes[index + 2] == 0x2E else { index += 1; continue }
                var end = index + 3
                while end < count, end - index < 12, bytes[end] != 0 { end += 1 }
                if end < count, bytes[end] == 0 {
                    let text = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(index + 1) ..< end]), as: UTF8.self)
                    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
                    if parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
                       let minor = Int(parts[1]), minor >= 20 {
                        found.insert(text)
                    }
                }
                index = end
            }
        }
        return found.count == 1 ? found.first : nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
