import Foundation

/// Spiele, deren Programm auf dem Mac GEBAUT wird, nicht geladen – das erste ist Minecraft: Java Edition mit
/// Vivecraft. Der Bau braucht einen Compiler und etwa 45 Minuten; die Brille kann ihn nie selbst machen. Sie kann
/// ein solches Spiel aber installieren, sobald ein Mac die fertigen „Spielteile“ einmal übergeben hat: Dann setzt
/// sie Vorlage und Spielteile zusammen (`FinishMacho`), signiert und installiert.
///
/// Was AVP Play dafür übergibt:
///
///   Documents/handover/built-games.json                         welche solchen Spiele es gibt, und ob ihre Spielteile
///                                                               auf dem Mac gebaut sind (auch wenn nichts mitkommt)
///   Documents/handover/klepton-macho-<Ziel>-<Nr>-<Commit>.zip   die App ohne das Spiel, aus der Toolchain
///   Documents/handover/built-<Kennung>-cover.png                ein Bild für die Kachel, aus den Spielteilen gemacht
///   Documents/parts/<Kennung>/<Datei>.zip                       die Spielteile (ein paar hundert Megabyte) – nur,
///   Documents/parts/<Kennung>/parts.json                        wenn der Nutzer dem am Mac zugestimmt hat
///
/// Die Spielteile bleiben in `Documents/parts`, wo der Mac sie hingelegt hat: So sieht AVP Play beim nächsten Mal,
/// dass sie schon da sind, und kopiert sie nicht noch einmal. `parts.json` kommt als Letztes; ohne sie gilt eine
/// Datei als halb kopiert.
struct BuiltGame: Codable, Equatable, Sendable {
    var id: String
    var title: String
    /// Der Name des Spiels in der Toolchain; die App heißt „<Präfix>.<target>“.
    var target: String
    var versionName: String
    var versionCode: Int
    /// Wie es um die Spielteile auf dem Mac steht.
    var parts: Parts
    /// Was man zum Spielen braucht (ein eigenes Konto beim Spiel): Überschrift und Absätze, je Sprache.
    var account: Account?
    /// Die Einstufung aus dem Rezept („verified“, …).
    var playability: String?

    struct Parts: Codable, Equatable, Sendable {
        /// `missing`: auf dem Mac noch nie gebaut. `built`: liegen auf dem Mac. `handedOver`: mit dieser Übergabe kopiert.
        var state: String
        var name: String?
        var size: Int64?
        var sha256: String?
    }

    struct Account: Codable, Equatable, Sendable {
        var title: [String: String]
        var notes: [[String: String]]
    }

    /// Was neben den Spielteilen liegt: welche Datei es ist und was sie sein muss.
    struct Record: Codable, Equatable, Sendable {
        var name: String
        var size: Int64
        var sha256: String
        var versionCode: Int
    }

    struct Manifest: Codable {
        var format: Int
        var games: [BuiltGame]
    }

    /// Eine Kennung, die als Ordnername taugt und nicht mit einer Store-Nummer zu verwechseln ist.
    var isSane: Bool {
        MachoTemplate.isPlainName(id) && !id.hasPrefix(".") && !id.hasPrefix("store-") && !id.allSatisfy(\.isNumber)
            && MachoTemplate.isPlainName(target) && !title.isEmpty && versionCode > 0
    }

    static func text(_ values: [String: String]) -> String {
        values[Language.code] ?? values["en"] ?? values[""] ?? values.sorted { $0.key < $1.key }.first?.value ?? ""
    }

    /// Liest die Liste aus der Übergabe; ein Eintrag, der nicht taugt, gilt nicht.
    static func read(_ file: URL) -> [BuiltGame] {
        guard let data = try? Data(contentsOf: file), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.format == 1 else { return [] }
        var seen = Set<String>()
        return manifest.games.filter { $0.isSane && seen.insert($0.id).inserted }
    }

    // MARK: Was davon auf der Brille liegt

