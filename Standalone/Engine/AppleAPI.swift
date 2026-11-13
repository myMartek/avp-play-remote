import CryptoKit
import Foundation

struct AppleAPIFailure: Error, CustomStringConvertible {
    let status: Int
    let detail: String
    var description: String { "Apple answered \(status): \(detail)" }
}

/// Apple's official interface for developer accounts (App Store Connect API), as far as signing needs it:
/// certificates, app identifiers, devices and provisioning profiles. Works with a team key of a paid team.
/// Plain HTTPS with a token this device signs itself, so nothing here needs a Mac.
final class AppleAPI {
    private let keyID: String
    private let issuerID: String
    private let key: P256.Signing.PrivateKey

    /// `folder` holds `asc.json` ({"keyID": "...", "issuerID": "..."}) and the key file `asc-key.p8`.
    init(folder: URL) throws {
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("asc.json")))
        guard let values = settings as? [String: String], let keyID = values["keyID"], let issuerID = values["issuerID"] else {
            throw AppleAPIFailure(status: 0, detail: "asc.json needs keyID and issuerID")
        }
        self.keyID = keyID
        self.issuerID = issuerID
        key = try P256.Signing.PrivateKey(
            pemRepresentation: String(contentsOf: folder.appendingPathComponent("asc-key.p8"), encoding: .utf8))
    }

    /// The documented interface.
    static let official = "https://api.appstoreconnect.apple.com/v1/"
    /// The interface Xcode itself uses when it is given a team key (`xcodebuild -authenticationKeyPath …`). Not
    /// documented. It is here for one thing the documented one refuses: an app identifier with the memory
    /// capabilities. The shape of the call is what Xcode 27.1 sends, read from its own log.
    static let xcode = "https://appstoreconnect.apple.com/xcbuild/v1/"
    /// That interface only creates such an identifier for a client that names an Xcode version.
    static let xcodeVersion = "27.1 (27A9275)"

    /// Creates an app identifier with capabilities switched on, the way Xcode's automatic signing does.
    /// `capabilities` are Apple's names, like "INCREASED_MEMORY_LIMIT".
    func createIdentifier(_ identifier: String, name: String, team: String, capabilities: [String]) throws -> [String: Any] {
        let wanted: [[String: Any]] = capabilities.map {
            ["type": "bundleIdCapabilities", "attributes": ["enabled": true, "settings": [Any]()],
             "relationships": ["capability": AppleAPI.link("capabilities", $0)]]
        }
        let body: [String: Any] = ["data": [
            "type": "bundleIds",
            "attributes": ["teamId": team, "bundleType": "bundle", "seedId": team, "hasExclusiveManagedCapabilities": false,
                           "identifier": identifier, "name": name],
            "relationships": ["bundleIdCapabilities": ["data": wanted]],
        ]]
        guard let created = try call("POST", "bundleIds", body: body, base: AppleAPI.xcode,
                                     headers: ["X-Xcode-Version": AppleAPI.xcodeVersion])["data"] as? [String: Any] else {
            throw AppleAPIFailure(status: 0, detail: "the answer to creating \(identifier) had no entry")
        }
        return created
    }

    private func token() throws -> String {
        func part(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).base64URL
        }
        let now = Int(Date().timeIntervalSince1970)
        let head = try part(["alg": "ES256", "kid": keyID, "typ": "JWT"])
        let body = try part(["iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"])
        let signature = try key.signature(for: Data("\(head).\(body)".utf8)).rawRepresentation.base64URL
        return "\(head).\(body).\(signature)"
    }

    /// One call, waited for. Returns the answer's JSON (empty for answers without one).
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
              base: String = AppleAPI.official, headers: [String: String] = [:]) throws -> [String: Any] {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue(base == AppleAPI.official ? "application/json" : "application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        var result: Result<[String: Any], Error> = .failure(AppleAPIFailure(status: 0, detail: "no answer"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { result = .failure(AppleAPIFailure(status: 0, detail: error.localizedDescription)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            if (200 ..< 300).contains(status) { result = .success(json); return }
            let first = (json["errors"] as? [[String: Any]])?.first
            let detail = [first?["code"], first?["detail"] ?? first?["title"]].compactMap { $0 as? String }.joined(separator: ": ")
            result = .failure(AppleAPIFailure(status: status, detail: detail.isEmpty ? "no details" : detail))
        }.resume()
        done.wait()
        return try result.get()
    }

    /// The entries of a list answer.
    func list(_ path: String, query: [String: String] = [:], limit: Bool = true) throws -> [[String: Any]] {
        var query = query
        if limit { query["limit"] = "200" }     // some lists (an identifier's capabilities) refuse the parameter
        return (try call("GET", path, query: query)["data"] as? [[String: Any]]) ?? []
    }

    /// The created entry (`data`) of a POST.
    func create(_ type: String, attributes: [String: Any], relationships: [String: Any] = [:]) throws -> [String: Any] {
        var data: [String: Any] = ["type": type, "attributes": attributes]
        if !relationships.isEmpty { data["relationships"] = relationships }
        guard let created = try call("POST", type, body: ["data": data])["data"] as? [String: Any] else {
            throw AppleAPIFailure(status: 0, detail: "the answer to creating \(type) had no entry")
        }
        return created
    }

    static func link(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
    static func links(_ type: String, _ ids: [String]) -> [String: Any] { ["data": ids.map { ["type": type, "id": $0] }] }
}

extension Dictionary where Key == String, Value == Any {
    var id: String { self["id"] as? String ?? "" }
    func attribute(_ name: String) -> String? { (self["attributes"] as? [String: Any])?[name] as? String }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
