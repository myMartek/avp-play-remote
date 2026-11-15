// Die Prüfungen von tools/headset-check: kleine, gestellte Fälle für das, was die Brille mit einem auf dem Mac gebauten
// Spiel tut – Archive lesen und schreiben, den Vertrag der Vorlage, das Zusammensetzen, den Stand eines Spiels.
import Foundation

var failures = 0, checks = 0

func check(_ ok: Bool, _ what: String) {
    checks += 1
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

/// Ob `body` mit einer Meldung scheitert, in der `text` vorkommt.
func fails(_ text: String, _ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return "\(error)".contains(text) }
}

@discardableResult
func shell(_ tool: String, _ arguments: [String], in folder: URL? = nil) -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Eine Bibliothek, wie `MachO.facts` sie liest: Kopf, Name, Plattform – und sonst nichts.
func fakeLibrary(name: String, platform: UInt32 = MachO.visionOS, arm64: Bool = true) -> Data {
    func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    var text = Data(name.utf8) + Data([0])
    while text.count % 8 != 0 { text.append(0) }
    let id = u32(0x0D) + u32(UInt32(24 + text.count)) + u32(24) + u32(0) + u32(0) + u32(0) + text
    let build = u32(0x32) + u32(24) + u32(platform) + u32(0x0002_0000) + u32(0x0002_0000) + u32(0)
    return u32(0xFEED_FACF) + u32(arm64 ? 0x0100_000C : 0x0100_0007) + u32(0) + u32(6) + u32(2) + u32(UInt32(id.count + build.count))
        + u32(0) + u32(0) + id + build
}

/// Ein Vertrag wie der von Toolchain 894, mit zwei Bibliotheken.
func sampleContract(iconCompiled: Bool = false) -> [String: Any] {
    [
        "format": 1, "kind": "macho", "target": "vivecraft", "version": 894, "commit": "4540abb", "app": "Payload/KleptonVivecraft.app",
        "entitlements": "Klepton.entitlements", "executable": "KleptonVivecraft", "display": "Minecraft",
        "libraries": ["architecture": "arm64", "platform": "visionOS", "from": "Frameworks/{name}.dylib", "to": "Frameworks/{name}.dylib",
                      "installName": "@rpath/{name}.dylib", "names": ["libminecraft", "liblwjgl"]],
        "payload": ["from": "klepton-payload", "to": "klepton-payload", "tree": "vivecraft",
                    "requires": ["launch.txt", "payload-version", "tree", "root/inst-*"]],
        "licenses": ["from": ["Licenses", "../../Licenses"], "index": "NOTICES.txt", "to": "Licenses", "inTemplate": 1],
        "info": ["file": "Info.plist", "row": ["KLOutputDefault": "full"],
                 "write": ["CFBundleIdentifier": "{bundleId}", "CFBundleShortVersionString": "{version}", "CFBundleVersion": "{build}",
                           "KLSharedKeychainGroup": "{team}.avpplay.shared"]],
        "sign": ["Frameworks/*.dylib", "Frameworks/*.framework", "."],
        "icon": ["compiled": iconCompiled, "name": "AppIcon-vivecraft",
                 "game": ["index": "klepton-payload/root/inst-*/assets/indexes/*.json", "names": ["icons/minecraft.icns", "icons/icon_256x256.png"],
                          "object": "klepton-payload/root/inst-*/assets/objects/{hash:2}/{hash}"]],
    ]
}

