// Die Kerne für „Auf dieser Brille“ als Kommando für den Mac (bauen: tools/headset-check/build.sh). Es läuft derselbe
// Code wie in der App: Standalone/Engine/Zip.swift, FinishMacho.swift, SignCore.swift und der Signierer aus
// Standalone/Signer. Nichts hier spricht mit einer Brille oder mit Apple.
//
//   headset-check check [Arbeitsordner]
//       die gestellten Prüfungen (checks.swift)
//   headset-check inspect <Vorlage.zip> <Spielteile.zip>
//       ob die Spielteile zu der Vorlage passen, ohne etwas auszupacken
//   headset-check state <Documents> [Ordner der Übergabe]
//       was die App aus einer Übergabe über die auf dem Mac gebauten Spiele liest: der Stand jedes Spiels und der Satz
//       dazu, Englisch und Deutsch. Ohne zweite Angabe: <Documents>/handover.
//   headset-check finish <Vorlage.zip> <Spielteile.zip> <Arbeitsordner> --bundle-id <Kennung> --version-name <26.3> --version-code <260301>
//       setzt die App zusammen (unsigniert): <Arbeitsordner>/finish/app/Payload/<App>
//   headset-check prepare <Arbeitsordner> <Vorlage.zip> --bundle-id <Kennung> --profile <Datei>
//       legt Profil und Berechtigungen bereit, wie vor dem Signieren: <Arbeitsordner>/sign/signed.entitlements
//   headset-check sign <Arbeitsordner> <Vorlage.zip> <Signierordner> --bundle-id <Kennung>
//       signiert mit dem Signierer der App und packt: <Arbeitsordner>/sign/signed.ipa. Der Signierordner hält
//       key.pem, certificate.der und profile.mobileprovision, wie SignCore.identity ihn hinterlässt.
//
// Jeder Schritt nennt seine Dauer; am Ende steht der höchste Speicherbedarf des Prozesses.
import Foundation

setbuf(stdout, nil)
var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
var positional: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument.hasPrefix("--") {
        guard !arguments.isEmpty else { print("Wert fehlt für \(argument)"); exit(2) }
        options[String(argument.dropFirst(2))] = arguments.removeFirst()
    } else {
        positional.append(argument)
    }
}

func usage() -> Never {
    print("Aufruf: headset-check check | inspect | finish | prepare | sign  (siehe tools/headset-check/main.swift)")
    exit(2)
}

func need(_ name: String) -> String {
    guard let value = options[name], !value.isEmpty else { print("--\(name) fehlt"); exit(2) }
    return value
}

func file(_ index: Int) -> URL {
    guard positional.count > index else { usage() }
    return URL(fileURLWithPath: positional[index]).standardizedFileURL
}

/// Der höchste Speicherbedarf bisher: was der Prozess höchstens belegt hat (wie Xcodes Anzeige; daran misst das
/// System auf der Brille eine App), und was davon höchstens im Arbeitsspeicher lag.
func peakMemory() -> (footprint: Int64, resident: Int64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return (result == KERN_SUCCESS ? Int64(info.ledger_phys_footprint_peak) : -1, Int64(usage.ru_maxrss))
}

func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

func timed<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
    let start = Date()
    let value = try body()
    let peak = peakMemory()
    print(String(format: "time %@: %.2f s (peak so far: footprint %@, resident %@)", what, Date().timeIntervalSince(start),
                 megabytes(peak.footprint), megabytes(peak.resident)))
    return value
}

func folderBytes(_ folder: URL) -> (files: Int, bytes: Int64) {
    var count = 0, bytes: Int64 = 0
    if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
    }
    return (count, bytes)
}

