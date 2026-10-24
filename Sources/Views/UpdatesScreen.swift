import SwiftUI

/// Spiele auf der Vision Pro, für die es einen neueren Bau gibt.
struct UpdatesScreen: View {
    @Environment(RemoteClient.self) private var client
    @Binding var section: AppTab

    var body: some View {
        NavigationStack {
            ConnectionGate(section: $section) {
                let ready = (client.status?.updatable ?? []).compactMap(client.game)
                let blocked = client.games.filter { $0.onDevice == .update && !(client.status?.updatable.contains($0.id) ?? false) }
                if ready.isEmpty && blocked.isEmpty {
                    ContentUnavailableView(L("Everything is up to date", "Alles ist auf dem neuesten Stand"), systemImage: "checkmark.circle",
                                           description: Text(L("Games with a newer build show up here.", "Spiele mit einem neueren Bau erscheinen hier.")))
                } else {
                    List {
                        if !ready.isEmpty {
                            SwiftUI.Section {
                                ForEach(ready) { UpdateRow(game: $0) }
                            } header: {
                                HStack {
                                    Text(L("Ready to update", "Bereit zum Aktualisieren"))
                                    Spacer()
                                    Button {
                                        client.perform(.updateAll, key: "updateAll")
                                    } label: {
                                        Label(L("Update All", "Alle aktualisieren"), systemImage: "arrow.down.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(client.busy.contains("updateAll"))
                                }
                            }
                        }
                        if !blocked.isEmpty {
                            SwiftUI.Section(L("Not possible right now", "Gerade nicht möglich")) {
                                ForEach(blocked) { UpdateRow(game: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Updates", "Updates"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { MacMenu(section: $section) } }
        }
    }
}

struct UpdateRow: View {
    @Environment(RemoteClient.self) private var client
    let game: RemoteGame

    var body: some View {
        HStack(spacing: 16) {
            CoverView(game: game).frame(width: 160).clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.headline)
                if let job = client.job(for: game), job.active {
                    Text(JobLook.line(job)).font(.subheadline).foregroundStyle(.blue)
                    if let progress = job.progress { ProgressView(value: progress) }
                } else if let why = game.installBlocker {
                    Text(why).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                } else if let built = game.builtWith {
                    Text(L("Installed: \(built)", "Installiert: \(built)")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            let key = "install:\(game.id)"
            Button(L("Update", "Aktualisieren")) { client.perform(.install(gameId: game.id), key: key) }
                .disabled(game.installBlocker != nil || game.busy || client.busy.contains(key))
        }
        .padding(.vertical, 4)
    }
}
