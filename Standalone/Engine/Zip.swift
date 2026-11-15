import Foundation
import zlib

struct ZipFailure: Error, CustomStringConvertible {
    let description: String
}

/// Just enough of the zip format for an app package: unpack one (stored or deflated entries), and pack a folder
/// without compression. Unix permissions are kept both ways, because the program inside has to stay executable.
/// No zip64: nothing here is over 4 GB.
///
/// Files go through in pieces, in both directions: an entry is never held in memory as a whole when it is written
/// to a file (a game's program can be a few hundred megabytes), and the archive itself is only mapped.
enum Zip {
    /// Unpacks the archive into `folder`; with `only`, just the entries it says yes to.
    static func unpack(_ archive: URL, to folder: URL, only wanted: ((String) -> Bool)? = nil) throws {
        try extract(archive) { entry in
            guard wanted?(entry.name) ?? true else { return nil }
            guard !entry.name.split(separator: "/").contains(".."), !entry.name.hasPrefix("/") else {
                throw ZipFailure(description: "the archive names a path outside its folder: \(entry.name)")
            }
            return folder.appendingPathComponent(entry.name)
        }
    }

    /// Unpacks the entries `place` gives a place to, each to that place: so that parts of an archive can go into
    /// another folder layout. Folders come as entries whose name ends in “/”. `written` hears how many bytes of
    /// files are on disk so far.
    static func extract(_ archive: URL, written: ((Int64) -> Void)? = nil, _ place: (Entry) throws -> URL?) throws {
        let files = FileManager.default
        var total: Int64 = 0
        try walk(archive) { stored in
            guard let target = try place(stored.entry) else { return }
            if stored.entry.name.hasSuffix("/") {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                return
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if stored.entry.mode & 0o170000 == 0o120000 {
                try? files.removeItem(at: target)
                try files.createSymbolicLink(atPath: target.path, withDestinationPath: String(decoding: try stored.contents(), as: UTF8.self))
                return
            }
            try stored.write(to: target)
            if stored.entry.mode & 0o777 != 0 {
                try files.setAttributes([.posixPermissions: stored.entry.mode & 0o777], ofItemAtPath: target.path)
            }
            total += Int64(stored.entry.size)
            written?(total)
        }
    }

    /// One entry's contents, or nil if the archive has no entry of that name.
    static func data(of name: String, in archive: URL) throws -> Data? {
        var found: Data?
        try walk(archive) { stored in
            if stored.entry.name == name, found == nil { found = try stored.contents() }
        }
        return found
    }

    /// The names of all entries.
    static func names(in archive: URL) throws -> [String] {
        try entries(in: archive).map(\.name)
    }

    /// All entries: name, mode and size once unpacked. Nothing is unpacked for it.
    static func entries(in archive: URL) throws -> [Entry] {
        var entries: [Entry] = []
        try walk(archive) { entries.append($0.entry) }
        return entries
    }

    struct Entry {
        let name: String
        let mode: Int
        /// The entry's size once unpacked.
        let size: Int
    }

    /// Calls `body` for every entry whose name starts with `prefix`, with a function that unpacks it when asked.
    static func forEach(in archive: URL, prefix: String, _ body: (Entry, @escaping () throws -> Data) throws -> Void) throws {
        try walk(archive) { stored in
            if stored.entry.name.hasPrefix(prefix), !stored.entry.name.hasSuffix("/") { try body(stored.entry, stored.contents) }
        }
    }

    /// One entry as it lies in the (mapped) archive.
    private struct Stored {
        let entry: Entry
        let archive: Data
        let method: UInt16
        let local: Int
        let packed: Int
        let checksum: UInt32

        private func range() throws -> Range<Int> {
            guard local + 30 <= archive.count else { throw ZipFailure(description: "\(entry.name) is cut off") }
            let start = local + 30 + Int(archive.u16(local + 26)) + Int(archive.u16(local + 28))
            guard start + packed <= archive.count else { throw ZipFailure(description: "\(entry.name) is cut off") }
            return start ..< start + packed
        }

        /// The contents in memory: for the small things (a manifest, a list, a picture).
        func contents() throws -> Data {
            var result = Data(capacity: entry.size)
            try pieces { result.append($0) }
            return result
        }

        /// The contents into a file, piece by piece.
        func write(to target: URL) throws {
            try? FileManager.default.removeItem(at: target)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw ZipFailure(description: "\(target.lastPathComponent) could not be created")
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try pieces { try handle.write(contentsOf: $0) }
        }

        /// Hands out the unpacked contents in pieces of at most a megabyte and checks length and checksum at the end.
        private func pieces(_ body: (Data) throws -> Void) throws {
            let range = try range()
            let piece = 1 << 20
            var sum = crc32(0, nil, 0), produced = 0
            func pass(_ data: Data) throws {
                data.withUnsafeBytes { sum = crc32(sum, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
                produced += data.count
                try body(data)
            }
            switch method {
            case 0:
                var at = range.lowerBound
                while at < range.upperBound {
                    let end = min(at + piece, range.upperBound)
                    try autoreleasepool { try pass(archive.subdata(in: at ..< end)) }
                    at = end
                }
            case 8:
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw ZipFailure(description: "\(entry.name) could not be unpacked")
                }
                defer { inflateEnd(&stream) }
                var buffer = [UInt8](repeating: 0, count: piece)
                var at = range.lowerBound, ended = false
                while !ended {
                    // The packed bytes are read where they lie in the mapped archive, a few megabytes at a time.
                    let end = min(at + 4 * piece, range.upperBound)
                    try archive.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress! + at)
                        stream.avail_in = UInt32(end - at)
                        repeat {
                            var status = Z_OK
                            let made: Int = buffer.withUnsafeMutableBufferPointer { out in
                                stream.next_out = out.baseAddress
                                stream.avail_out = UInt32(piece)
                                status = inflate(&stream, Z_NO_FLUSH)
                                return piece - Int(stream.avail_out)
                            }
                            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                                throw ZipFailure(description: "\(entry.name) is damaged")
                            }
                            if made > 0 { try autoreleasepool { try pass(Data(buffer[0 ..< made])) } }
                            if status == Z_STREAM_END { ended = true; break }
                            if status == Z_BUF_ERROR, made == 0 { break }
                        } while stream.avail_in > 0 || stream.avail_out == 0
                    }
                    at = end
                    if at >= range.upperBound, !ended {
                        // Everything was read and the stream did not end by itself: cut off.
                        guard produced == entry.size else { throw ZipFailure(description: "\(entry.name) did not unpack to its full size") }
                        ended = true
                    }
                }
            default:
                throw ZipFailure(description: "\(entry.name) is packed with method \(method), which is not handled")
            }
            guard produced == entry.size else { throw ZipFailure(description: "\(entry.name) did not unpack to its full size") }
            guard UInt32(truncatingIfNeeded: sum) == checksum else { throw ZipFailure(description: "\(entry.name) is damaged (checksum)") }
        }
    }

    /// Calls `body` for every entry of the archive.
    private static func walk(_ archive: URL, _ body: (Stored) throws -> Void) throws {
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
            let checksum = data.u32(offset + 16)
            let packed = Int(data.u32(offset + 20)), size = Int(data.u32(offset + 24))
            let nameLength = Int(data.u16(offset + 28))
            let skip = Int(data.u16(offset + 30)) + Int(data.u16(offset + 32))
            let mode = Int(data.u32(offset + 38) >> 16), local = Int(data.u32(offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZipFailure(description: "the archive's list of contents is damaged") }
            let name = String(decoding: data[offset + 46 ..< offset + 46 + nameLength], as: UTF8.self)
            offset += 46 + nameLength + skip
            try body(Stored(entry: Entry(name: name, mode: mode, size: size), archive: data, method: method, local: local,
                            packed: packed, checksum: checksum))
        }
    }

    /// Packs everything in `folder`, with paths relative to it, uncompressed. `written` hears how many bytes of
    /// files are in the archive so far.
    static func pack(folder: URL, to archive: URL, written: ((Int64) -> Void)? = nil) throws {
        let files = FileManager.default
        files.createFile(atPath: archive.path, contents: nil)
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        var directory = Data(), position = 0, count = 0
        var total: Int64 = 0
        for path in try files.subpathsOfDirectory(atPath: folder.path).sorted() {
            let source = folder.appendingPathComponent(path)
            let attributes = try files.attributesOfItem(atPath: source.path)
            let permissions = (attributes[.posixPermissions] as? Int) ?? 0o644
            var name = path, mode = 0o100000 | permissions, content = Data(), size = 0
            var streamed = false
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory?: name += "/"; mode = 0o040000 | permissions
            case .typeSymbolicLink?:
                content = Data(try files.destinationOfSymbolicLink(atPath: source.path).utf8)
                mode = 0o120777
                size = content.count
            default:
                streamed = true
                size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            }
            guard size <= Int(UInt32.max), position <= Int(UInt32.max) else {
                throw ZipFailure(description: "the package would be over 4 GB, which is not handled")
            }
            let nameBytes = Data(name.utf8)
            // Shared by both headers: version 2.0, UTF-8 names, stored, a fixed date (2026-11-13), sizes.
            func common(_ checksum: UInt32) -> Data {
                var common = Data()
                common.put16(20); common.put16(0x0800); common.put16(0); common.put16(0)
                common.put16(UInt16((2026 - 1980) << 9 | 11 << 5 | 13))
                common.put32(checksum); common.put32(UInt32(size)); common.put32(UInt32(size))
                common.put16(UInt16(nameBytes.count)); common.put16(0)
                return common
            }
            var checksum = UInt32(truncatingIfNeeded: content.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) })
            var header = Data()
            header.put32(0x0403_4B50); header.append(common(checksum)); header.append(nameBytes)
            try output.write(contentsOf: header)
            if streamed {
                // The file goes through in pieces; its checksum is known only afterwards and is then written into
                // the header that is already there.
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                var sum = crc32(0, nil, 0), copied = 0
                while true {
                    let more: Bool = try autoreleasepool {
                        guard let piece = try input.read(upToCount: 1 << 20), !piece.isEmpty else { return false }
                        piece.withUnsafeBytes { sum = crc32(sum, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
                        try output.write(contentsOf: piece)
                        copied += piece.count
                        return true
                    }
                    if !more { break }
                }
                guard copied == size else { throw ZipFailure(description: "\(path) changed while it was packed") }
                checksum = UInt32(truncatingIfNeeded: sum)
                let after = try output.offset()
                try output.seek(toOffset: UInt64(position + 14))
                var patch = Data()
                patch.put32(checksum)
                try output.write(contentsOf: patch)
                try output.seek(toOffset: after)
                total += Int64(size)
                written?(total)
            } else if !content.isEmpty {
                try output.write(contentsOf: content)
            }

            directory.put32(0x0201_4B50); directory.put16(3 << 8 | 20)          // made on Unix
            directory.append(common(checksum))
            directory.put16(0); directory.put16(0); directory.put16(0)          // comment, disk, internal attributes
            directory.put32(UInt32(mode) << 16); directory.put32(UInt32(position))
            directory.append(nameBytes)
            position += header.count + size
            count += 1
        }
        guard count < 0xFFFF, position < Int(UInt32.max) else {
            throw ZipFailure(description: "the package would be over 4 GB or 65535 entries, which is not handled")
        }
        var tail = Data()
        tail.put32(0x0605_4B50); tail.put16(0); tail.put16(0); tail.put16(UInt16(count)); tail.put16(UInt16(count))
        tail.put32(UInt32(directory.count)); tail.put32(UInt32(position)); tail.put16(0)
        try output.write(contentsOf: directory)
        try output.write(contentsOf: tail)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
    mutating func put16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(value & 0xFFFF)); put16(UInt16(value >> 16)) }
}
