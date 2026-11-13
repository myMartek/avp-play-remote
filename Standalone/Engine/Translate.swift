import CryptoKit
import Foundation
import KleptonLD

struct TranslateFailure: Error, CustomStringConvertible {
    let description: String
}

/// A game's own code, as it comes out of its Android package, and what to check the translation against.
struct Guest {
    /// The libraries (`<name>.so`): a folder holding them, or a zip with them at its top level.
    var sources: URL
    /// The game's name in Klepton's target list. The translator looks at it (KLEPTON_TARGET).
    var target: String
    /// The libraries to translate, without ".so".
    var libraries: [String]
    /// Library name → SHA-256 of what a Mac made of it. Empty: nothing to compare with.
    var expected: [String: String]
}

/// Klepton's translation step (visionos/mkguest.sh) without a Mac: each Android library becomes a framework in the
/// app, with a Mach-O that can be signed. The translator is Klepton's own tools/klepton_ld.c, called as a function.
enum Translate {
    /// Puts one framework per library into `app`/Frameworks. Returns how many matched `expected`.
    @discardableResult
    static func run(_ guest: Guest, into app: URL, scratch: URL, log: (String) -> Void) throws -> Int {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        files.fileExists(atPath: guest.sources.path, isDirectory: &isFolder)
        let unpacked = scratch.appendingPathComponent("sources")
        let sources = isFolder.boolValue ? guest.sources : unpacked
        if !isFolder.boolValue { try Zip.unpack(guest.sources, to: unpacked) }
        defer { try? files.removeItem(at: unpacked) }
        let errorLog = scratch.appendingPathComponent("translator-errors.txt")
        setenv("KLEPTON_TARGET", guest.target, 1)

        var bytes = 0, matching = 0, different: [String] = []
        for library in guest.libraries {
            // The names mkguest.sh uses: no '+' in a framework's name, only letters, digits, '.' and '-' in its identifier.
            let name = library.replacingOccurrences(of: "+", with: "x")
            let identifier = String(library.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" })
            let framework = app.appendingPathComponent("Frameworks/\(name).framework")
            guard !files.fileExists(atPath: framework.path) else {
                throw TranslateFailure(description: "the template already holds \(name).framework; nothing would be proven")
            }
            try files.createDirectory(at: framework, withIntermediateDirectories: true)
            let output = framework.appendingPathComponent(name)
            let arguments = ["klepton-ld", sources.appendingPathComponent("\(library).so").path, "-o", output.path,
                             "--platform", "visionos", "--install-name", "@rpath/\(name).framework/\(name)", "--quiet"]
            var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            let code = pointers.withUnsafeMutableBufferPointer { klepton_ld_run(Int32(arguments.count), $0.baseAddress, errorLog.path) }
            guard code == 0 else {
                let said = (try? String(contentsOf: errorLog, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw TranslateFailure(description: "translating \(library) failed: \(said.isEmpty ? "code \(code)" : said)")
            }
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleExecutable</key><string>\(name)</string>
              <key>CFBundleIdentifier</key><string>dev.klepton.guest.\(identifier)</string>
              <key>CFBundleName</key><string>\(name)</string>
              <key>CFBundlePackageType</key><string>FMWK</string>
              <key>CFBundleShortVersionString</key><string>1.0</string>
              <key>CFBundleVersion</key><string>1</string>
              <key>MinimumOSVersion</key><string>26.0</string>
            </dict></plist>

            """.utf8).write(to: framework.appendingPathComponent("Info.plist"))

            let translated = try Data(contentsOf: output, options: .mappedIfSafe)
            bytes += translated.count
            if let expected = guest.expected[library] {
                let digest = SHA256.hash(data: translated).map { String(format: "%02x", $0) }.joined()
                if digest == expected { matching += 1 } else { different.append(library) }
            }
        }
        try? files.removeItem(at: errorLog)
        log("     \(guest.libraries.count) libraries translated here, \(bytes) bytes")
        if !guest.expected.isEmpty {
            log("     \(matching) of \(guest.libraries.count) are byte for byte what the Mac made of them")
            if !different.isEmpty { throw TranslateFailure(description: "translated differently from the Mac: \(different.joined(separator: ", "))") }
        }
        return matching
    }
}
