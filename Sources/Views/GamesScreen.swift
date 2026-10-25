import SwiftUI

/// Die Filter der Spieleliste, wie auf dem Mac. Auf dieser Vision Pro gemerkt; der Mac behält seine eigenen.
struct GameFilters: Codable, Equatable {
    var verified = false
    var community = false
    var owned = false
    var horizonGames = false
    var horizonIndie = false
    var meta = false
    var steam = false
    var installed = false
    var downloaded = false
    var favourites = false
    var favouritesMissing = false
    var mixedReality = false
    var handTracking = false
    /// Eigene Filter des Macs: nur diese zeigen (`only`) oder ausblenden (`hide`).
    var custom: [String: String] = [:]

    static let key = "gameFilters"

    static func load() -> GameFilters {
        guard let data = UserDefaults.standard.data(forKey: key) else { return GameFilters() }
        return (try? JSONDecoder().decode(GameFilters.self, from: data)) ?? GameFilters()
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: GameFilters.key) }

    var isEmpty: Bool { self == GameFilters() }

    /// Ob ein Spiel durchkommt – dieselben Regeln wie `AppModel.visible` auf dem Mac: „Geprüft“ und „Von Nutzern
    /// bestätigt“ ergänzen einander, Meta und Steam ebenso, alle anderen engen weiter ein.
    func passes(_ game: RemoteGame, in filters: [RemoteFilter]) -> Bool {
        guard (!verified && !community) || (verified && game.trust == .verified) || (community && game.trust == .community),
              !installed || game.installed,
              !downloaded || (game.downloaded && !game.installed),
              !favourites || game.favourite,
              !favouritesMissing || (game.favourite && !game.downloaded),
              !mixedReality || game.mixedReality,
              !handTracking || game.handTracking,
              !owned || game.ownedAnywhere,
              (!horizonGames && !horizonIndie) || (horizonGames && game.horizonPlus == "games") || (horizonIndie && game.horizonPlus == "indie"),
              (!meta && !steam) || (meta && game.fromMeta) || (steam && game.fromSteam)
        else { return false }
        for filter in filters {
            switch custom[filter.id] {
            case "only": if !filter.games.contains(game.id) { return false }
            case "hide": if filter.games.contains(game.id) { return false }
            default: break
            }
        }
        return true
    }
}

