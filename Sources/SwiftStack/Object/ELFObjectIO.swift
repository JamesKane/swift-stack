// Sources/SwiftStack/Object/ELFObjectIO.swift
import Foundation

// MARK: - ELF64 Constants & Errors

/// Errors thrown by `ELFObjectReader` when parsing an invalid, truncated, or unsupported ELF input.
public enum ELFReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncatedHeader(expected: Int, actual: Int)
    case invalidMagic
    case unsupportedClass(UInt8)
    case unsupportedEndianness(UInt8)
    case unsupportedObjectType(UInt16)
    case unsupportedMachine(UInt16)
    case outOfBoundsSectionHeaders(offset: UInt64, count: Int, entrySize: Int, fileSize: Int)
    case outOfBoundsSectionData(sectionIndex: Int, offset: UInt64, size: UInt64, fileSize: Int)
    case invalidStringTableIndex(UInt16)
    case corruptSymbolTable(String)
    case corruptRelocationTable(String)
    case ioError(String)

    public var description: String {
        switch self {
        case .truncatedHeader(let expected, let actual):
            return "Truncated ELF header: expected at least \(expected) bytes, got \(actual)"
        case .invalidMagic:
            return "Invalid ELF magic bytes (expected 0x7F 'E' 'L' 'F')"
        case .unsupportedClass(let cls):
            return "Unsupported ELF class \(cls) (expected ELFCLASS64 = 2)"
        case .unsupportedEndianness(let data):
            return "Unsupported ELF endianness \(data) (expected ELFDATA2LSB = 1)"
        case .unsupportedObjectType(let type):
            return "Unsupported ELF type \(type) (expected ET_REL = 1)"
        case .unsupportedMachine(let machine):
            return "Unsupported ELF e_machine \(machine)"
        case .outOfBoundsSectionHeaders(let offset, let count, let entrySize, let fileSize):
            return "Section header table out of bounds (offset \(offset), count \(count), entsize \(entrySize), fileSize \(fileSize))"
        case .outOfBoundsSectionData(let secIdx, let offset, let size, let fileSize):
            return "Section \(secIdx) data out of bounds (offset \(offset), size \(size), fileSize \(fileSize))"
        case .invalidStringTableIndex(let idx):
            return "Invalid string table section index \(idx)"
        case .corruptSymbolTable(let msg):
            return "Corrupt ELF symbol table: \(msg)"
        case .corruptRelocationTable(let msg):
            return "Corrupt ELF relocation table: \(msg)"
        case .ioError(let msg):
            return "ELF I/O error: \(msg)"
        }
    }
}

/// ELF64 format constants used by `ELFObjectWriter` and `ELFObjectReader`.
public enum ELF64Constants {
    // e_ident indices and values
    public static let elfClass64: UInt8 = 2
    public static let elfData2LSB: UInt8 = 1
    public static let evCurrent: UInt8 = 1
    public static let elfOsAbiNone: UInt8 = 0

    // e_type
    public static let etRel: UInt16 = 1

    // e_machine
    public static let emX86_64: UInt16 = 62       // 0x3E
    public static let emAArch64: UInt16 = 183     // 0xB7
    public static let emRISCV: UInt16 = 243       // 0xF3

    // Structure sizes
    public static let ehdrSize: Int = 64
    public static let shdrSize: Int = 64
    public static let symEntrySize: Int = 24
    public static let relaEntrySize: Int = 24

    // sh_type
    public static let shtNull: UInt32 = 0
    public static let shtProgbits: UInt32 = 1
    public static let shtSymtab: UInt32 = 2
    public static let shtStrtab: UInt32 = 3
    public static let shtRela: UInt32 = 4
    public static let shtNote: UInt32 = 7
    public static let shtNobits: UInt32 = 8
    public static let shtRel: UInt32 = 9
    public static let shtGroup: UInt32 = 17
    public static let shtX86_64Unwind: UInt32 = 0x7000_0001
    public static let shtRiscvAttributes: UInt32 = 0x7000_0003

    // Special section indices
    public static let shnUndef: UInt16 = 0
    public static let shnAbs: UInt16 = 0xFFF1
    public static let shnCommon: UInt16 = 0xFFF2
}

// MARK: - String Table Builder

private struct ELFStringTableBuilder {
    var bytes: [UInt8] = [0] // Index 0 is always the empty string ""
    private var offsets: [String: UInt32] = ["": 0]

    mutating func add(_ string: String) -> UInt32 {
        if let existing = offsets[string] {
            return existing
        }
        let offset = UInt32(bytes.count)
        bytes.append(contentsOf: string.utf8)
        bytes.append(0)
        offsets[string] = offset
        return offset
    }
}

// MARK: - ELF Section Header Representation

private struct RawELFSectionHeader {
    var shName: UInt32 = 0
    var shType: UInt32 = 0
    var shFlags: UInt64 = 0
    var shAddr: UInt64 = 0
    var shOffset: UInt64 = 0
    var shSize: UInt64 = 0
    var shLink: UInt32 = 0
    var shInfo: UInt32 = 0
    var shAddralign: UInt64 = 0
    var shEntsize: UInt64 = 0
}

