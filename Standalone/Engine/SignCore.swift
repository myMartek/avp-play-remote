import Foundation
import ProbeSign

struct SignFailure: Error, CustomStringConvertible {
    let description: String
}

/// Signing without Apple's `codesign` and without a keychain: `identity` gets what a signature needs from Apple
/// (certificate, app identifier, profile), `sign` signs a finished app with it and packs it for installing.
enum SignCore {
    struct Signed {
        let package: URL
        let bundleID: String
        let build: String
        /// The name on the certificate that signed, as the device reports it for an installed app.
        let signer: String
    }

    /// The memory capabilities the game apps are signed with (Klepton.entitlements), by Apple's names.
    static let memoryCapabilities = ["INCREASED_MEMORY_LIMIT", "EXTENDED_VIRTUAL_ADDRESSING"]

    private static func timed<T>(_ what: String, _ log: (String) -> Void, _ body: () throws -> T) throws -> T {
        let start = Date()
        do {
            let value = try body()
            log(String(format: "ok   %@ (%.2f s)", what, Date().timeIntervalSince(start)))
            return value
        } catch {
            throw SignFailure(description: "\(what) failed: \(error)")
        }
    }

    // MARK: Apple's side

    /// Leaves `key.pem`, `certificate.der`, `certificate.id` and `profile.mobileprovision` in `state`.
    /// A certificate from an earlier run is used again as long as Apple still lists it: Apple issues one development
    /// certificate per access key and refuses a second.
    static func identity(api: AppleAPI, state: URL, bundleID: String, renew: Bool = false, log: @escaping (String) -> Void) throws {
        let files = FileManager.default
        let keyFile = state.appendingPathComponent("key.pem"), certificateFile = state.appendingPathComponent("certificate.der")
        let idFile = state.appendingPathComponent("certificate.id")

        var certificateID = (try? String(contentsOf: idFile, encoding: .utf8)) ?? ""
        if renew, !certificateID.isEmpty {
            // Only the certificate this test made itself: its number is the one this folder remembers.
            _ = try timed("certificate \(certificateID) from the earlier run revoked at Apple", log) {
                try api.call("DELETE", "certificates/\(certificateID)")
            }
            try? files.removeItem(at: idFile)
            certificateID = ""
        }
        if !certificateID.isEmpty, files.fileExists(atPath: keyFile.path), files.fileExists(atPath: certificateFile.path),
           (try? api.call("GET", "certificates/\(certificateID)")) != nil {
            log("     certificate \(certificateID) from an earlier run is still valid at Apple")
        } else {
            let requestFile = state.appendingPathComponent("request.pem")
            _ = try timed("new key and certificate request made on this device", log) {
                try rust { probe_sign_new_key(keyFile.path, requestFile.path, $0, $1) }
            }
            let created = try timed("Apple issued a development certificate", log) {
                try api.create("certificates", attributes: [
                    "certificateType": "DEVELOPMENT", "csrContent": String(contentsOf: requestFile, encoding: .utf8),
                ])
            }
            guard let content = created.attribute("certificateContent").flatMap({ Data(base64Encoded: $0) }) else {
                throw SignFailure(description: "Apple's answer carried no certificate")
            }
            try content.write(to: certificateFile)
            certificateID = created.id
            try certificateID.write(to: idFile, atomically: true, encoding: .utf8)
            log("     certificate \(certificateID), valid until \(created.attribute("expirationDate") ?? "?")")
        }

        let identifier = try timed("app identifier \(bundleID)", log) { () -> [String: Any] in
            if let known = try api.list("bundleIds", query: ["filter[identifier]": bundleID]).first(where: {
                $0.attribute("identifier") == bundleID
            }) { return known }
            // New to Apple. The documented interface cannot give an identifier the memory capabilities, so it is
            // created the way Xcode's automatic signing does it (AppleAPI.xcode); the documented one is the fallback.
            // Named the way Xcode names the identifiers it makes, so that both look alike in the developer portal.
            let name = "XC " + bundleID.map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            log("     Apple did not know \(bundleID) yet; creating it")
            if let team = try api.list("bundleIds").compactMap({ $0.attribute("seedId") }).first {
                do {
                    let created = try api.createIdentifier(bundleID, name: name, team: team, capabilities: memoryCapabilities)
                    log("     created through the interface Xcode uses, with the memory capabilities")
                    return created
                } catch {
                    log("     the interface Xcode uses refused (\(error)); creating it the documented way, without them")
                }
            }
            return try api.create("bundleIds", attributes: ["identifier": bundleID, "name": name, "platform": "IOS"])
        }
        // Only read: Apple's interface has no way to switch the memory capabilities on (they are not in its list).
        let capabilities = try api.list("bundleIds/\(identifier.id)/bundleIdCapabilities", limit: false)
            .compactMap { $0.attribute("capabilityType") }.sorted()
        log("     capabilities Apple lists for it: \(capabilities.isEmpty ? "none" : capabilities.joined(separator: ", "))")

        let devices = try timed("devices of the team read", log) {
            // Only the headsets: an Apple TV in the list makes Apple refuse the whole profile.
            try api.list("devices", query: ["filter[status]": "ENABLED"]).filter { $0.attribute("deviceClass") == "APPLE_VISION_PRO" }
        }
        log("     \(devices.count) Apple Vision Pro go into the profile")

        let name = "AVP Play Remote \(bundleID)"
        for old in try api.list("profiles", query: ["filter[name]": name]) where old.attribute("name") == name {
            try api.call("DELETE", "profiles/\(old.id)")
        }
        let profile = try timed("Apple issued a provisioning profile", log) {
            try api.create("profiles", attributes: ["name": name, "profileType": "IOS_APP_DEVELOPMENT"], relationships: [
                "bundleId": AppleAPI.link("bundleIds", identifier.id),
                "certificates": AppleAPI.links("certificates", [certificateID]),
                "devices": AppleAPI.links("devices", devices.map(\.id)),
            ])
        }
        guard let content = profile.attribute("profileContent").flatMap({ Data(base64Encoded: $0) }) else {
            throw SignFailure(description: "Apple's answer carried no profile")
        }
        try content.write(to: state.appendingPathComponent("profile.mobileprovision"))
    }

