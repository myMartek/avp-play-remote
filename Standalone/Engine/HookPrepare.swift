import CryptoKit
import Foundation

struct HookFailure: Error, CustomStringConvertible {
    let description: String
}

/// Klepton's ports/scotland2/tools/prepare_hooks.py as a function: it prepares explicitly selected ARM64 entry
/// points of a translated library BEFORE signing. Each selected entry gets a signed gate that jumps through a data
/// slot, and a trampoline holding the entry's first instruction; the runtime only fills the slots. No code is
/// written at run time. The output is byte for byte what the Python script writes.
enum HookPrepare {
    private static let page: UInt64 = 16384
    private static let segmentSize = 72, sectionSize = 80, headerSize = 64, entrySize = 40

    /// - Parameters:
    ///   - elf: the game's library as it lies in its APK.
    ///   - macho: what klepton-ld made of it: thin, unsigned.
    ///   - elfSHA256: what `elf` has to be (the hooks were measured on exactly that file).
    ///   - targets: the manifest's rows: `vaddr`, `expect`, optionally `translated_expect` and `name`.
    ///   - originalEntryDepth: how many levels of original-call trampolines get a gate of their own.
    static func run(elf: Data, macho: Data, elfSHA256: String, targets: [[String: Any]], originalEntryDepth: Int) throws -> Data {
        func fail(_ text: String) -> HookFailure { HookFailure(description: text) }
        guard SHA256.hash(data: elf).map({ String(format: "%02x", $0) }).joined() == elfSHA256.lowercased() else { throw fail("elf SHA-256 mismatch") }
        guard elf.count >= 64, elf.prefix(6) == Data([0x7f, 0x45, 0x4c, 0x46, 2, 1]), elf.u16(18) == 183 else {
            throw fail("expected ARM64 ELF64 little-endian source")
        }
        guard macho.count >= 32 else { throw fail("truncated Mach-O") }
        var header = (0 ..< 8).map { macho.u32($0 * 4) }
        guard Array(header[0 ..< 4]) == [0xfeedfacf, 0x100000c, 0, 6] else { throw fail("expected thin ARM64 klepton-ld dylib") }

        // The load commands, and of the segments what is needed below.
        struct Segment { var name: String, vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64, initprot: Int32 }
        var commands: [(command: UInt32, data: Data)] = []
        var segments: [Segment] = []
        var shift: UInt64?
        var cursor = 32
        let commandsEnd = 32 + Int(header[5])
        for _ in 0 ..< header[4] {
            guard cursor + 8 <= macho.count else { throw fail("invalid Mach-O load command") }
            let command = macho.u32(cursor), size = Int(macho.u32(cursor + 4))
            guard size >= 8, cursor + size <= commandsEnd, cursor + size <= macho.count else { throw fail("invalid Mach-O load command") }
            let data = Data(macho[macho.startIndex + cursor ..< macho.startIndex + cursor + size])
            if command == 0x1d { throw fail("input already signed; prepare hooks before codesign") }
            if command == 0x19 {
                guard size >= segmentSize else { throw fail("invalid Mach-O load command") }
                let name = data.name16(8)
                if name.hasPrefix("__SC2") { throw fail("input already has hook segments") }
                segments.append(Segment(name: name, vmaddr: data.u64(24), vmsize: data.u64(32), fileoff: data.u64(40), filesize: data.u64(48),
                                        initprot: Int32(bitPattern: data.u32(60))))
                let count = Int(data.u32(64))
                guard segmentSize + count * sectionSize <= size else { throw fail("invalid Mach-O load command") }
                for index in 0 ..< count where data.name16(segmentSize + index * sectionSize) == "__klelf" {
                    shift = data.u64(segmentSize + index * sectionSize + 32)
                }
            }
            commands.append((command, data))
            cursor += size
        }
        guard cursor == commandsEnd, let shift else { throw fail("invalid command size or missing __klelf") }
        guard segments.contains(where: { $0.name == "__TEXT" && $0.vmaddr == 0 && $0.fileoff == 0 }) else {
            throw fail("only zero-based klepton-ld layouts supported")
        }
        func fileOffset(_ va: UInt64, _ size: UInt64, executable: Bool) throws -> Int {
            for segment in segments where segment.vmaddr <= va && va + size <= segment.vmaddr + segment.filesize && (!executable || segment.initprot == 5) {
                return Int(segment.fileoff + va - segment.vmaddr)
            }
            throw fail(String(format: "address %#llx not in a qualifying file-backed segment", va))
        }

        // The ELF's program and section headers: a target has to be code that is in the file.
        let phoff = Int(elf.u64(32)), phsize = Int(elf.u16(54)), phnum = Int(elf.u16(56))
        guard phsize == 56, phoff + phnum * 56 <= elf.count else { throw fail("invalid ELF program headers") }
        struct Load { var type: UInt32, flags: UInt32, offset: UInt64, vaddr: UInt64, filesz: UInt64 }
        let loads = (0 ..< phnum).map { index -> Load in
            let at = phoff + index * 56
            return Load(type: elf.u32(at), flags: elf.u32(at + 4), offset: elf.u64(at + 8), vaddr: elf.u64(at + 16), filesz: elf.u64(at + 32))
        }
        let shoff = Int(elf.u64(40)), shsize = Int(elf.u16(58)), shnum = Int(elf.u16(60))
        guard shsize == 64, shnum > 0, shoff + shnum * 64 <= elf.count else { throw fail("valid ELF section headers are required to identify code") }
        struct Section { var type: UInt32, flags: UInt64, addr: UInt64, size: UInt64 }
        let sections = (0 ..< shnum).map { index -> Section in
            let at = shoff + index * 64
            return Section(type: elf.u32(at + 4), flags: elf.u64(at + 8), addr: elf.u64(at + 16), size: elf.u64(at + 32))
        }
        guard loads.filter({ $0.type == 1 }).map(\.vaddr).min() == 0 else { throw fail("only zero-based guest ELF layouts supported") }

        guard !targets.isEmpty, targets.count <= 1_000_000 else { throw fail("empty or excessive target list") }
        func number(_ value: Any?) -> UInt64? {
            if let text = value as? String {
                return text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
            }
            return (value as? NSNumber)?.uint64Value
        }
        struct Row { var va: UInt64, address: UInt64, fileAt: Int, word: UInt32 }
        var parsed: [(va: UInt64, expect: UInt32, translated: UInt32)] = []
        for target in targets {
            guard let va = number(target["vaddr"]), let expect = number(target["expect"]).flatMap({ UInt32(exactly: $0) }) else {
                throw fail("a target lacks vaddr or expect")
            }
            let translated = try target["translated_expect"].map { value -> UInt32 in
                guard let word = number(value).flatMap({ UInt32(exactly: $0) }) else { throw fail("a target's translated_expect is not a word") }
                return word
            }
            parsed.append((va, expect, translated ?? expect))
        }
        parsed.sort { $0.va < $1.va }
        var rows: [Row] = []
        for target in parsed {
            let va = target.va
            if va % 4 != 0 || rows.last?.va == va { throw fail("unaligned or duplicate target") }
            guard let load = loads.first(where: { $0.type == 1 && $0.flags & 1 != 0 && $0.vaddr <= va && va + 4 <= $0.vaddr + $0.filesz }) else {
                throw fail("target is not executable ELF file data")
            }
            guard sections.contains(where: { $0.type == 1 && $0.flags & 4 != 0 && $0.addr <= va && va + 4 <= $0.addr + $0.size }) else {
                throw fail("target is not in an executable ELF section")
            }
            guard elf.u32(Int(load.offset + va - load.vaddr)) == target.expect else { throw fail("original entry instruction mismatch") }
            let address = shift + va
            let fileAt = try fileOffset(address, 4, executable: true)
            let word = macho.u32(fileAt)
            guard word == target.translated else { throw fail("translated entry differs; explicitly bind the translated instruction") }
            rows.append(Row(va: va, address: address, fileAt: fileAt, word: word))
        }
        let selected = rows.count

        guard let link = segments.first(where: { $0.name == "__LINKEDIT" }), link.fileoff + link.filesize == UInt64(macho.count) else {
            throw fail("expected terminal klepton-ld __LINKEDIT")
        }
        // The translator emits no bindings, exports or rebases, and an empty symbol table.
        let linkedit = macho.suffix(from: macho.startIndex + Int(link.fileoff))
        for (command, data) in commands {
            if command == 2, data.u32(12) != 0 || UInt64(data.u32(16)) != link.fileoff || UInt64(data.u32(20)) != link.filesize || linkedit.contains(where: { $0 != 0 }) {
                throw fail("only empty klepton-ld symbol tables supported")
            }
            if [0x8000_0022, 0x22, 0x8000_0033, 0x8000_0034].contains(command) { throw fail("unexpected dyld linkedit payload") }
        }

        guard (0 ... 8).contains(originalEntryDepth) else { throw fail("originalEntryDepth must be an integer from 0 to 8") }
        let entryCount = selected * (originalEntryDepth + 1)
        guard entryCount <= 1_000_000 else { throw fail("excessive prepared entry count") }
        func align(_ value: UInt64, _ step: UInt64 = page) -> UInt64 { (value + step - 1) & ~(step - 1) }
        let codeVA = align(link.vmaddr), codeOff = align(link.fileoff)
        let codeSize = UInt64(entryCount) * 48                  // a 16-byte gate, the relocated instruction and a branch
        let recordsAt = align(codeSize, 8)
        let recordsSize = UInt64(headerSize + entryCount * entrySize)
        let rxSize = recordsAt + recordsSize
        let dataVA = align(codeVA + rxSize), dataOff = align(codeOff + rxSize)
        let slotsSize = UInt64(entryCount) * 8
        let linkVA = align(dataVA + slotsSize), linkOff = align(dataOff + slotsSize)

        var output = Data(count: Int(linkOff + link.filesize))
        output.replaceSubrange(0 ..< Int(link.fileoff), with: macho.prefix(Int(link.fileoff)))
        output.replaceSubrange(Int(linkOff) ..< output.count, with: linkedit)

        var records = Data()
        records.append(contentsOf: Array("SC2AOT1".utf8) + [0])
        for value in [1, UInt32(entrySize), UInt32(entryCount), 0] as [UInt32] { records.put32(value) }
        records.put64(shift)
        records.append(contentsOf: stride(from: 0, to: 64, by: 2).map { index -> UInt8 in
            let text = Array(elfSHA256.lowercased())
            return UInt8(String(text[index ... index + 1]), radix: 16) ?? 0
        })

        var index = 0
        while index < rows.count {
            let row = rows[index]
            let gate = codeVA + UInt64(index) * 48, original = gate + 16, slot = dataVA + UInt64(index) * 8
            var words: [UInt32] = [try adrp(gate, slot, 16), addAddress(16, slot), 0xc8df_fe10, 0xd61f_0200]    // LDAR x16,[x16]; BR x16
            var relocated = try relocate(row.word, row.address, original)
            relocated.append(try branch(original + UInt64(relocated.count) * 4, row.address + 4))
            words += relocated
            guard words.count * 4 <= 48 else { throw fail("original trampoline exceeds reserved record") }
            for (offset, word) in words.enumerated() { output.set32(word, at: Int(codeOff) + index * 48 + offset * 4) }
            let patched = try branch(row.address, gate)
            output.set32(patched, at: row.fileAt)
            for value in [row.address, original, slot, gate] { records.put64(value) }
            records.put32(patched)
            records.put32(row.word)
            if index < selected * originalEntryDepth {
                // The SDK's InstallOrigHook hooks an existing original-call trampoline. That entry gets its own
                // signed gate; relocating its first word again keeps the rest of the original sequence.
                rows.append(Row(va: original - shift, address: original, fileAt: Int(codeOff) + index * 48 + 16, word: relocated[0]))
            }
            index += 1
        }
        output.replaceSubrange(Int(codeOff + recordsAt) ..< Int(codeOff + recordsAt + recordsSize), with: records)

        func name16(_ name: String) -> Data { Data(name.utf8) + Data(count: 16 - name.utf8.count) }
        func section(_ name: String, _ segment: String, _ va: UInt64, _ size: UInt64, _ offset: UInt64, executable: Bool = false, alignment: UInt32 = 3) -> Data {
            var data = name16(name) + name16(segment)
            data.put64(va); data.put64(size)
            for value in [UInt32(offset), alignment, 0, 0, executable ? 0x8000_0400 : 0, 0, 0, 0] as [UInt32] { data.put32(value) }
            return data
        }
        func segment(_ name: String, _ va: UInt64, _ vmSize: UInt64, _ fileOffset: UInt64, _ fileSize: UInt64, _ protection: UInt32, _ sections: [Data]) -> Data {
            var data = Data()
            data.put32(0x19); data.put32(UInt32(segmentSize + sections.map(\.count).reduce(0, +)))
            data.append(name16(name))
            for value in [va, vmSize, fileOffset, fileSize] { data.put64(value) }
            for value in [protection, protection, UInt32(sections.count), 0] { data.put32(value) }
            return sections.reduce(data, +)
        }
        let added = [
            segment("__SC2HOOK", codeVA, align(rxSize), codeOff, rxSize, 5, [
                section("__gates", "__SC2HOOK", codeVA, codeSize, codeOff, executable: true, alignment: 4),
                section("__records", "__SC2HOOK", codeVA + recordsAt, recordsSize, codeOff + recordsAt),
            ]),
            segment("__SC2DATA", dataVA, align(slotsSize), dataOff, slotsSize, 3, [section("__slots", "__SC2DATA", dataVA, slotsSize, dataOff)]),
        ]
        var revised = Data()
        for (command, original) in commands {
            var data = original
            if command == 0x19, data.name16(8) == "__LINKEDIT" {
                added.forEach { revised.append($0) }
                data.set64(linkVA, at: 24)
                data.set64(linkOff, at: 40)
            }
            if command == 2 { data.set32(UInt32(linkOff), at: 16) }
            if command == 0x1b {
                var hasher = SHA256()
                hasher.update(data: macho)
                hasher.update(data: records)
                data.replaceSubrange(8 ..< 24, with: Data(hasher.finalize().prefix(16)))
            }
            revised.append(data)
        }
        guard 32 + revised.count <= 0x3fc0 else { throw fail("hook load commands overlap translator header reserve") }
        header[4] += 2
        header[5] = UInt32(revised.count)
        for (offset, value) in header.enumerated() { output.set32(value, at: offset * 4) }
        output.replaceSubrange(32 ..< 32 + revised.count, with: revised)
        return output
    }

