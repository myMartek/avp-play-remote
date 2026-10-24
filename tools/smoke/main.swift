// Prüft AVP Play auf dem Mac von der Kommandozeile aus, so wie die App es tut: Bonjour, Kopplung, Verbindung,
// Bitten. Bauen und starten (auf dem Mac, mit eingeschalteter Fernbedienung):
//
//   swiftc -O Sources/Shared/RemoteProtocol.swift tools/smoke/main.swift -o build/smoke
//   build/smoke <Code> [Host] [Spiel-ID]
//
// Es koppelt sich als eigene Fernbedienung („Smoke test“); auf dem Mac lässt sie sich danach entfernen.
import Foundation
import Network

setbuf(stdout, nil)
let args = CommandLine.arguments
guard args.count >= 2 else { print("Aufruf: smoke <Code> [Host] [Spiel-ID]"); exit(2) }
let code = args[1]
let host = args.count > 2 ? args[2] : "127.0.0.1"
let gameId = args.count > 3 ? args[3] : nil
let queue = DispatchQueue(label: "smoke")
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

/// Eine Verbindung, die Nachrichten in eine Liste sammelt.
final class Probe {
    let connection: NWConnection
    let channel: RemoteChannel
    var messages: [RemoteServerMessage] = []
    var state: NWConnection.State = .setup
    let lock = NSLock()

    init(port: UInt16, identity: String, key: Data) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: RemoteWire.parameters(psks: [(identity: identity, key: key)]))
        channel = RemoteChannel(connection: connection, queue: queue)
        connection.stateUpdateHandler = { [unowned self] s in self.lock.lock(); self.state = s; self.lock.unlock() }
        channel.receive({ [unowned self] data in
            guard let m = try? RemoteWire.decoder.decode(RemoteServerMessage.self, from: data) else { return }
            self.lock.lock(); self.messages.append(m); self.lock.unlock()
        }, closed: { _ in })
        connection.start(queue: queue)
    }

    func wait(_ seconds: Double = 8, until: (Probe) -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            lock.lock(); let done = until(self); lock.unlock()
            if done { return true }
            usleep(50_000)
        }
        return false
    }

    var ready: Bool { if case .ready = state { return true }; return false }
    var tlsFailed: Bool {
        switch state {
        case .failed(.tls), .waiting(.tls): return true
        default: return false
        }
    }

    func reply(to seq: Int) -> String?? {
        for case .reply(let s, let error) in messages where s == seq { return .some(error) }
        return nil
    }

    func send(_ seq: Int, _ request: RemoteRequest) { channel.send(RemoteClientMessage(seq: seq, request: request)) }
}

// 1. Bonjour: Der Mac zeigt sich mit Kennung und Version.
let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteWire.serviceType, domain: nil), using: NWParameters())
var seen: [(String, String?)] = []
browser.browseResultsChangedHandler = { results, _ in
    seen = results.compactMap { r in
        guard case .service(let name, _, _, _) = r.endpoint else { return nil }
        if case .bonjour(let txt) = r.metadata { return (name, txt[RemoteWire.txtServerId]) }
        return (name, nil)
    }
}
browser.start(queue: queue)
Thread.sleep(forTimeInterval: 3)
browser.cancel()
check(!seen.isEmpty, "Bonjour zeigt \(Set(seen.map(\.0)).sorted()) mit Kennung \(Set(seen.compactMap(\.1)).count == 1 ? "einheitlich" : "uneinheitlich")")

// 2. Ein falscher Code kommt nicht über den Handshake.
let wrong = Probe(port: RemoteWire.pairPort, identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code == "000000" ? "111111" : "000000"))
check(wrong.wait { $0.tlsFailed }, "falscher Code wird abgewiesen")
wrong.connection.cancel()