    // MARK: this device's side

    /// Signs the app in `root`/Payload with what `identity` left in `state`, and packs `root` into a package.
    /// `wanted` is Klepton's entitlements file: the signature gets those of its entries the profile grants.
    static func sign(root: URL, bundleID: String, wanted: URL?, state: URL, work: URL, log: @escaping (String) -> Void) throws -> Signed {
        let files = FileManager.default
        let payload = root.appendingPathComponent("Payload")
        guard let appName = try files.contentsOfDirectory(atPath: payload.path).first(where: { $0.hasSuffix(".app") }) else {
            throw SignFailure(description: "there is no app to sign")
        }
        let app = payload.appendingPathComponent(appName)

        let profileData = try Data(contentsOf: state.appendingPathComponent("profile.mobileprovision"))
        let profile = try profilePlist(profileData)
        guard let team = (profile["TeamIdentifier"] as? [String])?.first, let granted = profile["Entitlements"] as? [String: Any] else {
            throw SignFailure(description: "the profile names no team or no entitlements")
        }

        let infoFile = app.appendingPathComponent("Info.plist")
        guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoFile), format: nil) as? [String: Any] else {
            throw SignFailure(description: "the app's Info.plist is not readable")
        }
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw SignFailure(description: "the app is \(info["CFBundleIdentifier"] ?? "?"), not \(bundleID)")
        }
        // The one Info.plist value that depends on who signs: the keychain group AVP Play's apps share.
        if info["KLSharedKeychainGroup"] != nil {
            info["KLSharedKeychainGroup"] = "\(team).avpplay.shared"
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: infoFile)
        }
        let build = info["CFBundleVersion"] as? String ?? "?"
        try profileData.write(to: app.appendingPathComponent("embedded.mobileprovision"))

        var entitlements: [String: Any] = ["get-task-allow": granted["get-task-allow"] as? Bool ?? true]
        if let wanted {
            // Klepton's file is written for Xcode, with its two variables.
            let text = try String(contentsOf: wanted, encoding: .utf8)
                .replacingOccurrences(of: "$(AppIdentifierPrefix)", with: "\(team).")
                .replacingOccurrences(of: "$(PRODUCT_BUNDLE_IDENTIFIER)", with: bundleID)
            guard let list = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any] else {
                throw SignFailure(description: "the wanted entitlements are not readable")
            }
            var left: [String] = []
            for (key, value) in list {
                if granted[key] == nil { left.append(key) } else { entitlements[key] = value }
            }
            if !left.isEmpty { log("     not granted by the profile, left out: \(left.sorted().joined(separator: ", "))") }
        }
        entitlements["application-identifier"] = "\(team).\(bundleID)"
        entitlements["com.apple.developer.team-identifier"] = team
        let entitlementsFile = work.appendingPathComponent("signed.entitlements")
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: entitlementsFile)

        let signer = try timed("signed on this device", log) {
            try rust {
                probe_sign_app(app.path, state.appendingPathComponent("key.pem").path,
                               state.appendingPathComponent("certificate.der").path, entitlementsFile.path, $0, $1)
            }
        }
        let package = work.appendingPathComponent("signed.ipa")
        try timed("package packed", log) { try Zip.pack(folder: root, to: package) }
        return Signed(package: package, bundleID: bundleID, build: build,
                      signer: signer.components(separatedBy: ", team ").first ?? signer)
    }

    /// A profile is a signed envelope around a property list; the list sits in it as plain text.
    private static func profilePlist(_ data: Data) throws -> [String: Any] {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
              let plist = try PropertyListSerialization.propertyList(from: data[start.lowerBound ..< end.upperBound], format: nil)
              as? [String: Any] else {
            throw SignFailure(description: "the profile's contents are not readable")
        }
        return plist
    }

    /// Calls one of the signer's functions and returns its message, or throws it.
    private static func rust(_ call: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws -> String {
        var message = [CChar](repeating: 0, count: 2048)
        let code = message.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
        let text = String(cString: message)
        if code != 0 { throw SignFailure(description: text.isEmpty ? "code \(code)" : text) }
        return text
    }
}
