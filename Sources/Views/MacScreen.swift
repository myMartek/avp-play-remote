import SwiftUI

/// Die Macs: der verbundene, die gekoppelten, die im Netz gefundenen, und eine Adresse von Hand.
struct MacScreen: View {
    @Environment(RemoteClient.self) private var client
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                if client.known.isEmpty { macApp }
                if client.localNetworkDenied {
                    SwiftUI.Section { LocalNetworkHint().frame(maxWidth: .infinity).padding() }
                }
                if let mac = client.connectedMac, let server = client.server {
                    SwiftUI.Section(L("Connected", "Verbunden")) {
                        LabeledContent("Mac", value: mac.name)
                        LabeledContent("AVP Play", value: server.appVersion)
                        if let status = client.status {
                            LabeledContent(L("Installs on", "Installiert auf")) {
                                if let device = status.deviceName {
                                    Text(device + (status.deviceVia == "wifi" ? L(" · Wi-Fi", " · WLAN") : status.deviceVia == "cable" ? L(" · cable", " · Kabel") : ""))
                                } else {
                                    Text(status.deviceProblem ?? L("No Vision Pro", "Keine Vision Pro")).foregroundStyle(.orange)
                                }
                            }
                            if let problem = status.setupProblem {
                                Text(problem).foregroundStyle(.orange)
                            }
                        }
                        Button(L("Check Again on the Mac", "Auf dem Mac neu prüfen"), systemImage: "arrow.clockwise") {
                            client.perform(.refresh, key: "refresh")
                        }
                        .disabled(client.status?.refreshing == true || client.busy.contains("refresh"))
                    }
                }