    // MARK: Instructions

    private static func signed(_ value: UInt64, _ bits: Int) -> Int64 {
        Int64(value & ((1 << (bits - 1)) - 1)) - Int64(value & (1 << (bits - 1)))
    }

    private static func branch(_ source: UInt64, _ target: UInt64) throws -> UInt32 {
        let delta = Int64(bitPattern: target) - Int64(bitPattern: source)
        guard delta % 4 == 0, delta >= -(1 << 27), delta < (1 << 27) else { throw HookFailure(description: "branch exceeds signed 128 MiB reach") }
        return 0x1400_0000 | UInt32(truncatingIfNeeded: (delta / 4) & 0x3ff_ffff)
    }

    private static func adrp(_ source: UInt64, _ target: UInt64, _ register: UInt32) throws -> UInt32 {
        let delta = Int64(target / 4096) - Int64(source / 4096)
        guard delta >= -(1 << 20), delta < (1 << 20) else { throw HookFailure(description: "ADRP exceeds signed 4 GiB reach") }
        let imm = UInt32(truncatingIfNeeded: delta) & 0x1f_ffff
        return 0x9000_0000 | ((imm & 3) << 29) | ((imm >> 2) << 5) | register
    }

    private static func addAddress(_ register: UInt32, _ target: UInt64) -> UInt32 {
        0x9100_0000 | (UInt32(target & 4095) << 10) | (register << 5) | register
    }

