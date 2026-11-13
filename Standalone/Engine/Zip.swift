import Compression
import Foundation
import zlib

struct ZipFailure: Error, CustomStringConvertible {
    let description: String
}

/// Just enough of the zip format for an app package: unpack one (stored or deflated entries), and pack a folder
/// without compression. Unix permissions are kept both ways, because the program inside has to stay executable.
/// No zip64: nothing here is over 4 GB.
enum Zip {
    /// Unpacks the archive into `folder`; with `only`, just the entries it says yes to.
    static func unpack(_ archive: URL, to folder: URL, only wanted: ((String) -> Bool)? = nil) throws {
        let files = FileManager.default
        try walk(archive) { entry, content in
            guard wanted?(entry.name) ?? true else { return }
            guard !entry.name.split(separator: "/").contains(".."), !entry.name.hasPrefix("/") else {
                throw ZipFailure(description: "the archive names a path outside its folder: \(entry.name)")
            }
            let target = folder.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                return
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try content()
            if entry.mode & 0o170000 == 0o120000 {
                try files.createSymbolicLink(atPath: target.path, withDestinationPath: String(decoding: data, as: UTF8.self))
                return
            }
            try data.write(to: target)
            if entry.mode & 0o777 != 0 {
                try files.setAttributes([.posixPermissions: entry.mode & 0o777], ofItemAtPath: target.path)
            }
        }
    }

    /// One entry's contents, or nil if the archive has no entry of that name.
    static func data(of name: String, in archive: URL) throws -> Data? {
        var found: Data?
        try walk(archive) { entry, content in
            if entry.name == name, found == nil { found = try content() }
        }
        return found
    }

    /// The names of all entries.
    static func names(in archive: URL) throws -> [String] {
        var names: [String] = []
        try walk(archive) { entry, _ in names.append(entry.name) }
        return names
    }

    struct Entry {
        let name: String
        let mode: Int
        /// The entry's size once unpacked.
        let size: Int
    }

    /// Calls `body` for every entry whose name starts with `prefix`, with a function that unpacks it when asked.
    static func forEach(in archive: URL, prefix: String, _ body: (Entry, @escaping () throws -> Data) throws -> Void) throws {
        try walk(archive) { entry, content in
            if entry.name.hasPrefix(prefix), !entry.name.hasSuffix("/") { try body(entry, content) }
        }
    }

    /// Calls `body` for every entry, with a function that unpacks the entry's contents when asked.
    private static func walk(_ archive: URL, _ body: (Entry, @escaping () throws -> Data) throws -> Void) throws {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        var end = data.count - 22
        while end >= 0, data.u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0 else { throw ZipFailure(description: "\(archive.lastPathComponent) is not a zip archive") }
        let count = Int(data.u16(end + 10))
        var offset = Int(data.u32(end + 16))
        guard count != 0xFFFF, offset != 0xFFFF_FFFF else {
            throw ZipFailure(description: "\(archive.lastPathComponent) is a zip64 archive (over 4 GB or 65535 entries), which is not handled")
        }
        for _ in 0 ..< count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x0201_4B50 else {
                throw ZipFailure(description: "the archive's list of contents is damaged")
            }
            let method = data.u16(offset + 10)
            let packed = Int(data.u32(offset + 20)), size = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let skip = Int(data.u16(offset + 30)) + Int(data.u16(offset + 32))
            let mode = Int(data.u32(offset + 38) >> 16), local = Int(data.u32(offset + 42))
            let name = String(decoding: data[offset + 46 ..< offset + 46 + nameLength], as: UTF8.self)
            offset += 46 + nameLength + skip
            try body(Entry(name: name, mode: mode, size: size)) {
                let start = local + 30 + Int(data.u16(local + 26)) + Int(data.u16(local + 28))
                guard start + packed <= data.count else { throw ZipFailure(description: "\(name) is cut off") }
                let body = data.subdata(in: start ..< start + packed)
                switch method {
                case 0: return body
                case 8: return try inflate(body, to: size, name: name)
                default: throw ZipFailure(description: "\(name) is packed with method \(method), which is not handled")
                }
            }
        }
    }

    private static func inflate(_ body: Data, to size: Int, name: String) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { target in
            body.withUnsafeBytes { source in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, size,
                                          source.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipFailure(description: "\(name) did not unpack to its full size") }
        return output
    }

    /// Packs everything in `folder`, with paths relative to it, uncompressed.
    static func pack(folder: URL, to archive: URL) throws {
        let files = FileManager.default
        files.createFile(atPath: archive.path, contents: nil)
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        var directory = Data(), position = 0, count = 0
        for path in try files.subpathsOfDirectory(atPath: folder.path).sorted() {
            let source = folder.appendingPathComponent(path)
            let attributes = try files.attributesOfItem(atPath: source.path)
            let permissions = (attributes[.posixPermissions] as? Int) ?? 0o644
            var name = path, mode = 0o100000 | permissions, content = Data()
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: name += "/"; mode = 0o040000 | permissions
            case .typeSymbolicLink?:
                content = Data(try files.destinationOfSymbolicLink(atPath: source.path).utf8)
                mode = 0o120777
            default: content = try Data(contentsOf: source, options: .mappedIfSafe)
            }
            let nameBytes = Data(name.utf8)
            let checksum = content.withUnsafeBytes { bytes in
                UInt32(crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count)))
            }
            // Shared by both headers: version 2.0, UTF-8 names, stored, a fixed date (2026-11-13), sizes.
            var common = Data()
            common.put16(20); common.put16(0x0800); common.put16(0); common.put16(0)
            common.put16(UInt16((2026 - 1980) << 9 | 11 << 5 | 13))
            common.put32(checksum); common.put32(UInt32(content.count)); common.put32(UInt32(content.count))
            common.put16(UInt16(nameBytes.count)); common.put16(0)

            var header = Data()
            header.put32(0x0403_4B50); header.append(common); header.append(nameBytes)
            output.write(header); output.write(content)

            directory.put32(0x0201_4B50); directory.put16(3 << 8 | 20)          // made on Unix
            directory.append(common)
            directory.put16(0); directory.put16(0); directory.put16(0)          // comment, disk, internal attributes
            directory.put32(UInt32(mode) << 16); directory.put32(UInt32(position))
            directory.append(nameBytes)
            position += header.count + content.count
            count += 1
        }
        var tail = Data()
        tail.put32(0x0605_4B50); tail.put16(0); tail.put16(0); tail.put16(UInt16(count)); tail.put16(UInt16(count))
        tail.put32(UInt32(directory.count)); tail.put32(UInt32(position)); tail.put16(0)
        output.write(directory); output.write(tail)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    mutating func put16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(value & 0xFFFF)); put16(UInt16(value >> 16)) }
}