    /// Wo die Spielteile dieses Spiels liegen (unter „Documents“ der App).
    static func partsFolder(_ id: String, documents: URL) -> URL {
        documents.appendingPathComponent("parts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    /// Die Spielteile, wenn sie ganz da sind: die Datei, die `parts.json` nennt, in der Größe, die sie nennt, und für
    /// die Fassung des Spiels, um die es geht.
    func partsHere(documents: URL) -> (file: URL, record: Record)? {
        let folder = BuiltGame.partsFolder(id, documents: documents)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("parts.json")),
              let record = try? JSONDecoder().decode(Record.self, from: data), MachoTemplate.isPlainName(record.name),
              record.name.hasSuffix(".zip"), record.versionCode == versionCode else { return nil }
        let file = folder.appendingPathComponent(record.name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value
        return size == record.size ? (file, record) : nil
    }

    /// Wie es um das Spiel auf dieser Brille steht.
    enum Readiness: Equatable {
        /// Die Spielteile sind auf dem Mac noch nie gebaut worden.
        case needsMacBuild
        /// Gebaut sind sie, aber nicht hier: Der Nutzer hat sie am Mac (noch) nicht mitgegeben.
        case needsHandover(bytes: Int64?)
        /// Die Spielteile sind da, die App ohne das Spiel (aus der Toolchain) fehlt.
        case needsTemplate
        case ready(parts: URL, template: URL, bytes: Int64)
    }

    /// `templates` sind die Namen der Dateien im privaten Ordner der App.
    func readiness(documents: URL, home: URL, templates: [String]) -> Readiness {
        let template = BuiltGame.template(for: target, among: templates)
        if let here = partsHere(documents: documents) {
            guard let template else { return .needsTemplate }
            return .ready(parts: here.file, template: home.appendingPathComponent(template), bytes: here.record.size)
        }
        return parts.state == "missing" ? .needsMacBuild : .needsHandover(bytes: parts.size)
    }

    /// Die Vorlage für dieses Ziel: die mit der höchsten Toolchain-Nummer, falls mehrere da liegen.
    static func template(for target: String, among names: [String]) -> String? {
        names.compactMap { name in MachoTemplate.named(name).flatMap { $0.target == target ? (name, $0.version) : nil } }
            .max { $0.1 < $1.1 }?.0
    }

    /// In Megabyte, wie der Mac sie nennt (eine Million Bytes): Die Zahl hier soll zu der am Mac passen.
    static func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_000_000) }
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }

    /// Warum sich das Spiel hier (noch) nicht installieren lässt, in einem Satz für die Seite des Spiels – mit dem,
    /// was zu tun ist. `nil`: Es geht.
    func blocker(_ readiness: Readiness) -> String? {
        switch readiness {
        case .ready:
            return nil
        case .needsMacBuild:
            return L("\(title) has to be built on your Mac first: only a Mac can build the game's parts (about 45 minutes, once). Install it once with AVP Play on the Mac. Then, on the Mac under AVP Play Remote, switch on “Also hand over the game parts” and choose “Hand Over Now”. After that it can be installed here without the Mac.",
                     "\(title) muss zuerst auf deinem Mac gebaut werden: Die Spielteile kann nur ein Mac bauen (etwa 45 Minuten, einmal). Installiere es einmal mit AVP Play am Mac. Schalte danach am Mac unter AVP Play Remote „Auch die Spielteile mitgeben“ ein und wähle „Jetzt übergeben“. Dann lässt es sich hier ohne den Mac installieren.")
        case .needsHandover(let bytes):
            let size = bytes.map { L(" (about \(BuiltGame.megabytes($0)))", " (etwa \(BuiltGame.megabytes($0)))") } ?? ""
            return L("The game's parts are built on your Mac, but they are not on this headset yet\(size). On the Mac, under AVP Play Remote, switch on “Also hand over the game parts” and choose “Hand Over Now”.",
                     "Die Spielteile sind auf deinem Mac gebaut, liegen aber noch nicht auf dieser Brille\(size). Schalte am Mac unter AVP Play Remote „Auch die Spielteile mitgeben“ ein und wähle „Jetzt übergeben“.")
        case .needsTemplate:
            return L("The game's parts are here, but the game runtime for \(title) is missing. On the Mac, under AVP Play Remote, choose “Hand Over Now” once more.",
                     "Die Spielteile sind da, aber die Spiel-Laufzeit für \(title) fehlt. Wähle am Mac unter AVP Play Remote noch einmal „Jetzt übergeben“.")
        }
    }

    /// Der Stand in wenigen Wörtern, für die Zeile „Spielteile“ auf der Seite des Spiels.
    func partsFact(_ readiness: Readiness) -> String {
        switch readiness {
        case .ready(_, _, let bytes), .needsHandover(let bytes?):
            let size = BuiltGame.megabytes(bytes)
            if case .ready = readiness { return L("on this headset (\(size))", "auf dieser Brille (\(size))") }
            return L("built on the Mac, not here yet (\(size))", "auf dem Mac gebaut, noch nicht hier (\(size))")
        case .needsHandover:
            return L("built on the Mac, not here yet", "auf dem Mac gebaut, noch nicht hier")
        case .needsTemplate:
            return L("on this headset; the game runtime is missing", "auf dieser Brille; die Spiel-Laufzeit fehlt")
        case .needsMacBuild:
            return L("not built yet – only a Mac can build them", "noch nicht gebaut – das kann nur ein Mac")
        }
    }

    /// Wie viel Platz die Brille für die Installation frei haben muss: Die App liegt unterwegs ausgepackt, als Paket
    /// und beim Installationsdienst – dreimal ihre Größe –, dazu ein Gigabyte Luft.
    static func spaceNeeded(appBytes: Int64) -> Int64 { 3 * appBytes + (1 << 30) }
}
