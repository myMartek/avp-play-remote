import SwiftUI

/// Die Seite eines Spiels: Bild, Stand, und was sich damit tun lässt.
struct GameDetail: View {
    @Environment(RemoteClient.self) private var client
    let gameId: String

    var body: some View {
        if let game = client.game(gameId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(alignment: .top, spacing: 32) {
                        CoverView(game: game)
                            .frame(width: 460)
                            .clipShape(.rect(cornerRadius: 28))
                        VStack(alignment: .leading, spacing: 14) {
                            Text(game.title).font(.extraLargeTitle2).lineLimit(2)
                            HStack(spacing: 10) {
                                TrustBadge(trust: game.trust)
                                if game.mixedReality { Tag(text: "Mixed Reality", symbol: "visionpro") }
                                if game.handTracking { Tag(text: L("Hand tracking", "Hand-Tracking"), symbol: "hand.raised") }
                            }
                            let state = GameState(game, job: client.job(for: game))
                            Label(state.text, systemImage: state.symbol).font(.title3).foregroundStyle(state.color)
                            facts(game)
                        }
                    }

                    if let job = client.job(for: game), job.active || job.state == .stopped || job.state == .interrupted {
                        JobCard(job: job)
                    }

                    actions(game)
                }
                .padding(40)
            }
            .navigationTitle(game.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(L("This game is no longer in the list", "Dieses Spiel steht nicht mehr in der Liste"), systemImage: "gamecontroller")
        }
    }

    @ViewBuilder
    private func facts(_ game: RemoteGame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = game.source {
                fact(L("Bought at", "Gekauft bei"), source == "steam" ? "Steam" : "Meta")
            }
            if let owned = game.owned {
                fact(L("Owned", "Im Besitz"), owned ? L("Yes", "Ja") : L("No", "Nein"))
            }
            if let built = game.builtWith, game.installed {
                fact(L("Built with", "Gebaut mit"), built)
            }
            if game.storeBytes > 0 {
                fact(L("On the Mac", "Auf dem Mac"), game.storeBytes.gigabytes)
            }
            if let size = game.downloadSize, game.canDownload {
                fact(L("Still to download", "Noch zu laden"), size)
            }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder
    private func actions(_ game: RemoteGame) -> some View {
        let installKey = "install:\(game.id)", downloadKey = "download:\(game.id)"
        VStack(alignment: .leading, spacing: 16) {
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
                            Label(L("Only Download to the Mac", "Nur auf den Mac laden"), systemImage: "arrow.down.to.line")
                        }
                    }
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
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
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
