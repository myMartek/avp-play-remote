import SwiftUI
import UniformTypeIdentifiers

/// Der Team-Schlüssel für das Apple-Entwicklerkonto: eine Anleitung, wie man ihn anlegt, und die drei Angaben dazu.
///
/// Mit ihm holt die Brille selbst bei Apple, was eine Signatur braucht (Zertifikat, App-Kennung, Profil). Er bleibt
/// im privaten Bereich dieser App und geht nur an Apple.
struct AppleKeySetup: View {
    @Environment(RemoteClient.self) private var client
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var keyText: String?
    @State private var keyName: String?
    @State private var picking = false
    @State private var checking = false
    @State private var problem: String?
    @State private var stored = AppleKeySetup.storedKeyID()

    private static var folder: URL { LocalBackend.home }

    private static func storedKeyID() -> String? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("asc-key.p8").path),
              let data = try? Data(contentsOf: folder.appendingPathComponent("asc.json")),
              let facts = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return facts["keyID"]
    }

    private var cleanKeyID: String { keyID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var cleanIssuerID: String { issuerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    private var complete: Bool {
        cleanKeyID.count == 10 && cleanKeyID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && UUID(uuidString: cleanIssuerID) != nil && keyText != nil
    }

    var body: some View {
        if let stored {
            Section {
                LabeledContent(L("Key ID", "Schlüssel-ID"), value: stored)
                Button(L("Remove the Key from This Headset", "Schlüssel von dieser Brille entfernen"), role: .destructive) { remove() }
            } header: {
                Text(L("Apple developer account", "Apple-Entwicklerkonto"))
            } footer: {
                Text(L("With this team key the headset gets certificates and profiles from Apple itself. It stays in this app and is sent only to Apple. To end its use for good, revoke the key at App Store Connect.",
                       "Mit diesem Team-Schlüssel holt die Brille Zertifikate und Profile selbst bei Apple. Er bleibt in dieser App und geht nur an Apple. Um ihn ganz außer Dienst zu nehmen, widerrufe ihn bei App Store Connect."))
            }
        } else {
            Section {
                step(1, L("You need a paid Apple Developer Program membership. A free Apple account cannot do this.",
                          "Du brauchst eine bezahlte Mitgliedschaft im Apple Developer Program. Mit einem kostenlosen Apple-Account geht das nicht."))
                step(2, L("In a browser, open App Store Connect and go to Users and Access › Integrations › App Store Connect API › Team Keys. The first time, Apple asks you to request access there.",
                          "Öffne in einem Browser App Store Connect und gehe zu Benutzer und Zugriff › Integrationen › App Store Connect API › Team-Schlüssel. Beim ersten Mal lässt Apple dich dort den Zugriff anfordern."))
                Link(L("Open App Store Connect", "App Store Connect öffnen"), destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!)
                step(3, L("Create a key with “+”: any name, access “App Manager”.",
                          "Lege mit „+“ einen Schlüssel an: Name beliebig, Zugriff „App Manager“."))
                step(4, L("Download the key file (AuthKey_….p8). Apple offers it only once. Save it to iCloud Drive or to this Apple Vision Pro, so the Files app can reach it.",
                          "Lade die Schlüsseldatei (AuthKey_….p8) herunter. Apple bietet sie nur einmal an. Sichere sie in iCloud Drive oder auf dieser Apple Vision Pro, damit die Dateien-App sie erreicht."))
                step(5, L("Enter the two IDs from that page below and choose the file.",
                          "Trage unten die beiden IDs von dieser Seite ein und wähle die Datei."))
            } header: {
                Text(L("Connect your Apple developer account", "Apple-Entwicklerkonto verbinden"))
            } footer: {
                Text(L("Games have to be signed for your headset. With a team key, this headset gets what a signature needs from Apple itself: a certificate, an app identifier and a profile per game.",
                       "Spiele müssen für deine Brille signiert werden. Mit einem Team-Schlüssel holt diese Brille selbst bei Apple, was eine Signatur braucht: ein Zertifikat, je Spiel eine App-Kennung und ein Profil."))
            }
            Section {
                TextField(L("Key ID (10 characters, in the key's row)", "Schlüssel-ID (10 Zeichen, in der Zeile des Schlüssels)"), text: $keyID)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField(L("Issuer ID (above the list of keys)", "Issuer-ID (über der Liste der Schlüssel)"), text: $issuerID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(keyName ?? L("Choose the Key File (.p8) …", "Schlüsseldatei (.p8) wählen …"), systemImage: keyName == nil ? "doc.badge.plus" : "doc.fill") { picking = true }
                if let problem { Text(problem).foregroundStyle(.orange) }
                Button {
                    save()
                } label: {
                    if checking {
                        HStack(spacing: 10) { ProgressView(); Text(L("Asking Apple …", "Apple wird gefragt …")) }
                    } else {
                        Text(L("Check with Apple and Save", "Bei Apple prüfen und sichern"))
                    }
                }
                .disabled(!complete || checking)
            } footer: {
                Text(L("The key is checked with one harmless request to Apple and then kept in this app. It is sent to Apple only.",
                       "Der Schlüssel wird mit einer harmlosen Anfrage bei Apple geprüft und dann in dieser App aufbewahrt. Er geht nur an Apple."))
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains("BEGIN PRIVATE KEY") else {
                    problem = L("That is not a key file from App Store Connect (AuthKey_….p8).", "Das ist keine Schlüsseldatei aus App Store Connect (AuthKey_….p8).")
                    return
                }
                keyText = text
                keyName = url.lastPathComponent
                problem = nil
                // Der Name der Datei nennt die Schlüssel-ID: AuthKey_<ID>.p8.
                let name = url.deletingPathExtension().lastPathComponent
                if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst(8)) }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "\(number).circle.fill") }
    }

    /// Prüft den Schlüssel in einem eigenen Ordner bei Apple und legt ihn erst danach zu den Sachen der App.
    private func save() {
        guard let keyText, complete else { return }
        checking = true
        problem = nil
        let facts = ["keyID": cleanKeyID, "issuerID": cleanIssuerID]
        Task.detached {
            let files = FileManager.default
            let trial = files.temporaryDirectory.appendingPathComponent("asc-trial-\(UUID().uuidString)")
            defer { try? files.removeItem(at: trial) }
            var failure: String?
            do {
                try files.createDirectory(at: trial, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: facts).write(to: trial.appendingPathComponent("asc.json"))
                try Data(keyText.utf8).write(to: trial.appendingPathComponent("asc-key.p8"))
                // Eine Frage, die nichts ändert: die App-Kennungen des Teams, höchstens eine.
                _ = try AppleAPI(folder: trial).call("GET", "bundleIds", query: ["limit": "1"])
                try files.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                for name in ["asc.json", "asc-key.p8"] {
                    let target = Self.folder.appendingPathComponent(name)
                    try? files.removeItem(at: target)
                    try files.copyItem(at: trial.appendingPathComponent(name), to: target)
                    try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                }
            } catch let error as AppleAPIFailure {
                failure = error.status == 401
                    ? L("Apple does not accept this key. Check the key ID, the issuer ID and the file; all three must belong to the same key.",
                        "Apple nimmt diesen Schlüssel nicht an. Prüfe Schlüssel-ID, Issuer-ID und Datei; alle drei müssen zum selben Schlüssel gehören.")
                    : error.status == 403
                    ? L("Apple accepts the key, but it may not manage certificates and profiles. Create a team key with the access “App Manager”.",
                        "Apple nimmt den Schlüssel an, aber er darf keine Zertifikate und Profile verwalten. Lege einen Team-Schlüssel mit dem Zugriff „App Manager“ an.")
                    : "\(error)"
            } catch {
                failure = L("The key file could not be read: ", "Die Schlüsseldatei ließ sich nicht lesen: ") + error.localizedDescription
            }
            await MainActor.run { [failure] in
                checking = false
                problem = failure
                if failure == nil {
                    stored = Self.storedKeyID()
                    self.keyText = nil
                    client.localRefresh()
                }
            }
        }
    }

    private func remove() {
        for name in ["asc.json", "asc-key.p8"] { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(name)) }
        stored = nil
        keyID = ""
        issuerID = ""
        keyName = nil
        client.localRefresh()
    }
}