do {
    guard let command = positional.first else { usage() }
    switch command {
    case "check":
        let scratch = positional.count > 1 ? file(1) : FileManager.default.temporaryDirectory.appendingPathComponent("headset-check-\(UUID().uuidString)")
        let status = runChecks(scratch: scratch)
        if positional.count <= 1 { try? FileManager.default.removeItem(at: scratch) }
        exit(status)

    case "inspect":
        let contract = try MachoTemplate.contract(of: file(1))
        let parts = try timed("inspect") { try GameParts.inspect(file(2), for: contract) }
        print("target \(contract.target): \(contract.libraries.count) libraries, game files \(contract.payloadFrom), app in the parts: \(parts.root)")
        print("to unpack: \(megabytes(parts.bytes)) in \(parts.entries.count) entries; licence notices: \(parts.licenses ?? "the template's")")
        print("icon compiled into the template: \(contract.iconCompiled); the game's own icon candidates: \(GameParts.iconCandidates(in: file(2), parts: parts, contract: contract).map(\.count))")
        print("space needed on the headset: \(BuiltGame.gigabytes(BuiltGame.spaceNeeded(appBytes: parts.bytes))) (estimated from the archive's size alone: \(BuiltGame.gigabytes(BuiltGame.spaceNeeded(appBytes: (parts.entries.isEmpty ? 0 : Int64((try? FileManager.default.attributesOfItem(atPath: file(2).path)[.size] as? NSNumber)?.int64Value ?? 0)) * 17 / 12))))")

    case "state":
        let documents = file(1)
        let home = positional.count > 2 ? file(2) : documents.appendingPathComponent("handover")
        let games = BuiltGame.read(home.appendingPathComponent("built-games.json"))
        let templates = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { MachoTemplate.named($0) != nil }
        print("\(games.count) games built on the Mac; templates here: \(templates.sorted().joined(separator: ", "))")
        for game in games {
            let ready = game.readiness(documents: documents, home: home, templates: templates)
            let state: String
            switch ready {
            case .needsMacBuild: state = "needs to be built on the Mac"
            case .needsHandover: state = "built on the Mac, parts not here"
            case .needsTemplate: state = "parts here, template missing"
            case .ready: state = "ready to install"
            }
            print("\(game.id) (\(game.title), \(game.versionName) / \(game.versionCode), target \(game.target)): \(state)")
            for german in [false, true] {
                Language.german = german
                print("  [\(Language.code)] parts: \(game.partsFact(ready))")
                print("  [\(Language.code)] \(game.blocker(ready) ?? (german ? "(nichts im Weg)" : "(nothing in the way)"))")
                if let account = game.account { print("  [\(Language.code)] \(BuiltGame.text(account.title)) – \(account.notes.count) notes") }
            }
            Language.german = false
            if case .ready(let parts, let template, _) = ready, let record = game.partsHere(documents: documents)?.record {
                let sum = try timed("checksum of the parts") { try Hashing.sha256(of: parts) }
                print("  checksum \(sum == record.sha256 ? "matches the note" : "DOES NOT MATCH the note"); template \(template.lastPathComponent)")
            }
        }

    case "finish":
        let work = file(3)
        let request = FinishMacho.Request(bundleID: need("bundle-id"), versionName: need("version-name"), versionCode: Int(need("version-code")) ?? 0,
                                          team: options["team"])
        let template = try timed("template unpacked") { try MachoTemplate.open(file(1), in: work.appendingPathComponent("template")) }
        print("toolchain \(template.version) (\(template.commit)), target \(template.contract.target)")
        var last = -1.0
        let finished = try timed("app put together") {
            try FinishMacho.run(request, template: template, parts: file(2), work: work.appendingPathComponent("finish"), log: { print($0) }) { share in
                if share - last >= 0.25 || share >= 1 { last = share; print(String(format: "     unpacked: %.0f %%", share * 100)) }
            }
        }
        let app = finished.root.appendingPathComponent("Payload").appendingPathComponent(template.app.lastPathComponent)
        let size = folderBytes(app)
        print("app: \(app.path)")
        print("build \(finished.build), version \(finished.version), \(size.files) files, \(megabytes(size.bytes))")
        print("sign order: \(FinishMacho.signOrder(app: app, contract: template.contract).joined(separator: " "))")

    case "prepare":
        let work = file(1)
        let contract = try MachoTemplate.contract(of: file(2))
        _ = contract
        let prepared = try timed("signature prepared") {
            try SignCore.prepare(root: work.appendingPathComponent("finish/app"), bundleID: need("bundle-id"),
                                 wanted: work.appendingPathComponent("template/Klepton.entitlements"), profile: URL(fileURLWithPath: need("profile")),
                                 work: work.appendingPathComponent("sign")) { print($0) }
        }
        print("app: \(prepared.app.path)")
        print("entitlements: \(prepared.entitlements.path)")
        print("team \(prepared.team), build \(prepared.build)")

    case "sign":
        let work = file(1)
        _ = try MachoTemplate.contract(of: file(2))
        var last: Int64 = 0
        let signed = try timed("signed and packed") {
            try SignCore.sign(root: work.appendingPathComponent("finish/app"), bundleID: need("bundle-id"),
                              wanted: work.appendingPathComponent("template/Klepton.entitlements"), state: file(3), work: work.appendingPathComponent("sign"),
                              packed: { if $0 - last >= 256 << 20 { last = $0; print("     packed: \(megabytes($0))") } }, log: { print($0) })
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: signed.package.path))?[.size] as? NSNumber)?.int64Value ?? 0
        print("package: \(signed.package.path), \(megabytes(size)); signed by \(signed.signer); build \(signed.build)")

    default:
        usage()
    }
    let peak = peakMemory()
    print("peak memory: footprint \(megabytes(peak.footprint)), resident \(megabytes(peak.resident))")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