// MARK: - ELFObjectWriter

/// Deterministic 64-bit little-endian ELF relocatable object (`.o`, `ET_REL`) serializer (06-linker.md §5.1, §5.8).
public struct ELFObjectWriter: Sendable {
    public init() {}

    /// Serializes `obj` into an in-memory ELF64 `ET_REL` byte array.
    public func write(_ obj: borrowing RelocatableObject) -> [UInt8] {
        Self.write(obj)
    }

    /// Serializes `obj` and writes it to `path`.
    public func write(_ obj: borrowing RelocatableObject, toPath path: String) throws {
        try Self.write(obj, toPath: path)
    }

    /// Serializes `obj` into a deterministic ELF64 `ET_REL` byte array.
    public static func write(_ obj: borrowing RelocatableObject) -> [UInt8] {
        var shstrtab = ELFStringTableBuilder()
        var strtab = ELFStringTableBuilder()

        // 1. Partition symbols into [NULL] + STB_LOCAL + non-local (STB_GLOBAL / STB_WEAK)
        // preserving deterministic input order within each partition (06-linker.md §5.8).
        let totalSymRows = Int(obj.symbolNames.count)
        var localObjSyms: [SymbolIndex] = []
        var nonLocalObjSyms: [SymbolIndex] = []
        if totalSymRows > 1 {
            for rawIdx in 1..<totalSymRows {
                let symIdx = SymbolIndex(UInt32(rawIdx))
                if obj.symbolBindings[symIdx] == .local {
                    localObjSyms.append(symIdx)
                } else {
                    nonLocalObjSyms.append(symIdx)
                }
            }
        }

        var elfSymByObjSym = [UInt32](repeating: 0, count: max(totalSymRows, 1))
        var orderedObjSyms: [SymbolIndex] = []
        orderedObjSyms.reserveCapacity(localObjSyms.count + nonLocalObjSyms.count)

        for sym in localObjSyms {
            let elfIdx = UInt32(1 + orderedObjSyms.count)
            elfSymByObjSym[Int(sym.rawIndex)] = elfIdx
            orderedObjSyms.append(sym)
        }
        let firstNonLocalSymIndex = UInt32(1 + localObjSyms.count)
        for sym in nonLocalObjSyms {
            let elfIdx = UInt32(1 + orderedObjSyms.count)
            elfSymByObjSym[Int(sym.rawIndex)] = elfIdx
            orderedObjSyms.append(sym)
        }

        // Check if we have any symbol type records that should be emitted into `.ss_symtypes`
        var hasExplicitSymTypesSection = false
        let userSecCount = Int(obj.sectionNames.count)
        if userSecCount > 1 {
            for rawSec in 1..<userSecCount {
                let sec = SectionIndex(UInt32(rawSec))
                if obj.sectionKinds[sec] == .ssSymTypes || obj.sectionName(sec) == ".ss_symtypes" {
                    hasExplicitSymTypesSection = true
                    break
                }
            }
        }

        var synthesizedSymTypeBytes: [UInt8] = []
        if !hasExplicitSymTypesSection && totalSymRows > 1 {
            for rawSym in 1..<totalSymRows {
                let sym = SymbolIndex(UInt32(rawSym))
                let rec = obj.symbolTypes[sym]
                if rec.symbolIndex != 0 || rec.signatureHash != 0 || rec.kind != 0 || rec.language != 0 || rec.flags != 0 || rec.providerModule != 0 {
                    let mappedSymIdx = elfSymByObjSym[rawSym]
                    appendUInt32(&synthesizedSymTypeBytes, mappedSymIdx)
                    synthesizedSymTypeBytes.append(rec.kind)
                    synthesizedSymTypeBytes.append(rec.language)
                    appendUInt16(&synthesizedSymTypeBytes, rec.flags)
                    appendUInt64(&synthesizedSymTypeBytes, rec.signatureHash)
                    appendUInt32(&synthesizedSymTypeBytes, rec.providerModule)
                    appendUInt32(&synthesizedSymTypeBytes, rec.reserved)
                }
            }
        }

        // 2. Plan ELF section indices:
        //    0: NULL
        //    1..N: user sections (plus optional synthesized .ss_symtypes)
        //    followed by .rela<sec> for each user section that has relocations
        //    followed by .symtab, .strtab, .shstrtab
        let numUserSecs = userSecCount > 1 ? (userSecCount - 1) : 0
        let hasSynthesizedSymTypes = !synthesizedSymTypeBytes.isEmpty
        let totalContentSections = numUserSecs + (hasSynthesizedSymTypes ? 1 : 0)

        var secWithRelocs: [SectionIndex] = []
        if numUserSecs > 0 {
            for rawSec in 1..<userSecCount {
                let sec = SectionIndex(UInt32(rawSec))
                if obj.relocSectionCount[sec] > 0 {
                    secWithRelocs.append(sec)
                }
            }
        }

        let relaStartElfIdx = 1 + totalContentSections
        let symtabElfIdx = relaStartElfIdx + secWithRelocs.count
        let strtabElfIdx = symtabElfIdx + 1
        let shstrtabElfIdx = strtabElfIdx + 1
        let totalElfSections = shstrtabElfIdx + 1

        var sectionHeaders: [RawELFSectionHeader] = []
        sectionHeaders.reserveCapacity(totalElfSections)
        // Section 0: NULL
        sectionHeaders.append(RawELFSectionHeader())

        // Start file buffer with 64-byte ELF header placeholder
        var fileBytes = [UInt8](repeating: 0, count: ELF64Constants.ehdrSize)

        // 3. Emit user sections (1..numUserSecs)
        if numUserSecs > 0 {
            for rawSec in 1..<userSecCount {
                let sec = SectionIndex(UInt32(rawSec))
                let name = obj.sectionName(sec)
                let kind = obj.sectionKinds[sec]
                let flags = UInt64(obj.sectionFlags[sec])
                let alignLog2 = obj.sectionAligns[sec]
                let align = alignLog2 == 0 ? UInt64(1) : (UInt64(1) << UInt64(alignLog2))
                let shName = shstrtab.add(name)
                let shType = elfSectionType(for: kind)

                if kind.isNobits {
                    alignBuffer(&fileBytes, to: Int(align))
                    let offset = UInt64(fileBytes.count)
                    let size = UInt64(obj.sectionBytes[sec].count)
                    sectionHeaders.append(
                        RawELFSectionHeader(
                            shName: shName,
                            shType: shType,
                            shFlags: flags,
                            shAddr: 0,
                            shOffset: offset,
                            shSize: size,
                            shLink: 0,
                            shInfo: 0,
                            shAddralign: align,
                            shEntsize: 0
                        )
                    )
                } else {
                    alignBuffer(&fileBytes, to: Int(align))
                    let offset = UInt64(fileBytes.count)
                    var secData = obj.sectionData(sec)
                    // If this is an explicit .ss_symtypes section and its symbol indices refer to
                    // pre-reordered SymbolIndex handles, remap them to ELF .symtab indices.
                    if (kind == .ssSymTypes || name == ".ss_symtypes") && secData.count >= 24 && secData.count % 24 == 0 {
                        remapSymTypesBuffer(&secData, elfSymByObjSym: elfSymByObjSym)
                    }
                    fileBytes.append(contentsOf: secData)
                    sectionHeaders.append(
                        RawELFSectionHeader(
                            shName: shName,
                            shType: shType,
                            shFlags: flags,
                            shAddr: 0,
                            shOffset: offset,
                            shSize: UInt64(secData.count),
                            shLink: 0,
                            shInfo: 0,
                            shAddralign: align,
                            shEntsize: 0
                        )
                    )
                }
            }
        }

        // Optional synthesized .ss_symtypes section
        if hasSynthesizedSymTypes {
            let shName = shstrtab.add(".ss_symtypes")
            alignBuffer(&fileBytes, to: 8)
            let offset = UInt64(fileBytes.count)
            fileBytes.append(contentsOf: synthesizedSymTypeBytes)
            sectionHeaders.append(
                RawELFSectionHeader(
                    shName: shName,
                    shType: ELF64Constants.shtProgbits,
                    shFlags: 0,
                    shAddr: 0,
                    shOffset: offset,
                    shSize: UInt64(synthesizedSymTypeBytes.count),
                    shLink: 0,
                    shInfo: 0,
                    shAddralign: 8,
                    shEntsize: 24
                )
            )
        }

        // 4. Emit .rela<sectionName> sections
        for sec in secWithRelocs {
            let targetSecName = obj.sectionName(sec)
            let relaName = targetSecName.hasPrefix(".rela") ? targetSecName : ".rela\(targetSecName)"
            let shName = shstrtab.add(relaName)
            alignBuffer(&fileBytes, to: 8)
            let offset = UInt64(fileBytes.count)

            let secRelocs = obj.relocs(for: sec)
            for reloc in secRelocs {
                let rawSym = Int(reloc.symbol.rawIndex)
                let elfSymIdx: UInt32 = (rawSym > 0 && rawSym < elfSymByObjSym.count) ? elfSymByObjSym[rawSym] : 0
                let elfType = reloc.kind.toELFType(arch: obj.arch)
                let rInfo = (UInt64(elfSymIdx) << 32) | UInt64(elfType)

                appendUInt64(&fileBytes, reloc.offset)
                appendUInt64(&fileBytes, rInfo)
                appendInt64(&fileBytes, reloc.addend)
            }

            let size = UInt64(secRelocs.count * ELF64Constants.relaEntrySize)
            sectionHeaders.append(
                RawELFSectionHeader(
                    shName: shName,
                    shType: ELF64Constants.shtRela,
                    shFlags: UInt64(SectionFlags.infoLink.rawValue),
                    shAddr: 0,
                    shOffset: offset,
                    shSize: size,
                    shLink: UInt32(symtabElfIdx),
                    shInfo: sec.rawIndex,
                    shAddralign: 8,
                    shEntsize: UInt64(ELF64Constants.relaEntrySize)
                )
            )
        }

        // 5. Build and emit .symtab
        let symtabShName = shstrtab.add(".symtab")
        alignBuffer(&fileBytes, to: 8)
        let symtabOffset = UInt64(fileBytes.count)

        // Entry 0: STN_UNDEF (24 zero bytes)
        fileBytes.append(contentsOf: repeatElement(UInt8(0), count: ELF64Constants.symEntrySize))

        for sym in orderedObjSyms {
            let name = obj.symbolName(sym)
            let stName = name.isEmpty ? UInt32(0) : strtab.add(name)
            let binding = obj.symbolBindings[sym]
            let kind = obj.symbolKinds[sym]
            let vis = obj.symbolVisibility[sym]
            let stInfo = (binding.rawValue << 4) | (kind.rawValue & 0x0F)
            let stOther = vis.rawValue & 0x03

            let sec = obj.symbolSections[sym]
            let stShndx: UInt16
            if sec == .undefined {
                stShndx = ELF64Constants.shnUndef
            } else if sec == .absolute {
                stShndx = ELF64Constants.shnAbs
            } else if sec == .common {
                stShndx = ELF64Constants.shnCommon
            } else {
                stShndx = UInt16(sec.rawIndex)
            }

            appendUInt32(&fileBytes, stName)
            fileBytes.append(stInfo)
            fileBytes.append(stOther)
            appendUInt16(&fileBytes, stShndx)
            appendUInt64(&fileBytes, obj.symbolValues[sym])
            appendUInt64(&fileBytes, obj.symbolSizes[sym])
        }

        let symtabSize = UInt64((1 + orderedObjSyms.count) * ELF64Constants.symEntrySize)
        sectionHeaders.append(
            RawELFSectionHeader(
                shName: symtabShName,
                shType: ELF64Constants.shtSymtab,
                shFlags: 0,
                shAddr: 0,
                shOffset: symtabOffset,
                shSize: symtabSize,
                shLink: UInt32(strtabElfIdx),
                shInfo: firstNonLocalSymIndex,
                shAddralign: 8,
                shEntsize: UInt64(ELF64Constants.symEntrySize)
            )
        )

        // 6. Emit .strtab
        let strtabShName = shstrtab.add(".strtab")
        let strtabShstrName = shstrtab.add(".shstrtab")

        let strtabOffset = UInt64(fileBytes.count)
        fileBytes.append(contentsOf: strtab.bytes)
        sectionHeaders.append(
            RawELFSectionHeader(
                shName: strtabShName,
                shType: ELF64Constants.shtStrtab,
                shFlags: 0,
                shAddr: 0,
                shOffset: strtabOffset,
                shSize: UInt64(strtab.bytes.count),
                shLink: 0,
                shInfo: 0,
                shAddralign: 1,
                shEntsize: 0
            )
        )

        // 7. Emit .shstrtab
        let shstrtabOffset = UInt64(fileBytes.count)
        fileBytes.append(contentsOf: shstrtab.bytes)
        sectionHeaders.append(
            RawELFSectionHeader(
                shName: strtabShstrName,
                shType: ELF64Constants.shtStrtab,
                shFlags: 0,
                shAddr: 0,
                shOffset: shstrtabOffset,
                shSize: UInt64(shstrtab.bytes.count),
                shLink: 0,
                shInfo: 0,
                shAddralign: 1,
                shEntsize: 0
            )
        )

        // 8. Emit Section Header Table aligned to 8 bytes
        alignBuffer(&fileBytes, to: 8)
        let shoff = UInt64(fileBytes.count)
        for shdr in sectionHeaders {
            appendUInt32(&fileBytes, shdr.shName)
            appendUInt32(&fileBytes, shdr.shType)
            appendUInt64(&fileBytes, shdr.shFlags)
            appendUInt64(&fileBytes, shdr.shAddr)
            appendUInt64(&fileBytes, shdr.shOffset)
            appendUInt64(&fileBytes, shdr.shSize)
            appendUInt32(&fileBytes, shdr.shLink)
            appendUInt32(&fileBytes, shdr.shInfo)
            appendUInt64(&fileBytes, shdr.shAddralign)
            appendUInt64(&fileBytes, shdr.shEntsize)
        }

        // 9. Fill in 64-byte ELF Header at offset 0
        var headerBytes: [UInt8] = []
        headerBytes.reserveCapacity(ELF64Constants.ehdrSize)
        headerBytes.append(contentsOf: [
            0x7F, 0x45, 0x4C, 0x46,       // Magic: \x7FELF
            ELF64Constants.elfClass64,    // EI_CLASS: 64-bit
            ELF64Constants.elfData2LSB,   // EI_DATA: little-endian
            ELF64Constants.evCurrent,     // EI_VERSION: 1
            ELF64Constants.elfOsAbiNone,  // EI_OSABI: System V
            0, 0, 0, 0, 0, 0, 0, 0        // Padding
        ])
        appendUInt16(&headerBytes, ELF64Constants.etRel) // e_type = ET_REL (1)
        appendUInt16(&headerBytes, elfMachine(for: obj.arch)) // e_machine
        appendUInt32(&headerBytes, 1) // e_version = EV_CURRENT
        appendUInt64(&headerBytes, 0) // e_entry = 0
        appendUInt64(&headerBytes, 0) // e_phoff = 0
        appendUInt64(&headerBytes, shoff) // e_shoff
        let eFlags: UInt32 = (obj.arch == .riscv64) ? 0x0005 : 0 // RVC + double-float ABI default or 0
        appendUInt32(&headerBytes, eFlags)
        appendUInt16(&headerBytes, UInt16(ELF64Constants.ehdrSize)) // e_ehsize = 64
        appendUInt16(&headerBytes, 0) // e_phentsize = 0
        appendUInt16(&headerBytes, 0) // e_phnum = 0
        appendUInt16(&headerBytes, UInt16(ELF64Constants.shdrSize)) // e_shentsize = 64
        appendUInt16(&headerBytes, UInt16(sectionHeaders.count)) // e_shnum
        appendUInt16(&headerBytes, UInt16(shstrtabElfIdx)) // e_shstrndx

        for i in 0..<ELF64Constants.ehdrSize {
            fileBytes[i] = headerBytes[i]
        }

        return fileBytes
    }