    /// Relocates one entry instruction from `source` to `destination`; classes not covered here are refused.
    private static func relocate(_ word: UInt32, _ source: UInt64, _ destination: UInt64) throws -> [UInt32] {
        func fail(_ text: String) -> HookFailure { HookFailure(description: text) }
        func moved(_ base: UInt64, _ by: Int64) -> UInt64 { UInt64(bitPattern: Int64(bitPattern: base) &+ by) }
        let wide = UInt64(word)
        if word & 0x7c00_0000 == 0x1400_0000 {                  // B / BL
            if word & 0x8000_0000 != 0 { throw fail("BL entry requires an unwind-aware trampoline, not yet supported") }
            return [try branch(destination, moved(source, signed(wide & 0x3ff_ffff, 26) * 4))]
        }
        if word & 0x1f00_0000 == 0x1000_0000 {                  // ADR / ADRP
            let rd = word & 31
            if rd == 18 { throw fail("untranslated x18 destination") }
            let imm = signed(((wide >> 5) & 0x7ffff) * 4 + ((wide >> 29) & 3), 21)
            if word & 0x8000_0000 != 0 { return [try adrp(destination, moved(source & ~4095, imm * 4096), rd)] }
            let target = moved(source, imm)
            return [try adrp(destination, target, rd), addAddress(rd, target)]
        }
        if word & 0xff00_0010 == 0x5400_0000 {                  // B.cond
            if word & 15 >= 14 { throw fail("unsupported AL/NV conditional branch") }
            let target = moved(source, signed((wide >> 5) & 0x7ffff, 19) * 4)
            let inverse = ((word ^ 1) & ~0xff_ffe0) | (2 << 5)
            return [inverse, try branch(destination + 4, target)]
        }
        if [0x3400_0000, 0x3600_0000].contains(word & 0x7e00_0000) {     // CBZ/NZ, TBZ/NZ
            if word & 31 == 18 { throw fail("untranslated x18 conditional branch") }
            let bits = word & 0x7e00_0000 == 0x3600_0000 ? 14 : 19
            let mask = UInt32((1 << bits) - 1) << 5
            let target = moved(source, signed(UInt64((word & mask) >> 5), bits) * 4)
            let inverse = ((word ^ 0x0100_0000) & ~mask) | (2 << 5)
            return [inverse, try branch(destination + 4, target)]
        }
        if word & 0x3b00_0000 == 0x1800_0000 {                  // PC-relative literal load
            let rt = word & 31, opc = Int(word >> 30), vector = word & (1 << 26) != 0
            if !vector, rt == 18 { throw fail("untranslated x18 literal load") }
            let loads: [UInt32] = vector ? [0xbd40_0000, 0xfd40_0000, 0x3dc0_0000] : [0xb940_0000, 0xf940_0000, 0xb980_0000]
            guard opc < loads.count else { throw fail("unsupported prefetch/reserved literal instruction") }
            let target = moved(source, signed((wide >> 5) & 0x7ffff, 19) * 4)
            return [try adrp(destination, target, 17), addAddress(17, target), loads[opc] | (17 << 5) | rt]
        }
        if word == 0xd503_201f || word == 0xd65f_03c0 { return [word] }      // NOP, RET x30
        // Integer unsigned-immediate LDR/STR: bits 10..21 are an offset, not registers.
        if [0xf940_0000, 0xf900_0000, 0xb940_0000, 0xb900_0000].contains(word & 0xffc0_0000) {
            if word & 31 == 18 || (word >> 5) & 31 == 18 { throw fail("untranslated x18 load/store operand") }
            return [word]
        }
        // These groups hold no PC-relative operands. Anything that looks like x18 is refused, false positives included.
        let fields: [UInt32]
        switch (word >> 25) & 15 {
        case 8, 9: fields = [word & 31, (word >> 5) & 31]
        case 4, 5, 6, 7, 12, 13, 14, 15: fields = [word & 31, (word >> 5) & 31, (word >> 10) & 31, (word >> 16) & 31]
        default: throw fail(String(format: "unsupported entry instruction %#010x", word))
        }
        if fields.contains(18) { throw fail(String(format: "possible untranslated x18 instruction %#010x", word)) }
        return [word]
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) } }
    func u32(_ at: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
    func u64(_ at: Int) -> UInt64 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) } }
    /// A name of a segment or section: sixteen bytes, padded with zeros.
    func name16(_ at: Int) -> String {
        String(decoding: self[startIndex + at ..< startIndex + at + 16].prefix { $0 != 0 }, as: UTF8.self)
    }
    mutating func put32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func put64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func set32(_ value: UInt32, at: Int) { Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(at ..< at + 4, with: $0) } }
    mutating func set64(_ value: UInt64, at: Int) { Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(at ..< at + 8, with: $0) } }
}
