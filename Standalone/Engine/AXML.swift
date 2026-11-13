import Foundation

// Taken from AVP Play (core/Sources/AVPPlayCore/ApkUnpacker.swift, MIT, same author): the decoder for Android's
// binary XML, unchanged except for the error type. The Klepton runtime reads the manifest as text.

struct AXMLFailure: Error, CustomStringConvertible {
    let description: String
}

/// Binäres Android-XML (AXML) -> Text, in der Form, die die Runtime liest:
/// `package="…"`, `<meta-data android:name="…" android:value="…"/>`, `<uses-permission android:name="…"/>`.
enum AXML {
    static let androidNS = "http://schemas.android.com/apk/res/android"
    // Nur für Builds, die die Attributnamen aus dem Stringpool entfernt haben.
    static let attributeIDs: [UInt32: String] = [0x01010003: "name", 0x01010024: "value", 0x01010025: "resource",
                                                 0x0101021b: "versionCode", 0x0101021c: "versionName", 0x01010001: "label"]

    struct Reader {
        let data: Data
        func u8(_ o: Int) throws -> Int { try check(o, 1); return Int(data[data.startIndex + o]) }
        func u16(_ o: Int) throws -> Int { try check(o, 2); return try u8(o) | (try u8(o + 1) << 8) }
        func u32(_ o: Int) throws -> UInt32 {
            try check(o, 4)
            return UInt32(try u16(o)) | (UInt32(try u16(o + 2)) << 16)
        }
        func bytes(_ o: Int, _ n: Int) throws -> Data {
            try check(o, n)
            return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + n))
        }
        func check(_ o: Int, _ n: Int) throws {
            guard o >= 0, n >= 0, o + n <= data.count else { throw AXMLFailure(description: "data ends unexpectedly") }
        }
    }

    static func stringPool(_ r: Reader, at off: Int) throws -> [String] {
        let headerSize = try r.u16(off + 2)
        let count = Int(try r.u32(off + 8))
        let utf8 = (try r.u32(off + 16) & 0x100) != 0
        let stringsStart = Int(try r.u32(off + 20))
        guard count < 1_000_000 else { throw AXMLFailure(description: "string pool too large") }
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var p = off + stringsStart + Int(try r.u32(off + headerSize + 4 * i))
            if utf8 {
                if try r.u8(p) & 0x80 != 0 { p += 1 }      // Zeichenanzahl (1 oder 2 Bytes), nicht gebraucht
                p += 1
                var n = try r.u8(p); p += 1
                if n & 0x80 != 0 { n = ((n & 0x7F) << 8) | (try r.u8(p)); p += 1 }
                out.append(String(decoding: try r.bytes(p, n), as: UTF8.self))
            } else {
                var n = try r.u16(p); p += 2
                if n & 0x8000 != 0 { n = ((n & 0x7FFF) << 16) | (try r.u16(p)); p += 2 }
                let raw = try r.bytes(p, 2 * n)
                out.append(String(decoding: stride(from: 0, to: raw.count, by: 2).map {
                    UInt16(raw[raw.startIndex + $0]) | (UInt16(raw[raw.startIndex + $0 + 1]) << 8)
                }, as: UTF16.self))
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Kürzeste Dezimaldarstellung, die denselben 32-Bit-Wert ergibt (wie apktool: 2.1, nicht 2.0999999).
    static func floatText(_ bits: UInt32) -> String { "\(Float(bitPattern: bits))" }

    static func typedValue(type: Int, data: UInt32, raw: UInt32, strings: [String]) -> String {
        func string(_ i: UInt32) -> String { Int(i) < strings.count ? strings[Int(i)] : "" }
        if type == 0x03 { return string(raw != 0xFFFF_FFFF ? raw : data) }
        if raw != 0xFFFF_FFFF, type != 0x01, type != 0x02 { return string(raw) }
        switch type {
        case 0x01: return String(format: "@0x%08x", data)       // Referenz, nicht aufgelöst
        case 0x02: return String(format: "?0x%08x", data)
        case 0x12: return data != 0 ? "true" : "false"
        case 0x11: return String(format: "0x%x", data)
        case 0x04: return floatText(data)
        case 0x10...0x1F: return String(Int32(bitPattern: data))
        default: return String(format: "0x%08x", data)
        }
    }

    static func decode(_ data: Data) throws -> (text: String, package: String?, versionCode: String?, versionName: String?) {
        let r = Reader(data: data)
        guard data.count >= 8, try r.u16(0) == 0x0003 else { throw AXMLFailure(description: "not binary XML") }
        var strings: [String] = [], resourceMap: [UInt32] = []
        var prefixes: [String: String] = [:], pendingNS: [(String, String)] = []
        var lines: [String] = [], depth = 0
        var package: String?, versionCode: String?, versionName: String?
        var off = 8
        while off + 8 <= data.count {
            let type = try r.u16(off), headerSize = try r.u16(off + 2), size = Int(try r.u32(off + 4))
            guard size >= 8, off + size <= data.count else { throw AXMLFailure(description: "chunk with an invalid size") }
            func string(_ i: UInt32) -> String { Int(i) < strings.count ? strings[Int(i)] : "" }
            switch type {
            case 0x0001:
                strings = try stringPool(r, at: off)
            case 0x0180:
                resourceMap = try (0..<((size - headerSize) / 4)).map { try r.u32(off + headerSize + 4 * $0) }
            case 0x0100:
                let prefix = string(try r.u32(off + headerSize)), uri = string(try r.u32(off + headerSize + 4))
                prefixes[uri] = prefix
                pendingNS.append((prefix, uri))
            case 0x0102:
                let tag = string(try r.u32(off + headerSize + 4))
                let attrStart = try r.u16(off + headerSize + 8), attrSize = try r.u16(off + headerSize + 10)
                let attrCount = try r.u16(off + headerSize + 12)
                var parts = ["<\(tag)"]
                for (p, u) in pendingNS { parts.append("xmlns:\(p)=\"\(u)\"") }
                pendingNS = []
                for i in 0..<attrCount {
                    let a = off + headerSize + attrStart + i * attrSize
                    let ns = try r.u32(a), nameIndex = try r.u32(a + 4), raw = try r.u32(a + 8)
                    let valueType = try r.u8(a + 15), valueData = try r.u32(a + 16)
                    var name = string(nameIndex)
                    if name.isEmpty, Int(nameIndex) < resourceMap.count {
                        let id = resourceMap[Int(nameIndex)]
                        name = attributeIDs[id] ?? String(format: "attr_0x%08x", id)
                    }
                    var uri = ns != 0xFFFF_FFFF ? string(ns) : ""
                    if uri.isEmpty, Int(nameIndex) < resourceMap.count, tag != "manifest" { uri = androidNS }
                    let value = typedValue(type: valueType, data: valueData, raw: raw, strings: strings)
                    let qualified = uri.isEmpty ? name : "\(prefixes[uri] ?? "android"):\(name)"
                    parts.append("\(qualified)=\"\(escape(value))\"")
                    if tag == "manifest" {
                        if name == "package" { package = value }
                        if name == "versionCode" { versionCode = value }
                        if name == "versionName" { versionName = value }
                    }
                }
                lines.append(String(repeating: "    ", count: max(depth, 0)) + parts.joined(separator: " ") + ">")
                depth += 1
            case 0x0103:
                depth -= 1
                lines.append(String(repeating: "    ", count: max(depth, 0)) + "</\(string(try r.u32(off + headerSize + 4)))>")
            default:
                break
            }
            off += size
        }
        let text = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\"?>\n" + lines.joined(separator: "\n") + "\n"
        return (text, package, versionCode, versionName)
    }
}
