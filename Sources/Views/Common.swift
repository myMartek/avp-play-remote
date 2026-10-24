import SwiftUI

/// Zeigt den Inhalt nur bei stehender Verbindung; sonst, wie es um sie steht und was zu tun ist.
struct ConnectionGate<Content: View>: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab
    @ViewBuilder var content: () -> Content

    var body: some View {
        if client.connectedMac != nil {
            content()
        } else {
            VStack(spacing: 24) {
                switch client.state {
                case .connecting(let name):
                    ProgressView()
                    Text(L("Connecting to “\(name)” …", "Verbinde mit „\(name)“ …")).font(.title2)
                case .retrying(let why):
                    ProgressView()
                    Text(why).font(.title3).multilineTextAlignment(.center)
                    Text(L("Trying again by itself.", "Es wird von selbst erneut versucht.")).foregroundStyle(.secondary)
                case .refused(let why):
                    Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 56)).foregroundStyle(.orange)
                    Text(why).font(.title3).multilineTextAlignment(.center)
                case .searching, .connected:
                    if client.localNetworkDenied {
                        LocalNetworkHint()
                    } else if client.known.isEmpty {
                        Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 56)).foregroundStyle(.secondary)
                        Text(L("Pair a Mac", "Einen Mac koppeln")).font(.largeTitle.bold())
                        Text(L("Open AVP Play on your Mac and switch on Settings › Remote control. The Mac then appears here, and you pair it once with the code it shows.",
                               "Öffne AVP Play auf deinem Mac und schalte Einstellungen › Fernbedienung ein. Der Mac erscheint dann hier, und du koppelst ihn einmal mit dem Code, den er zeigt."))
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
                    } else {
                        ProgressView()
                        Text(L("Looking for your Mac …", "Suche deinen Mac …")).font(.title2)
                        Text(L("Is AVP Play open and the remote control switched on?", "Ist AVP Play offen und die Fernbedienung eingeschaltet?")).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 16) {
                    Button(L("Show Macs", "Macs zeigen")) { section = .mac }
                    if !client.known.isEmpty {
                        Button(L("Try Again", "Erneut versuchen")) { client.reconnect() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct LocalNetworkHint: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 56)).foregroundStyle(.orange)
            Text(L("Local network not allowed", "Lokales Netzwerk nicht erlaubt")).font(.title.bold())
            Text(L("AVP Play Remote needs access to the local network to find your Mac. Allow it under Settings › Apps › AVP Play Remote.",
                   "AVP Play Remote braucht Zugriff aufs lokale Netzwerk, um deinen Mac zu finden. Erlaube ihn unter Einstellungen › Apps › AVP Play Remote."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 560)
            Button(L("Open Settings", "Einstellungen öffnen")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }
}

/// Oben in der Spieleliste: was auf dem Mac noch fehlt oder warum die Vision Pro nicht erreichbar ist.
struct StatusBanner: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        if let status = client.status, let text = status.setupProblem ?? status.deviceProblem {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.setupProblem != nil ? L("On the Mac", "Auf dem Mac") : L("Vision Pro", "Vision Pro")).font(.headline)
                    Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }
}

/// In der Leiste jeder Seite: welcher Mac verbunden ist, und der Wechsel zu einem anderen.
struct MacMenu: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab

    var body: some View {
        Menu {
            ForEach(client.known) { mac in
                Button {
                    client.switchTo(mac)
                } label: {
                    if client.connectingMac?.serverId == mac.serverId {
                        Label(mac.name, systemImage: "checkmark")
                    } else {
                        Text(mac.name)
                    }
                }
            }
            Divider()
            Button(L("Pair or Connect Another Mac …", "Anderen Mac koppeln oder verbinden …"), systemImage: "plus") { section = .mac }
            if client.connectedMac != nil {
                Button(L("Check Again on the Mac", "Auf dem Mac neu prüfen"), systemImage: "arrow.clockwise") {
                    client.perform(.refresh, key: "refresh")
                }
            }
        } label: {
            Label(client.connectedMac?.name ?? client.connectingMac?.name ?? L("No Mac", "Kein Mac"),
                  systemImage: client.connectedMac != nil ? "laptopcomputer" : "laptopcomputer.slash")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// Das Titelbild eines Spiels, sonst eine ruhige Fläche mit seinem Namen – wie in AVP Play.
struct CoverView: View {
    @Environment(RemoteClient.self) private var client
    let game: RemoteGame

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image = client.cover(for: game) {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.black.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Text(game.title).font(.title3.bold()).foregroundStyle(.white).multilineTextAlignment(.center).padding(12))
                }
            }
            .clipped()
            .animation(.easeIn(duration: 0.25), value: client.cover(for: game) != nil)
            .task(id: game.coverKey) { client.loadCover(game) }
    }
}

struct TrustBadge: View {
    let trust: RemoteGame.Trust

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.bold())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.85), in: .capsule)
            .foregroundStyle(.white)
    }

    var text: String {
        switch trust {
        case .verified: return L("Verified", "Geprüft")
        case .community: return L("Community", "Von Nutzern bestätigt")
        case .untested: return L("Untested", "Ungetestet")
        case .incompatible: return L("Does not run", "Läuft nicht")
        }
    }
    var symbol: String {
        switch trust {
        case .verified: return "checkmark.seal.fill"
        case .community: return "person.2.fill"
        case .untested: return "questionmark.circle"
        case .incompatible: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch trust {
        case .verified: return .green
        case .community: return .teal
        case .untested: return .gray
        case .incompatible: return .red
        }
    }
}

/// Wie es um ein Spiel steht, in einer Zeile.
struct GameState {
    let text: String
    let symbol: String
    let color: Color

    @MainActor
    init(_ game: RemoteGame, job: RemoteJob?) {
        if let job, job.state == .running {
            text = job.step.map { L("Running: \($0)", "Läuft: \($0)") } ?? L("Running", "Läuft")
            symbol = "arrow.triangle.2.circlepath"; color = .blue
            return
        }
        if let job, job.state == .queued {
            text = L("Waiting on the Mac", "Wartet auf dem Mac"); symbol = "clock"; color = .secondary
            return
        }
        switch game.onDevice {
        case .update: text = L("Update available", "Aktualisierung möglich"); symbol = "arrow.down.circle.fill"; color = .orange
        case .current: text = L("Installed", "Installiert"); symbol = "checkmark.circle.fill"; color = .green
        case .otherSource: text = L("Other version installed", "Andere Fassung installiert"); symbol = "arrow.left.arrow.right.circle"; color = .secondary
        case .notInstalled, .unknown:
            if game.downloaded {
                text = L("Ready on the Mac", "Bereit auf dem Mac"); symbol = "laptopcomputer"; color = .secondary
            } else {
                text = L("Not installed", "Nicht installiert"); symbol = "circle.dashed"; color = .secondary
            }
        }
    }
}

extension RemoteClient {
    /// Der laufende oder wartende Auftrag eines Spiels, sonst der jüngste.
    func job(for game: RemoteGame) -> RemoteJob? {
        let jobs = status?.jobs.filter { $0.gameId == game.id } ?? []
        return jobs.first(where: \.active) ?? jobs.first
    }

    func game(_ id: String) -> RemoteGame? { games.first { $0.id == id } }
}
