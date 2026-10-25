import Foundation

/// Der Demo-Modus: ein erfundener Mac mit erfundenen Spielen und eigenen Titelbildern – zum Ausprobieren ohne Mac,
/// für Apples Prüfer und für die Screenshots im Store. Nichts davon kommt von einem Mac oder geht an einen.
enum Demo {
    static let mac = KnownMac(serverId: "demo", name: L("Demo Mac", "Demo-Mac"), host: nil, port: nil, lastConnected: Date())
    static let server = RemoteServerInfo(serverId: "demo", name: L("Demo Mac", "Demo-Mac"), appVersion: "1.5.0")
    static let runningJob = "demo-starfall-job"

    private static func game(_ id: String, _ title: String, trust: RemoteGame.Trust, on onDevice: RemoteGame.OnDevice, downloaded: Bool = true,
                             favourite: Bool = false, mixedReality: Bool = false, handTracking: Bool = false, busy: Bool = false,
                             blocker: String? = nil, bytes: Int64 = 0, works: Int = 0, source: String = "meta") -> RemoteGame {
        var game = RemoteGame(id: id, title: title, trust: trust, onDevice: onDevice, downloaded: downloaded, owned: true, source: source,
                              busy: busy, installBlocker: busy ? nil : blocker, canDownload: !downloaded, downloadBlocker: nil,
                              downloadSize: downloaded ? nil : "2.4 GB", storeBytes: bytes, mixedReality: mixedReality,
                              handTracking: handTracking, favourite: favourite, coverKey: "demo-\(id)",
                              builtWith: onDevice == .current || onDevice == .update ? "Toolchain 812" : nil)
        game.ownedAnywhere = true
        game.fromMeta = source == "meta"
        game.fromSteam = source == "steam"
        game.works = works
        return game
    }

    static var games: [RemoteGame] {
        [
            game("starfall", "Starfall Rangers", trust: .verified, on: .notInstalled, downloaded: false, favourite: true, busy: true, works: 41),
            game("neonrhythm", "Neon Rhythm", trust: .verified, on: .update, favourite: true, handTracking: true, bytes: 3_800_000_000, works: 128),
            game("harbor", "Harbor Lights", trust: .verified, on: .current, mixedReality: true, bytes: 1_200_000_000, works: 77),
            game("gravitygarden", "Gravity Garden", trust: .community, on: .current, mixedReality: true, handTracking: true, bytes: 900_000_000, works: 23),
            game("deepreef", "Deep Reef Explorer", trust: .verified, on: .current, favourite: true, bytes: 5_600_000_000, works: 64),
            game("skycourier", "Sky Courier", trust: .verified, on: .update, bytes: 2_100_000_000, works: 39),
            game("pocketkingdoms", "Pocket Kingdoms", trust: .community, on: .notInstalled, bytes: 1_700_000_000, works: 12, source: "steam"),
            game("mountaingolf", "Mountain Golf Club", trust: .verified, on: .current, favourite: true, bytes: 3_100_000_000, works: 95),
            game("echoracers", "Echo Racers", trust: .verified, on: .notInstalled, downloaded: false, works: 52),
            game("lanternwoods", "Lantern Woods", trust: .untested, on: .notInstalled, downloaded: false),
            game("orbitchef", "Orbit Chef", trust: .community, on: .current, handTracking: true, bytes: 800_000_000, works: 18),
            game("pixelpaddle", "Pixel Paddle", trust: .untested, on: .notInstalled, downloaded: false),
        ]
    }

    static let filters = [RemoteFilter(id: "demo-guests", name: L("For Guests", "Für Gäste"), games: ["harbor", "mountaingolf", "pixelpaddle"])]

