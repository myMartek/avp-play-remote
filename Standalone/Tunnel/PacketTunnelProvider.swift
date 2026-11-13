import NetworkExtension

/// Eine Schleife zurück auf dieselbe Brille.
///
/// visionOS weist Verbindungen ab, die ein Gerät zu seinen eigenen Entwicklerdiensten aufbaut (Installieren,
/// Dateien einer App). Über diesen Tunnel kommen sie wie von außen an: Die App verbindet sich mit 10.7.0.1, jedes
/// Paket dorthin läuft hier durch, Absender und Empfänger werden getauscht, und das Paket geht zurück ins System.
/// Die Prüfsummen bleiben gültig, weil beide Adressen in ihnen nur als Summe vorkommen.
///
/// Es verlässt kein Paket die Brille: Der Tunnel bekommt nur die eine Adresse 10.7.0.1 zugeleitet.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let own = "10.7.0.0", peer = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peer)
        let ipv4 = NEIPv4Settings(addresses: [Self.own], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.peer, subnetMask: "255.255.255.255")]
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil { self?.pump() }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    private func pump() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var turned: [Data] = [], kinds: [NSNumber] = []
            for (packet, kind) in zip(packets, protocols) where packet.count >= 20 && packet[packet.startIndex] >> 4 == 4 {
                var packet = packet
                let start = packet.startIndex
                for offset in 0 ..< 4 { packet.swapAt(start + 12 + offset, start + 16 + offset) }
                turned.append(packet)
                kinds.append(kind)
            }
            if !turned.isEmpty { self.packetFlow.writePackets(turned, withProtocols: kinds) }
            self.pump()
        }
    }
}
