import SwiftUI

/// Die Seite eines Spiels: oben Bild, Stand und die Knöpfe zum Installieren; darunter, was der Mac zu dem Spiel
/// anbietet – Favorit, Filter, Fassung, Toolchain, Spielstände, wählbare Inhalte, Rückmeldung, Store-Seite.
struct GameDetail: View {
    @Environment(RemoteClient.self) private var client
    let gameId: String

    var body: some View {
        if let game = client.game(gameId) {
            Form {
                SwiftUI.Section {
                    header(game)
                }
                .listRowBackground(Color.clear)

                SwiftUI.Section {
                    actions(game)
                }

                if let job = client.job(for: game), job.active || job.state == .stopped || job.state == .interrupted {
                    SwiftUI.Section(L("Job", "Auftrag")) {
                        NavigationLink(value: JobRoute(id: job.id)) { JobRow(job: job) }
                    }
                }

                PanelSections(panelId: "game:\(game.id)")
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(L("This game is no longer in the list", "Dieses Spiel steht nicht mehr in der Liste"), systemImage: "gamecontroller")
        }
    }

    private func header(_ game: RemoteGame) -> some View {
        HStack(alignment: .top, spacing: 32) {
            CoverView(game: game)
                .frame(width: 440)
                .clipShape(.rect(cornerRadius: 28))
            VStack(alignment: .leading, spacing: 14) {
                Text(game.title).font(.extraLargeTitle2).lineLimit(2)
                HStack(spacing: 10) {
                    TrustBadge(trust: game.trust)
                    if game.favourite { Tag(text: L("Favourite", "Favorit"), symbol: "star.fill") }
                    if game.mixedReality { Tag(text: "Mixed Reality", symbol: "visionpro") }
                    if game.handTracking { Tag(text: L("Hand tracking", "Hand-Tracking"), symbol: "hand.raised") }
                }
                let state = GameState(game, job: client.job(for: game))
                Label(state.text, systemImage: state.symbol).font(.title3).foregroundStyle(state.color)
                if let built = game.builtWith, game.installed {
                    Text(L("Built with \(built)", "Gebaut mit \(built)")).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actions(_ game: RemoteGame) -> some View {
        let installKey = "install:\(game.id)", downloadKey = "download:\(game.id)"
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Button {
                    client.perform(.install(gameId: game.id), key: installKey)
                } label: {
                    HStack {
                        if client.busy.contains(installKey) { ProgressView().controlSize(.small) }
                        Label(installTitle(game), systemImage: game.onDevice == .update ? "arrow.down.circle" : "visionpro")
                    }
                    .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(game.installBlocker != nil || game.busy || client.busy.contains(installKey))

                if game.canDownload {
                    Button {
                        client.perform(.download(gameId: game.id), key: downloadKey)
                    } label: {
                        HStack {
                            if client.busy.contains(downloadKey) { ProgressView().controlSize(.small) }
                            Label(L("Download Only", "Nur herunterladen") + (game.downloadSize.map { " · \($0)" } ?? ""), systemImage: "arrow.down.to.line")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(game.downloadBlocker != nil || game.busy || client.busy.contains(downloadKey))
                }
            }
            if let why = game.installBlocker, !game.busy {
                Label(why, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if game.installed {
                Text(L("If the game is open on the Vision Pro, it is closed when the new build is installed. Saved games stay.",
                       "Ist das Spiel auf der Vision Pro offen, wird es beim Installieren des neuen Baus beendet. Spielstände bleiben."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func installTitle(_ game: RemoteGame) -> String {
        switch game.onDevice {
        case .update: return L("Update", "Aktualisieren")
        case .current: return L("Install Again", "Neu installieren")
        default: return L("Install", "Installieren")
        }
    }
}

struct Tag: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.thinMaterial, in: .capsule)
    }
}
