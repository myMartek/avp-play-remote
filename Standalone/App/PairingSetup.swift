import SwiftUI

/// Die Kopplung der App mit der Brille, auf der sie läuft: Erst mit ihr erreicht die App den Installationsdienst
/// der Brille. Sie entsteht hier, ohne Mac – die Brille bietet das Koppeln an, solange in den Einstellungen die
/// Seite „Entfernte Geräte“ offen ist, zeigt einen Code, und der wird hier eingetippt (`PairingCore`).
///
/// Die Kopplungsdatei bleibt im privaten Bereich dieser App. Im Protokoll steht nie der Code.
@MainActor @Observable
final class PairingFlow {
    enum Phase: Equatable {
        case idle
        /// Der Tunnel geht an und der Kopplungsdienst der Brille wird gesucht.
        case searching
        /// Die Brille zeigt ihren Code; `submit` nimmt, was getippt wird.
        case code
        /// Der Code ist unterwegs, die Kopplung wird geprüft und gesichert.
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var paired = PairingFlow.hasFile
    private var entry: CodeEntry?
    /// Zählt die Versuche: Was ein abgebrochener später meldet, gilt nicht mehr.
    private var attempt = 0

    static let file = LocalBackend.home.appendingPathComponent("pairing.plist")
    static var hasFile: Bool { FileManager.default.fileExists(atPath: file.path) }

    var busy: Bool { phase == .searching || phase == .code || phase == .finishing }

    func start(done: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        attempt += 1
        let run = attempt
        let entry = CodeEntry()
        self.entry = entry
        phase = .searching
        let port = LocalBackend.tunnelPort()
        Task.detached { [weak self] in
            var failure: String?
            do {
                // Die Brille weist eine Verbindung ab, die von ihr selbst kommt: Der Weg führt durch den Tunnel der App.
                try await Tunnel.start()
                let found = PairingCore.find(timeout: 30)
                guard let service = found.port else {
                    throw Stop(found.denied
                        ? L("AVP Play Remote may not look into the local network. Allow it under Settings › Privacy & Security › Local Network and try again.",
                            "AVP Play Remote darf nicht ins lokale Netz sehen. Erlaube es unter Einstellungen › Datenschutz & Sicherheit › Lokales Netzwerk und versuche es noch einmal.")
                        : L("This Apple Vision Pro is not offering to pair. Open Settings › General › Remote Devices, leave that page open and try again.",
                            "Diese Apple Vision Pro bietet das Koppeln nicht an. Öffne Einstellungen › Allgemein › Entfernte Geräte, lass die Seite offen und versuche es noch einmal."))
                }
                let data = try PairingCore.pair(address: "10.7.0.1", port: service, hostName: "AVP Play Remote") {
                    Task { @MainActor [weak self] in self?.codeWanted(run) }
                    return entry.wait(timeout: 300)
                }
                await MainActor.run { [weak self] in self?.sent(run) }
                // Erst prüfen, dann behalten: Mit der neuen Datei muss sich der Tunnel zu den Diensten der Brille öffnen.
                let files = FileManager.default
                let trial = files.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString).plist")
                defer { try? files.removeItem(at: trial) }
                try data.write(to: trial, options: .atomic)
                _ = try DeviceLink(address: "10.7.0.1", port: port, pairingFile: trial.path)
                try files.createDirectory(at: LocalBackend.home, withIntermediateDirectories: true)
                try? files.removeItem(at: PairingFlow.file)
                try files.copyItem(at: trial, to: PairingFlow.file)
                try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: PairingFlow.file.path)
            } catch let stop as Stop {
                failure = stop.text
            } catch {
                failure = entry.cancelled ? "" : L("The pairing did not come about. Check the code and try again, with Settings › General › Remote Devices open.",
                                                   "Die Kopplung ist nicht zustande gekommen. Prüfe den Code und versuche es noch einmal, mit geöffneter Seite Einstellungen › Allgemein › Entfernte Geräte.")
                    + "\n\n\(error)"
            }
            await MainActor.run { [weak self, failure] in
                guard let self, self.attempt == run else { return }
                self.entry = nil
                self.paired = PairingFlow.hasFile
                self.phase = failure.map { $0.isEmpty ? .idle : .failed($0) } ?? .idle
                if failure == nil { done() }
            }
        }
    }

    /// Der Code, wie ihn die Brille zeigt.
    func submit(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard phase == .code, !digits.isEmpty else { return }
        entry?.give(digits)
    }

    func cancel() {
        guard busy else { return }
        attempt += 1
        entry?.cancel()
        entry = nil
        phase = .idle
    }

    func forget() {
        guard !busy else { return }
        try? FileManager.default.removeItem(at: PairingFlow.file)
        paired = false
        phase = .idle
    }

    private func codeWanted(_ run: Int) {
        guard attempt == run, phase == .searching else { return }
        phase = .code
    }

    private func sent(_ run: Int) {
        guard attempt == run else { return }
        phase = .finishing
    }

    private struct Stop: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }
}

