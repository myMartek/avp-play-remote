import SwiftUI

enum GameFilter: String, CaseIterable, Identifiable {
    /// Was auf der Vision Pro ist, auf dem Mac liegt oder dem Konto gehört.
    case library, installed, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return L("Library", "Bibliothek")
        case .installed: return L("On Vision Pro", "Auf der Vision Pro")
        case .all: return L("All", "Alle")
        }
    }
}

struct GamesScreen: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab
    @AppStorage("gameFilter") private var filter: GameFilter = .library
    @State private var search = ""
    @State private var path: [String] = GamesScreen.startPath

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionGate(section: $section) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        StatusBanner()
                        let list = visible
                        if list.isEmpty {
                            ContentUnavailableView(search.isEmpty ? L("No games here", "Hier sind keine Spiele") : L("Nothing found", "Nichts gefunden"),
                                                   systemImage: "gamecontroller",
                                                   description: Text(search.isEmpty && filter != .all ? L("“All” shows every game AVP Play knows.", "„Alle“ zeigt jedes Spiel, das AVP Play kennt.") : ""))
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
                .navigationDestination(for: String.self) { id in
                    GameDetail(gameId: id)
                }
            }
            .navigationTitle(L("Games", "Spiele"))
            .searchable(text: $search, prompt: L("Search games", "Spiele suchen"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker(L("Show", "Zeigen"), selection: $filter) {
                        ForEach(GameFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) }
            }
        }
    }

    /// Die Spiele nach Filter und Suche: Zu Aktualisierendes zuerst, dann Installiertes, dann nach Prüfstand und Namen.
    var visible: [RemoteGame] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return client.games.filter { game in
            let passes: Bool
            switch filter {
            case .library: passes = game.installed || game.downloaded || game.owned == true || game.busy
            case .installed: passes = game.installed
            case .all: passes = true
            }
            return passes && (words.isEmpty || game.title.lowercased().contains(words))
        }
        .sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    private func rank(_ game: RemoteGame) -> Int {
        if game.busy { return 0 }
        switch game.onDevice {
        case .update: return 1
        case .current: return 2
        default: break
        }
        if game.downloaded { return 3 }
        switch game.trust {
        case .verified: return 4
        case .community: return 5
        case .untested: return 6
        case .incompatible: return 7
        }
    }
}

extension GamesScreen {
    /// `-AVPRemoteGame <Kennung>` öffnet zum Testen gleich die Seite eines Spiels (nur in Debug-Builds).
    static var startPath: [String] {
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: "AVPRemoteGame") { return [id] }
        #endif
        return []
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
