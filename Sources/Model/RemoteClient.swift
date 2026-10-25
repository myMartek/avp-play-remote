import Network
import Observation
import SwiftUI
import UIKit

/// Wie es mit der Verbindung steht.
enum ConnectionState: Equatable {
    /// Noch kein Mac gewählt oder gefunden.
    case searching
    case connecting(String)
    case connected
    /// Die Verbindung kam nicht zustande oder ist abgerissen; es wird gleich neu versucht.
    case retrying(String)
    /// Der Mac nimmt diese Vision Pro nicht (mehr) an; ohne neue Kopplung wird nicht neu versucht.
    case refused(String)
}

/// Ein Mac, mit dem gekoppelt werden soll: aus der Bonjour-Liste oder von Hand eingegeben.
struct PairingTarget: Identifiable, Equatable {
    var name: String
    var endpoint: NWEndpointBox?
    var host: String?
    var pairPort: UInt16 = RemoteWire.pairPort
    var id: String { name + (host ?? "") }
}

struct CoverEntry {
    var key: String
    var image: UIImage
}

/// Eine stehende Verbindung zu einem Mac.
private final class Link {
    let connection: NWConnection
    let channel: RemoteChannel
    let mac: KnownMac
    var welcomed = false

    init(connection: NWConnection, channel: RemoteChannel, mac: KnownMac) {
        self.connection = connection
        self.channel = channel
        self.mac = mac
    }
}

/// Die Fernbedienung: findet die Macs mit AVP Play im Netz (Bonjour), koppelt mit ihnen, hält die Verbindung zu
/// einem davon und zeigt, was er schickt. Gekoppelte Macs werden von selbst verbunden – zuerst der zuletzt
/// benutzte, sonst einer, der gerade im Netz ist.
@MainActor
@Observable
final class RemoteClient {
    private(set) var found: [FoundMac] = []
    private(set) var known: [KnownMac] = KnownMac.load()
    private(set) var state: ConnectionState = .searching
    private(set) var server: RemoteServerInfo?
    private(set) var games: [RemoteGame] = []
    /// Die eigenen Filter des Macs und was die Filterleiste zeigen soll.
    private(set) var filters: [RemoteFilter] = []
    private(set) var onlineCatalog = true
    private(set) var horizonPlusKnown = false
    /// Die Seiten, die der Mac beschreibt (Spiel, Auftrag, Einrichtung, Einstellungen), nach Kennung.
    private(set) var panels: [String: RemotePanel] = [:]
    private(set) var status: RemoteStatus?
    private(set) var covers: [String: CoverEntry] = [:]
    /// Bitten, auf deren Antwort gerade gewartet wird – für Knöpfe, die so lange drehen.
    private(set) var busy: Set<String> = []
    /// Das lokale Netz ist für diese App nicht freigegeben.
    private(set) var localNetworkDenied = false
    /// Öffnet das Blatt zum Koppeln.
    var pairingTarget: PairingTarget?
    /// Eine Meldung, die als Hinweis erscheint (Antwort des Macs auf eine Bitte).
    var message: String?

    private var browser: NWBrowser?
    private var link: Link?
    private var retryTask: Task<Void, Never>?
    private var attempt = 0
    private var seq = 0
    private var pending: [Int: (String?) -> Void] = [:]
    private var coverRequests: Set<String> = []
    private var active = false
    private var offeredPairing = false
    /// Wie oft jede Seite gerade gezeigt wird – erst wenn keine Ansicht sie mehr braucht, wird sie geschlossen.
    private var openPanels: [String: Int] = [:]
    private let queue = DispatchQueue(label: "io.github.mymartek.avpplay.remote.net")

    /// Der Mac, der zuletzt verbunden war oder zuletzt gewählt wurde.
    private(set) var preferredId: String? = UserDefaults.standard.string(forKey: "lastMac") {
        didSet { UserDefaults.standard.set(preferredId, forKey: "lastMac") }
    }

    var connectedMac: KnownMac? { link?.welcomed == true ? link?.mac : nil }
    var connectingMac: KnownMac? { link?.mac }

    // MARK: Leben der App