struct GamesScreen: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab
    @State private var filters = GameFilters.load()
    @State private var search = ""
    @State private var path = GamesScreen.startPath

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionGate(section: $section) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StatusBanner()
                        if !activeChips.isEmpty { chips }
                        let list = visible
                        if list.isEmpty {
                            ContentUnavailableView(L("Nothing found", "Nichts gefunden"), systemImage: "gamecontroller",
                                                   description: Text(filters.isEmpty ? "" : L("The filters hide the rest.", "Die Filter blenden den Rest aus.")))
                                .padding(.top, 60)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 24)], spacing: 24) {
                            ForEach(list) { game in
                                NavigationLink(value: game.id) {
                                    GameCard(game: game, job: client.job(for: game))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(32)
                }
                .navigationDestination(for: String.self) { GameDetail(gameId: $0) }
                .navigationDestination(for: JobRoute.self) { JobDetail(jobId: $0.id) }
            }
            .navigationTitle(L("Games", "Spiele"))
            .searchable(text: $search, prompt: L("Search games", "Spiele suchen"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) }
            }
            .onChange(of: filters) { filters.save() }
        }
    }

    // MARK: Filter

    private var filterMenu: some View {
        Menu {
            SwiftUI.Section(L("Tested", "Geprüft")) {
                Toggle(L("Verified", "Geprüft"), isOn: $filters.verified)
                if client.onlineCatalog { Toggle(L("Community Verified", "Von Nutzern bestätigt"), isOn: $filters.community) }
            }
            SwiftUI.Section(L("Purchase", "Kauf")) {
                Toggle(L("Owned", "Im Besitz"), isOn: $filters.owned)
                if client.horizonPlusKnown {
                    Toggle(L("Horizon+ Games", "Horizon+ Spiele"), isOn: $filters.horizonGames)
                    Toggle("Horizon+ Indie", isOn: $filters.horizonIndie)
                }
                Toggle("Meta", isOn: $filters.meta)
                Toggle("Steam", isOn: $filters.steam)
            }
            SwiftUI.Section(L("Where", "Wo")) {
                Toggle(L("Installed", "Installiert"), isOn: $filters.installed)
                Toggle(L("Downloaded, Not Installed", "Geladen, nicht installiert"), isOn: $filters.downloaded)
            }
            SwiftUI.Section(L("Favourites", "Favoriten")) {
                Toggle(L("Favourites", "Favoriten"), isOn: $filters.favourites)
                Toggle(L("Favourites Not Downloaded", "Nicht geladene Favoriten"), isOn: $filters.favouritesMissing)
            }
            SwiftUI.Section(L("Features", "Eigenschaften")) {
                Toggle("Mixed Reality", isOn: $filters.mixedReality)
                Toggle(L("Hand Tracking", "Hand-Tracking"), isOn: $filters.handTracking)
            }
            if !client.filters.isEmpty {
                SwiftUI.Section(L("Your filters", "Eigene Filter")) {
                    ForEach(client.filters) { filter in
                        Picker(filter.name, selection: Binding(get: { filters.custom[filter.id] ?? "off" },
                                                               set: { filters.custom[filter.id] = $0 == "off" ? nil : $0 })) {
                            Text(L("Off", "Aus")).tag("off")
                            Text(L("Only these", "Nur diese")).tag("only")
                            Text(L("Hide these", "Ausblenden")).tag("hide")
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            if !filters.isEmpty {
                Button(L("Clear All Filters", "Alle Filter aufheben"), systemImage: "xmark.circle", role: .destructive) { filters = GameFilters() }
            }
        } label: {
            Label(L("Filter", "Filter"), systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .labelStyle(.titleAndIcon)
        }
    }

    /// Die gesetzten Filter als Kärtchen über der Liste – antippen nimmt einen heraus.
    private var activeChips: [(title: String, clear: () -> Void)] {
        var result: [(String, () -> Void)] = []
        func add(_ on: Bool, _ title: String, _ path: WritableKeyPath<GameFilters, Bool>) {
            if on { result.append((title, { filters[keyPath: path] = false })) }
        }
        add(filters.verified, L("Verified", "Geprüft"), \.verified)
        add(filters.community, L("Community Verified", "Von Nutzern bestätigt"), \.community)
        add(filters.owned, L("Owned", "Im Besitz"), \.owned)
        add(filters.horizonGames, L("Horizon+ Games", "Horizon+ Spiele"), \.horizonGames)
        add(filters.horizonIndie, "Horizon+ Indie", \.horizonIndie)
        add(filters.meta, "Meta", \.meta)
        add(filters.steam, "Steam", \.steam)
        add(filters.installed, L("Installed", "Installiert"), \.installed)
        add(filters.downloaded, L("Downloaded, Not Installed", "Geladen, nicht installiert"), \.downloaded)
        add(filters.favourites, L("Favourites", "Favoriten"), \.favourites)
        add(filters.favouritesMissing, L("Favourites Not Downloaded", "Nicht geladene Favoriten"), \.favouritesMissing)
        add(filters.mixedReality, "Mixed Reality", \.mixedReality)
        add(filters.handTracking, L("Hand Tracking", "Hand-Tracking"), \.handTracking)
        for filter in client.filters {
            switch filters.custom[filter.id] {
            case "only": result.append((L("Only “\(filter.name)”", "Nur „\(filter.name)“"), { filters.custom[filter.id] = nil }))
            case "hide": result.append((L("Without “\(filter.name)”", "Ohne „\(filter.name)“"), { filters.custom[filter.id] = nil }))
            default: break
            }
        }
        return result
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(activeChips.enumerated()), id: \.offset) { _, chip in
                    Button(action: chip.clear) {
                        Label(chip.title, systemImage: "xmark")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    /// Die Spiele nach Filtern und Suche, in der Reihenfolge des Macs: Geprüftes zuerst, dann was Nutzer bestätigen,
    /// das Ungetestete, zuletzt was nicht läuft – jeweils nach der Zahl derer, die sagen, es läuft, dann nach Namen.
    var visible: [RemoteGame] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rank: (RemoteGame) -> Int = { game in
            switch game.trust {
            case .verified: return 0
            case .community: return 1
            case .untested: return 2
            case .incompatible: return 3
            }
        }
        return client.games
            .filter { filters.passes($0, in: client.filters) && (words.isEmpty || $0.title.lowercased().contains(words)) }
            .sorted { a, b in
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if a.works != b.works { return a.works > b.works }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }
}

extension GamesScreen {
    /// `-AVPRemoteGame <Kennung>` öffnet zum Testen gleich die Seite eines Spiels (nur in Debug-Builds).
    static var startPath: NavigationPath {
        var path = NavigationPath()
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "AVPRemoteGame") { path.append(id) }
        if let id = UserDefaults.standard.string(forKey: "AVPRemoteJob") { path.append(JobRoute(id: id)) }
        #endif
        return path
    }
}

struct GameCard: View {
    let game: RemoteGame
    let job: RemoteJob?

    var body: some View {
        let state = GameState(game, job: job)
        VStack(alignment: .leading, spacing: 0) {
            CoverView(game: game)
                .overlay(alignment: .topTrailing) {
                    if game.trust != .untested { TrustBadge(trust: game.trust).padding(10) }
                }
                .overlay(alignment: .topLeading) {
                    if game.favourite {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).padding(8).background(.thinMaterial, in: .circle).padding(10)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let job, job.state == .running, let progress = job.progress {
                        ProgressView(value: progress).tint(.blue).padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(game.title).font(.headline).lineLimit(1)
                Label(state.text, systemImage: state.symbol)
                    .font(.subheadline)
                    .foregroundStyle(state.color)
                    .lineLimit(1)
            }
            .padding(16)
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 24))
        .contentShape(.hoverEffect, .rect(cornerRadius: 24))
        .hoverEffect()
    }
}