/// Legt eine gestellte Vorlage und gestellte Spielteile an und packt beide mit dem Zip des Systems (also verdichtet).
func makeSamples(in folder: URL, contract: [String: Any] = sampleContract(), row: String = "full", platform: UInt32 = MachO.visionOS,
                 tree: String = "vivecraft", leaveOut: String? = nil, ownLicenses: Bool = true) throws -> (template: URL, parts: URL) {
    let files = FileManager.default
    try? files.removeItem(at: folder)
    func write(_ data: Data, _ path: String, mode: Int = 0o644) throws {
        let file = folder.appendingPathComponent(path)
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
    // Die Vorlage: die App ohne das Spiel.
    let app = "t/Payload/KleptonVivecraft.app"
    try write(Data("program".utf8), "\(app)/KleptonVivecraft", mode: 0o755)
    let info: [String: Any] = ["CFBundleIdentifier": "x", "CFBundleDisplayName": "Minecraft", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                               "KLSharedKeychainGroup": "0000000000.avpplay.shared", "KLOutputDefault": row, "CFBundleIconName": "AppIcon-vivecraft"]
    try write(try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0), "\(app)/Info.plist")
    try write(Data("template notices".utf8), "\(app)/Licenses/NOTICES.txt")
    try write(Data("old".utf8), "\(app)/Licenses/old.txt")
    try write(fakeLibrary(name: "@rpath/libEGL.framework/libEGL"), "\(app)/Frameworks/libEGL.framework/libEGL", mode: 0o755)
    try write(try JSONSerialization.data(withJSONObject: contract), "t/macho.json")
    try write(Data(#"{"format": 1, "version": 894, "commit": "4540abb", "app": "Payload/KleptonVivecraft.app", "surreal": false, "mods": false, "macho": "vivecraft"}"#.utf8), "t/template.json")
    try write(Data("""
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
    <key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string><string>$(AppIdentifierPrefix)avpplay.shared</string></array>
    <key>com.apple.developer.kernel.increased-memory-limit</key><true/>
    <key>com.apple.developer.low-latency-streaming</key><true/>
    </dict></plist>
    """.utf8), "t/Klepton.entitlements")
    // Die Spielteile: ein Archiv in der Form eines App-Pakets, mit mehr darin, als gebraucht wird.
    let game = "p/Payload/Vivecraft.app"
    var big = Data(count: 3 << 20)
    big.withUnsafeMutableBytes { bytes in for index in stride(from: 0, to: bytes.count, by: 7) { bytes[index] = UInt8(truncatingIfNeeded: index &* 31) } }
    for name in ["libminecraft", "liblwjgl"] where name != leaveOut {
        try write(fakeLibrary(name: "@rpath/\(name).dylib", platform: platform) + (name == "libminecraft" ? big : Data()), "\(game)/Frameworks/\(name).dylib")
    }
    try write(Data("someone else's program".utf8), "\(game)/Vivecraft", mode: 0o755)
    try write(Data("not wanted".utf8), "\(game)/Frameworks/libother.dylib")
    try write(Data("launch".utf8), "\(game)/klepton-payload/launch.txt")
    try write(Data("d1556f13aaaabbbbcccc\n".utf8), "\(game)/klepton-payload/payload-version")
    try write(Data("\(tree)\n".utf8), "\(game)/klepton-payload/tree")
    try write(Data(), "\(game)/klepton-payload/root/inst-26.3/empty.txt")
    try write(Data("#!/bin/sh\n".utf8), "\(game)/klepton-payload/root/inst-26.3/run.sh", mode: 0o755)
    try write(Data(#"{"objects": {"icons/icon_256x256.png": {"hash": "ab12cd", "size": 3}, "icons/minecraft.icns": {"hash": "ffee00", "size": 4}}}"#.utf8),
              "\(game)/klepton-payload/root/inst-26.3/assets/indexes/26.json")
    try write(Data("PNG".utf8), "\(game)/klepton-payload/root/inst-26.3/assets/objects/ab/ab12cd")
    try write(Data("ICNS".utf8), "\(game)/klepton-payload/root/inst-26.3/assets/objects/ff/ffee00")
    if ownLicenses {
        try write(Data("the parts' notices".utf8), "\(game)/Licenses/NOTICES.txt")
        try write(Data("mit".utf8), "\(game)/Licenses/a/MIT.txt")
    }
    let template = folder.appendingPathComponent("klepton-macho-vivecraft-894-4540abb.zip"), parts = folder.appendingPathComponent("vivecraft-parts-1-abc1234.zip")
    guard shell("/usr/bin/zip", ["-qry", template.path, "Payload", "Klepton.entitlements", "template.json", "macho.json"], in: folder.appendingPathComponent("t")).status == 0,
          shell("/usr/bin/zip", ["-qry", parts.path, "Payload"], in: folder.appendingPathComponent("p")).status == 0 else {
        throw FinishFailure(description: "zip did not run")
    }
    return (template, parts)
}

func runChecks(scratch: URL) -> Int32 {
    let files = FileManager.default
    try? files.removeItem(at: scratch)
    try? files.createDirectory(at: scratch, withIntermediateDirectories: true)
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func mode(_ url: URL) -> Int? { (try? files.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int }

    // --- Namen und Muster -------------------------------------------------------------------------------------
    check(Stamp.short("26.3") == "26.3" && Stamp.short("1.40.8_7379") == "1.40.8" && Stamp.short("abc") == "1.0", "Fassung: wie AVP Play sie kürzt")
    let named = MachoTemplate.named("klepton-macho-vivecraft-894-4540abb.zip")
    check(named?.target == "vivecraft" && named?.version == 894 && named?.stamp == "894-4540abb", "Vorlage: Ziel und Nummer aus dem Namen")
    check(MachoTemplate.named("klepton-macho-some-game-12-abc.zip")?.target == "some-game", "Vorlage: ein Ziel mit Bindestrich")
    check(MachoTemplate.named("klepton-template-894-4540abb.zip") == nil && MachoTemplate.named("klepton-macho-894-4540abb.zip") == nil, "Vorlage: andere Namen gelten nicht")
    check(GameParts.matches("a/root/inst-26.3/x/y", pattern: "a/root/inst-*") && !GameParts.matches("a/root/other/x", pattern: "a/root/inst-*")
          && GameParts.matches("a/tree", pattern: "a/tree") && !GameParts.matches("a", pattern: "a/tree")
          && GameParts.matches("a/b/26.json", pattern: "a/b/*.json") && !GameParts.matches("a/b/26.txt", pattern: "a/b/*.json"), "Muster: ein Stern steht für einen Namen")
    check(GameParts.resolve("Payload/X.app/../../Licenses") == "Licenses/" && GameParts.resolve("Payload/X.app/Licenses") == "Payload/X.app/Licenses/"
          && GameParts.resolve("a/../../b") == nil, "Pfade: „..“ wird aufgelöst und verlässt das Archiv nicht")
    check(MachoTemplate.isInside("Frameworks/{name}.dylib") && !MachoTemplate.isInside("../x") && !MachoTemplate.isInside("/x") && !MachoTemplate.isInside("a//b"),
          "Pfade: nur solche, die im Ordner bleiben")

    // --- Archive: lesen und schreiben, in Stücken ------------------------------------------------------------
    do {
        let source = scratch.appendingPathComponent("zip-in")
        try files.createDirectory(at: source.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        var large = Data(count: 5 << 20 | 123)
        large.withUnsafeMutableBytes { bytes in for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: (index &* 2_654_435_761) >> 13) } }
        try large.write(to: source.appendingPathComponent("large.bin"))
        try Data(repeating: 0x41, count: 2 << 20).write(to: source.appendingPathComponent("sub/squeezable.bin"))
        try Data().write(to: source.appendingPathComponent("sub/empty"))
        try Data("#!/bin/sh\n".utf8).write(to: source.appendingPathComponent("sub/deep/tool"))
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("sub/deep/tool").path)
        try files.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "sub/empty")
        func same(_ folder: URL) -> Bool {
            ["large.bin", "sub/squeezable.bin", "sub/empty", "sub/deep/tool"].allSatisfy {
                (try? Data(contentsOf: folder.appendingPathComponent($0))) == (try? Data(contentsOf: source.appendingPathComponent($0)))
            } && mode(folder.appendingPathComponent("sub/deep/tool")) == 0o755
                && (try? files.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path)) == "sub/empty"
        }
        // Verdichtet, vom Zip des Systems gepackt:
        let deflated = scratch.appendingPathComponent("deflated.zip")
        check(shell("/usr/bin/zip", ["-qry", deflated.path, "."], in: source).status == 0, "Archiv: das Zip des Systems packt die Probe")
        try Zip.unpack(deflated, to: scratch.appendingPathComponent("zip-out-1"))
        check(same(scratch.appendingPathComponent("zip-out-1")), "Archiv: verdichtete Einträge kommen Stück für Stück gleich heraus (Inhalt, Rechte, Verweis)")
        check(try Zip.data(of: "sub/squeezable.bin", in: deflated) == Data(repeating: 0x41, count: 2 << 20) && Zip.data(of: "nichts", in: deflated) == nil,
              "Archiv: ein einzelner Eintrag im Speicher")
        check(try Zip.entries(in: deflated).first { $0.name == "large.bin" }?.size == 5 << 20 | 123, "Archiv: die Liste nennt die Größen")
        // Unverdichtet, selbst gepackt:
        let stored = scratch.appendingPathComponent("stored.zip")
        var heard: Int64 = 0
        try Zip.pack(folder: source, to: stored) { heard = $0 }
        check(heard == Int64(large.count + (2 << 20) + 10), "Archiv: Packen meldet, wie viel geschrieben ist")
        let tested = shell("/usr/bin/unzip", ["-tq", stored.path])
        check(tested.status == 0, "Archiv: das Zip des Systems findet am selbst gepackten keinen Fehler (\(tested.output.trimmingCharacters(in: .whitespacesAndNewlines)))")
        try Zip.unpack(stored, to: scratch.appendingPathComponent("zip-out-2"))
        check(same(scratch.appendingPathComponent("zip-out-2")), "Archiv: selbst Gepacktes kommt gleich heraus")
        // Nur ein Teil, an andere Orte:
        try Zip.extract(stored) { $0.name == "sub/deep/tool" ? scratch.appendingPathComponent("zip-out-3/elsewhere/t") : nil }
        check(read(scratch.appendingPathComponent("zip-out-3/elsewhere/t")) == "#!/bin/sh\n"
              && (try? files.contentsOfDirectory(atPath: scratch.appendingPathComponent("zip-out-3").path)) == ["elsewhere"], "Archiv: einzelne Einträge an einen anderen Ort")
        // Ein beschädigter Eintrag fällt auf.
        var damaged = try Data(contentsOf: stored)
        if let at = damaged.range(of: Data(repeating: 0x41, count: 64))?.lowerBound { damaged[at + 10] = 0x42 }
        let broken = scratch.appendingPathComponent("broken.zip")
        try damaged.write(to: broken)
        check(fails("checksum") { try Zip.unpack(broken, to: scratch.appendingPathComponent("zip-out-4")) }, "Archiv: ein beschädigter Eintrag wird nicht angenommen")
        check(fails("not a zip") { _ = try Zip.entries(in: source.appendingPathComponent("large.bin")) }, "Archiv: keine Zip-Datei")
    } catch { check(false, "Archiv: \(error)") }

    // --- Mach-O --------------------------------------------------------------------------------------------------
    do {
        let file = scratch.appendingPathComponent("lib.dylib")
        try fakeLibrary(name: "@rpath/libx.dylib").write(to: file)
        let facts = try MachO.facts(of: file)
        check(facts.arm64 && facts.platform == MachO.visionOS && facts.installName == "@rpath/libx.dylib", "Programm: Chip, Plattform und Name werden gelesen")
        try Data("#!/bin/sh\nexit 0\n# a script, long enough to read a header from".utf8).write(to: file)
        check(fails("not a 64-bit program") { _ = try MachO.facts(of: file) }, "Programm: ein Skript ist keines")
    } catch { check(false, "Programm: \(error)") }

    // --- Vertrag ----------------------------------------------------------------------------------------------------
    check((try? MachoTemplate.Contract(sampleContract()))?.libraries == ["libminecraft", "liblwjgl"], "Vertrag: Format 1 wird gelesen")
    for (what, change) in [("ein anderes Format", { (c: inout [String: Any]) in c["format"] = 2 }),
                           ("eine andere Art", { c in c["kind"] = "elf" }),
                           ("ein Ziel mit Pfad", { c in c["target"] = "../x" }),
                           ("eine Bibliothek mit Pfad", { c in var l = c["libraries"] as! [String: Any]; l["names"] = ["../../x"]; c["libraries"] = l }),
                           ("ein Ort außerhalb der App", { c in var l = c["libraries"] as! [String: Any]; l["to"] = "../{name}.dylib"; c["libraries"] = l }),
                           ("ein Spielordner außerhalb", { c in var p = c["payload"] as! [String: Any]; p["to"] = "/tmp/x"; c["payload"] = p }),
                           ("Signieren ohne die App am Ende", { c in c["sign"] = ["Frameworks/*.dylib"] })] as [(String, (inout [String: Any]) -> Void)] {
        var contract = sampleContract()
        change(&contract)
        check((try? MachoTemplate.Contract(contract)) == nil, "Vertrag: \(what) wird abgelehnt")
    }

    // --- Zusammensetzen ---------------------------------------------------------------------------------------------
    let request = FinishMacho.Request(bundleID: "user.dev.klepton.target.vivecraft", versionName: "26.3", versionCode: 260301, team: nil)
    func finish(_ name: String, _ samples: (template: URL, parts: URL), _ request: FinishMacho.Request) throws -> (FinishMacho.Finished, MachoTemplate, URL) {
        let work = scratch.appendingPathComponent("work-\(name)")
        let template = try MachoTemplate.open(samples.template, in: work.appendingPathComponent("template"))
        let finished = try FinishMacho.run(request, template: template, parts: samples.parts, work: work.appendingPathComponent("finish"), log: { _ in })
        return (finished, template, finished.root.appendingPathComponent("Payload/KleptonVivecraft.app"))
    }
    do {
        let samples = try makeSamples(in: scratch.appendingPathComponent("s1"))
        let contract = try MachoTemplate.contract(of: samples.template)
        let parts = try GameParts.inspect(samples.parts, for: contract)
        check(parts.root == "Payload/Vivecraft.app/" && parts.licenses == "Payload/Vivecraft.app/Licenses/", "Spielteile: die eine App und ihre Lizenzhinweise werden gefunden")
        check(GameParts.iconCandidates(in: samples.parts, parts: parts, contract: contract) == [Data("ICNS".utf8), Data("PNG".utf8)],
              "Spielteile: das eigene Icon des Spiels, in der Reihenfolge des Vertrags")
        var heard = 0.0
        let work = scratch.appendingPathComponent("work-s1")
        let template = try MachoTemplate.open(samples.template, in: work.appendingPathComponent("template"))
        let finished = try FinishMacho.run(request, template: template, parts: samples.parts, work: work.appendingPathComponent("finish"), log: { _ in }) { heard = $0 }
        let app = finished.root.appendingPathComponent("Payload/KleptonVivecraft.app")
        let all = Set(try files.subpathsOfDirectory(atPath: app.path))
        check(all.contains("Frameworks/libminecraft.dylib") && all.contains("Frameworks/liblwjgl.dylib") && all.contains("Frameworks/libEGL.framework/libEGL")
              && !all.contains("Frameworks/libother.dylib") && !all.contains("Vivecraft"), "Zusammensetzen: genau die Bibliotheken des Vertrags, nichts sonst aus den Spielteilen")
        check(all.contains("klepton-payload/root/inst-26.3/empty.txt") && read(app.appendingPathComponent("klepton-payload/launch.txt")) == "launch"
              && mode(app.appendingPathComponent("klepton-payload/root/inst-26.3/run.sh")) == 0o755,
              "Zusammensetzen: der Ordner des Spiels unverändert, mit Rechten und leeren Dateien")
        check(read(app.appendingPathComponent("Licenses/NOTICES.txt")) == "the parts' notices" && all.contains("Licenses/a/MIT.txt") && !all.contains("Licenses/old.txt"),
              "Zusammensetzen: die Lizenzhinweise der Spielteile ersetzen die der Vorlage")
        check(mode(app.appendingPathComponent("Frameworks/libminecraft.dylib")) == 0o755
              && read(app.appendingPathComponent("KleptonVivecraft")) == "program", "Zusammensetzen: Bibliotheken ausführbar, das Programm der Vorlage bleibt")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
        check(info["CFBundleIdentifier"] as? String == "user.dev.klepton.target.vivecraft" && info["CFBundleShortVersionString"] as? String == "26.3"
              && info["CFBundleVersion"] as? String == "260301.894" && info["CFBundleDisplayName"] as? String == "Minecraft" && info["KLOutputDefault"] as? String == "full",
              "Zusammensetzen: Info.plist bekommt Kennung, Fassung und Baunummer wie am Mac; alles andere bleibt")
        check(finished.build == "260301.894" && finished.version == "26.3" && heard == 1, "Zusammensetzen: Baunummer gemeldet, Fortschritt bis zum Ende")
        check(FinishMacho.signOrder(app: app, contract: template.contract) == ["Frameworks/liblwjgl.dylib", "Frameworks/libminecraft.dylib", "Frameworks/libEGL.framework", "."],
              "Signieren: die Reihenfolge des Vertrags, die App zuletzt")
        check(info["CFBundleIconName"] as? String == "AppIcon-vivecraft" && info["CFBundleIcons"] == nil, "Icon: ohne mitgegebene Bilder bleibt die Info.plist, wie sie ist")

        // Signatur vorbereiten: was das Profil nicht gewährt, bleibt weg; der Wert für das Team wird gesetzt.
        let profile = scratch.appendingPathComponent("test.mobileprovision")
        try (Data([0x30, 0x82, 0x01]) + Data("""
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>TeamIdentifier</key><array><string>TEAM123456</string></array>
        <key>Entitlements</key><dict><key>get-task-allow</key><true/><key>keychain-access-groups</key><array><string>TEAM123456.*</string></array>
        <key>com.apple.developer.kernel.increased-memory-limit</key><true/><key>application-identifier</key><string>TEAM123456.*</string></dict></dict></plist>
        """.utf8) + Data([0x00, 0x01])).write(to: profile)
        var said: [String] = []
        let prepared = try SignCore.prepare(root: finished.root, bundleID: request.bundleID, wanted: template.entitlements, profile: profile,
                                            work: work.appendingPathComponent("sign")) { said.append($0) }
        let entitlements = try PropertyListSerialization.propertyList(from: Data(contentsOf: prepared.entitlements), format: nil) as? [String: Any] ?? [:]
        check(prepared.team == "TEAM123456" && entitlements["application-identifier"] as? String == "TEAM123456.user.dev.klepton.target.vivecraft"
              && entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool == true && entitlements["com.apple.developer.low-latency-streaming"] == nil
              && (entitlements["keychain-access-groups"] as? [String]) == ["TEAM123456.user.dev.klepton.target.vivecraft", "TEAM123456.avpplay.shared"]
              && said.contains { $0.contains("low-latency-streaming") }, "Signatur: Berechtigungen der Vorlage, soweit das Profil sie gewährt")
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
        check(after["KLSharedKeychainGroup"] as? String == "TEAM123456.avpplay.shared" && files.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path),
              "Signatur: der Wert für das Team und das Profil kommen in die App")
    } catch { check(false, "Zusammensetzen: \(error)") }
    do {
        // Mit Bildern, wenn die Vorlage kein Icon hat – und ohne, wenn sie eines hat.
        var withIcon = request
        (withIcon.pictures, withIcon.iconNames) = (["AppIcon60x60@2x.png": Data("png".utf8)], ["AppIcon60x60"])
        let (_, _, app) = try finish("s2", try makeSamples(in: scratch.appendingPathComponent("s2")), withIcon)
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
        check(info["CFBundleIconName"] == nil && ((info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String] == ["AppIcon60x60"]
              && files.fileExists(atPath: app.appendingPathComponent("AppIcon60x60@2x.png").path), "Icon: ohne kompiliertes Icon kommen die Bilder als Dateien hinein")
        let (_, _, compiled) = try finish("s3", try makeSamples(in: scratch.appendingPathComponent("s3"), contract: sampleContract(iconCompiled: true)), withIcon)
        let kept = try PropertyListSerialization.propertyList(from: Data(contentsOf: compiled.appendingPathComponent("Info.plist")), format: nil) as? [String: Any] ?? [:]
        check(kept["CFBundleIconName"] as? String == "AppIcon-vivecraft" && !files.fileExists(atPath: compiled.appendingPathComponent("AppIcon60x60@2x.png").path),
              "Icon: ein kompiliertes Icon der Vorlage bleibt")
        let (_, _, plain) = try finish("s4", try makeSamples(in: scratch.appendingPathComponent("s4"), ownLicenses: false), request)
        check((try? String(contentsOf: plain.appendingPathComponent("Licenses/NOTICES.txt"), encoding: .utf8)) == "template notices"
              && files.fileExists(atPath: plain.appendingPathComponent("Licenses/old.txt").path), "Zusammensetzen: ohne eigene Lizenzhinweise bleiben die der Vorlage")
    } catch { check(false, "Icon und Lizenzen: \(error)") }
    for (what, text, make) in [
        ("eine fehlende Bibliothek", "no liblwjgl", { try makeSamples(in: $0, leaveOut: "liblwjgl") }),
        ("eine Bibliothek für eine andere Plattform", "not built for the Vision Pro", { try makeSamples(in: $0, platform: 2) }),
        ("Spielteile für ein anderes Ziel", "laid out for other", { try makeSamples(in: $0, tree: "other") }),
        ("eine Vorlage mit anderen Werten, als sie nennt", "does not hold the value", { try makeSamples(in: $0, row: "mixed") }),
    ] as [(String, String, (URL) throws -> (template: URL, parts: URL))] {
        check(fails(text) { _ = try finish("bad", try make(scratch.appendingPathComponent("bad")), request) }, "Zusammensetzen: \(what) beendet den Auftrag")
    }

    // --- Der Stand eines gebauten Spiels ---------------------------------------------------------------------------
    do {
        let documents = scratch.appendingPathComponent("Documents"), home = scratch.appendingPathComponent("home")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        func manifest(_ state: String, size: Int64? = 9) throws -> [BuiltGame] {
            var parts: [String: Any] = ["state": state]
            if state != "missing" { parts["name"] = "vivecraft-parts-1-abc1234.zip"; parts["size"] = size; parts["sha256"] = String(repeating: "a", count: 64) }
            let games: [[String: Any]] = [
                ["id": "vivecraft", "title": "Minecraft: Java Edition (Vivecraft)", "target": "vivecraft", "versionName": "26.3", "versionCode": 260301, "parts": parts,
                 "account": ["title": ["en": "You need Minecraft: Java Edition", "de": "Du brauchst Minecraft: Java Edition"], "notes": [["en": "a", "de": "b"]]], "playability": "verified"],
                ["id": "../evil", "title": "x", "target": "x", "versionName": "1", "versionCode": 1, "parts": ["state": "missing"]],
                ["id": "12345678", "title": "x", "target": "x", "versionName": "1", "versionCode": 1, "parts": ["state": "missing"]],
                ["id": "vivecraft", "title": "twice", "target": "vivecraft", "versionName": "1", "versionCode": 1, "parts": ["state": "missing"]],
            ]
            let file = home.appendingPathComponent("built-games.json")
            try JSONSerialization.data(withJSONObject: ["format": 1, "games": games]).write(to: file)
            return BuiltGame.read(file)
        }
        var games = try manifest("missing")
        check(games.count == 1 && games.first?.id == "vivecraft" && games.first?.account?.notes.count == 1, "Liste: nur brauchbare Einträge, jeder einmal")
        check(BuiltGame.read(home.appendingPathComponent("gibt-es-nicht.json")).isEmpty, "Liste: ohne Datei kein Spiel")
        guard var game = games.first else { throw FinishFailure(description: "no game") }
        let template = "klepton-macho-vivecraft-894-4540abb.zip"
        check(game.readiness(documents: documents, home: home, templates: [template]) == .needsMacBuild, "Stand: nie gebaut → muss zuerst auf dem Mac gebaut werden")
        check(game.blocker(.needsMacBuild)?.contains("built on your Mac first") == true, "Stand: der Satz dazu (Englisch)")
        Language.german = true
        check(game.blocker(.needsMacBuild)?.contains("zuerst auf deinem Mac gebaut werden") == true && game.blocker(.needsHandover(bytes: 625_872_192))?.contains("etwa 626 MB") == true,
              "Stand: die Sätze auf Deutsch, mit der Größe")
        Language.german = false
        games = try manifest("built", size: 625_872_192)
        game = games[0]
        check(game.readiness(documents: documents, home: home, templates: [template]) == .needsHandover(bytes: 625_872_192), "Stand: gebaut, nicht hier → am Mac übergeben")
        // Die Datei ohne ihre Notiz gilt als halb kopiert.
        let folder = BuiltGame.partsFolder("vivecraft", documents: documents)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("123456789".utf8).write(to: folder.appendingPathComponent("vivecraft-parts-1-abc1234.zip"))
        check(game.partsHere(documents: documents) == nil, "Stand: Spielteile ohne ihre Notiz gelten nicht")
        func note(size: Int64, code: Int) throws {
            try JSONEncoder().encode(BuiltGame.Record(name: "vivecraft-parts-1-abc1234.zip", size: size, sha256: String(repeating: "a", count: 64), versionCode: code))
                .write(to: folder.appendingPathComponent("parts.json"))
        }
        try note(size: 10, code: 260301)
        check(game.partsHere(documents: documents) == nil, "Stand: eine andere Größe, als die Notiz nennt, gilt nicht")
        try note(size: 9, code: 250000)
        check(game.partsHere(documents: documents) == nil, "Stand: Spielteile einer anderen Fassung gelten nicht")
        try note(size: 9, code: 260301)
        check(game.partsHere(documents: documents)?.record.size == 9, "Stand: Datei und Notiz zusammen gelten")
        check(game.readiness(documents: documents, home: home, templates: ["klepton-template-894-4540abb.zip"]) == .needsTemplate, "Stand: Spielteile da, Vorlage fehlt")
        let ready = game.readiness(documents: documents, home: home, templates: ["klepton-macho-vivecraft-893-aaaaaaa.zip", template, "klepton-macho-other-900-bbbbbbb.zip"])
        check(ready == .ready(parts: folder.appendingPathComponent("vivecraft-parts-1-abc1234.zip"), template: home.appendingPathComponent(template), bytes: 9)
              && game.blocker(ready) == nil, "Stand: beides da → installierbar, mit der neuesten Vorlage für dieses Ziel")
        // Auch wenn der Mac die Teile inzwischen nicht mehr hat: Was hier liegt, gilt weiter.
        games = try manifest("missing")
        check(games[0].readiness(documents: documents, home: home, templates: [template]) == ready, "Stand: was auf der Brille liegt, gilt auch ohne die Teile am Mac")
        check(BuiltGame.spaceNeeded(appBytes: 900 << 20) == 3 * (900 << 20) + (1 << 30), "Platz: dreimal die App und ein Gigabyte")
    } catch { check(false, "Stand: \(error)") }

    print(failures == 0 ? "Alles gut: \(checks) Prüfungen." : "\(failures) von \(checks) Prüfungen gescheitert.")
    return failures == 0 ? 0 : 1
}
