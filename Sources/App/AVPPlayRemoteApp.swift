import SwiftUI

@main
struct AVPPlayRemoteApp: App {
    @State private var client = RemoteClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .onChange(of: phase, initial: true) { _, now in client.setActive(now == .active) }
        }
        .defaultSize(width: 1180, height: 780)
    }
}

enum AppTab: String, Hashable { case games, updates, jobs, setup, settings, mac }

struct RootView: View {
    @Environment(RemoteClient.self) private var client
    @State private var section: AppTab = RootView.startTab

    var body: some View {
        @Bindable var client = client
        TabView(selection: $section) {
            Tab(L("Games", "Spiele"), systemImage: "square.grid.2x2", value: AppTab.games) {
                GamesScreen(section: $section)
            }
            Tab(L("Updates", "Updates"), systemImage: "arrow.down.circle", value: AppTab.updates) {
                UpdatesScreen(section: $section)
            }
            .badge(client.connectedMac == nil ? 0 : client.status?.updatable.count ?? 0)
            Tab(L("Jobs", "Aufträge"), systemImage: "list.bullet.clipboard", value: AppTab.jobs) {
                JobsScreen(section: $section)
            }
            .badge(client.connectedMac == nil ? 0 : client.status?.jobs.filter(\.active).count ?? 0)
            Tab(L("Setup", "Einrichtung"), systemImage: "checklist", value: AppTab.setup) {
                PanelScreen(section: $section, panelId: "setup", title: L("Setup", "Einrichtung"))
            }
            Tab(L("Settings", "Einstellungen"), systemImage: "gearshape", value: AppTab.settings) {
                PanelScreen(section: $section, panelId: "settings", title: L("Settings", "Einstellungen"))
            }
            Tab("Mac", systemImage: "laptopcomputer", value: AppTab.mac) {
                MacScreen()
            }
        }
        .sheet(item: $client.pairingTarget) { target in
            PairingSheet(target: target)
        }
        .alert(client.demo ? "Demo" : L("The Mac says", "Der Mac meldet"), isPresented: Binding(get: { client.message != nil }, set: { if !$0 { client.message = nil } })) {
            Button("OK") { client.message = nil }
        } message: {
            Text(client.message ?? "")
        }
    }
}

extension RootView {
    /// `-AVPRemoteTab mac` öffnet zum Testen gleich eine andere Seite (nur in Debug-Builds).
    static var startTab: AppTab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "AVPRemoteTab"), let tab = AppTab(rawValue: raw) { return tab }
        #endif
        return .games
    }
}