    /// Serializes `obj` and writes the resulting ELF64 `.o` file to `path`.
    public static func write(_ obj: borrowing RelocatableObject, toPath path: String) throws {
        let bytes = write(obj)
        let data = Data(bytes)
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            throw ELFReadError.ioError(error.localizedDescription)
        }
    }

    private static func elfMachine(for arch: ObjectArch) -> UInt16 {
        switch arch {
        case .x86_64: return ELF64Constants.emX86_64
        case .aarch64: return ELF64Constants.emAArch64
        case .riscv64: return ELF64Constants.emRISCV
        }
    }

    private static func elfSectionType(for kind: SectionKind) -> UInt32 {
        switch kind {
        case .null:
            return ELF64Constants.shtNull
        case .bss, .sbss, .tbss, .customNobits:
            return ELF64Constants.shtNobits
        case .note:
            return ELF64Constants.shtNote
        case .riscvAttributes:
            return ELF64Constants.shtRiscvAttributes
        default:
            return ELF64Constants.shtProgbits
        }
    }

    private static func remapSymTypesBuffer(_ bytes: inout [UInt8], elfSymByObjSym: [UInt32]) {
        let recordCount = bytes.count / 24
        for i in 0..<recordCount {
            let base = i * 24
            let origSym = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)
            if Int(origSym) > 0 && Int(origSym) < elfSymByObjSym.count {
                let mapped = elfSymByObjSym[Int(origSym)]
                bytes[base] = UInt8(truncatingIfNeeded: mapped)
                bytes[base + 1] = UInt8(truncatingIfNeeded: mapped >> 8)
                bytes[base + 2] = UInt8(truncatingIfNeeded: mapped >> 16)
                bytes[base + 3] = UInt8(truncatingIfNeeded: mapped >> 24)
            }
        }
    }

    private static func alignBuffer(_ bytes: inout [UInt8], to alignment: Int) {
        guard alignment > 1 else { return }
        let rem = bytes.count % alignment
        if rem != 0 {
            let pad = alignment - rem
            bytes.append(contentsOf: repeatElement(UInt8(0), count: pad))
        }
    }

    private static func appendUInt16(_ bytes: inout [UInt8], _ val: UInt16) {
        let le = val.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ val: UInt32) {
        let le = val.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ bytes: inout [UInt8], _ val: UInt64) {
        let le = val.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }

    private static func appendInt64(_ bytes: inout [UInt8], _ val: Int64) {
        let le = val.littleEndian
        withUnsafeBytes(of: le) { bytes.append(contentsOf: $0) }
    }
}