    static var status: RemoteStatus {
        let now = Date()
        func job(_ id: String, _ gameId: String, _ title: String, _ state: RemoteJob.State, ago: TimeInterval) -> RemoteJob {
            RemoteJob(id: id, gameId: gameId, title: title, state: state, kind: .install, step: nil, stepIndex: 5, stepCount: 5,
                      progress: nil, progressText: nil, failure: nil, lastLine: nil, updated: now.addingTimeInterval(-ago),
                      canResume: false, canCancel: false)
        }
        var running = RemoteJob(id: runningJob, gameId: "starfall", title: "Starfall Rangers", state: .running, kind: .install,
                                step: L("Download files", "Dateien laden"), stepIndex: 2, stepCount: 5, progress: 0.62,
                                progressText: L("2.9 GB of 4.7 GB downloaded", "2,9 GB von 4,7 GB geladen"), failure: nil,
                                lastLine: L("Downloading starfall-main.obb …", "Lade starfall-main.obb …"), updated: now, canResume: false, canCancel: true)
        running.bars = [
            RemoteProgress(value: 0.62, text: L("2.9 GB of 4.7 GB downloaded · about 4 minutes left", "2,9 GB von 4,7 GB geladen · noch etwa 4 Minuten")),
            RemoteProgress(title: L("File 2 of 3", "Datei 2 von 3") + " · starfall-main.obb", value: 1.0 / 3.0, text: nil),
            RemoteProgress(value: 0.71, text: L("2,410 MB of 3,390 MB", "2.410 MB von 3.390 MB")),
        ]
        var waiting = job("demo-sky-job", "skycourier", "Sky Courier", .queued, ago: 30)
        waiting.canCancel = true
        return RemoteStatus(deviceName: "Apple Vision Pro", deviceVia: "wifi", deviceProblem: nil, setupProblem: nil, refreshing: false,
                            updatable: ["neonrhythm", "skycourier"],
                            jobs: [running, waiting,
                                   job("demo-golf-job", "mountaingolf", "Mountain Golf Club", .finished, ago: 3_600),
                                   job("demo-harbor-job", "harbor", "Harbor Lights", .finished, ago: 86_000)],
                            notice: nil,
                            clearable: [RemoteChoice(id: "finished", title: L("Finished Jobs (2)", "Abgeschlossene Aufträge (2)"))])
    }

    // MARK: Seiten

    static func panel(_ id: String, games: [RemoteGame]) -> RemotePanel? {
        if id == "setup" { return RemotePanel(id: id, sections: setup) }
        if id == "settings" { return RemotePanel(id: id, sections: settings) }
        if id.hasPrefix("job:") { return RemotePanel(id: id, sections: job(String(id.dropFirst(4)))) }
        if id.hasPrefix("game:"), let game = games.first(where: { $0.id == id.dropFirst(5) }) {
            return RemotePanel(id: id, sections: gameSections(game))
        }
        return nil
    }

