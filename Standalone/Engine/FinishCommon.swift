import Foundation

/// Why an app could not be finished. Shared by both finishers: the one for a game from an APK (`Finish`) and the one
/// for a game whose program was built on a Mac (`FinishMacho`).
struct FinishFailure: Error, CustomStringConvertible {
    let description: String
}

/// How a finished app is numbered, as AVP Play does it on the Mac (`AppStamp`), so that both name a build alike.
enum Stamp {
    /// AVP Play's AppStamp.short: the game's version cut to three numbers ("1.40.8_7379" → "1.40.8").
    static func short(_ name: String) -> String {
        var tokens: [String] = [], current = ""
        for character in name {
            if character.isASCII, character.isNumber || character == "." {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        for token in tokens {
            let parts = token.split(separator: ".").map(String.init).prefix(3)
            if !parts.isEmpty, parts.allSatisfy({ $0.count <= 9 }) { return parts.joined(separator: ".") }
        }
        return "1.0"
    }
}