// MARK: - ELFObjectReader

/// 64-bit little-endian ELF relocatable object (`ET_REL`) reader (06-linker.md §5.1).
public struct ELFObjectReader: Sendable {
    public init() {}

    /// Parses a `RelocatableObject` from an `UnsafeRawBufferPointer`.
    public func read(bytes: UnsafeRawBufferPointer) throws -> RelocatableObject {
        try Self.read(bytes: bytes)
    }

    /// Parses a `RelocatableObject` from a byte array.
    public func read(bytes: [UInt8]) throws -> RelocatableObject {
        try Self.read(bytes: bytes)
    }

    /// Reads and parses a `RelocatableObject` from a file at `path`.
    public func read(fromPath path: String) throws -> RelocatableObject {
        try Self.read(fromPath: path)
    }

    /// Parses a `RelocatableObject` from a byte array.
    public static func read(bytes: [UInt8]) throws -> RelocatableObject {
        var parsed: RelocatableObject? = nil
        try bytes.withUnsafeBytes { rawBuf in
            parsed = try read(bytes: rawBuf)
        }
        return parsed.take()!
    }

    /// Reads and parses a `RelocatableObject` from a file at `path`.
    public static func read(fromPath path: String) throws -> RelocatableObject {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ELFReadError.ioError(error.localizedDescription)
        }
        return try read(bytes: [UInt8](data))
    }

    /// Parses a `RelocatableObject` from an `UnsafeRawBufferPointer`, validating all bounds.
    public static func read(bytes: UnsafeRawBufferPointer) throws -> RelocatableObject {
        let fileSize = bytes.count
        guard fileSize >= ELF64Constants.ehdrSize else {
            throw ELFReadError.truncatedHeader(expected: ELF64Constants.ehdrSize, actual: fileSize)
        }

        // 1. Validate ELF magic
        guard bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 else {
            throw ELFReadError.invalidMagic
        }

        // 2. Validate 64-bit little-endian
        let eiClass = bytes[4]
        guard eiClass == ELF64Constants.elfClass64 else {
            throw ELFReadError.unsupportedClass(eiClass)
        }

        let eiData = bytes[5]
        guard eiData == ELF64Constants.elfData2LSB else {
            throw ELFReadError.unsupportedEndianness(eiData)
        }

        // 3. Validate e_type == ET_REL (1)
        let eType = readUInt16(bytes, at: 16)
        guard eType == ELF64Constants.etRel else {
            throw ELFReadError.unsupportedObjectType(eType)
        }

        // 4. Map e_machine
        let eMachine = readUInt16(bytes, at: 18)
        let arch: ObjectArch
        switch eMachine {
        case ELF64Constants.emX86_64:
            arch = .x86_64
        case ELF64Constants.emAArch64:
            arch = .aarch64
        case ELF64Constants.emRISCV:
            arch = .riscv64
        default:
            throw ELFReadError.unsupportedMachine(eMachine)
        }

        let eShoff = readUInt64(bytes, at: 40)
        let eShentsize = Int(readUInt16(bytes, at: 58))
        let eShnum = Int(readUInt16(bytes, at: 60))
        let eShstrndx = readUInt16(bytes, at: 62)

        var obj = RelocatableObject(origin: .foreignELF, arch: arch, moduleId: .foreign)
        if eShnum == 0 {
            return obj
        }

        guard eShentsize >= ELF64Constants.shdrSize else {
            throw ELFReadError.outOfBoundsSectionHeaders(
                offset: eShoff,
                count: eShnum,
                entrySize: eShentsize,
                fileSize: fileSize
            )
        }

        let (shTableBytes, shOverflow1) = UInt64(eShnum).multipliedReportingOverflow(by: UInt64(eShentsize))
        let (shTableEnd, shOverflow2) = eShoff.addingReportingOverflow(shTableBytes)
        guard !shOverflow1, !shOverflow2, shTableEnd <= UInt64(fileSize) else {
            throw ELFReadError.outOfBoundsSectionHeaders(
                offset: eShoff,
                count: eShnum,
                entrySize: eShentsize,
                fileSize: fileSize
            )
        }

        // 5. Parse section headers and validate section data bounds
        var shdrs: [RawELFSectionHeader] = []
        shdrs.reserveCapacity(eShnum)
        for i in 0..<eShnum {
            let base = Int(eShoff) + i * eShentsize
            let shdr = RawELFSectionHeader(
                shName: readUInt32(bytes, at: base),
                shType: readUInt32(bytes, at: base + 4),
                shFlags: readUInt64(bytes, at: base + 8),
                shAddr: readUInt64(bytes, at: base + 16),
                shOffset: readUInt64(bytes, at: base + 24),
                shSize: readUInt64(bytes, at: base + 32),
                shLink: readUInt32(bytes, at: base + 40),
                shInfo: readUInt32(bytes, at: base + 44),
                shAddralign: readUInt64(bytes, at: base + 48),
                shEntsize: readUInt64(bytes, at: base + 56)
            )
            if shdr.shType != ELF64Constants.shtNull && shdr.shType != ELF64Constants.shtNobits && shdr.shSize > 0 {
                let (endOff, over) = shdr.shOffset.addingReportingOverflow(shdr.shSize)
                guard !over, endOff <= UInt64(fileSize) else {
                    throw ELFReadError.outOfBoundsSectionData(
                        sectionIndex: i,
                        offset: shdr.shOffset,
                        size: shdr.shSize,
                        fileSize: fileSize
                    )
                }
            }
            shdrs.append(shdr)
        }

        // 6. Validate e_shstrndx
        guard Int(eShstrndx) < eShnum else {
            throw ELFReadError.invalidStringTableIndex(eShstrndx)
        }
        let shstrHdr = shdrs[Int(eShstrndx)]
        guard shstrHdr.shType == ELF64Constants.shtStrtab || eShstrndx == 0 else {
            throw ELFReadError.invalidStringTableIndex(eShstrndx)
        }

        // 7. Create user sections in `obj`
        var elfSecToObjSec: [Int: SectionIndex] = [:]
        var symTypesElfSecIndices: [Int] = []

        for elfIdx in 1..<eShnum {
            let shdr = shdrs[elfIdx]
            switch shdr.shType {
            case ELF64Constants.shtNull,
                 ELF64Constants.shtSymtab,
                 ELF64Constants.shtStrtab,
                 ELF64Constants.shtRela,
                 ELF64Constants.shtRel:
                continue
            default:
                break
            }

            let name = readNullTerminatedString(bytes, tableHeader: shstrHdr, offset: shdr.shName)
            let kind = classifySectionKind(name: name, shType: shdr.shType, shFlags: shdr.shFlags)
            let flags = SectionFlags(rawValue: UInt32(truncatingIfNeeded: shdr.shFlags))
            let alignLog2: UInt8 = shdr.shAddralign <= 1 ? 0 : UInt8(shdr.shAddralign.trailingZeroBitCount)

            let secIdx: SectionIndex
            if kind.isNobits {
                secIdx = obj.addSection(
                    name: name,
                    kind: kind,
                    flags: flags,
                    alignLog2: alignLog2,
                    bytes: [],
                    nobitsSize: UInt32(truncatingIfNeeded: shdr.shSize)
                )
            } else {
                let start = Int(shdr.shOffset)
                let end = start + Int(shdr.shSize)
                let dataSlice = start < end ? Array(bytes[start..<end]) : []
                secIdx = obj.addSection(
                    name: name,
                    kind: kind,
                    flags: flags,
                    alignLog2: alignLog2,
                    bytes: dataSlice
                )
            }
            elfSecToObjSec[elfIdx] = secIdx
            if kind == .ssSymTypes || name == ".ss_symtypes" {
                symTypesElfSecIndices.append(elfIdx)
            }
        }

        // 8. Parse .symtab (if present)
        var elfSymToObjSym: [UInt32: SymbolIndex] = [0: .nilId]
        for elfIdx in 1..<eShnum where shdrs[elfIdx].shType == ELF64Constants.shtSymtab {
            let symHdr = shdrs[elfIdx]
            guard Int(symHdr.shLink) < eShnum else {
                throw ELFReadError.corruptSymbolTable("sh_link \(symHdr.shLink) out of range")
            }
            let strHdr = shdrs[Int(symHdr.shLink)]
            guard strHdr.shType == ELF64Constants.shtStrtab else {
                throw ELFReadError.corruptSymbolTable("sh_link \(symHdr.shLink) is not SHT_STRTAB")
            }
            let entSize = symHdr.shEntsize == 0 ? UInt64(ELF64Constants.symEntrySize) : symHdr.shEntsize
            guard entSize >= UInt64(ELF64Constants.symEntrySize), symHdr.shSize % entSize == 0 else {
                throw ELFReadError.corruptSymbolTable("invalid sh_size \(symHdr.shSize) or sh_entsize \(entSize)")
            }

            let symCount = Int(symHdr.shSize / entSize)
            if symCount > 1 {
                for symI in 1..<symCount {
                    let base = Int(symHdr.shOffset) + symI * Int(entSize)
                    let stName = readUInt32(bytes, at: base)
                    let stInfo = bytes[base + 4]
                    let stOther = bytes[base + 5]
                    let stShndx = readUInt16(bytes, at: base + 6)
                    let stValue = readUInt64(bytes, at: base + 8)
                    let stSize = readUInt64(bytes, at: base + 16)

                    let symName = readNullTerminatedString(bytes, tableHeader: strHdr, offset: stName)
                    let binding = decodeSymbolBinding(stInfo >> 4)
                    let symKind = decodeSymbolKind(stInfo & 0x0F)
                    let visibility = decodeSymbolVisibility(stOther & 0x03)

                    let section: SectionIndex
                    if stShndx == ELF64Constants.shnUndef {
                        section = .undefined
                    } else if stShndx == ELF64Constants.shnAbs {
                        section = .absolute
                    } else if stShndx == ELF64Constants.shnCommon {
                        section = .common
                    } else {
                        section = elfSecToObjSec[Int(stShndx)] ?? .undefined
                    }

                    let objSym = obj.addSymbol(
                        name: symName,
                        section: section,
                        value: stValue,
                        size: stSize,
                        binding: binding,
                        visibility: visibility,
                        kind: symKind
                    )
                    elfSymToObjSym[UInt32(symI)] = objSym
                }
            }
        }

        // 9. Populate symbolTypes from any `.ss_symtypes` section
        for symTypesElfIdx in symTypesElfSecIndices {
            let shdr = shdrs[symTypesElfIdx]
            let count = Int(shdr.shSize) / 24
            for i in 0..<count {
                let base = Int(shdr.shOffset) + i * 24
                let elfSymIdx = readUInt32(bytes, at: base)
                let kind = bytes[base + 4]
                let lang = bytes[base + 5]
                let flags = readUInt16(bytes, at: base + 6)
                let sigHash = readUInt64(bytes, at: base + 8)
                let providerMod = readUInt32(bytes, at: base + 16)
                let reserved = readUInt32(bytes, at: base + 20)

                if let mappedSym = elfSymToObjSym[elfSymIdx], mappedSym.isValid {
                    let rec = SymbolTypeRecord(
                        symbolIndex: mappedSym.rawIndex,
                        kind: kind,
                        language: lang,
                        flags: flags,
                        signatureHash: sigHash,
                        providerModule: providerMod,
                        reserved: reserved
                    )
                    obj.setSymbolType(mappedSym, rec)
                }
            }
        }

        // 10. Parse .rela.* sections
        for elfIdx in 1..<eShnum where shdrs[elfIdx].shType == ELF64Constants.shtRela {
            let relaHdr = shdrs[elfIdx]
            let entSize = relaHdr.shEntsize == 0 ? UInt64(ELF64Constants.relaEntrySize) : relaHdr.shEntsize
            guard entSize >= UInt64(ELF64Constants.relaEntrySize), relaHdr.shSize % entSize == 0 else {
                throw ELFReadError.corruptRelocationTable("invalid sh_size \(relaHdr.shSize) or sh_entsize \(entSize)")
            }
            guard let targetSec = elfSecToObjSec[Int(relaHdr.shInfo)] else {
                continue
            }

            let relocCount = Int(relaHdr.shSize / entSize)
            for r in 0..<relocCount {
                let base = Int(relaHdr.shOffset) + r * Int(entSize)
                let rOffset = readUInt64(bytes, at: base)
                let rInfo = readUInt64(bytes, at: base + 8)
                let rAddend = readInt64(bytes, at: base + 16)

                let elfSymIdx = UInt32(rInfo >> 32)
                let elfType = UInt32(rInfo & 0xFFFF_FFFF)
                let mappedSym = elfSymToObjSym[elfSymIdx] ?? .nilId
                let kind = RelocKind.fromELFType(elfType, arch: arch)

                obj.addRelocation(
                    section: targetSec,
                    offset: rOffset,
                    symbol: mappedSym,
                    kind: kind,
                    addend: rAddend
                )
            }
        }

        return obj
    }

    // MARK: - Private Decoding Helpers

    private static func classifySectionKind(name: String, shType: UInt32, shFlags: UInt64) -> SectionKind {
        if shType == ELF64Constants.shtRiscvAttributes || name == ".riscv.attributes" {
            return .riscvAttributes
        }
        if shType == ELF64Constants.shtNote || name.hasPrefix(".note") {
            return .note
        }
        if name == ".text" || name.hasPrefix(".text.") {
            return .text
        }
        if name == ".rodata" || name.hasPrefix(".rodata.") {
            return .rodata
        }
        if name == ".data" || name.hasPrefix(".data.") {
            return .data
        }
        if name == ".bss" || name.hasPrefix(".bss.") {
            return .bss
        }
        if name == ".sdata" || name.hasPrefix(".sdata.") {
            return .sdata
        }
        if name == ".sbss" || name.hasPrefix(".sbss.") {
            return .sbss
        }
        if name == ".tdata" || name.hasPrefix(".tdata.") {
            return .tdata
        }
        if name == ".tbss" || name.hasPrefix(".tbss.") {
            return .tbss
        }
        if name == ".eh_frame" || shType == ELF64Constants.shtX86_64Unwind {
            return .ehFrame
        }
        if name == ".ss_symtypes" {
            return .ssSymTypes
        }
        if name == ".ss_debug" {
            return .ssDebug
        }
        if name == ".ss_unwind" {
            return .ssUnwind
        }
        if shType == ELF64Constants.shtNobits {
            return .customNobits
        }
        return .customProgbits
    }

    private static func decodeSymbolBinding(_ raw: UInt8) -> SymbolBinding {
        switch raw {
        case 0: return .local
        case 1: return .global
        case 2: return .weak
        default: return .global
        }
    }

    private static func decodeSymbolKind(_ raw: UInt8) -> SymbolKind {
        switch raw {
        case 0: return .noType
        case 1: return .object
        case 2: return .function
        case 3: return .section
        case 4: return .file
        case 5: return .common
        case 6: return .tls
        default: return .noType
        }
    }

    private static func decodeSymbolVisibility(_ raw: UInt8) -> SymbolVisibility {
        switch raw {
        case 0: return .defaultVis
        case 1: return .internalVis
        case 2: return .hidden
        case 3: return .protected
        default: return .defaultVis
        }
    }

    private static func readNullTerminatedString(
        _ bytes: UnsafeRawBufferPointer,
        tableHeader: RawELFSectionHeader,
        offset: UInt32
    ) -> String {
        guard UInt64(offset) < tableHeader.shSize else { return "" }
        let start = Int(tableHeader.shOffset + UInt64(offset))
        let maxEnd = Int(tableHeader.shOffset + tableHeader.shSize)
        guard start >= 0 && start < maxEnd && maxEnd <= bytes.count else { return "" }

        var cur = start
        while cur < maxEnd && bytes[cur] != 0 {
            cur += 1
        }
        guard cur > start else { return "" }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[start..<cur])
        return String(decoding: slice, as: UTF8.self)
    }

    @inline(__always)
    private static func readUInt16(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    @inline(__always)
    private static func readUInt64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32(bytes, at: offset))
        let hi = UInt64(readUInt32(bytes, at: offset + 4))
        return lo | (hi << 32)
    }

    @inline(__always)
    private static func readInt64(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int64 {
        Int64(bitPattern: readUInt64(bytes, at: offset))
    }
}
