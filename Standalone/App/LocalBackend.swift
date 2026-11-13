import Foundation
import UIKit

/// „Auf dieser Brille“: was sonst der Mac schickt, kommt hier von der Brille selbst.
///
/// Die Seiten der App sind dieselben wie mit einem Mac; sie lesen aus `RemoteClient`, und der bekommt von hier
/// dieselben Werte in derselben Form: Spiele (`RemoteGame`), Stand und Aufträge (`RemoteStatus`, `RemoteJob`), die
/// beschriebenen Seiten (`RemotePanel`) und die Titelbilder. Die Arbeit selbst machen die Kerne unter
/// Standalone/Engine: Dateien bei Meta laden, aus der Laufzeit-Vorlage die App des Spiels bauen, signieren,
/// installieren, Spieldaten dazulegen.
///
/// Was dafür nur ein Mac herstellen kann, übergibt AVP Play, wenn es die Remote installiert: einen Ordner
/// `Documents/handover`, der beim Start in den privaten Bereich der App wandert.
///
///   handover.json       {"bundlePrefix": "<Nutzer>.dev.klepton.target", "pairingPort": 49152}
///   pairing.plist       die Kopplungsdatei für diese Brille
///   asc.json, asc-key.p8  Team-Schlüssel für Apples Entwicklerkonto
///   klepton-template-<Nummer>-<Commit>.zip
///   klepton-mods-<Versionscode>-<Nummer>-<Commit>.zip   dieselbe Vorlage mit den Mods einer Spielfassung (Beat Saber)
///   meta-token          das Zugangstoken für Meta (wandert in den Schlüsselbund, die Datei wird gelöscht)
///   library.json        die Spiele des Meta-Kontos, wie AVP Play sie führt
///   recipes.json        die Rezepte von AVP Play für Spiele aus dem Meta-Store: welche Dateien ein Spiel braucht,
///                       wohin sie gehören, seine Sprachen und Zusatzinhalte
///   games/<App-ID>/     game.json und die Dateien eines Spiels, wenn der Mac eines gleich mitgibt
@MainActor
final class LocalBackend {
    static let mac = KnownMac(serverId: "this-headset", name: L("This Headset", "Diese Brille"), host: nil, port: nil, lastConnected: nil)
    static let catalogHost = "https://avpplay.martek.de"