/// Reicht den getippten Code an den Faden, der koppelt und darauf wartet.
final class CodeEntry: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?
    private var stopped = false

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func give(_ code: String) {
        lock.lock(); value = code; lock.unlock()
        ready.signal()
    }

    func cancel() {
        lock.lock(); stopped = true; lock.unlock()
        ready.signal()
    }

    /// Der Code; nichts, wenn abgebrochen wurde oder niemand rechtzeitig getippt hat.
    func wait(timeout: TimeInterval) -> String? {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return stopped ? nil : value
    }
}

/// Auf der Seite „Einrichtung“: der Abschnitt zur Kopplung, mit der Anleitung.
struct PairingSetup: View {
    @Environment(RemoteClient.self) private var client
    @State private var flow = PairingFlow()
    @State private var code = ""

    var body: some View {
        Section {
            if flow.paired, !flow.busy {
                LabeledContent(L("This headset", "Diese Brille"), value: L("Paired", "Gekoppelt"))
                Button(L("Pair Again", "Neu koppeln")) { begin() }
                Button(L("Remove the Pairing from This App", "Kopplung aus dieser App entfernen"), role: .destructive) {
                    flow.forget()
                    client.localRefresh()
                }
            } else {
                Text(L("Pair with this headset", "Mit dieser Brille koppeln"))
                    .font(.headline)
                Text(L("To install games, this app uses the headset's own installation service. The headset lets it in once it is paired with it – the same pairing a Mac with Xcode does, only that this app pairs with the headset it runs on.",
                       "Zum Installieren nutzt diese App den Installationsdienst der Brille. Die Brille lässt sie hinein, sobald sie mit ihr gekoppelt ist – dieselbe Kopplung, die ein Mac mit Xcode macht, nur dass sich diese App mit der Brille koppelt, auf der sie läuft."))
                    .foregroundStyle(.secondary)
                step(1, L("Open Settings › General › Remote Devices on this headset and leave that page open, beside this window.",
                          "Öffne auf dieser Brille Einstellungen › Allgemein › Entfernte Geräte und lass die Seite offen, neben diesem Fenster."))
                step(2, L("Tap “Pair” here. The first time, visionOS asks whether AVP Play Remote may add a VPN configuration and look into the local network; both stay on this headset.",
                          "Tippe hier auf „Koppeln“. Beim ersten Mal fragt visionOS, ob AVP Play Remote eine VPN-Konfiguration hinzufügen und ins lokale Netz sehen darf; beides bleibt auf dieser Brille."))
                step(3, L("The headset shows a code. Enter it here.", "Die Brille zeigt einen Code. Gib ihn hier ein."))
                switch flow.phase {
                case .idle, .failed:
                    Button(L("Pair", "Koppeln")) { begin() }
                        .buttonStyle(.borderedProminent)
                case .searching:
                    HStack(spacing: 10) { ProgressView(); Text(L("Looking for the headset's pairing service …", "Der Kopplungsdienst der Brille wird gesucht …")) }
                    Button(L("Cancel", "Abbrechen")) { flow.cancel() }
                case .code:
                    TextField(L("Code the headset shows", "Code, den die Brille zeigt"), text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .onSubmit { flow.submit(code) }
                    Button(L("Send the Code", "Code senden")) { flow.submit(code) }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.filter(\.isNumber).isEmpty)
                    Button(L("Cancel", "Abbrechen")) { flow.cancel() }
                case .finishing:
                    HStack(spacing: 10) { ProgressView(); Text(L("Checking the pairing …", "Die Kopplung wird geprüft …")) }
                }
            }
            if case .failed(let why) = flow.phase {
                Text(why).foregroundStyle(.orange)
            }
        } header: {
            Text(L("Pairing", "Kopplung"))
        } footer: {
            Text(L("The pairing stays in this app on this headset. To end it for good, remove “AVP Play Remote” under Settings › General › Remote Devices.",
                   "Die Kopplung bleibt in dieser App auf dieser Brille. Um sie ganz zu beenden, entferne „AVP Play Remote“ unter Einstellungen › Allgemein › Entfernte Geräte."))
        }
    }

    private func begin() {
        code = ""
        flow.start { client.localRefresh() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "\(number).circle.fill") }
    }
}