    private static func gameSections(_ game: RemoteGame) -> [RemoteSection] {
        [
            RemoteSection(id: "mine", title: L("Favourite and filters", "Favorit und Filter"), items: [
                RemoteItem(id: "favourite", kind: .toggle, title: L("Favourite", "Favorit"), on: game.favourite),
                RemoteItem(id: "filter:demo-guests", kind: .toggle, title: L("For Guests", "Für Gäste"), on: filters[0].games.contains(game.id)),
            ]),
            RemoteSection(id: "device", title: L("On the Vision Pro", "Auf der Vision Pro"), items: [
                RemoteItem(id: "device", kind: .text, title: "",
                           detail: game.onDevice == .update ? L("Installed. The current toolchain produces a newer build – “Update” builds it; saved games and data are kept.",
                                                               "Installiert. Mit der jetzigen Toolchain gibt es eine neuere Fassung – „Aktualisieren“ baut sie; Spielstände und Daten bleiben.")
                                : game.installed ? L("Installed and up to date.", "Installiert und auf dem neuesten Stand.") : L("Not installed yet.", "Noch nicht installiert.")),
            ]),
            RemoteSection(id: "toolchain", title: "Toolchain", items: [
                RemoteItem(id: "summary", kind: .text, title: "", detail: L("This game is built with the newest toolchain (812).", "Dieses Spiel wird mit der neuesten Toolchain gebaut (812).")),
                RemoteItem(id: "toolchain", kind: .choice, title: L("Build with", "Bauen mit"), value: "newest", choices: [
                    RemoteChoice(id: "newest", title: L("Always the newest (now 812) – recommended", "Immer die neueste (jetzt 812) – empfohlen")),
                    RemoteChoice(id: "798", title: L("Version 798", "Version 798"), section: L("On the Mac", "Auf dem Mac")),
                ]),
            ]),
            RemoteSection(id: "saves", title: L("Saved Games", "Spielstände"), items: [
                RemoteItem(id: "saves", kind: .text, title: "", detail: L("On the Mac: 3 files (2.1 MB), fetched yesterday.", "Auf dem Mac: 3 Dateien (2,1 MB), gestern geholt.")),
                RemoteItem(id: "fetchSaves", kind: .action, title: L("Fetch Now", "Jetzt holen")),
                RemoteItem(id: "restoreOnInstall", kind: .toggle, title: L("When this game is installed and has no saved games on the Vision Pro, put these back",
                                                                          "Wenn dieses Spiel installiert wird und auf der Vision Pro keine Spielstände hat, diese zurückspielen"), on: true),
            ]),
            RemoteSection(id: "content", title: L("Optional Content", "Wählbare Inhalte"), items: [
                RemoteItem(id: "locale:de", kind: .toggle, title: L("German · 0.4 GB", "Deutsch · 0,4 GB"), on: true),
                RemoteItem(id: "addons", kind: .toggle, title: L("Add-on content you have purchased", "Zusatzinhalte, die du gekauft hast"),
                           detail: L("Only what the store confirms as purchased is downloaded and unlocked.", "Geladen und freigeschaltet wird nur, was der Store als gekauft bestätigt."), on: true),
                RemoteItem(id: "syncAddons", kind: .action, title: L("Sync DLCs", "DLCs abgleichen")),
            ]),
            RemoteSection(id: "know", title: L("Good to Know", "Gut zu wissen"), items: [
                RemoteItem(id: "owned", kind: .fact, title: L("Ownership", "Besitz"), value: L("In your account", "In deinem Konto")),
                RemoteItem(id: "playability", kind: .text, title: "",
                           detail: game.trust == .verified ? L("Verified: the project has tested this game on an Apple Vision Pro.", "Geprüft: Das Projekt hat dieses Spiel auf einer Apple Vision Pro getestet.")
                                                           : L("Untested: nobody has confirmed yet that this game runs. You can try it.", "Ungetestet: Noch hat niemand bestätigt, dass dieses Spiel läuft. Du kannst es versuchen.")),
            ]),
        ]
    }

    private static func job(_ id: String) -> [RemoteSection] {
        let running = id == runningJob
        let steps: [(String, String)] = [(L("Check account and ownership", "Konto und Besitz prüfen"), "ok"),
                                         (L("Download files", "Dateien laden"), running ? "checking" : "ok"),
                                         (L("Build and install", "Bauen und installieren"), running ? "missing" : "ok"),
                                         (L("Copy data to the device", "Daten aufs Gerät kopieren"), running ? "missing" : "ok"),
                                         (L("Unlock add-on content", "Zusatzinhalte freischalten"), running ? "missing" : "ok")]
        var head = [RemoteItem(id: "phase", kind: .fact, title: L("State", "Stand"), value: running ? L("Running", "Läuft") : L("Finished", "Abgeschlossen"))]
        if running {
            head.append(RemoteItem(id: "cancel", kind: .action, title: L("Cancel", "Abbrechen"), style: .destructive,
                                   confirm: L("Cancel this job? Downloaded files and everything on the Vision Pro stay.", "Diesen Auftrag abbrechen? Geladene Dateien und alles auf der Vision Pro bleiben.")))
        }
        let log = [
            "[1/5] " + L("Check account and ownership", "Konto und Besitz prüfen"),
            "    " + L("Purchase confirmed.", "Kauf bestätigt."),
            "[2/5] " + L("Download files", "Dateien laden"),
            "    " + L("Files: 3 needed, 0 present, 3 to download.", "Dateien: 3 gebraucht, 0 im Bestand, 3 zu laden."),
            "      " + L("downloaded: starfall.apk (412 MB)", "geladen: starfall.apk (412 MB)"),
        ]
        return [
            RemoteSection(id: "head", title: nil, items: head),
            RemoteSection(id: "steps", title: L("Steps", "Schritte"), items: steps.enumerated().map { i, step in
                RemoteItem(id: "step:\(i)", kind: .check, title: step.0, state: step.1)
            }),
            RemoteSection(id: "log", title: L("Log", "Verlauf"), items: [RemoteItem(id: "log", kind: .log, title: "", detail: log.joined(separator: "\n"))]),
        ]
    }