    /// Im Vordergrund wird gesucht und verbunden; im Hintergrund hält visionOS die App ohnehin an.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            startBrowsing()
            attempt = 0
            #if DEBUG
            // Zum Testen: `-AVPRemoteConnect 127.0.0.1` verbindet wie eine eingetippte Adresse (mit
            // `-AVPRemotePairCode` auch gleich gekoppelt).
            if let host = UserDefaults.standard.string(forKey: "AVPRemoteConnect"), !known.contains(where: { $0.host == host }) {
                connectManually(host)
                if let code = UserDefaults.standard.string(forKey: "AVPRemotePairCode"), let target = pairingTarget {
                    Task { if let problem = await pair(target, code: code) { message = problem } }
                }
            }
            #endif
            if case .refused = state {} else { connectAutomatically() }
        } else {
            browser?.cancel()
            browser = nil
            retryTask?.cancel()
            retryTask = nil
            disconnect(keepState: true)
        }
    }

    // MARK: Suchen

    private func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteWire.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> FoundMac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var serverId: String?
                var pairPort = RemoteWire.pairPort
                if case .bonjour(let txt) = result.metadata {
                    serverId = txt[RemoteWire.txtServerId]
                    if let text = txt[RemoteWire.txtPairPort], let port = UInt16(text) { pairPort = port }
                }
                return FoundMac(name: name, serverId: serverId, pairPort: pairPort, endpoint: NWEndpointBox(endpoint: result.endpoint))
            }
            // Derselbe Mac erscheint einmal je Netzwerkschnittstelle (WLAN, Ethernet, …) – er zählt einmal.
            var seen = Set<String>()
            let unique = macs.filter { seen.insert($0.id).inserted }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.foundChanged(unique) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { self.localNetworkDenied = true }
                case .ready: self.localNetworkDenied = false
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func foundChanged(_ macs: [FoundMac]) {
        guard macs != found else { return }
        found = macs
        // Ein gekoppelter Mac ist aufgetaucht, während keiner verbunden ist: gleich versuchen, nicht erst nach der Pause.
        if link == nil, macs.contains(where: { mac in known.contains { $0.serverId == mac.serverId } }) {
            if case .refused = state {} else {
                retryTask?.cancel()
                retryTask = nil
                connectAutomatically()
            }
        }
        // Noch nie gekoppelt und genau ein Mac im Netz: gleich nach dem Code fragen – einmal.
        if known.isEmpty, macs.count == 1, pairingTarget == nil, !offeredPairing {
            offeredPairing = true
            pairingTarget = PairingTarget(name: macs[0].name, endpoint: macs[0].endpoint, pairPort: macs[0].pairPort)
            #if DEBUG
            // Zum Testen im Simulator, wo sich nichts antippen lässt: `-AVPRemotePairCode 123456` koppelt gleich.
            if let code = UserDefaults.standard.string(forKey: "AVPRemotePairCode"), let target = pairingTarget {
                Task { if let problem = await pair(target, code: code) { message = problem } }
            }
            #endif
        }
    }

    func isFound(_ mac: KnownMac) -> Bool { found.contains { $0.serverId == mac.serverId } }

    // MARK: Verbinden

    /// Wählt einen gekoppelten Mac und verbindet: der bevorzugte, wenn er im Netz ist oder eine Adresse bekannt ist,
    /// sonst reihum die anderen.
    func connectAutomatically() {
        guard active, link == nil, retryTask == nil else { return }
        let reachable = known.filter { isFound($0) || $0.host != nil }
        guard !reachable.isEmpty else {
            state = .searching
            return
        }
        let ordered = reachable.sorted { a, b in
            if (a.serverId == preferredId) != (b.serverId == preferredId) { return a.serverId == preferredId }
            if isFound(a) != isFound(b) { return isFound(a) }
            return (a.lastConnected ?? .distantPast) > (b.lastConnected ?? .distantPast)
        }
        // Der bevorzugte, solange er im Netz ist; sonst wechselt jeder neue Versuch zum nächsten.
        let mac = ordered.first.flatMap { $0.serverId == preferredId && isFound($0) ? $0 : nil } ?? ordered[attempt % ordered.count]
        connect(mac)
    }

    /// Zu einem anderen gekoppelten Mac wechseln.
    func switchTo(_ mac: KnownMac) {
        preferredId = mac.serverId
        disconnect()
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        connect(mac)
    }

    private func connect(_ mac: KnownMac) {
        guard let secret = MacKeychain.read(serverId: mac.serverId) else {
            forget(mac)
            return
        }
        // Über Bonjour, wenn er dort ist (die Adresse kann sich geändert haben), sonst über die zuletzt bekannte.
        // Jeder zweite Versuch nimmt die Adresse, falls Bonjour einen Eintrag zeigt, der nicht mehr antwortet.
        let bonjour = found.first { $0.serverId == mac.serverId }?.endpoint.endpoint
        let direct = mac.host.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: NWEndpoint.Port(rawValue: mac.port ?? RemoteWire.defaultPort)!) }
        guard let endpoint = (attempt % 2 == 1 ? direct ?? bonjour : bonjour ?? direct) else { return scheduleRetry() }
        let parameters = RemoteWire.parameters(psks: [(identity: RemoteWire.clientIdentity(secret.clientId), key: secret.key)])
        let connection = NWConnection(to: endpoint, using: parameters)
        let channel = RemoteChannel(connection: connection, queue: queue)
        let link = Link(connection: connection, channel: channel, mac: mac)
        self.link = link
        state = .connecting(mac.name)
        connection.stateUpdateHandler = { [weak self, weak link] state in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                switch state {
                case .ready:
                    self.linkReady(link, clientId: secret.clientId)
                case .waiting(let error), .failed(let error):
                    self.linkFailed(link, error: error)
                default: break
                }
            }
        }
        channel.receive({ [weak self, weak link] data in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.received(data, on: link)
            }
        }, closed: { [weak self, weak link] _ in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.linkClosed(link)
            }
        })
        connection.start(queue: queue)
    }

    private func linkReady(_ link: Link, clientId: String) {
        link.channel.send(RemoteClientMessage(seq: nextSeq(), request: .hello(RemoteHello(clientId: clientId, name: deviceName, language: Language.code))))
        // Die Adresse merken, unter der er antwortet – falls Bonjour ihn einmal nicht zeigt.
        if case .hostPort(let host, _)? = link.connection.currentPath?.remoteEndpoint, let text = RemoteClient.storable(host) {
            update(link.mac.serverId) { $0.host = text; $0.port = RemoteWire.defaultPort }
        }
    }

    private func linkFailed(_ link: Link, error: NWError) {
        // Am Schlüssel gescheitert: Der Mac hat die Kopplung entfernt (oder seine Daten verloren). Neu versuchen hilft
        // nicht – neu koppeln.
        if case .tls = error {
            disconnect()
            state = .refused(L("“\(link.mac.name)” no longer accepts this Vision Pro. Pair it again with the code from AVP Play › Remote Control.",
                               "„\(link.mac.name)“ nimmt diese Vision Pro nicht mehr an. Koppele erneut mit dem Code aus AVP Play › Fernbedienung."))
            return
        }
        disconnect()
        state = .retrying(L("“\(link.mac.name)” is not reachable. Is AVP Play open with the remote control switched on?",
                            "„\(link.mac.name)“ ist nicht erreichbar. Ist AVP Play offen und die Fernbedienung eingeschaltet?"))
        scheduleRetry()
    }

    private func linkClosed(_ link: Link) {
        let name = link.mac.name
        disconnect()
        if case .refused = state { return }
        state = .retrying(L("The connection to “\(name)” was lost.", "Die Verbindung zu „\(name)“ ist abgerissen."))
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard active, retryTask == nil else { return }
        attempt += 1
        // 1, 2, 4, 8 Sekunden, dann alle zehn.
        let delay = min(10, pow(2, Double(min(attempt, 4)) - 1))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.connectAutomatically()
        }
    }

    private func disconnect(keepState: Bool = false) {
        link?.connection.cancel()
        link = nil
        for (_, done) in pending { done(L("The connection to the Mac was lost.", "Die Verbindung zum Mac ist abgerissen.")) }
        pending = [:]
        coverRequests = []
        busy = []
        panels = [:]
        if !keepState { state = .searching }
    }

    /// Von Hand neu verbinden – auch nach einer Ablehnung.
    func reconnect() {
        disconnect()
        retryTask?.cancel()
        retryTask = nil
        attempt = 0
        connectAutomatically()
    }

    // MARK: Nachrichten

    private func received(_ data: Data, on link: Link) {
        guard let message = try? RemoteWire.decoder.decode(RemoteServerMessage.self, from: data) else { return }
        switch message {
        case .welcome(let info):
            link.welcomed = true
            server = info
            state = .connected
            attempt = 0
            preferredId = info.serverId
            update(info.serverId) { $0.name = info.name; $0.lastConnected = Date() }
            // Was nach einer abgerissenen Verbindung noch gezeigt wird, wieder anfordern.
            for id in openPanels.keys { link.channel.send(RemoteClientMessage(seq: nextSeq(), request: .openPanel(id: id))) }
        case .status(let status):
            self.status = status
        case .library(let library):
            games = library.games
            filters = library.filters
            onlineCatalog = library.onlineCatalog
            horizonPlusKnown = library.horizonPlus
        case .panel(let panel):
            panels[panel.id] = panel
        case .cover(let gameId, let key, let jpeg):
            if let key { coverRequests.remove(key) }
            guard let key, let jpeg, let image = UIImage(data: jpeg) else { return }
            CoverDisk.write(jpeg, key: key)
            covers[gameId] = CoverEntry(key: key, image: image)
        case .reply(let seq, let error):
            pending.removeValue(forKey: seq)?(error)
        case .refused(let why):
            disconnect()
            state = .refused(why)
        case .paired:
            break
        }
    }

    private func nextSeq() -> Int {
        seq += 1
        return seq
    }

    /// Schickt eine Bitte und wartet auf die Antwort; zurück kommt, was der Mac dagegen hatte.
    func send(_ request: RemoteRequest) async -> String? {
        guard let link, link.welcomed else { return L("Not connected to a Mac.", "Mit keinem Mac verbunden.") }
        let number = nextSeq()
        return await withCheckedContinuation { continuation in
            pending[number] = { continuation.resume(returning: $0) }
            link.channel.send(RemoteClientMessage(seq: number, request: request))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.pending.removeValue(forKey: number)?(L("The Mac did not answer.", "Der Mac hat nicht geantwortet."))
            }
        }
    }

    /// Eine Bitte aus einem Knopf: dreht, solange sie läuft, und zeigt, was der Mac dagegen hatte.
    func perform(_ request: RemoteRequest, key: String) {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            let error = await send(request)
            busy.remove(key)
            if let error { message = error }
        }
    }

    // MARK: Seiten

    /// Eine Ansicht zeigt eine Seite: Der Mac schickt sie und jede Änderung, bis sie wieder geschlossen wird.
    func openPanel(_ id: String) {
        openPanels[id, default: 0] += 1
        guard openPanels[id] == 1, let link, link.welcomed else { return }
        link.channel.send(RemoteClientMessage(seq: nextSeq(), request: .openPanel(id: id)))
    }

    func closePanel(_ id: String) {
        guard let count = openPanels[id] else { return }
        if count > 1 { openPanels[id] = count - 1; return }
        openPanels[id] = nil
        guard let link, link.welcomed else { return }
        link.channel.send(RemoteClientMessage(seq: nextSeq(), request: .closePanel(id: id)))
    }

    /// Ein Schalter, eine Wahl oder ein Knopf einer Seite.
    func act(_ panel: String, _ item: String, value: String? = nil) {
        perform(.panelAction(panel: panel, item: item, value: value), key: "\(panel)/\(item)")
    }

    // MARK: Bilder

    func cover(for game: RemoteGame) -> UIImage? {
        guard let key = game.coverKey, let entry = covers[game.id], entry.key == key else { return nil }
        return entry.image
    }

    /// Holt das Bild eines Spiels: von der Platte, sonst vom Mac.
    func loadCover(_ game: RemoteGame) {
        guard let key = game.coverKey, covers[game.id]?.key != key else { return }
        if let data = CoverDisk.read(key), let image = UIImage(data: data) {
            covers[game.id] = CoverEntry(key: key, image: image)
            return
        }
        guard let link, link.welcomed, !coverRequests.contains(key) else { return }
        coverRequests.insert(key)
        link.channel.send(RemoteClientMessage(seq: nextSeq(), request: .cover(gameId: game.id)))
    }

    // MARK: Koppeln

    /// Koppelt mit einem Mac. Zurück kommt, was schiefging; `nil` = gekoppelt, die Verbindung wird aufgebaut.
    func pair(_ target: PairingTarget, code: String) async -> String? {
        guard let code = RemoteWire.normalizedCode(code) else { return L("The code has six digits.", "Der Code hat sechs Ziffern.") }
        let host: NWEndpoint.Host
        if let text = target.host {
            host = NWEndpoint.Host(text)
        } else if let endpoint = target.endpoint?.endpoint, let resolved = await RemoteClient.resolve(endpoint, queue: queue) {
            host = resolved
        } else {
            return L("“\(target.name)” cannot be reached.", "„\(target.name)“ ist nicht erreichbar.")
        }
        let outcome = await RemoteClient.pairingExchange(host: host, port: target.pairPort, code: code, name: deviceName, queue: queue)
        switch outcome {
        case .failure(let why):
            return why.text
        case .success(let pairing):
            guard MacKeychain.write(MacKeychain.Secret(clientId: pairing.clientId, key: pairing.key), serverId: pairing.server.serverId) else {
                return L("The key could not be stored on this Vision Pro.", "Der Schlüssel ließ sich auf dieser Vision Pro nicht ablegen.")
            }
            let address = RemoteClient.storable(host)
            if let index = known.firstIndex(where: { $0.serverId == pairing.server.serverId }) {
                known[index].name = pairing.server.name
                known[index].host = address ?? known[index].host
            } else {
                known.append(KnownMac(serverId: pairing.server.serverId, name: pairing.server.name, host: address, port: RemoteWire.defaultPort))
            }
            KnownMac.save(known)
            pairingTarget = nil
            if case .refused = state { state = .searching }
            switchTo(known.first { $0.serverId == pairing.server.serverId }!)
            return nil
        }
    }

    /// Vergisst einen Mac: sein Schlüssel wird gelöscht. Auf dem Mac bleibt der Eintrag stehen, bis er dort entfernt wird.
    func forget(_ mac: KnownMac) {
        if link?.mac.serverId == mac.serverId {
            disconnect()
            server = nil
            games = []
            status = nil
        }
        MacKeychain.delete(serverId: mac.serverId)
        known.removeAll { $0.serverId == mac.serverId }
        KnownMac.save(known)
        if preferredId == mac.serverId { preferredId = nil }
        connectAutomatically()
    }

    /// Eine von Hand eingegebene Adresse: ein bekannter Mac unter dieser Adresse wird verbunden, sonst gekoppelt.
    func connectManually(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let mac = known.first(where: { $0.host == trimmed }) { return switchTo(mac) }
        pairingTarget = PairingTarget(name: trimmed, host: trimmed)
    }

    // MARK: Hilfen

    private func update(_ serverId: String, _ change: (inout KnownMac) -> Void) {
        guard let index = known.firstIndex(where: { $0.serverId == serverId }) else { return }
        var mac = known[index]
        change(&mac)
        guard mac != known[index] else { return }
        known[index] = mac
        KnownMac.save(known)
    }

    private var deviceName: String { UIDevice.current.name }

    /// Eine Adresse, die sich auch später noch eignet: IPv4, oder ein Name. Link-lokale IPv6-Adressen hängen an
    /// einer Schnittstelle und taugen nicht zum Merken.
    nonisolated static func storable(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address): return "\(address)".components(separatedBy: "%").first
        case .name(let name, _): return name
        case .ipv6: return nil
        @unknown default: return nil
        }
    }

    /// Ermittelt die IPv4-Adresse hinter einem Bonjour-Eintrag – der Kopplungsport hat keinen eigenen Eintrag.
    nonisolated static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue) async -> NWEndpoint.Host? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        return await withCheckedContinuation { continuation in
            let once = Once()
            @Sendable func finish(_ host: NWEndpoint.Host?) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint { finish(host) } else { finish(nil) }
                case .failed, .waiting: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { finish(nil) }
        }
    }

    /// Verbindet sich mit dem Kopplungsport, schickt den Namen und wartet auf den eigenen Schlüssel.
    nonisolated static func pairingExchange(host: NWEndpoint.Host, port: UInt16, code: String, name: String,
                                            queue: DispatchQueue) async -> Result<RemotePairing, PairingError> {
        let parameters = RemoteWire.parameters(psks: [(identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code))])
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let channel = RemoteChannel(connection: connection, queue: queue)
        return await withCheckedContinuation { continuation in
            let once = Once()
            @Sendable func finish(_ result: Result<RemotePairing, PairingError>) {
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    channel.send(RemoteClientMessage(seq: 1, request: .hello(RemoteHello(clientId: nil, name: name, language: Language.code))))
                    channel.send(RemoteClientMessage(seq: 2, request: .pair(name: name)))
                    channel.receive({ data in
                        switch try? RemoteWire.decoder.decode(RemoteServerMessage.self, from: data) {
                        case .paired(let pairing)?: finish(.success(pairing))
                        case .refused(let why)?: finish(.failure(PairingError(why)))
                        case .reply(_, let error?)?: finish(.failure(PairingError(error)))
                        default: break
                        }
                    }, closed: { _ in finish(.failure(PairingError(L("The Mac closed the connection.", "Der Mac hat die Verbindung beendet.")))) })
                case .failed(let error), .waiting(let error):
                    if case .tls = error {
                        finish(.failure(PairingError(L("The code is not right – or it has changed. Look again in AVP Play › Remote Control.",
                                                       "Der Code stimmt nicht – oder er hat sich geändert. Sieh noch einmal in AVP Play › Fernbedienung nach."))))
                    } else {
                        finish(.failure(PairingError(L("The Mac cannot be reached for pairing. Is “Remote Control” switched on in AVP Play?",
                                                       "Der Mac ist zum Koppeln nicht erreichbar. Ist „Fernbedienung“ in AVP Play eingeschaltet?"))))
                    }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                finish(.failure(PairingError(L("The Mac did not answer.", "Der Mac hat nicht geantwortet."))))
            }
        }
    }
}

struct PairingError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

/// Genau einmal: für Fortsetzungen, die aus mehreren Rückrufen enden können.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