                SwiftUI.Section {
                    if client.known.isEmpty {
                        Text(L("No Mac paired yet.", "Noch kein Mac gekoppelt.")).foregroundStyle(.secondary)
                    }
                    ForEach(client.known) { mac in
                        HStack(spacing: 16) {
                            Image(systemName: "laptopcomputer").font(.title2)
                                .foregroundStyle(client.connectedMac?.serverId == mac.serverId ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name).font(.headline)
                                Text(detail(mac)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if client.connectedMac?.serverId == mac.serverId {
                                Text(L("Connected", "Verbunden")).foregroundStyle(.green)
                            } else if client.connectingMac?.serverId == mac.serverId {
                                ProgressView()
                            } else {
                                Button(L("Connect", "Verbinden")) { client.switchTo(mac) }
                            }
                        }
                        .contextMenu {
                            Button(L("Forget This Mac", "Diesen Mac vergessen"), systemImage: "trash", role: .destructive) { client.forget(mac) }
                        }
                        .swipeActions {
                            Button(L("Forget", "Vergessen"), role: .destructive) { client.forget(mac) }
                        }
                    }
                } header: {
                    Text(L("Paired Macs", "Gekoppelte Macs"))
                } footer: {
                    if case .refused(let why) = client.state { Text(why).foregroundStyle(.orange) }
                }

                SwiftUI.Section {
                    let unpaired = client.found.filter { mac in !client.known.contains { $0.serverId == mac.serverId } }
                    if unpaired.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(L("Looking for Macs with AVP Play …", "Suche Macs mit AVP Play …")).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(unpaired) { mac in
                        HStack {
                            Image(systemName: "laptopcomputer").font(.title2).foregroundStyle(.secondary)
                            Text(mac.name).font(.headline)
                            Spacer()
                            Button(L("Pair", "Koppeln")) {
                                client.pairingTarget = PairingTarget(name: mac.name, endpoint: mac.endpoint, pairPort: mac.pairPort)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    Text(L("In this network", "In diesem Netz"))
                } footer: {
                    Text(L("A Mac shows up here when AVP Play is open on it and “Remote Control” is switched on in its sidebar.",
                           "Ein Mac erscheint hier, wenn AVP Play darauf offen ist und „Fernbedienung“ in der Seitenleiste eingeschaltet ist."))
                }

                SwiftUI.Section {
                    HStack {
                        TextField(L("IP address or name, e.g. 192.168.1.20", "IP-Adresse oder Name, z. B. 192.168.1.20"), text: $address)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(connect)
                        Button(L("Connect", "Verbinden"), action: connect)
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text(L("Connect by address", "Mit Adresse verbinden"))
                } footer: {
                    Text(L("If the Mac does not show up (for example in a network that blocks Bonjour), enter the address shown in AVP Play › Remote Control.",
                           "Erscheint der Mac nicht (etwa in einem Netz, das Bonjour sperrt), gib die Adresse ein, die AVP Play › Fernbedienung zeigt."))
                }

                if !client.known.isEmpty { macApp }
            }
            .navigationTitle("Mac")
        }
    }

    /// Wo es AVP Play für den Mac gibt – zum Teilen an den Mac, etwa per AirDrop – und die Anleitung im Wiki.
    private var macApp: some View {
        SwiftUI.Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("This app only controls AVP Play on a Mac – the Mac downloads, builds and installs the games. AVP Play for the Mac is free and open source; download the newest version on the Mac and open it there.",
                       "Diese App steuert nur AVP Play auf einem Mac – der Mac lädt, baut und installiert die Spiele. AVP Play für den Mac ist kostenlos und quelloffen; lade die neueste Fassung auf dem Mac und öffne sie dort."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Link(destination: MacScreen.download) {
                    Label(L("Download AVP Play for the Mac", "AVP Play für den Mac laden"), systemImage: "arrow.down.circle")
                }
                Spacer()
                // Zum Mac schicken, etwa per AirDrop – auf der Vision Pro selbst lässt sich damit nichts anfangen.
                ShareLink(item: MacScreen.download, subject: Text("AVP Play"),
                          message: Text(L("AVP Play for the Mac", "AVP Play für den Mac"))) {
                    Label(L("Send to Mac", "An den Mac senden"), systemImage: "square.and.arrow.up")
                }
            }
            Link(destination: MacScreen.wiki) {
                Label(L("Instructions in the wiki", "Anleitung im Wiki"), systemImage: "book")
            }
        } header: {
            Text(L("AVP Play for the Mac", "AVP Play für den Mac"))
        } footer: {
            Text(L("“Send to Mac” opens the share sheet – with AirDrop the link arrives right on your Mac.",
                   "„An den Mac senden“ öffnet das Teilen-Menü – per AirDrop kommt der Link direkt auf deinem Mac an."))
        }
    }

    static let download = URL(string: "https://github.com/myMartek/avp-play/releases/latest")!
    static let wiki = URL(string: "https://github.com/myMartek/avp-play/wiki")!

    private func connect() {
        client.connectManually(address)
        address = ""
    }

    private func detail(_ mac: KnownMac) -> String {
        var parts: [String] = []
        parts.append(client.isFound(mac) ? L("In this network", "In diesem Netz") : L("Not seen in this network", "In diesem Netz nicht gesehen"))
        if let host = mac.host { parts.append(host) }
        if let last = mac.lastConnected { parts.append(L("last connected \(last.formatted(.relative(presentation: .named)))", "zuletzt verbunden \(last.formatted(.relative(presentation: .named)))")) }
        return parts.joined(separator: " · ")
    }
}

/// Koppeln: der Code, den AVP Play auf dem Mac zeigt.
struct PairingSheet: View {
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let target: PairingTarget
    @State private var code = ""
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "laptopcomputer.and.arrow.down").font(.system(size: 56)).foregroundStyle(.tint)
                Text(L("Pair with “\(target.name)”", "Mit „\(target.name)“ koppeln")).font(.title.bold()).multilineTextAlignment(.center)
                Text(L("Enter the code that AVP Play on this Mac shows under “Remote Control”. You only need to do this once.",
                       "Gib den Code ein, den AVP Play auf diesem Mac unter „Fernbedienung“ zeigt. Das ist nur einmal nötig."))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                TextField("000 000", text: $code)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .frame(width: 280)
                    .focused($focused)
                    .onSubmit(pair)
                    .disabled(working)
                if let problem {
                    Text(problem).foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 460)
                }
                Button(action: pair) {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text(L("Pair", "Koppeln")).frame(minWidth: 160)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(working || RemoteWire.normalizedCode(code) == nil)
            }
            .padding(48)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel", "Abbrechen")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .onAppear { focused = true }
    }

    private func pair() {
        guard !working, RemoteWire.normalizedCode(code) != nil else { return }
        working = true
        problem = nil
        Task {
            problem = await client.pair(target, code: code)
            working = false
            if problem == nil { dismiss() }
        }
    }
}