    private static var setup: [RemoteSection] {
        func check(_ id: String, _ title: String, _ detail: String) -> RemoteSection {
            RemoteSection(id: id, title: nil, items: [RemoteItem(id: id, kind: .check, title: title, detail: detail, state: "ok")])
        }
        return [
            RemoteSection(id: "refresh", title: nil, items: [RemoteItem(id: "refresh", kind: .action, title: L("Check Again", "Neu prüfen"))]),
            check("xcode", "Xcode", L("Xcode with visionOS support.", "Xcode mit visionOS-Unterstützung.")),
            check("device", "Vision Pro", L("Apple Vision Pro is reachable over Wi-Fi.", "Apple Vision Pro ist über WLAN erreichbar.")),
            check("team", L("Apple Developer Team", "Apple-Entwicklerteam"), L("Your team signs the apps.", "Dein Team signiert die Apps.")),
            check("meta", L("Meta Account (for Meta Store games)", "Meta-Konto (für Spiele aus dem Meta-Store)"), L("Signed in.", "Angemeldet.")),
            check("toolchain", "Toolchain", L("Version 812 is installed.", "Version 812 ist installiert.")),
        ]
    }

    private static var settings: [RemoteSection] {
        [
            RemoteSection(id: "controllers", title: L("Controllers", "Controller"), items: [
                RemoteItem(id: "controllerMode", kind: .choice, title: L("Controller Type", "Controllertyp"), value: "standard",
                           choices: [RemoteChoice(id: "standard", title: L("Standard Controllers", "Standard-Controller")), RemoteChoice(id: "surreal", title: "Surreal Touch")]),
            ]),
            RemoteSection(id: "play", title: L("Play area", "Spielbereich"), items: [
                RemoteItem(id: "roomMeasuring", kind: .toggle, title: L("Measure room in the games that are installed", "„Raum vermessen“ in den Spielen, die installiert werden"), on: true),
            ]),
            RemoteSection(id: "gameLanguage", title: L("Game language", "Sprache der Spiele"), items: [
                RemoteItem(id: "gameLanguage", kind: .choice, title: L("Language games start with", "Sprache, mit der Spiele beginnen"), value: "device",
                           choices: [RemoteChoice(id: "", title: L("As each game has it", "Wie im jeweiligen Spiel")), RemoteChoice(id: "device", title: L("Like the Vision Pro", "Wie die Vision Pro"))]),
            ]),
            RemoteSection(id: "saves", title: L("Saved Games", "Spielstände"), items: [
                RemoteItem(id: "syncSaves", kind: .toggle, title: L("Fetch saved games from the Vision Pro to the Mac by itself", "Spielstände von selbst von der Vision Pro auf den Mac holen"), on: true),
            ]),
            RemoteSection(id: "renew", title: L("Renew signatures", "Signaturen erneuern"), items: [
                RemoteItem(id: "renewInBackground", kind: .toggle, title: L("Check in the background and renew games before their signature runs out",
                                                                          "Im Hintergrund prüfen und Spiele erneuern, bevor ihre Signatur abläuft"), on: true),
            ]),
        ]
    }

    /// Ein Schalter oder eine Wahl auf einer Demo-Seite: Nur die Seite ändert sich, sonst nichts.
    static func apply(_ item: String, value: String?, to panel: inout RemotePanel) {
        for s in panel.sections.indices {
            for i in panel.sections[s].items.indices where panel.sections[s].items[i].id == item {
                switch panel.sections[s].items[i].kind {
                case .toggle: panel.sections[s].items[i].on = value == "1"
                case .choice: panel.sections[s].items[i].value = value
                default: break
                }
            }
        }
    }
}