    nonisolated static let home: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Standalone")
    }()
    nonisolated static let handover = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("handover")
    nonisolated static let logFile = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("standalone.log")

    // MARK: Was die Brille weiß

    /// Ein Eintrag des Katalogs von AVP Play: Einstufung, Meldungen, Hinweise.
    struct CatalogEntry: Codable {
        var status: String
        var mixedReality: Bool
        var handTracking: Bool
        var cover: Bool
        var works: Int
        var problems: Int
        var fails: Int
        var noteEn: String?
        var noteDe: String?
        var target: String?
        var versionCode: Int?
    }

    /// Ein Spiel, wie es auf der Brille installiert ist: Baunummer („250.890“) und Fassung.
    struct InstalledGame: Codable {
        var build: String
        var version: String
        var toolchain: Int? { build.split(separator: ".").dropFirst().first.flatMap { Int($0) } }
        var versionCode: Int? { build.split(separator: ".").first.flatMap { Int($0) } }
        /// Die dritte Zahl der Baunummer sagt, was an dem Bau besonders ist (AVP Plays `AppStamp`); 256: mit Mods.
        var coreMods: Bool { (build.split(separator: ".").dropFirst(2).first.flatMap { Int($0) } ?? 0) & 256 != 0 }
    }

    /// Was der Nutzer für ein Spiel gewählt hat, und was die Brille über das Konto und dieses Spiel weiß. Die Wahl
    /// trägt dieselben Namen wie am Mac (`GameOptions`).
    struct GameOptions: Codable, Equatable, Sendable {
        /// Sprachen, deren wählbare Dateien mitkommen (Kürzel wie im Rezept).
        var locales: [String] = []
        /// Weitere wählbare Dateien, mit Namen.
        var optionalNames: [String] = []
        /// Gekaufte Zusatzinhalte laden und freischalten.
        var addons = true
        /// Das Spiel mit seinen Mods bauen (Beat Saber: eigene Songs). Ohne Angabe: wie das Mod-Profil sagt.
        var coreMods: Bool?
        /// Dateien, die Meta diesem Konto nicht ausliefert (ihre Kennungen): Sie werden nicht wieder angefragt.
        var withheld: [String] = []
        /// Der zuletzt von Meta bestätigte Kaufstand.
        var skus: [String]?
        var verified: Date?

        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            locales = try values.decodeIfPresent([String].self, forKey: .locales) ?? []
            optionalNames = try values.decodeIfPresent([String].self, forKey: .optionalNames) ?? []
            addons = try values.decodeIfPresent(Bool.self, forKey: .addons) ?? true
            coreMods = try values.decodeIfPresent(Bool.self, forKey: .coreMods)
            withheld = try values.decodeIfPresent([String].self, forKey: .withheld) ?? []
            skus = try values.decodeIfPresent([String].self, forKey: .skus)
            verified = try values.decodeIfPresent(Date.self, forKey: .verified)
        }
    }

    /// Was ein laufender Auftrag festhält, auch wenn er danach scheitert.
    enum Memo: Sendable {
        /// Die Dateien, die Meta für den neuesten Build nennt, als Entwurf eines Rezepts.
        case draft(Recipe)
        case withheld(String)
        case purchases([String], Date)
    }

    enum Step: String, Codable, CaseIterable {
        case account, fetch, build, stage, unlock
        /// Die Titel sind die von AVP Play (InstallStep.title).
        var title: String {
            switch self {
            case .account: return L("Check account and ownership", "Konto und Besitz prüfen")
            case .fetch: return L("Download files", "Dateien laden")
            case .build: return L("Build and install", "Bauen und installieren")
            case .stage: return L("Copy data to the device", "Daten aufs Gerät kopieren")
            case .unlock: return L("Unlock add-on content", "Zusatzinhalte freischalten")
            }
        }
    }

    struct Job: Codable, Identifiable {
        var id: String
        var appId: String
        var title: String
        var kind: RemoteJob.Kind
        var state: RemoteJob.State
        var created: Date
        var updated: Date
        var steps: [Step]
        /// Wie viele Schritte fertig sind.
        var done = 0
        var failure: String?
        var log: [String] = []
        var gameId: String { "store-\(appId)" }
    }

    private weak var client: RemoteClient?
    private var hasPairing = false, hasAppleKey = false, hasMetaToken = false
    private var templateName: String?
    /// Die Vorlage mit Mods, wenn sie zur selben Toolchain gehört wie die Vorlage, und für welches Spiel sie ist.
    private var modsName: String?
    private var mods: Template.Mods?
    private var prefix = "avpplay.dev.klepton.target"
    private var port: UInt16 = 49152
    private var library: [LibraryApp] = []
    /// AVP Plays Rezepte, nach der App-ID im Meta-Store.
    private var recipes: [String: Recipe] = [:]
    /// Entwürfe für Spiele ohne Rezept: was Meta zuletzt für sie genannt hat.
    private var drafts: [String: Recipe] = [:]
    private var options: [String: GameOptions] = [:]
    private var catalog: [String: CatalogEntry] = [:]
    private var installed: [String: InstalledGame] = [:]
    private var installedChecked = false
    private var jobs: [Job] = []
    private var bars: [String: [RemoteProgress]] = [:]
    private var waiting: [String] = []
    private var running: (id: String, task: Task<Void, Never>)?
    private var refreshing = false
    private var publishScheduled = false
    private var coverWaiting: [(gameId: String, key: String, appId: String)] = []
    private var coverRunning = 0
    private var coverAsked: Set<String> = []

    init(client: RemoteClient) { self.client = client }

    // MARK: Einstellungen (dieselben Namen wie am Mac, soweit es sie hier gibt)

    private let defaults = UserDefaults.standard
    private var favourites: Set<String> {
        get { Set(defaults.stringArray(forKey: "local.favourites") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "local.favourites") }
    }
    private var roomMeasuring: Bool { defaults.object(forKey: "local.roomMeasuring") as? Bool ?? true }
    private var gameLanguage: String { defaults.string(forKey: "local.gameLanguage") ?? "" }
    private var onlineCatalog: Bool { defaults.object(forKey: "local.onlineCatalog") as? Bool ?? true }
    private var storePictures: Bool { defaults.object(forKey: "local.storePictures") as? Bool ?? true }
    private var metalFX: Bool { defaults.bool(forKey: "local.metalFX") }
    private var metalFXResolution: Int { defaults.object(forKey: "local.metalFXResolution") as? Int ?? 75 }

    // MARK: Start und Stand

    func start() {
        importHandover()
        jobs = Self.read("jobs.json", [Job].self) ?? []
        // Was beim letzten Mal lief, als die App endete, ist unterbrochen.
        for index in jobs.indices where jobs[index].state == .running || jobs[index].state == .queued { jobs[index].state = .interrupted }
        installed = Self.read("installed.json", [String: InstalledGame].self) ?? [:]
        installedChecked = FileManager.default.fileExists(atPath: Self.home.appendingPathComponent("installed.json").path)
        catalog = Self.read("catalog.json", [String: CatalogEntry].self) ?? [:]
        options = Self.read("options.json", [String: GameOptions].self) ?? [:]
        publish()
        Task {
            await loadCatalog()
            // Was installiert ist und was ein Update braucht, sagt die Brille selbst – auch für Spiele, die ein Mac
            // installiert hat. Dafür geht der Tunnel kurz an.
            _ = await readInstalled()
            publishNow()
        }
    }

    nonisolated private static func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
        (try? Data(contentsOf: home.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    nonisolated private static func write<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: home.appendingPathComponent(name), options: .atomic)
    }

    /// Nimmt eine neue Übergabe an und liest, was da ist.
    private func importHandover() {
        let files = FileManager.default
        try? files.createDirectory(at: Self.home, withIntermediateDirectories: true)
        if let names = try? files.contentsOfDirectory(atPath: Self.handover.path) {
            for name in names {
                let source = Self.handover.appendingPathComponent(name), target = Self.home.appendingPathComponent(name)
                if name == "games" {
                    try? files.createDirectory(at: target, withIntermediateDirectories: true)
                    for game in (try? files.contentsOfDirectory(atPath: source.path)) ?? [] {
                        let to = target.appendingPathComponent(game)
                        try? files.removeItem(at: to)
                        try? files.moveItem(at: source.appendingPathComponent(game), to: to)
                    }
                    try? files.removeItem(at: source)
                } else {
                    for kind in ["klepton-template-", "klepton-mods-"] where name.hasPrefix(kind) {
                        // Nur eine Vorlage jeder Art zur selben Zeit: die neu übergebene.
                        for old in (try? files.contentsOfDirectory(atPath: Self.home.path)) ?? [] where old.hasPrefix(kind) {
                            try? files.removeItem(at: Self.home.appendingPathComponent(old))
                        }
                    }
                    try? files.removeItem(at: target)
                    try? files.moveItem(at: source, to: target)
                }
            }
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var home = Self.home
        try? home.setResourceValues(values)

        func has(_ name: String) -> Bool { files.fileExists(atPath: Self.home.appendingPathComponent(name).path) }
        // Das Token gehört in den Schlüsselbund, nicht in eine Datei.
        let tokenFile = Self.home.appendingPathComponent("meta-token")
        if let text = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { MetaToken.save(token) }
            try? files.removeItem(at: tokenFile)
        }
        hasMetaToken = MetaToken.read() != nil
        hasPairing = has("pairing.plist")
        hasAppleKey = has("asc.json") && has("asc-key.p8")
        let names = (try? files.contentsOfDirectory(atPath: Self.home.path)) ?? []
        templateName = names.first { $0.hasPrefix("klepton-template-") && $0.hasSuffix(".zip") }
        // Die Mods gelten nur mit der Vorlage derselben Toolchain: „klepton-mods-<Code>-<Nummer>-<Commit>.zip“.
        let toolchain = templateName.map { String($0.dropFirst("klepton-template-".count)) }
        modsName = names.first { name in name.hasPrefix("klepton-mods-") && toolchain.map { name.hasSuffix("-" + $0) } == true }
        mods = modsName.flatMap { Template.Mods.read(from: Self.home.appendingPathComponent($0)) }
        if let data = try? Data(contentsOf: Self.home.appendingPathComponent("handover.json")),
           let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = facts["bundlePrefix"] as? String, !value.isEmpty { prefix = value }
            if let value = facts["pairingPort"] as? Int, let number = UInt16(exactly: value) { port = number }
        }
        // AVP Plays eigene Datei ({"apps": […], "checked": …}) oder nur die Liste.
        struct LibraryFile: Decodable { let apps: [LibraryApp] }
        let data = (try? Data(contentsOf: Self.home.appendingPathComponent("library.json"))) ?? Data()
        library = ((try? JSONDecoder().decode(LibraryFile.self, from: data))?.apps ?? (try? JSONDecoder().decode([LibraryApp].self, from: data)) ?? [])
            .filter { CatalogGame.isIdentifier($0.appId) }
        // Die Rezepte: jedes wird geprüft wie am Mac; eines, das die Prüfung nicht besteht, gilt nicht.
        recipes = [:]
        for recipe in Self.read("recipes.json", [Recipe].self) ?? [] where (try? recipe.validate()) != nil {
            if let appId = recipe.store.appId { recipes[appId] = recipe }
        }
        drafts = [:]
        for name in (try? files.contentsOfDirectory(atPath: Self.home.appendingPathComponent("drafts").path)) ?? [] where name.hasSuffix(".json") {
            if let draft = Self.read("drafts/\(name)", Recipe.self), (try? draft.validate()) != nil, let appId = draft.store.appId { drafts[appId] = draft }
        }
    }

    /// Das Rezept eines Spiels: das von AVP Play, sonst der letzte Entwurf aus Metas Angaben.
    private func recipe(_ appId: String) -> Recipe? { recipes[appId] ?? drafts[appId] }

    /// Die Wahl für ein Spiel. Ohne eigene Wahl wie am Mac (`defaultOptions`): die Sprache des Systems, wenn es dafür
    /// Dateien gibt. Englisch braucht bei Sprachpaketen nichts – es ist die Fassung des Spiels selbst.
    private func options(_ appId: String) -> GameOptions {
        if let chosen = options[appId] { return chosen }
        var result = GameOptions()
        let available = Set((recipe(appId)?.files ?? []).filter { !$0.required }.compactMap(\.locale))
        for language in Locale.preferredLanguages {
            let code = language.split(separator: "-").first.map(String.init) ?? language
            if let match = available.first(where: { $0 == language }) ?? available.sorted().first(where: { $0 == code || $0.hasPrefix(code + "-") }) {
                result.locales = [match]
                break
            }
            if code == "en" { break }
        }
        return result
    }

    private func setOptions(_ value: GameOptions, _ appId: String) {
        options[appId] = value
        Self.write(options, "options.json")
    }

    /// Hält fest, was ein Auftrag unterwegs erfahren hat.
    private func remember(_ memo: Memo, _ appId: String) {
        switch memo {
        case .draft(let draft):
            drafts[appId] = draft
            try? FileManager.default.createDirectory(at: Self.home.appendingPathComponent("drafts"), withIntermediateDirectories: true)
            Self.write(draft, "drafts/\(appId).json")
        case .withheld(let id):
            var next = options(appId)
            if !next.withheld.contains(id) { next.withheld.append(id) }
            setOptions(next, appId)
        case .purchases(let skus, let verified):
            var next = options(appId)
            (next.skus, next.verified) = (skus, verified)
            setOptions(next, appId)
        }
    }

    private var templateVersion: Int? {
        templateName.flatMap { name in name.split(separator: "-").dropFirst(2).first.flatMap { Int($0) } }
    }

    private func folder(_ appId: String) -> URL { Self.home.appendingPathComponent("games").appendingPathComponent(appId) }

    /// Die Dateien eines Spiels in seinem Ordner: nach der Liste, die beim Laden geschrieben wird, sonst nach den
    /// Endungen (so gibt sie der Mac mit). Eine halb geladene Liste gilt nicht.
    nonisolated static func files(of folder: URL) -> [(name: String, kind: String)] {
        struct Listed: Codable { var name: String; var kind: String }
        let manager = FileManager.default
        if let data = try? Data(contentsOf: folder.appendingPathComponent("files.json")),
           let listed = try? JSONDecoder().decode([Listed].self, from: data) {
            return listed.allSatisfy { manager.fileExists(atPath: folder.appendingPathComponent($0.name).path) } ? listed.map { ($0.name, $0.kind) } : []
        }
        let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return names.compactMap { name in name.hasSuffix(".apk") ? (name, "APK") : name.hasSuffix(".obb") ? (name, "OBB") : nil }
    }

    nonisolated private static func bytes(of folder: URL) -> Int64 {
        files(of: folder).reduce(0) {
            $0 + (((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($1.name).path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func appId(of gameId: String) -> String? {
        gameId.hasPrefix("store-") ? String(gameId.dropFirst(6)) : nil
    }

    private func title(_ appId: String) -> String {
        library.first { $0.appId == appId }?.title.nilIfEmpty ?? jobs.first { $0.appId == appId }?.title ?? appId
    }

    private func activeJob(_ appId: String) -> Job? { jobs.first { $0.appId == appId && ($0.state == .running || $0.state == .queued) } }

    private var setupProblem: String? {
        if !hasPairing { return L("The pairing with this headset is missing (see “Setup”).", "Die Kopplung mit dieser Brille fehlt (siehe „Einrichtung“).") }
        if !hasAppleKey { return L("The Apple team key is missing (see “Setup”).", "Der Team-Schlüssel von Apple fehlt (siehe „Einrichtung“).") }
        if templateName == nil { return L("The game runtime is missing (see “Setup”).", "Die Spiel-Laufzeit fehlt (siehe „Einrichtung“).") }
        return nil
    }

    /// Ein installiertes Spiel, dessen Fassung der Katalog nicht überholt hat, lässt sich aus seiner eigenen APK neu
    /// bauen: ohne Meta und ohne Download. Das ist der Fall nach einer neuen Toolchain.
    private func rebuildsFromInstalled(_ appId: String) -> Bool {
        guard let app = installed[appId] else { return false }
        // Mit einem Rezept von AVP Play gilt dessen Fassung, nicht die neueste im Store.
        if let recipe = recipes[appId] { return app.versionCode == recipe.versionCode }
        guard let newest = catalog[appId]?.versionCode, let have = app.versionCode else { return true }
        return newest <= have
    }

    /// Sprachen und Zusatzinhalte gehören zu der Fassung, die das Rezept nennt: Zu einer anderen passen sie nicht.
    private func contentBlocker(_ app: InstalledGame, _ recipe: Recipe) -> String? {
        guard app.versionCode != recipe.versionCode else { return nil }
        return L("Version \(app.version) is installed; this content belongs to version \(recipe.versionName), the one AVP Play installs. Install the game again first.",
                 "Installiert ist Fassung \(app.version); diese Inhalte gehören zur Fassung \(recipe.versionName), die AVP Play installiert. Installiere das Spiel zuerst neu.")
    }

    /// Die Mods, mit denen dieses Spiel gebaut werden kann: Es gibt sie für genau eine Fassung des Spiels.
    private func modsProfile(_ appId: String) -> Template.Mods? {
        guard let mods, let recipe = recipes[appId], recipe.toolchain.target == mods.target, recipe.versionCode == mods.versionCode else { return nil }
        return mods
    }

    /// Ob dieses Spiel mit Mods gebaut wird: die Wahl des Nutzers, sonst wie das Mod-Profil sagt (wie am Mac).
    private func buildsWithMods(_ appId: String) -> Bool {
        guard let profile = modsProfile(appId) else { return false }
        return options(appId).coreMods ?? profile.defaultOn
    }

    /// Ob für dieses Spiel gekaufte Zusatzinhalte abgefragt und freigeschaltet werden.
    private func wantsAddons(_ appId: String) -> Bool {
        guard let addons = recipes[appId]?.addons, addons.dest != nil else { return false }
        return options(appId).addons
    }

    private func blocker(_ appId: String, downloaded: Bool) -> String? {
        if let setupProblem { return setupProblem }
        if !downloaded, !hasMetaToken, !rebuildsFromInstalled(appId) { return L("The Meta sign-in is missing (see “Setup”).", "Die Meta-Anmeldung fehlt (siehe „Einrichtung“).") }
        if activeJob(appId) != nil { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        return nil
    }

    private func onDevice(_ appId: String) -> RemoteGame.OnDevice {
        guard let app = installed[appId] else { return installedChecked ? .notInstalled : .unknown }
        if let built = app.toolchain, let now = templateVersion, built < now { return .update }
        if let recipe = recipes[appId] {
            // Auch ein Umschalten der Mods ist ein Update derselben App.
            if modsProfile(appId) != nil, buildsWithMods(appId) != app.coreMods { return .update }
            return app.versionCode == recipe.versionCode ? .current : .update
        }
        if let have = app.versionCode, let newest = catalog[appId]?.versionCode, have < newest { return .update }
        return .current
    }

    private func remoteGame(_ appId: String, title: String) -> RemoteGame {
        let entry = catalog[appId]
        let downloaded = Self.files(of: folder(appId)).contains { $0.kind == "APK" }
        let state = onDevice(appId)
        let trust: RemoteGame.Trust = switch entry?.status {
        case "verified": .verified
        case "community": .community
        case "incompatible": .incompatible
        default: .untested
        }
        let active = activeJob(appId) != nil
        let canDownload = !downloaded && hasMetaToken
        var game = RemoteGame(id: "store-\(appId)", title: title, trust: trust, onDevice: state, downloaded: downloaded, owned: true,
                              source: "meta", busy: active, installBlocker: blocker(appId, downloaded: downloaded),
                              canDownload: canDownload, downloadBlocker: canDownload && active ? blocker(appId, downloaded: false) : nil,
                              downloadSize: nil, storeBytes: Self.bytes(of: folder(appId)),
                              mixedReality: entry?.mixedReality ?? false, handTracking: entry?.handTracking ?? false,
                              favourite: favourites.contains(appId), coverKey: storePictures ? "store-\(appId)" : nil,
                              builtWith: installed[appId]?.toolchain.map { "Toolchain \($0)" })
        game.ownedAnywhere = true
        game.fromMeta = true
        game.works = entry?.works ?? 0
        return game
    }

    private func remoteJob(_ job: Job) -> RemoteJob {
        let isRunning = job.state == .running
        let current = isRunning && job.done < job.steps.count ? job.steps[job.done] : nil
        let shown = bars[job.id] ?? []
        let lead = shown.first { $0.value != nil && $0.title == nil } ?? shown.first
        var remote = RemoteJob(id: job.id, gameId: job.gameId, title: job.title, state: job.state, kind: job.kind, step: current?.title,
                               stepIndex: min(job.done + (isRunning ? 1 : 0), job.steps.count), stepCount: job.steps.count,
                               progress: lead?.value.map { min(max($0, 0), 1) }, progressText: lead?.text ?? lead?.title,
                               failure: job.state == .stopped ? job.failure : nil,
                               lastLine: isRunning ? job.log.last?.trimmingCharacters(in: .whitespaces) : nil, updated: job.updated,
                               canResume: job.state == .stopped || job.state == .interrupted,
                               canCancel: job.state != .finished && job.state != .cancelled)
        remote.bars = isRunning && !shown.isEmpty ? shown : nil
        return remote
    }

    /// Schickt den ganzen Stand an die Seiten – gebündelt, weil Fortschritt oft kommt.
    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.publishNow()
        }
    }

    private func publishNow() {
        publishScheduled = false
        guard let client else { return }
        var ids: [String: String] = [:]
        for app in library { ids[app.appId] = app.title.isEmpty ? app.appId : app.title }
        // Auch was hier liegt oder installiert ist, ohne in der Bibliothek zu stehen.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Self.home.appendingPathComponent("games").path)) ?? []
        where ids[name] == nil && CatalogGame.isIdentifier(name) && !Self.files(of: folder(name)).isEmpty {
            let facts = (try? Data(contentsOf: folder(name).appendingPathComponent("game.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            ids[name] = facts?["title"] ?? name
        }
        let games = ids.map { remoteGame($0.key, title: $0.value) }
        let updatable = games.filter { $0.onDevice == .update && $0.installBlocker == nil }.map(\.id)
        func count(_ states: Set<RemoteJob.State>) -> Int { jobs.filter { states.contains($0.state) }.count }
        var clearable: [RemoteChoice] = []
        let groups: [(String, String, Set<RemoteJob.State>)] = [
            ("finished", L("Finished Jobs", "Abgeschlossene Aufträge"), [.finished]),
            ("stopped", L("Stopped, Interrupted and Cancelled Jobs", "Angehaltene, unterbrochene und abgebrochene Aufträge"), [.stopped, .interrupted, .cancelled]),
            ("all", L("All Jobs That Are Not Running or Waiting", "Alle Aufträge, die nicht laufen oder warten"), [.finished, .stopped, .interrupted, .cancelled]),
        ]
        for (id, title, states) in groups where count(states) > 0 { clearable.append(RemoteChoice(id: id, title: "\(title) (\(count(states)))", section: nil)) }
        let status = RemoteStatus(deviceName: UIDevice.current.name, deviceVia: nil, deviceProblem: nil, setupProblem: setupProblem,
                                  refreshing: refreshing, updatable: updatable, jobs: jobs.prefix(40).map(remoteJob), notice: nil,
                                  clearable: clearable)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        client.localPublish(server: RemoteServerInfo(serverId: Self.mac.serverId, name: Self.mac.name, appVersion: version),
                            games: games, status: status, onlineCatalog: onlineCatalog)
    }

    private func saveJobs() { Self.write(Array(jobs.prefix(40)), "jobs.json") }

    // MARK: Katalog und Bilder

    /// Holt Einstufung, Meldungen und Hinweise für die Spiele der Bibliothek aus dem Katalog von AVP Play. An den
    /// Dienst gehen nur die Kennungen der Spiele; nichts über das Konto oder die Brille.
    private func loadCatalog() async {
        guard onlineCatalog else { return }
        let ids = library.map(\.appId)
        var found: [String: CatalogEntry] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start ..< min(start + 100, ids.count)].joined(separator: ",")
            guard let url = URL(string: "\(Self.catalogHost)/api/v1/catalog?ids=\(batch)"),
                  let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let games = root["games"] as? [[String: Any]] else { return }
            for game in games {
                guard let id = game["appId"] as? String else { continue }
                found[id] = CatalogEntry(status: game["status"] as? String ?? "untested", mixedReality: game["mixedReality"] as? Bool ?? false,
                                         handTracking: game["handTracking"] as? Bool ?? false, cover: game["cover"] as? Bool ?? false,
                                         works: game["works"] as? Int ?? 0, problems: game["problems"] as? Int ?? 0, fails: game["fails"] as? Int ?? 0,
                                         noteEn: game["noteEn"] as? String, noteDe: game["noteDe"] as? String, target: game["target"] as? String,
                                         versionCode: (game["build"] as? [String: Any])?["versionCode"] as? Int)
            }
        }
        catalog = found
        Self.write(found, "catalog.json")
        publish()
    }

    /// Holt das Titelbild eines Spiels: von der Seite des Meta-Stores, wie AVP Play es tut, sonst aus dem Katalog.
    func loadCover(_ game: RemoteGame) {
        guard let key = game.coverKey, let appId = appId(of: game.id), !coverAsked.contains(key) else { return }
        coverAsked.insert(key)
        coverWaiting.append((game.id, key, appId))
        pumpCovers()
    }

    private func pumpCovers() {
        while coverRunning < 3, !coverWaiting.isEmpty {
            let next = coverWaiting.removeFirst()
            let fallback = catalog[next.appId]?.cover == true
            coverRunning += 1
            Task { [weak self] in
                var data = await StoreArt().landscapeCover(appId: next.appId)
                if data == nil, fallback, let url = URL(string: "\(Self.catalogHost)/api/v1/covers/\(next.appId)"),
                   let (bytes, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                    data = bytes
                }
                let image = data.flatMap { Self.shrunk($0) }
                await MainActor.run {
                    guard let self else { return }
                    self.coverRunning -= 1
                    if let image {
                        CoverDisk.write(image.jpeg, key: next.key)
                        self.client?.localCover(gameId: next.gameId, key: next.key, image: image.image)
                    }
                    self.pumpCovers()
                }
            }
        }
    }

    /// Icon und Startbild eines Spiels aus den Bildern seiner Store-Seite, als Dateien für die App: das quadratische
    /// Titelbild als Icon (sonst die Mitte des breiten), das breite als Startbild.
    nonisolated private static func pictures(appId: String) async -> (files: [String: Data], icons: [String]) {
        let store = StoreArt()
        let wide = await store.landscapeCover(appId: appId) ?? CoverDisk.read("store-\(appId)")
        let square = await store.squareCover(appId: appId)
        var files: [String: Data] = [:]
        func drawn(_ source: UIImage, _ size: CGSize, crop: Bool) -> Data? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                // Füllend: das Bild deckt die Fläche, der Überstand fällt weg.
                let scale = crop ? max(size.width / source.size.width, size.height / source.size.height) : size.width / source.size.width
                let fitted = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
            }.pngData()
        }
        if let wide, let image = UIImage(data: wide), image.size.width > 0 {
            let width = min(image.size.width, 1920)
            files["StartHero.png"] = drawn(image, CGSize(width: width, height: (image.size.height * width / image.size.width).rounded()), crop: false)
        }
        var icons: [String] = []
        if let source = (square ?? wide).flatMap({ UIImage(data: $0) }), source.size.width > 0 {
            let sizes: [(String, String, CGFloat)] = [("AppIcon60x60", "@2x.png", 120), ("AppIcon60x60", "@3x.png", 180), ("AppIcon76x76", "@2x~ipad.png", 152),
                                                      ("AppIcon83.5x83.5", "@2x~ipad.png", 167), ("AppIcon512x512", "@2x.png", 1024)]
            for (name, suffix, side) in sizes {
                guard let data = drawn(source, CGSize(width: side, height: side), crop: true) else { continue }
                files[name + suffix] = data
                if !icons.contains(name) { icons.append(name) }
            }
        }
        return (files.compactMapValues { $0 }, icons)
    }

    /// Höchstens 960 Punkte breit, als JPEG: so schickt auch der Mac seine Bilder.
    nonisolated private static func shrunk(_ data: Data) -> (image: UIImage, jpeg: Data)? {
        guard let source = UIImage(data: data), source.size.width > 0 else { return nil }
        let scale = min(1, 960 / source.size.width)
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        return image.jpegData(compressionQuality: 0.8).map { (image, $0) }
    }

    // MARK: Bitten der Seiten

    func handle(_ request: RemoteRequest) async -> String? {
        switch request {
        case .refresh:
            return await refresh()
        case .install(let gameId):
            return enqueue(gameId, kind: .install)
        case .download(let gameId):
            return enqueue(gameId, kind: .download)
        case .updateAll:
            for game in client?.status?.updatable ?? [] { _ = enqueue(game, kind: .install) }
            return nil
        case .cancel(let jobId):
            return cancel(jobId)
        case .resume(let jobId):
            return resume(jobId)
        case .clearJobs(let kind):
            let cleared: Set<RemoteJob.State> = kind == "finished" ? [.finished] : kind == "stopped" ? [.stopped, .interrupted, .cancelled]
                : [.finished, .stopped, .interrupted, .cancelled]
            jobs.removeAll { cleared.contains($0.state) }
            saveJobs()
            publish()
            return nil
        case .panelAction(let panel, let item, let value):
            return await act(panel: panel, item: item, value: value)
        case .hello, .pair, .cover, .openPanel, .closePanel:
            return nil
        }
    }

    /// „Neu prüfen“: die Übergabe, der Katalog und was auf der Brille installiert ist (dafür geht der Tunnel an).
    private func refresh() async -> String? {
        guard !refreshing else { return nil }
        refreshing = true
        publishNow()
        importHandover()
        await loadCatalog()
        let problem = await readInstalled()
        refreshing = false
        publishNow()
        return problem
    }

    /// Liest über den Installationsdienst der Brille, welche Spiele installiert sind und in welcher Fassung. Die
    /// Kennung einer Spiel-App endet auf den Namen des Spiels in der Toolchain: „x<App-ID>“, oder ein eigener Name,
    /// den der Katalog der App-ID zuordnet.
    private func readInstalled() async -> String? {
        guard hasPairing, running == nil else { return nil }
        let pairing = Self.home.appendingPathComponent("pairing.plist").path, port = port, prefix = prefix
        var named: [String: String] = [:]
        for (appId, entry) in catalog { if let target = entry.target, !target.isEmpty { named[target] = appId } }
        do {
            try await Tunnel.start()
            let apps = try await Task.detached { try DeviceLink(address: "10.7.0.1", port: port, pairingFile: pairing).installedApps() }.value
            var found: [String: InstalledGame] = [:]
            for (bundle, app) in apps where bundle.hasPrefix(prefix + ".") {
                let target = String(bundle.dropFirst(prefix.count + 1))
                let appId = target.hasPrefix("x") && CatalogGame.isIdentifier(String(target.dropFirst())) ? String(target.dropFirst()) : named[target]
                if let appId { found[appId] = InstalledGame(build: app.build, version: app.version) }
            }
            installed = found
            installedChecked = true
            Self.write(found, "installed.json")
            return nil
        } catch {
            return L("What is installed on this headset could not be read: ", "Was auf dieser Brille installiert ist, ließ sich nicht lesen: ") + "\(error)"
        }
    }

    // MARK: Aufträge

    private func enqueue(_ gameId: String, kind: RemoteJob.Kind) -> String? {
        guard let appId = appId(of: gameId) else { return L("This game is not known here.", "Dieses Spiel ist hier nicht bekannt.") }
        let downloaded = Self.files(of: folder(appId)).contains { $0.kind == "APK" }
        let missingToken = L("The Meta sign-in is missing (see “Setup”).", "Die Meta-Anmeldung fehlt (siehe „Einrichtung“).")
        let busy = L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.")
        var steps: [Step]
        switch kind {
        case .download:
            if downloaded { return L("The files of this game are here already.", "Die Dateien dieses Spiels liegen schon hier.") }
            if !hasMetaToken { return missingToken }
            if activeJob(appId) != nil { return busy }
            steps = [.account, .fetch]
        case .install:
            if let blocker = blocker(appId, downloaded: downloaded) { return blocker }
            // Meta wird gefragt, wenn Dateien fehlen oder Käufe abzufragen sind. Fehlt nichts – die Dateien liegen
            // hier, oder das installierte Spiel hat sie in derselben Fassung –, geht es ohne Meta.
            let addons = wantsAddons(appId) && hasMetaToken
            steps = (downloaded || rebuildsFromInstalled(appId)) && !addons ? [.fetch] : [.account, .fetch]
            steps += [.build, .stage]
            if wantsAddons(appId) { steps.append(.unlock) }
        case .addons, .content:
            // Nur die Inhalte eines installierten Spiels abgleichen: Gebaut und installiert wird nichts.
            if let setupProblem { return setupProblem }
            guard let app = installed[appId], let recipe = recipes[appId] else { return L("This game is not installed.", "Dieses Spiel ist nicht installiert.") }
            if let why = contentBlocker(app, recipe) { return why }
            if !hasMetaToken { return missingToken }
            if activeJob(appId) != nil { return busy }
            steps = kind == .addons ? [.account, .fetch, .stage, .unlock] : [.account, .fetch, .stage]
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let id = "store-\(appId)-\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())"
        jobs.insert(Job(id: id, appId: appId, title: title(appId), kind: kind, state: .queued, created: Date(), updated: Date(), steps: steps), at: 0)
        waiting.append(id)
        saveJobs()
        pump()
        publish()
        return nil
    }

    private func change(_ id: String, _ body: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
        jobs[index].updated = Date()
    }

    private func append(_ id: String, _ line: String) {
        let clean = Redaction.redact(line)
        change(id) { $0.log.append(clean); if $0.log.count > 400 { $0.log.removeFirst($0.log.count - 400) } }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(clean)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: Self.logFile)
        }
        publish()
    }

    private func cancel(_ id: String) -> String? {
        guard let job = jobs.first(where: { $0.id == id }) else { return L("This job is no longer there.", "Diesen Auftrag gibt es nicht mehr.") }
        if running?.id == id {
            running?.task.cancel()      // der laufende Schritt endet noch; dann hört der Auftrag auf
        } else if job.state != .finished {
            waiting.removeAll { $0 == id }
            change(id) { $0.state = .cancelled }
            saveJobs()
        }
        publish()
        return nil
    }

    private func resume(_ id: String) -> String? {
        guard let job = jobs.first(where: { $0.id == id }), job.state == .stopped || job.state == .interrupted else {
            return L("This job cannot be resumed.", "Dieser Auftrag lässt sich nicht fortsetzen.")
        }
        if activeJob(job.appId) != nil { return L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.") }
        change(id) { $0.state = .queued; $0.failure = nil; $0.done = 0 }
        waiting.append(id)
        saveJobs()
        pump()
        publish()
        return nil
    }

    /// Startet den nächsten wartenden Auftrag; es läuft immer nur einer.
    private func pump() {
        guard running == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard let job = jobs.first(where: { $0.id == id }), let templateName else { return pump() }
        change(id) { $0.state = .running; $0.done = 0 }
        var settings: [String: String] = ["KLRoomGuardDefault": roomMeasuring ? "1" : "0", "KLGameLanguageDefault": gameLanguage]
        var switches: [String] = []
        var buildExtra = 0
        if metalFX {
            switches.append("KL_METALFX_UPSCALE")
            if metalFXResolution < 100 { settings["KLRenderScaleDefault"] = String(format: "%.2f", Double(metalFXResolution) / 100) }
            // Die Baunummer sagt es wie am Mac: 4 für MetalFX, darüber die Stufe unter 100 % in Schritten von 5.
            buildExtra = 4 + 8 * ((100 - min(100, max(50, metalFXResolution))) / 5)
        }
        let appId = job.appId
        // Mit Mods: die Vorlage, die sie mitbringt.
        let withMods = job.kind == .install && buildsWithMods(appId)
        let plan = Plan(job: job, folder: folder(appId), template: Self.home.appendingPathComponent(withMods ? modsName ?? templateName : templateName),
                        prefix: prefix, port: port,
                        target: recipes[appId]?.toolchain.target ?? catalog[appId]?.target, settings: settings, switches: switches,
                        buildExtra: buildExtra, installedBuild: installed[appId]?.build, recipe: recipe(appId), shipped: recipes[appId] != nil,
                        options: options(appId))
        let hooks = Hooks(
            line: { text in Task { @MainActor [weak self] in self?.append(id, "    " + text) } },
            step: { index in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.change(id) { $0.done = index }
                    self.bars[id] = nil
                    if index < job.steps.count { self.append(id, "[\(index + 1)/\(job.steps.count)] \(job.steps[index].title)") }
                }
            },
            bars: { shown in Task { @MainActor [weak self] in self?.bars[id] = shown; self?.publish() } },
            remember: { memo in Task { @MainActor [weak self] in self?.remember(memo, appId) } })
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            var cancelled = false
            var installedAs: InstalledGame?
            do {
                installedAs = try await Self.run(plan, hooks)
            } catch is CancellationError {
                cancelled = true
            } catch {
                let text = Redaction.redact("\(error)")
                failure = text.contains("staged background update")
                    ? L("The headset could not replace the installed app; it waited five minutes for it. Why is not known. Make sure the game is closed and resume this job: a second try has worked.",
                        "Die Brille konnte die installierte App nicht ersetzen; sie hat fünf Minuten darauf gewartet. Warum, ist nicht bekannt. Stelle sicher, dass das Spiel geschlossen ist, und setze den Auftrag fort: Ein zweiter Versuch hat schon geklappt.")
                    + "\n\n" + text
                    : text
            }
            await MainActor.run { [failure, cancelled, installedAs] in
                guard let self else { return }
                self.running = nil
                self.bars[id] = nil
                self.change(id) {
                    $0.state = cancelled ? .cancelled : failure == nil ? .finished : .stopped
                    $0.failure = failure
                    if failure == nil, !cancelled { $0.done = $0.steps.count }
                }
                if let failure { self.append(id, "    " + failure) }
                if let installedAs {
                    self.installed[job.appId] = installedAs
                    self.installedChecked = true
                    Self.write(self.installed, "installed.json")
                }
                self.saveJobs()
                self.pump()
                self.publish()
            }
        }
        running = (id, task)
    }

    /// Was ein Auftrag zum Arbeiten braucht, als Werte: Er läuft außerhalb des Hauptfadens.
    struct Plan: Sendable {
        let job: Job
        let folder: URL
        let template: URL
        let prefix: String
        let port: UInt16
        let target: String?
        let settings: [String: String]
        let switches: [String]
        let buildExtra: Int
        /// Die Baunummer des installierten Spiels, wenn es eines gibt: Dann kann seine APK für einen Neubau dienen.
        let installedBuild: String?
        /// Das Rezept von AVP Play (`shipped`), sonst der letzte Entwurf aus Metas Angaben, sonst nichts.
        let recipe: Recipe?
        let shipped: Bool
        let options: GameOptions
    }

    struct Hooks: Sendable {
        let line: @Sendable (String) -> Void
        let step: @Sendable (Int) -> Void
        let bars: @Sendable ([RemoteProgress]) -> Void
        let remember: @Sendable (Memo) -> Void
    }

    nonisolated private static func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
    nonisolated private static func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_073_741_824) }

    /// Die Arbeit eines Auftrags, Schritt für Schritt. Zurück kommt, als was das Spiel installiert ist (bei einem
    /// Auftrag, der nichts installiert: nichts).
    ///
    /// Welche Dateien ein Spiel braucht und wohin sie gehören, sagt sein Rezept – das von AVP Play, oder ein Entwurf
    /// aus dem, was Meta für den neuesten Build nennt. Welche davon gebraucht werden, entscheidet AVP Plays eigener
    /// Code (`FetchPlan`): Pflichtdateien, die gewählten Sprachen und Inhalte, die gekauften Zusatzinhalte.
    ///
    /// Die Regeln für Meta sind die von AVP Play: zuerst das Konto prüfen und ob ihm das Spiel gehört, dann genau die
    /// Dateien laden, die gebraucht werden, eine nach der anderen. Nichts wird durchprobiert; das erste unerwartete
    /// Ergebnis beendet den Auftrag. Die eine Ausnahme ist die von AVP Play: eine weitere Datei eines Entwurfs, die
    /// Meta dem Konto nicht ausliefert (ein nicht gekaufter Zusatzinhalt), wird übersprungen und nie wieder angefragt.
    nonisolated private static func run(_ plan: Plan, _ hooks: Hooks) async throws -> InstalledGame? {
        let manager = FileManager.default
        let job = plan.job
        let work = manager.temporaryDirectory.appendingPathComponent("standalone-work")
        defer { try? manager.removeItem(at: work) }
        func begin(_ step: Step) throws {
            try Task.checkCancellation()
            guard let at = job.steps.firstIndex(of: step) else { return }
            hooks.step(at)
        }
        let installing = job.kind == .install
        let syncing = job.kind == .addons || job.kind == .content

        // Die Vorlage zuerst: Sie sagt, unter welchem Namen das Spiel installiert ist und wie seine APK dort heißt.
        let template = try Template.open(plan.template, in: work.appendingPathComponent("template"))
        let known = plan.target.flatMap { template.known($0) != nil ? $0 : nil }
        let target = known ?? "x\(job.appId)"
        let bundleID = "\(plan.prefix).\(target)"
        let pairing = home.appendingPathComponent("pairing.plist").path
        let apkName = (known.flatMap { template.known($0)?["apk"] as? String }) ?? "\(target).apk"
        let installedCode = plan.installedBuild?.split(separator: ".").first.flatMap { Int($0) }

        var current = plan.recipe
        var replaced = false
        var options = plan.options
        var client: MetaClient?

        func signIn() async throws {
            guard let token = MetaToken.read() else { throw FinishFailure(description: L("There is no Meta sign-in on this headset.", "Auf dieser Brille gibt es keine Meta-Anmeldung.")) }
            let meta = MetaClient(token: token)
            let user = try await meta.me()
            guard try await meta.ownsApp(appId: job.appId, userId: user) else {
                throw FinishFailure(description: L("Meta says this account does not own the game.", "Meta sagt, dass diesem Konto das Spiel nicht gehört."))
            }
            hooks.line(L("The account owns the game.", "Das Spiel gehört dem Konto."))
            client = meta
            // Mit einem Rezept von AVP Play stehen Fassung und Dateien fest. Sonst: der neueste Build und seine Dateien.
            if plan.shipped || syncing { return }
            guard let newest = try await meta.builds(appId: job.appId).first else {
                throw FinishFailure(description: L("Meta named no build of this game for the account.", "Meta nennt für das Konto keinen Build dieses Spiels."))
            }
            hooks.line(L("Version \(newest.version) (\(newest.versionCode)).", "Fassung \(newest.version) (\(newest.versionCode))."))
            if let have = current, have.versionCode == newest.versionCode, have.files.contains(where: { $0.role == "apk" && !$0.id.isEmpty }) { return }
            let listed = try await meta.buildFiles(buildId: newest.buildId)
            guard listed.contains(where: { $0.kind == "APK" }) else {
                throw FinishFailure(description: L("Meta named no files for version \(newest.version).", "Meta nennt für die Fassung \(newest.version) keine Dateien."))
            }
            // Reste einer anderen Fassung tragen oft dieselben Namen; sie dürfen nicht für die neue gelten.
            if let have = current, have.versionCode != newest.versionCode { try? manager.removeItem(at: plan.folder) }
            let draft = try DraftRecipe.make(appId: job.appId, title: job.title, package: "", build: newest, files: listed, target: target, minCommit: "")
            current = draft
            replaced = true
            hooks.remember(.draft(draft))
        }

        /// Fragt Meta, was das Konto für dieses Spiel gekauft hat. Antwortet Meta nicht, gilt wie am Mac die letzte
        /// bestätigte Antwort.
        func askPurchases() async {
            guard let recipe = current, recipe.addons != nil, options.addons, let client else { return }
            do {
                let skus = try await client.purchases(appId: job.appId).sorted()
                let now = Date()
                (options.skus, options.verified) = (skus, now)
                hooks.remember(.purchases(skus, now))
                hooks.line(L("Purchases: \(skus.count) confirmed.", "Käufe: \(skus.count) bestätigt."))
            } catch {
                hooks.line(L("Note: \(Redaction.redact("\(error)"))", "Hinweis: \(Redaction.redact("\(error)"))"))
                if let skus = options.skus, let verified = options.verified {
                    let day = DateFormatter.localizedString(from: verified, dateStyle: .medium, timeStyle: .none)
                    hooks.line(L("Purchases: the last confirmed state applies (\(skus.count), from \(day)).",
                                 "Käufe: Es gilt der zuletzt bestätigte Stand (\(skus.count), vom \(day))."))
                }
            }
        }

        if job.steps.contains(.account) {
            try begin(.account)
            try await signIn()
            await askPurchases()
        }

        try begin(.fetch)
        if current == nil {
            // Kein Rezept und kein Entwurf: Dateien, die der Mac mitgegeben hat; oder das installierte Spiel, dessen
            // APK für einen Neubau reicht; sonst sagt Meta, was es gibt.
            let present = files(of: plan.folder)
            if present.contains(where: { $0.kind == "APK" }) {
                let facts = (try? Data(contentsOf: plan.folder.appendingPathComponent("game.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
                current = DraftRecipe.local(appId: job.appId, title: job.title, target: target,
                                            versionCode: facts?["versionCode"].flatMap { Int($0) } ?? installedCode ?? 0, files: present)
            } else if installing, let installedCode {
                current = DraftRecipe.local(appId: job.appId, title: job.title, target: target, versionCode: installedCode, files: [(apkName, "APK")])
            } else {
                try await signIn()
            }
        }

        // Der Datenordner des installierten Spiels auf der Brille.
        var documents: DeviceFolder?
        func device() async throws -> DeviceFolder {
            if let documents { return documents }
            try await Tunnel.start()
            let folder = try DeviceLink(address: "10.7.0.1", port: plan.port, pairingFile: pairing).documents(of: bundleID)
            documents = folder
            return folder
        }

        /// Liest die APK aus dem installierten Spiel zurück: Dann wird für einen Neubau derselben Fassung nichts geladen.
        func readBack(to local: URL) async throws -> Bool {
            do {
                let folder = try await device()
                guard let size = folder.size(of: apkName), size > 0 else { return false }
                try manager.createDirectory(at: plan.folder, withIntermediateDirectories: true)
                let started = Date(), meter = Meter()
                try folder.read(apkName, to: local) { read in
                    let share = Double(read) / Double(size)
                    if meter.moved(share) {
                        hooks.bars([RemoteProgress(value: share, text: L("\(megabytes(Int64(read))) of \(megabytes(Int64(size))) read from the installed game",
                                                                       "\(megabytes(Int64(read))) von \(megabytes(Int64(size))) aus dem installierten Spiel gelesen"))])
                    }
                }
                hooks.line(String(format: L("Taken from the installed game: %@, %@ (%.0f s).", "Aus dem installierten Spiel genommen: %@, %@ (%.0f s)."),
                                  apkName, megabytes(Int64(size)), Date().timeIntervalSince(started)))
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? manager.removeItem(at: local)
                hooks.line(L("The installed game's files could not be read (\(error)).", "Die Dateien des installierten Spiels ließen sich nicht lesen (\(error))."))
                return false
            }
        }

        var loaded: Int64 = 0
        /// Lädt eine Datei von Meta in den Ordner des Spiels und prüft sie gegen das Rezept. `false`: Meta liefert sie
        /// diesem Konto nicht aus.
        func download(_ file: RecipeFile, _ number: Int, of count: Int) async throws -> Bool {
            try Task.checkCancellation()
            guard let client, !file.id.isEmpty, file.id.allSatisfy(\.isNumber) else {
                throw FinishFailure(description: L("\(file.name) is missing, and it cannot be downloaded.", "\(file.name) fehlt und lässt sich nicht laden."))
            }
            try manager.createDirectory(at: plan.folder, withIntermediateDirectories: true)
            let final = plan.folder.appendingPathComponent(file.name)
            let part = plan.folder.appendingPathComponent(".\(file.name).part")
            try? manager.removeItem(at: final)
            var offset = ContentStore.fileSize(part) ?? 0
            if let expected = file.size, offset >= expected {
                try? manager.removeItem(at: part)
                offset = 0
            }
            let started = Date(), before = loaded, meter = Meter()
            let outcome: MetaClient.DownloadOutcome
            do {
                outcome = try await client.download(id: file.id, to: part, resumeFrom: offset) { received, total in
                    let share = total.map { $0 > 0 ? Double(received) / Double($0) : 0 } ?? 0
                    guard meter.moved(share) else { return }
                    hooks.bars([
                        RemoteProgress(value: (Double(number - 1) + share) / Double(count), text: "\(gigabytes(before + received)) \(L("downloaded", "geladen"))"),
                        RemoteProgress(title: L("File \(number) of \(count) · \(file.name)", "Datei \(number) von \(count) · \(file.name)"),
                                       value: share, text: total.map { L("\(megabytes(received)) of \(megabytes($0))", "\(megabytes(received)) von \(megabytes($0))") }
                                           ?? L("\(megabytes(received)) loaded", "\(megabytes(received)) geladen")),
                    ])
                }
            } catch MetaError.denied(status: 404) where Fetcher.mayBeWithheld(file) {
                // Kein unerwarteter Ausgang, sondern Metas Antwort auf einen Zusatzinhalt, der nicht gekauft ist.
                try? manager.removeItem(at: part)
                if !options.withheld.contains(file.id) { options.withheld.append(file.id) }
                hooks.remember(.withheld(file.id))
                hooks.line(L("not delivered by Meta for this account (HTTP 404): \(file.name) – most likely add-on content that isn't purchased. Skipped and remembered; it won't be requested again.",
                             "von Meta für dieses Konto nicht ausgeliefert (HTTP 404): \(file.name) – sehr wahrscheinlich ein Zusatzinhalt, der nicht gekauft ist. Übersprungen und vermerkt; die Datei wird nicht wieder angefragt."))
                return false
            }
            if let total = outcome.totalSize, outcome.bytesReceived != total {
                throw FinishFailure(description: L("\(file.name) arrived with \(outcome.bytesReceived) of \(total) bytes.",
                                                   "\(file.name) kam mit \(outcome.bytesReceived) von \(total) Bytes an."))
            }
            let size = ContentStore.fileSize(part) ?? 0
            if let expected = file.size, size != expected {
                try? manager.removeItem(at: part)
                throw FinishFailure(description: L("\(file.name) has \(size) bytes, the recipe names \(expected).", "\(file.name) hat \(size) Bytes, das Rezept nennt \(expected)."))
            }
            if let expected = file.sha256, try Hashing.sha256(of: part) != expected.lowercased() {
                try? manager.removeItem(at: part)
                throw FinishFailure(description: L("\(file.name) does not have the checksum the recipe names.", "\(file.name) hat nicht die Prüfsumme, die das Rezept nennt."))
            }
            try manager.moveItem(at: part, to: final)
            loaded += size
            hooks.line(String(format: L("%@ loaded, %@ (%.0f s).", "%@ geladen, %@ (%.0f s)."), file.name, megabytes(size), Date().timeIntervalSince(started)))
            return true
        }

        // Wo die Dateien im Datenordner des Spiels liegen (unter „Documents“). Ein Entwurf lässt offen, wo die
        // Haupt-Datendatei hingehört und wie das Paket heißt; das sagt die APK.
        var places: (package: String?, obb: String, arm64: Bool)?
        func place(_ file: RecipeFile) -> String? {
            if file.role == "apk" { return apkName }
            guard var dest = file.dest else { return nil }
            if dest == DraftRecipe.obbPlaceholder {
                guard let places else { return nil }
                dest = "android-files/\(places.obb)"
            } else if DraftRecipe.needsPackage(dest) {
                guard let package = places?.package else { return nil }
                dest = DraftRecipe.packageFolder(package: package)
            }
            let name = file.localName ?? file.name
            return dest.isEmpty ? name : "\(dest)/\(name)"
        }

        var wanted: [RecipeFile] = []
        var apk: URL?
        for round in 1...2 {
            guard let recipe = current else { break }
            replaced = false
            var selection = FetchSelection(locales: Set(options.locales), optionalNames: Set(options.optionalNames), withheld: Set(options.withheld))
            if recipe.addons?.kind == .deliveredAssets, options.addons, let skus = options.skus { selection.ownedSKUs = Set(skus) }
            // Was Meta liefert und einen Ort auf dem Gerät hat. Ein Abgleich betrifft nur das Wählbare und Gekaufte.
            wanted = FetchPlan.wantedFiles(recipe: recipe, selection: selection).filter { $0.source == nil && ($0.role == "apk" || $0.dest != nil) }
            if syncing { wanted = wanted.filter { !$0.required && place($0) != nil } }

            // 1. Die APK: Sie liegt hier, im installierten Spiel derselben Fassung, oder bei Meta.
            if !syncing {
                guard let file = wanted.first(where: { $0.role == "apk" }) else {
                    throw FinishFailure(description: L("The game's files are not complete.", "Die Dateien des Spiels sind nicht vollständig."))
                }
                let local = plan.folder.appendingPathComponent(file.name)
                var have = ContentStore.fileSize(local)
                if let size = have, let expected = file.size, size != expected { have = nil }
                if have == nil, installing, plan.installedBuild != nil, installedCode == recipe.versionCode, try await readBack(to: local) {
                    have = ContentStore.fileSize(local)
                    if let size = have, let expected = file.size, size != expected { have = nil }
                }
                if have == nil {
                    if client == nil {
                        hooks.line(L("Downloading from Meta.", "Es wird von Meta geladen."))
                        try await signIn()
                        if replaced, round == 1 { continue }
                    }
                    _ = try await download(file, 1, of: wanted.count)
                }
                let found = try Finish.places(apk: local, target: known, appID: job.appId, template: template)
                // Steht fest, sobald die APK da ist – bevor Gigabytes für ein Spiel geladen werden, das nie starten kann.
                guard found.arm64 else {
                    throw FinishFailure(description: L("This game has no 64-bit ARM code. It cannot run on the Vision Pro.",
                                                       "Dieses Spiel enthält keinen 64-Bit-ARM-Code. Es kann auf der Vision Pro nicht laufen."))
                }
                (places, apk) = (found, local)
            }

            // 2. Alles Weitere: Was im installierten Spiel schon an seinem Ort liegt, wird nicht geladen. Kennt das
            //    Rezept die Größe, entscheidet sie; sonst gilt es nur für dieselbe Fassung.
            var onDevice: [String: Int64] = [:]
            if plan.installedBuild != nil, job.kind != .download {
                do {
                    let there = try await device()
                    for file in wanted where file.role != "apk" {
                        guard let path = place(file), let size = there.size(of: path).map(Int64.init), size > 0 else { continue }
                        if let expected = file.size { if size == expected { onDevice[file.name] = size } }
                        else if installedCode == recipe.versionCode { onDevice[file.name] = size }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if syncing { throw error }
                    hooks.line(L("The installed game's files could not be looked at (\(error)).", "Die Dateien des installierten Spiels ließen sich nicht ansehen (\(error))."))
                }
            }
            let folder = plan.folder, there = onDevice
            let planned = FetchPlan.plan(recipe: recipe, selection: selection) { file in
                if let size = ContentStore.fileSize(folder.appendingPathComponent(file.name)) { return .present(size: size) }
                if let size = ContentStore.fileSize(folder.appendingPathComponent(".\(file.name).part")), size > 0 { return .partial(size) }
                if let size = there[file.name] { return .present(size: file.size ?? size) }
                return .missing
            }
            let names = Set(wanted.map(\.name))
            let todo = planned.filter { names.contains($0.file.name) && $0.file.role != "apk" && $0.action != .keep }
            let rest = wanted.filter { $0.role != "apk" }.count
            if rest > 0 || syncing {
                hooks.line(L("Files: \(rest) needed, \(there.count) already in the installed game, \(todo.count) to download.",
                             "Dateien: \(rest) gebraucht, \(there.count) liegen schon im installierten Spiel, \(todo.count) zu laden."))
            }
            if !todo.isEmpty {
                if client == nil {
                    hooks.line(L("Downloading from Meta.", "Es wird von Meta geladen."))
                    try await signIn()
                    if replaced, round == 1 { continue }
                }
                for (number, item) in todo.enumerated() { _ = try await download(item.file, number + 1, of: todo.count) }
            }
            break
        }
        guard let recipe = current else {
            throw FinishFailure(description: L("Nothing is known about this game's files.", "Über die Dateien dieses Spiels ist nichts bekannt."))
        }
        func localSize(_ file: RecipeFile) -> Int64? { ContentStore.fileSize(plan.folder.appendingPathComponent(file.name)) }
        if !syncing {
            // Erst wenn alles da ist, steht die Liste: Ein abgebrochener Lauf gilt nicht als geladen.
            let facts = ["appID": job.appId, "title": job.title, "version": recipe.versionName, "versionCode": "\(recipe.versionCode)"]
            try JSONSerialization.data(withJSONObject: facts).write(to: plan.folder.appendingPathComponent("game.json"))
            let list = wanted.filter { localSize($0) != nil }
                .map { ["name": $0.name, "kind": $0.role == "apk" ? "APK" : $0.role.hasSuffix("-obb") ? "OBB" : "ASSET"] }
            try JSONSerialization.data(withJSONObject: list).write(to: plan.folder.appendingPathComponent("files.json"))
        }
        guard installing || syncing else { return nil }

        // Was von hier aufs Gerät gehört, und wohin.
        let staged: [(file: RecipeFile, url: URL, size: Int64, path: String)] = wanted.compactMap { file in
            guard file.role != "apk", let path = place(file), let size = localSize(file) else { return nil }
            return (file, plan.folder.appendingPathComponent(file.name), size, path)
        }
        for file in wanted where file.role != "apk" && place(file) == nil {
            hooks.line(L("No place on the device is known for \(file.name); it is left out.", "Für \(file.name) ist kein Ort auf dem Gerät bekannt; die Datei bleibt weg."))
        }
        let apkSize = apk.flatMap { ContentStore.fileSize($0) } ?? 0
        let total = staged.map(\.size).reduce(0, +) + (installing ? apkSize : 0)
        let quiet: (String) -> Void = { hooks.line($0.trimmingCharacters(in: .whitespaces)) }

        // Bauen und installieren: aus Vorlage und APK die App, signieren, über den Tunnel installieren.
        var installed: InstallCore.Installed?
        var finished: Finish.Finished?
        if installing, let apk {
            try begin(.build)
            hooks.line("Toolchain \(template.version) (\(template.commit))" + (template.mods.map { L(", with the mods for \($0.versionName)", ", mit den Mods für \($0.versionName)") } ?? ""))
            let art = await pictures(appId: job.appId)
            hooks.line(art.files.isEmpty ? L("No store picture found: the game gets no icon and no start image.", "Kein Bild aus dem Store gefunden: Das Spiel bekommt kein Icon und kein Startbild.")
                       : L("Icon and start image from the store's pictures.", "Icon und Startbild aus den Bildern des Stores."))
            let built = try Finish.run(Finish.Request(apk: apk, libraries: nil, target: known, appID: job.appId, title: job.title, bundleID: bundleID,
                                                      settings: plan.settings, switches: plan.switches, pictures: art.files, iconNames: art.icons,
                                                      buildExtra: plan.buildExtra),
                                       template: template, work: work.appendingPathComponent("finish"), log: quiet)
            try Task.checkCancellation()
            let state = home.appendingPathComponent("signing")
            try manager.createDirectory(at: state, withIntermediateDirectories: true)
            try SignCore.identity(api: AppleAPI(folder: home), state: state, bundleID: bundleID, log: quiet)
            let signed = try SignCore.sign(root: built.root, bundleID: bundleID, wanted: template.entitlements, state: state,
                                           work: work.appendingPathComponent("sign"), log: quiet)
            try Task.checkCancellation()
            try await Tunnel.start()
            let link = try DeviceLink(address: "10.7.0.1", port: plan.port, pairingFile: pairing)
            let free = try link.files().freeBytes()
            guard Int64(free) > total + (2 << 30) else {
                throw FinishFailure(description: L("Not enough free space on this headset: the game needs \(gigabytes(total + (2 << 30))).",
                                                   "Nicht genug freier Speicher auf dieser Brille: Das Spiel braucht \(gigabytes(total + (2 << 30)))."))
            }
            hooks.line(L("Installing on the Vision Pro …", "Wird auf der Vision Pro installiert …"))
            let result: InstallCore.Installed
            do {
                result = try InstallCore.run(address: "10.7.0.1", port: plan.port, pairingFile: pairing, package: signed.package,
                                             bundleID: bundleID, log: quiet)
            } catch let error where "\(error)".contains("PublicStaging") {
                // Die Verbindung zu den Diensten der Brille ist beim Kopieren des Pakets abgerissen (gesehen: „BrokenPipe“
                // nach einer halben Minute). Installiert ist dann noch nichts: einmal neu verbinden und noch einmal.
                hooks.line(L("The connection to the headset's services broke while the package was copied. Trying once more.",
                             "Die Verbindung zu den Diensten der Brille ist beim Kopieren des Pakets abgerissen. Ein zweiter Versuch folgt."))
                try Task.checkCancellation()
                try await Tunnel.start()
                result = try InstallCore.run(address: "10.7.0.1", port: plan.port, pairingFile: pairing, package: signed.package,
                                             bundleID: bundleID, log: quiet)
            }
            if let signer = result.signer, signer != signed.signer {
                throw FinishFailure(description: "the headset names \(signer) as the signer, not \(signed.signer)")
            }
            (installed, finished) = (result, built)
            documents = nil     // der Datenordner der neu installierten App
        }

        // Die Spieldaten in den Ordner der App: wohin AVP Play sie am Mac auch legt.
        try begin(.stage)
        let folder = try await device()
        var copied: Int64 = 0
        let verb = L("copied to the Vision Pro", "auf die Vision Pro kopiert")
        func show(_ now: Int64) {
            hooks.bars([RemoteProgress(value: total > 0 ? Double(now) / Double(total) : nil,
                                       text: L("\(gigabytes(now)) of \(gigabytes(total)) \(verb)", "\(gigabytes(now)) von \(gigabytes(total)) \(verb)"))])
        }
        func put(_ local: URL, _ path: String) throws {
            try Task.checkCancellation()
            let size = ContentStore.fileSize(local) ?? 0
            if folder.size(of: path).map(Int64.init) != size {
                let before = copied
                try folder.write(local, to: path) { written in show(before + Int64(written)) }
            }
            copied += size
            show(copied)
        }
        if total > 0 { show(0) }
        if let finished, let apk {
            try put(apk, finished.apkName)
            if let manifest = finished.manifest, let yml = finished.apktoolYml {
                try folder.write(Data(manifest.utf8), to: "\(finished.tree)/AndroidManifest.xml")
                try folder.write(Data(yml.utf8), to: "\(finished.tree)/apktool.yml")
            }
            try Zip.forEach(in: apk, prefix: "assets/") { entry, content in
                let path = "\(finished.tree)/\(entry.name)"
                if folder.size(of: path) != entry.size { try folder.write(try content(), to: path) }
            }
            // Steam Link sucht seine Qt-Erweiterungen zusätzlich als Dateien in seinem Ordner (stage_assets.sh, qtplugins).
            if finished.kind == "steamlink" {
                try Zip.forEach(in: apk, prefix: "lib/arm64-v8a/libplugins_") { entry, content in
                    let path = "\(finished.tree)/qtplugins/\((entry.name as NSString).lastPathComponent)"
                    if folder.size(of: path) != entry.size { try folder.write(try content(), to: path) }
                }
            }
        }
        for entry in staged { try put(entry.url, entry.path) }
        if !staged.isEmpty {
            hooks.line(L("Data: \(staged.count) files copied to the game (\(gigabytes(staged.map(\.size).reduce(0, +)))).",
                         "Daten: \(staged.count) Dateien zum Spiel kopiert (\(gigabytes(staged.map(\.size).reduce(0, +))))."))
        }
        // Abgewähltes, das sich vom Gerät nehmen lässt.
        let chosen = Set(wanted.map(\.name))
        for file in recipe.files where file.clearable == true && !file.required && !chosen.contains(file.name) {
            guard let path = place(file), let size = folder.size(of: path), size > 0 else { continue }
            folder.remove(path)
            hooks.line(L("Taken off the device: \(file.title?.text ?? file.name) (\(gigabytes(Int64(size))) freed).",
                         "Vom Gerät genommen: \(file.title?.text ?? file.name) (\(gigabytes(Int64(size))) frei)."))
        }
        if installing {
            // Nach einem Wechsel der Fassung: Die OBB-Dateien der alten Fassung („main.<Nummer>.….obb“) braucht niemand mehr.
            let obbs = wanted.filter { $0.role.hasSuffix("-obb") }
            let fresh = Set(obbs.map { $0.localName ?? $0.name })
            for directory in Set(obbs.compactMap { place($0).map { ($0 as NSString).deletingLastPathComponent } }) {
                for name in (try? folder.list(directory)) ?? []
                where !fresh.contains(name) && name.hasSuffix(".obb") && (name.hasPrefix("main.") || name.hasPrefix("patch.")) {
                    folder.remove("\(directory)/\(name)")
                    hooks.line(L("Removed the previous version's \(name).", "\(name) der vorigen Fassung entfernt."))
                }
            }
            // Die Liste der Asset-Dateien, die das Spiel über den Store erfragt (Sprachpakete): aus dem Rezept, wie am Mac.
            let strip: (String) -> String = { $0.hasPrefix("Documents/") ? String($0.dropFirst(10)) : $0 }
            if let text = AssetFilesList.contents(for: recipe) {
                try folder.write(Data(text.utf8), to: strip(AssetFilesList.destination))
                hooks.line(L("Asset files: list with \(recipe.assetFiles?.count ?? 0) entries written for the game.",
                             "Asset-Dateien: Liste mit \(recipe.assetFiles?.count ?? 0) Einträgen für das Spiel geschrieben."))
            } else {
                let container = AssetFilesList.Container(size: { folder.size(of: strip($0)).map(Int64.init) },
                                                         fetch: { try folder.read(strip($0), to: $1) },
                                                         put: { try folder.write($0, to: strip($1)) })
                if (try? AssetFilesList.clearOwn(in: container)) == .cleared {
                    hooks.line(L("Asset files: this version of the game has no list, so the one written earlier was emptied.",
                                 "Asset-Dateien: Diese Fassung des Spiels hat keine Liste, daher wurde die früher geschriebene geleert."))
                }
            }
        }
        // Die Dateien liegen jetzt im Spiel; hier werden sie nicht noch einmal gebraucht. Ein späterer Neubau liest die
        // APK aus dem Spiel zurück.
        for entry in staged { try? manager.removeItem(at: entry.url) }
        if installing, let apk { try? manager.removeItem(at: apk) }
        if !syncing { try? manager.removeItem(at: plan.folder.appendingPathComponent("files.json")) }

        // Zusatzinhalte freischalten: dieselben zwei Dateien, die AVP Play am Mac schreibt.
        if job.steps.contains(.unlock), let addons = recipe.addons, let dest = addons.dest {
            try begin(.unlock)
            if options.addons, let skus = options.skus, let verified = options.verified {
                switch addons.kind {
                case .purchaseList:
                    try folder.write(Data(AddonFiles.entitlements(appId: job.appId, skus: skus, verified: verified).utf8),
                                     to: "\(dest)/\(AddonFiles.entitlementsName)")
                    hooks.line(L("Add-on content: purchase list with \(skus.count) purchases copied to the device.",
                                 "Zusatzinhalte: Kaufliste mit \(skus.count) Käufen aufs Gerät gelegt."))
                case .deliveredAssets:
                    // Gemeldet wird nur, was gekauft ist und wirklich auf dem Gerät liegt.
                    let bought = (addons.items ?? []).filter { skus.contains($0.sku) }
                    let present = bought.filter { item in
                        guard let size = folder.size(of: "\(dest)/\(item.name)"), size > 0 else { return false }
                        return item.size == nil || item.size == Int64(size)
                    }
                    try folder.write(Data(AddonFiles.assetIndex(present).utf8), to: "\(dest)/\(AddonFiles.assetIndexName)")
                    hooks.line(L("Add-on content: \(present.count) of \(bought.count) purchased files reported"
                                 + (present.count < bought.count ? " (the rest not downloaded yet)" : "") + ".",
                                 "Zusatzinhalte: \(present.count) von \(bought.count) gekauften Dateien gemeldet"
                                 + (present.count < bought.count ? " (Rest noch nicht geladen)" : "") + "."))
                }
            } else {
                hooks.line(L("Add-on content: no confirmed purchases – nothing will be unlocked.",
                             "Zusatzinhalte: kein bestätigter Kaufstand – es wird nichts freigeschaltet."))
            }
        }
        hooks.step(job.steps.count)
        guard let installed else {
            hooks.line(L("The game's content on the Vision Pro is up to date. It applies from the next start of the game.",
                         "Die Inhalte des Spiels auf der Vision Pro sind auf dem Stand. Sie gelten ab dem nächsten Start des Spiels."))
            return nil
        }
        hooks.line(L("Installed as \(bundleID), build \(installed.version). Start it from the Home View.",
                     "Installiert als \(bundleID), Build \(installed.version). Starte es aus der Home-Ansicht."))
        return InstalledGame(build: installed.version, version: Finish.shortVersion(installed.version))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Die beschriebenen Seiten

/// Die Seiten, die sonst der Mac beschreibt: dieselben Abschnitte und Wörter, soweit es sie auf der Brille gibt.
extension LocalBackend {
    private typealias Item = RemoteItem
    private typealias Section = RemoteSection

    func panel(_ id: String) -> RemotePanel? {
        if id == "setup" { return RemotePanel(id: id, sections: setupSections()) }
        if id == "settings" { return RemotePanel(id: id, sections: settingsSections()) }
        if id.hasPrefix("job:"), let job = job(String(id.dropFirst(4))) { return RemotePanel(id: id, sections: jobSections(job)) }
        if id.hasPrefix("game:"), let appId = appId(ofGame: String(id.dropFirst(5))) { return RemotePanel(id: id, sections: gameSections(appId)) }
        return nil
    }

    func act(panel: String, item: String, value: String?) async -> String? {
        let on = value == "1"
        if panel == "setup" {
            return item == "refresh" ? await handle(.refresh) : nil
        }
        if panel == "settings" {
            switch item {
            case "roomMeasuring": set("local.roomMeasuring", on)
            case "gameLanguage": set("local.gameLanguage", value ?? "")
            case "onlineCatalog":
                set("local.onlineCatalog", on)
                if on { Task { await self.reloadCatalog() } }
            case "storePictures": set("local.storePictures", on)
            case "metalFX": set("local.metalFX", on)
            case "removeAllFiles":
                guard running == nil else { return L("A job is running; try again when it is done.", "Ein Auftrag läuft; versuche es danach noch einmal.") }
                try? FileManager.default.removeItem(at: Self.home.appendingPathComponent("games"))
            case "metalFXResolution": set("local.metalFXResolution", min(100, max(50, Int(value ?? "") ?? 75)))
            default: break
            }
            republish()
            return nil
        }
        if panel.hasPrefix("job:") {
            let id = String(panel.dropFirst(4))
            return item == "resume" ? await handle(.resume(jobId: id)) : item == "cancel" ? await handle(.cancel(jobId: id)) : nil
        }
        if panel.hasPrefix("game:"), let appId = appId(ofGame: String(panel.dropFirst(5))) {
            switch item {
            case "favourite": toggleFavourite(appId, on)
            case "removeFiles": return removeFiles(appId)
            case _ where item.hasPrefix("locale:"):
                let locale = String(item.dropFirst(7))
                changeOptions(appId) { $0.locales = on ? Array(Set($0.locales + [locale])).sorted() : $0.locales.filter { $0 != locale } }
            case _ where item.hasPrefix("extra:"):
                let name = String(item.dropFirst(6))
                changeOptions(appId) { $0.optionalNames = on ? Array(Set($0.optionalNames + [name])).sorted() : $0.optionalNames.filter { $0 != name } }
            case "addons": changeOptions(appId) { $0.addons = on }
            case "coreMods": changeOptions(appId) { $0.coreMods = on }
            case "syncAddons": return enqueue("store-\(appId)", kind: .addons)
            case "syncExtras": return enqueue("store-\(appId)", kind: .content)
            default: break
            }
            republish()
        }
        return nil
    }

    private func gameSections(_ appId: String) -> [RemoteSection] {
        let info = gameInfo(appId)
        var sections: [RemoteSection] = [
            Section(id: "mine", title: nil, items: [Item(id: "favourite", kind: .toggle, title: L("Favourite", "Favorit"), on: info.favourite)]),
        ]
        if let entry = info.entry, info.trust == .untested || info.trust == .incompatible, entry.works + entry.problems + entry.fails > 0 {
            let title = info.trust == .incompatible ? L("Reported not to work", "Als nicht lauffähig gemeldet") : L("Users report that it works", "Nutzer melden, dass es läuft")
            sections.append(Section(id: "untested", title: title, items: [
                Item(id: "reports", kind: .text, title: "",
                     detail: L("Reports from users: \(entry.works) say it works, \(entry.problems) report problems, \(entry.fails) say it does not start.",
                               "Meldungen von Nutzern: \(entry.works) melden, dass es läuft, \(entry.problems) melden Probleme, \(entry.fails) melden, dass es nicht startet.")),
            ]))
        }
        // Wählbare Inhalte: dieselben Schalter und Wörter wie am Mac.
        if let recipe = recipes[appId] {
            let optional = recipe.files.filter { !$0.required && $0.source == nil && $0.dest != nil }
            let languages = Set(optional.compactMap(\.locale)).sorted()
            let extras = optional.filter { $0.locale == nil && $0.title != nil }
            let hasAddons = recipe.addons?.dest != nil
            if !languages.isEmpty || !extras.isEmpty || hasAddons {
                let chosen = options(appId)
                let isInstalled = installed[appId] != nil
                let blocker = activeJob(appId) != nil ? L("A job for this game is already running.", "Für dieses Spiel läuft schon ein Auftrag.")
                    : installed[appId].flatMap { contentBlocker($0, recipe) } != nil ? installed[appId].flatMap { contentBlocker($0, recipe) }
                    : !hasMetaToken ? L("The Meta sign-in is missing (see “Setup”).", "Die Meta-Anmeldung fehlt (siehe „Einrichtung“).") : setupProblem
                func size(_ bytes: Int64?) -> String { bytes.map { String(format: " · %.2f GB", Double($0) / 1e9) } ?? "" }
                var items: [RemoteItem] = []
                for locale in languages {
                    let sizes = optional.filter { $0.locale == locale }.map(\.size)
                    let bytes = sizes.contains(where: { $0 == nil }) ? nil : sizes.compactMap { $0 }.reduce(0, +)
                    items.append(Item(id: "locale:\(locale)", kind: .toggle,
                                      title: (Locale.current.localizedString(forIdentifier: locale) ?? locale) + size(bytes),
                                      on: chosen.locales.contains(locale)))
                }
                for file in extras {
                    items.append(Item(id: "extra:\(file.name)", kind: .toggle, title: (file.title?.text ?? file.name) + size(file.size),
                                      on: chosen.optionalNames.contains(file.name)))
                }
                if !languages.isEmpty || !extras.isEmpty, isInstalled {
                    items.append(Item(id: "syncExtras", kind: .action, title: L("Bring the Vision Pro up to Date", "Vision Pro auf den Stand bringen"),
                                      detail: blocker ?? L("Downloads what is chosen and still missing and adds it to the game – without building the game again.",
                                                           "Lädt, was gewählt ist und noch fehlt, und legt es zum Spiel – ohne das Spiel neu zu bauen."),
                                      enabled: blocker == nil))
                }
                if hasAddons {
                    items.append(Item(id: "addons", kind: .toggle, title: L("Add-on content you have purchased", "Zusatzinhalte, die du gekauft hast"),
                                      detail: L("Only what Meta confirms as purchased is downloaded and unlocked.",
                                                "Geladen und freigeschaltet wird nur, was Meta als gekauft bestätigt.")
                                        + (chosen.skus.map { L(" Last confirmed: \($0.count) purchases.", " Zuletzt bestätigt: \($0.count) Käufe.") } ?? ""),
                                      on: chosen.addons))
                    if isInstalled {
                        items.append(Item(id: "syncAddons", kind: .action, title: L("Sync DLCs", "DLCs abgleichen"),
                                          detail: blocker ?? L("Asks Meta again what you have purchased, downloads what is missing and adds it – without building the game again.",
                                                               "Fragt Meta neu, was du gekauft hast, lädt das Fehlende und legt es dazu – ohne das Spiel neu zu bauen."),
                                          enabled: blocker == nil))
                    }
                }
                sections.append(Section(id: "content", title: L("Optional Content", "Wählbare Inhalte"),
                                        footer: languages.isEmpty ? nil : L("Languages – each one is an extra download.", "Sprachen – jede ist ein zusätzlicher Download."),
                                        items: items))
            }
        }
        // Mods: der Schalter des Macs, mit seinen Worten.
        if let recipe = recipes[appId], let mods, recipe.toolchain.target == mods.target {
            let profile = modsProfile(appId)
            var items = [Item(id: "coreMods", kind: .toggle, title: L("Build with mods", "Mit Mods bauen"),
                              detail: L("Brings SongCore, BetterSongSearch and SongDownloader into the game: you search and download songs from BeatSaver in the game. Off: the game as before. Switching is an update of the same app; saves stay.",
                                        "Bringt SongCore, BetterSongSearch und SongDownloader ins Spiel: Songs suchst und lädst du im Spiel von BeatSaver. Aus: das Spiel wie bisher. Umschalten ist ein Update derselben App; Spielstände bleiben."),
                              on: buildsWithMods(appId), enabled: profile != nil)]
            if profile == nil {
                items.append(Item(id: "coreModsVersion", kind: .text, title: "",
                                  detail: L("The mods exist for version \(mods.versionName) of the game only.", "Die Mods gibt es nur für die Fassung \(mods.versionName) des Spiels.")))
            } else if let app = installed[appId], app.coreMods != buildsWithMods(appId) {
                items.append(Item(id: "coreModsPending", kind: .text, title: "",
                                  detail: app.coreMods ? L("The installed game has the mods. Install it again to take them out.", "Das installierte Spiel hat die Mods. Installiere es neu, um sie herauszunehmen.")
                                    : L("The installed game has no mods yet. Install it again to bring them in.", "Das installierte Spiel hat die Mods noch nicht. Installiere es neu, um sie hineinzubringen.")))
            }
            sections.append(Section(id: "mods", title: L("Mods (custom songs)", "Mods (eigene Songs)"), items: items))
        }
        var here: [RemoteItem] = [
            Item(id: "files", kind: .fact, title: L("Files", "Dateien"),
                 value: info.downloaded ? L("present (\(info.size))", "vorhanden (\(info.size))")
                    : info.hasToken ? L("are downloaded from Meta when installing", "werden beim Installieren von Meta geladen") : L("not here", "nicht hier")),
        ]
        if info.downloaded {
            here.append(Item(id: "removeFiles", kind: .action, title: L("Remove Files", "Dateien entfernen"), style: .destructive,
                             confirm: L("Remove the downloaded files of this game from this headset? The installed game stays.",
                                        "Die geladenen Dateien dieses Spiels von dieser Brille entfernen? Das installierte Spiel bleibt.")))
        }
        sections.append(Section(id: "mac", title: L("On This Headset", "Auf dieser Brille"),
                                footer: L("Downloaded files are removed here once the game is installed: the game has its own copy, and an update that only rebuilds the game takes it from there.",
                                          "Geladene Dateien werden hier entfernt, sobald das Spiel installiert ist: Das Spiel hat seine eigene Kopie, und ein Update, das das Spiel nur neu baut, nimmt sie von dort."),
                                items: here))
        sections.append(Section(id: "device", title: L("On the Vision Pro", "Auf der Vision Pro"),
                                items: [Item(id: "device", kind: .text, title: "", detail: info.deviceText)]))
        var know: [RemoteItem] = [
            Item(id: "owned", kind: .fact, title: L("Ownership", "Besitz"), value: L("In your Meta account", "In deinem Meta-Konto")),
            Item(id: "store", kind: .link, title: L("Open in the Meta Store", "Im Meta-Store öffnen"), value: "https://www.meta.com/experiences/\(appId)/", shareable: true),
            Item(id: "playability", kind: .text, title: "", detail: info.playability),
        ]
        if let note = info.note { know.append(Item(id: "note-0", kind: .text, title: "", detail: "• " + note)) }
        sections.append(Section(id: "know", title: L("Good to Know", "Gut zu wissen"), items: know))
        return sections
    }

    private func jobSections(_ job: Job) -> [RemoteSection] {
        let phase: String = switch job.state {
        case .running: L("Running", "Läuft")
        case .queued: L("Waiting", "Wartet")
        case .finished: L("Finished", "Abgeschlossen")
        case .cancelled: L("Cancelled", "Abgebrochen")
        case .stopped: L("Stopped", "Angehalten")
        case .interrupted: L("Interrupted", "Unterbrochen")
        }
        var head: [RemoteItem] = [
            Item(id: "phase", kind: .fact, title: L("State", "Stand"), value: phase),
            Item(id: "created", kind: .fact, title: L("Created", "Angelegt"), value: DateFormatter.localizedString(from: job.created, dateStyle: .medium, timeStyle: .short)),
        ]
        if job.state == .stopped || job.state == .interrupted {
            head.append(Item(id: "resume", kind: .action, title: L("Resume", "Fortsetzen"), style: .prominent))
        }
        if job.state != .finished, job.state != .cancelled {
            head.append(Item(id: "cancel", kind: .action, title: L("Cancel Job", "Auftrag abbrechen"), style: .destructive,
                             confirm: job.state == .running
                                ? L("Cancel this job? The current step finishes first; downloaded files and everything on the Vision Pro stay.",
                                    "Diesen Auftrag abbrechen? Der laufende Schritt wird noch beendet; geladene Dateien und alles auf der Vision Pro bleiben.")
                                : L("Cancel this job? Downloaded files and everything on the Vision Pro stay.",
                                    "Diesen Auftrag abbrechen? Geladene Dateien und alles auf der Vision Pro bleiben.")))
        }
        var sections = [Section(id: "head", title: nil, items: head)]
        if job.state == .stopped, let failure = job.failure {
            sections.append(Section(id: "failure", title: L("What Went Wrong", "Woran es lag"),
                                    items: [Item(id: "failure", kind: .text, title: "", detail: failure, style: .warning)]))
        } else if job.state == .interrupted {
            sections.append(Section(id: "failure", title: nil, items: [
                Item(id: "interrupted", kind: .text, title: "",
                     detail: L("The app was closed while this job was running. Resume continues where it stopped; files that are here are not downloaded again.",
                               "Die App wurde beendet, während dieser Auftrag lief. „Fortsetzen“ macht dort weiter; Dateien, die schon hier liegen, werden nicht noch einmal geladen.")),
            ]))
        }
        let shown = jobProgressText(job)
        sections.append(Section(id: "steps", title: L("Steps", "Schritte"), items: job.steps.enumerated().map { index, step in
            let state = index < job.done ? "ok" : index == job.done && job.state == .running ? "checking"
                : index == job.done && job.state == .stopped ? "warning" : "missing"
            return Item(id: "step:\(step.rawValue)", kind: .check, title: step.title, detail: state == "checking" ? shown : nil, state: state)
        }))
        let lines = job.log.suffix(200)
        sections.append(Section(id: "log", title: L("Log", "Verlauf"),
                                footer: job.log.count > 200 ? L("The last 200 of \(job.log.count) lines.", "Die letzten 200 von \(job.log.count) Zeilen.") : nil,
                                items: [Item(id: "log", kind: .log, title: "", detail: lines.joined(separator: "\n"))]))
        return sections
    }

    private func setupSections() -> [RemoteSection] {
        let facts = setupFacts()
        func check(_ id: String, _ title: String, _ ok: Bool, _ yes: String, _ no: String) -> RemoteSection {
            Section(id: id, title: nil, items: [Item(id: id, kind: .check, title: title, detail: ok ? yes : no, state: ok ? "ok" : "missing")])
        }
        let handedOver = L("AVP Play on your Mac hands it over when it installs AVP Play Remote.",
                           "AVP Play auf deinem Mac übergibt es, wenn es AVP Play Remote installiert.")
        return [
            Section(id: "refresh", title: nil, items: [
                facts.refreshing ? Item(id: "refreshing", kind: .progress, title: L("Checking …", "Wird geprüft …"))
                    : Item(id: "refresh", kind: .action, title: L("Check Again", "Neu prüfen"),
                           detail: L("Reads the handover again and looks at what is installed on this headset.",
                                     "Liest die Übergabe neu ein und sieht nach, was auf dieser Brille installiert ist.")),
            ]),
            check("device", "Vision Pro", facts.pairing,
                  L("\(facts.device) is paired with itself: games are installed through its own installation service.",
                    "\(facts.device) ist mit sich selbst gekoppelt: Spiele werden über ihren eigenen Installationsdienst installiert."),
                  L("The pairing with this headset is missing. ", "Die Kopplung mit dieser Brille fehlt. ") + handedOver),
            check("team", L("Apple Developer Team", "Apple-Entwicklerteam"), facts.appleKey,
                  L("The team key is here: this headset gets certificates and profiles from Apple itself.",
                    "Der Team-Schlüssel ist da: Diese Brille holt Zertifikate und Profile selbst bei Apple."),
                  L("The team key for the Apple developer account is missing. Enter it above.", "Der Team-Schlüssel für das Apple-Entwicklerkonto fehlt. Trage ihn oben ein.")),
            check("meta", L("Meta Account (for Meta Store games)", "Meta-Konto (für Spiele aus dem Meta-Store)"), facts.meta,
                  L("Signed in; \(facts.library) games in the library.", "Angemeldet; \(facts.library) Spiele in der Bibliothek."),
                  L("Not signed in. Without it, only games whose files your Mac handed over can be installed. ",
                    "Nicht angemeldet. Ohne sie lassen sich nur Spiele installieren, deren Dateien der Mac mitgegeben hat. ") + handedOver),
            check("toolchain", "Toolchain", facts.toolchain != nil,
                  L("Version \(facts.toolchain ?? 0) is here.", "Fassung \(facts.toolchain ?? 0) ist da."),
                  L("Not here yet. The toolchain translates the games for the Vision Pro. ", "Noch nicht da. Die Toolchain übersetzt die Spiele für die Vision Pro. ") + handedOver),
            check("recipes", L("Game Recipes", "Rezepte der Spiele"), !recipes.isEmpty,
                  L("\(recipes.count) recipes from AVP Play are here: they name each game's files, languages and add-on content.",
                    "\(recipes.count) Rezepte von AVP Play sind da: Sie nennen für jedes Spiel die Dateien, Sprachen und Zusatzinhalte."),
                  L("Not here yet. Without them every game is installed in the newest version Meta offers, without languages to choose and without add-on content. ",
                    "Noch nicht da. Ohne sie wird jedes Spiel in der neuesten Fassung installiert, die Meta anbietet – ohne wählbare Sprachen und ohne Zusatzinhalte. ") + handedOver),
        ]
    }

    private func settingsSections() -> [RemoteSection] {
        let values = settingsValues()
        var experimental: [RemoteItem] = [
            Item(id: "metalFX", kind: .toggle, title: L("MetalFX: switch on upscaling automatically when installing", "MetalFX: Hochskalieren beim Installieren automatisch einschalten"),
                 on: values.metalFX),
        ]
        if values.metalFX {
            experimental.append(Item(id: "metalFXResolution", kind: .choice, title: L("Resolution", "Auflösung"), value: "\(values.resolution)",
                                     choices: stride(from: 50, through: 100, by: 5).map { RemoteChoice(id: "\($0)", title: "\($0) %") }))
        }
        let languages: [(String, String)] = [
            ("en", "English"), ("en_GB", "English (UK)"), ("de_DE", "Deutsch"), ("fr_FR", "Français"), ("es_ES", "Español"),
            ("es_MX", "Español (Latinoamérica)"), ("it_IT", "Italiano"), ("pt_BR", "Português (Brasil)"), ("pt_PT", "Português (Portugal)"),
            ("nl_NL", "Nederlands"), ("pl_PL", "Polski"), ("sv_SE", "Svenska"), ("da_DK", "Dansk"), ("nb_NO", "Norsk"), ("fi_FI", "Suomi"),
            ("cs_CZ", "Čeština"), ("tr_TR", "Türkçe"), ("ru_RU", "Русский"), ("uk_UA", "Українська"), ("ja_JP", "日本語"), ("ko_KR", "한국어"),
            ("zh_CN", "简体中文"), ("zh_TW", "繁體中文"),
        ]
        return [
            Section(id: "app", title: "AVP Play Remote", items: [Item(id: "version", kind: .fact, title: L("Version", "Version"), value: values.version)]),
            Section(id: "play", title: L("Play area", "Spielbereich"), items: [
                Item(id: "roomMeasuring", kind: .toggle, title: L("Measure room in the games that are installed", "„Raum vermessen“ in den Spielen, die installiert werden"),
                     on: values.roomMeasuring),
            ]),
            Section(id: "gameLanguage", title: L("Game language", "Spielsprache"), items: [
                Item(id: "gameLanguage", kind: .choice, title: L("Language games start with", "Sprache, mit der Spiele starten"), value: values.gameLanguage,
                     choices: [RemoteChoice(id: "", title: L("As each game has it", "Wie jedes Spiel sie hat")),
                               RemoteChoice(id: "device", title: L("Like the Vision Pro", "Wie die Vision Pro"))]
                        + languages.map { RemoteChoice(id: $0.0, title: $0.1) }),
            ]),
            Section(id: "catalog", title: L("Online catalogue", "Online-Katalog"), items: [
                Item(id: "onlineCatalog", kind: .toggle, title: L("Load ratings and notes from the AVP Play catalogue", "Einstufungen und Hinweise aus dem Katalog von AVP Play laden"),
                     on: values.onlineCatalog),
            ]),
            Section(id: "pictures", title: L("Pictures", "Bilder"), items: [
                Item(id: "storePictures", kind: .toggle, title: L("Show cover pictures from the store", "Titelbilder aus dem Store zeigen"), on: values.storePictures),
            ]),
            Section(id: "storage", title: L("Game files on this headset", "Spieldateien auf dieser Brille"),
                    footer: L("Downloaded files (APK, OBB) are only needed to build a game and are removed once it is installed. What lies here belongs to games that were only downloaded, or to a job that did not finish; a new try continues with it.",
                              "Geladene Dateien (APK, OBB) braucht es nur, um ein Spiel zu bauen; nach der Installation werden sie entfernt. Was hier liegt, gehört zu Spielen, die nur geladen wurden, oder zu einem Auftrag, der nicht fertig wurde; ein neuer Versuch macht damit weiter."),
                    items: [
                        Item(id: "storageUsed", kind: .fact, title: L("Used by downloaded files", "Von geladenen Dateien belegt"), value: values.storage),
                    ] + (values.storageBytes > 0 ? [
                        Item(id: "removeAllFiles", kind: .action, title: L("Remove All Downloaded Files", "Alle geladenen Dateien entfernen"), style: .destructive,
                             confirm: L("Remove the downloaded files of all games from this headset (\(values.storage))? Installed games stay as they are.",
                                        "Die geladenen Dateien aller Spiele von dieser Brille entfernen (\(values.storage))? Installierte Spiele bleiben, wie sie sind.")),
                    ] : [])),
            Section(id: "experimental", title: L("Experimental", "Experimentell"), items: experimental),
            Section(id: "more", title: nil,
                    footer: L("The settings apply to games installed on this headset from now on. The app identifier prefix and the sign-ins come from your Mac.",
                              "Die Einstellungen gelten für Spiele, die ab jetzt auf dieser Brille installiert werden. Der Präfix für App-Kennungen und die Anmeldungen kommen von deinem Mac."),
                    items: []),
        ]
    }
}

// MARK: - Was die Seiten dafür wissen müssen

extension LocalBackend {
    struct GameInfo {
        var favourite: Bool
        var entry: CatalogEntry?
        var trust: RemoteGame.Trust
        var downloaded: Bool
        var size: String
        var hasToken: Bool
        var deviceText: String
        var playability: String
        var note: String?
    }

    private func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    private func appId(ofGame gameId: String) -> String? { appId(of: gameId) }
    private func set(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    private func republish() { publishNow() }
    private func reloadCatalog() async { await loadCatalog() }

    private func changeOptions(_ appId: String, _ body: (inout GameOptions) -> Void) {
        var next = options(appId)
        body(&next)
        setOptions(next, appId)
    }

    private func toggleFavourite(_ appId: String, _ on: Bool) {
        var all = favourites
        if on { all.insert(appId) } else { all.remove(appId) }
        favourites = all
    }

    private func removeFiles(_ appId: String) -> String? {
        if activeJob(appId) != nil { return L("A job for this game is running.", "Für dieses Spiel läuft ein Auftrag.") }
        try? FileManager.default.removeItem(at: folder(appId))
        publishNow()
        return nil
    }

    private func jobProgressText(_ job: Job) -> String? {
        let shown = bars[job.id] ?? []
        return (shown.first { $0.value != nil && $0.title == nil } ?? shown.first)?.text
    }

    private func gameInfo(_ appId: String) -> GameInfo {
        let entry = catalog[appId]
        let trust: RemoteGame.Trust = switch entry?.status {
        case "verified": .verified
        case "community": .community
        case "incompatible": .incompatible
        default: .untested
        }
        // Die vier Sätze sind die von AVP Play (playabilityText).
        let playability: String = switch trust {
        case .verified: L("Verified: the project has tested this game on an Apple Vision Pro.", "Geprüft: Das Projekt hat dieses Spiel auf einer Apple Vision Pro getestet.")
        case .community: L("Community Verified: more users report that it runs than that it does not. The project has not tested it.",
                           "Von Nutzern bestätigt: Mehr Nutzer melden, dass es läuft, als dass es nicht läuft. Das Projekt hat es nicht getestet.")
        case .incompatible: L("Incompatible: more users report that it does not run than that it does.", "Inkompatibel: Mehr Nutzer melden, dass es nicht läuft, als dass es läuft.")
        case .untested: L("Untested: nobody has confirmed yet that this game runs. You can try it.", "Ungetestet: Noch hat niemand bestätigt, dass dieses Spiel läuft. Du kannst es versuchen.")
        }
        let deviceText: String
        if let app = installed[appId] {
            let built = app.toolchain.map { "Toolchain \($0)" } ?? "?"
            let pinned = recipes[appId].flatMap { $0.versionCode != app.versionCode ? $0 : nil }
            deviceText = onDevice(appId) == .update
                ? pinned.map { L("Version \(app.version) is installed, built with \(built). AVP Play installs version \($0.versionName): its files, languages and add-on content are known for that one.",
                                 "Fassung \(app.version) ist installiert, gebaut mit \(built). AVP Play installiert Fassung \($0.versionName): Für sie sind Dateien, Sprachen und Zusatzinhalte bekannt.") }
                ?? L("Version \(app.version) is installed, built with \(built). A newer build is possible.", "Fassung \(app.version) ist installiert, gebaut mit \(built). Ein neuerer Bau ist möglich.")
                : L("Version \(app.version) is installed, built with \(built).", "Fassung \(app.version) ist installiert, gebaut mit \(built).")
        } else if installedChecked {
            deviceText = L("Not installed.", "Nicht installiert.")
        } else {
            deviceText = L("Not checked yet: “Check Again” under Setup looks at what is installed.", "Noch nicht geprüft: „Neu prüfen“ unter Einrichtung sieht nach, was installiert ist.")
        }
        let note = (L("en", "de") == "de" ? entry?.noteDe ?? entry?.noteEn : entry?.noteEn ?? entry?.noteDe).flatMap { $0.isEmpty ? nil : $0 }
        let bytes = Self.bytes(of: folder(appId))
        return GameInfo(favourite: favourites.contains(appId), entry: entry, trust: trust,
                        downloaded: Self.files(of: folder(appId)).contains { $0.kind == "APK" },
                        size: String(format: "%.2f GB", Double(bytes) / 1_073_741_824), hasToken: hasMetaToken, deviceText: deviceText,
                        playability: playability, note: note)
    }

    private func setupFacts() -> (refreshing: Bool, pairing: Bool, appleKey: Bool, meta: Bool, library: Int, toolchain: Int?, device: String) {
        (refreshing, hasPairing, hasAppleKey, hasMetaToken, library.count, templateVersion, UIDevice.current.name)
    }

    private func settingsValues() -> (version: String, roomMeasuring: Bool, gameLanguage: String, onlineCatalog: Bool, storePictures: Bool, metalFX: Bool,
                                       resolution: Int, storage: String, storageBytes: Int64) {
        // Alles unter „games“, auch halb geladene Dateien.
        var bytes: Int64 = 0
        let root = Self.home.appendingPathComponent("games")
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker { bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", roomMeasuring, gameLanguage, onlineCatalog,
                storePictures, metalFX, metalFXResolution, String(format: "%.2f GB", Double(bytes) / 1_073_741_824), bytes)
    }
}