// 3. Mit dem richtigen Code: koppeln.
let pairing = Probe(port: RemoteWire.pairPort, identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code))
check(pairing.wait { $0.ready }, "Kopplungsport mit richtigem Code erreichbar")
pairing.send(1, .hello(RemoteHello(clientId: nil, name: "Smoke test")))
// Auf dem Kopplungsport ist nichts anderes erlaubt als koppeln …
pairing.send(2, .install(gameId: "x"))
check(pairing.wait { p in p.messages.contains { if case .refused = $0 { return true }; return false } }, "Kopplungsport lehnt andere Bitten ab")
pairing.connection.cancel()
let pairing2 = Probe(port: RemoteWire.pairPort, identity: RemoteWire.pairIdentity, key: RemoteWire.pairingKey(code: code))
_ = pairing2.wait { $0.ready }
pairing2.send(1, .hello(RemoteHello(clientId: nil, name: "Smoke test")))
pairing2.send(2, .pair(name: "Smoke test"))
var result: RemotePairing?
_ = pairing2.wait { p in
    for case .paired(let r) in p.messages { result = r; return true }
    return false
}
pairing2.connection.cancel()
guard let result else { check(false, "Kopplung"); exit(1) }
check(true, "gekoppelt mit „\(result.server.name)“ (Kennung \(result.server.serverId.prefix(8))…)")

// 4. Ein fremder Schlüssel kommt am eigentlichen Port nicht hinein.
let stranger = Probe(port: RemoteWire.defaultPort, identity: RemoteWire.clientIdentity(result.clientId), key: RemoteWire.newKey())
check(stranger.wait { $0.tlsFailed }, "fremder Schlüssel wird abgewiesen")
stranger.connection.cancel()

// 5. Mit dem eigenen Schlüssel: verbinden, Stand und Spiele kommen von selbst.
Thread.sleep(forTimeInterval: 1)   // der Mac öffnet den Port mit dem neuen Schlüssel neu
let main = Probe(port: RemoteWire.defaultPort, identity: RemoteWire.clientIdentity(result.clientId), key: result.key)
check(main.wait { $0.ready }, "Verbindung mit eigenem Schlüssel")
main.send(1, .hello(RemoteHello(clientId: result.clientId, name: "Smoke test")))
var games: [RemoteGame] = []
var status: RemoteStatus?
check(main.wait { p in
    for m in p.messages {
        if case .games(let g) = m { games = g }
        if case .status(let s) = m { status = s }
    }
    return !games.isEmpty && status != nil
}, "Stand und Spieleliste kommen")
print("     \(games.count) Spiele, \(games.filter(\.installed).count) installiert, \(status?.jobs.count ?? 0) Aufträge, Vision Pro: \(status?.deviceName ?? status?.deviceProblem ?? "-")")
if let problem = status?.setupProblem { print("     Mac: \(problem)") }

// 6. Bitten: unbekanntes Spiel und unbekannter Auftrag werden begründet abgelehnt; Neu prüfen wird angenommen.
main.send(10, .install(gameId: "gibt-es-nicht"))
main.send(11, .cancel(jobId: "gibt-es-nicht"))
main.send(12, .refresh)
check(main.wait { $0.reply(to: 10) != nil && $0.reply(to: 11) != nil && $0.reply(to: 12) != nil }, "Antworten auf Bitten kommen")
check(main.reply(to: 10)! != nil, "unbekanntes Spiel: \(main.reply(to: 10)!! ?? "-")")
check(main.reply(to: 11)! != nil, "unbekannter Auftrag: \(main.reply(to: 11)!! ?? "-")")
check(main.reply(to: 12)! == nil, "Neu prüfen angenommen")

// 7. Ein Spiel: Installieren nur, wenn nichts im Weg steht – sonst kommt der Grund. Ohne Spiel-ID nur, wenn etwas im
//    Weg steht (damit der Test nichts installiert).
let target = gameId.flatMap { id in games.first { $0.id == id } } ?? games.first { $0.installBlocker != nil }
if let game = target {
    main.send(20, .install(gameId: game.id))
    _ = main.wait { $0.reply(to: 20) != nil }
    let answer = main.reply(to: 20).flatMap { $0 }
    check(game.installBlocker == nil ? answer == nil : answer == game.installBlocker,
          "Installieren „\(game.title)“: \(answer ?? "angenommen")")
}

// 8. Ein Titelbild.
if let game = games.first(where: { $0.coverKey != nil }) {
    main.send(30, .cover(gameId: game.id))
    var size = 0
    _ = main.wait(15) { p in
        for case .cover(let id, _, let jpeg?) in p.messages where id == game.id { size = jpeg.count; return true }
        return false
    }
    check(size > 1000, "Titelbild „\(game.title)“: \(size / 1024) KB")
}
main.connection.cancel()
print(failures == 0 ? "Alles gut." : "\(failures) Fehler.")
exit(failures == 0 ? 0 : 1)
