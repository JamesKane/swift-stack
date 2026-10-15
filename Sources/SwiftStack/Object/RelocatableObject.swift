// Sources/SwiftStack/Object/RelocatableObject.swift

// MARK: - TypedId Handles for Object Model

/// Handle identifying a module in the object model (06-linker.md §5.1).
/// Row 0 (`.foreign`) represents foreign/unattributed objects.
@frozen
public struct ModuleId: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    public static let foreign = ModuleId(0)
}

/// Handle indexing into a `RelocatableObject`'s symbol columns (row 0 is the nil/STN_UNDEF symbol).
@frozen
public struct SymbolIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Handle indexing into a `RelocatableObject`'s `relocs` column (row 0 is the nil relocation).
@frozen
public struct RelocIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Handle indexing into a `RelocatableObject`'s `bytes` payload column (row 0 is reserved nil byte).
@frozen
public struct ByteIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

/// Handle indexing into a `RelocatableObject`'s `unwind` CUD column (row 0 is the nil record).
@frozen
public struct UnwindIndex: TypedId {
    public let rawIndex: UInt32

    @inlinable
    public init(rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }

    @inlinable
    public init(_ rawIndex: UInt32) {
        self.rawIndex = rawIndex
    }
}

extension SectionIndex {
    /// Undefined section (`SHN_UNDEF` = 0).
    public static let undefined = SectionIndex(0)
    /// Absolute symbol value pseudo-section (`SHN_ABS` = 0xFFF1).
    public static let absolute = SectionIndex(0xFFF1)
    /// Common symbol pseudo-section (`SHN_COMMON` = 0xFFF2).
    public static let common = SectionIndex(0xFFF2)

    /// Returns true if this is a special pseudo-section (`undefined`, `absolute`, `common`).
    @inlinable
    public var isSpecial: Bool {
        rawIndex == 0 || rawIndex >= 0xFF00
    }
}

/// Namespace of special ELF-compatible section indices.
public enum SpecialSectionIndex {
    public static let undefined = SectionIndex.undefined
    public static let absolute = SectionIndex.absolute
    public static let common = SectionIndex.common
}

// MARK: - Target & Origin Enumerations

/// Target instruction set architecture for a relocatable object.
@frozen
public enum ObjectArch: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case x86_64 = 0
    case aarch64 = 1
    case riscv64 = 2

    public var description: String {
        switch self {
        case .x86_64: return "x86_64"
        case .aarch64: return "aarch64"
        case .riscv64: return "riscv64"
        }
    }
}

/// Origin of a `RelocatableObject` (06-linker.md §5.1).
@frozen
public enum ObjectOrigin: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case compiled = 0
    case assembled = 1
    case foreignELF = 2
    case foreignMachO = 3

    public static let assembler: ObjectOrigin = .assembled

    public var description: String {
        switch self {
        case .compiled: return "compiled"
        case .assembled: return "assembled"
        case .foreignELF: return "foreignELF"
        case .foreignMachO: return "foreignMachO"
        }
    }
}

// MARK: - Section Types & Flags

/// Semantic section kind in `RelocatableObject` (06-linker.md §5.1).
@frozen
public enum SectionKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case null = 0
    case text = 1
    case rodata = 2
    case data = 3
    case bss = 4
    case sdata = 5
    case sbss = 6
    case tdata = 7
    case tbss = 8
    case ehFrame = 9
    case ssSymTypes = 10
    case ssDebug = 11
    case ssUnwind = 12
    case riscvAttributes = 13
    case customProgbits = 14
    case customNobits = 15
    case note = 16

    /// True if this section occupies no bytes in the object file (`SHT_NOBITS`).
    @inlinable
    public var isNobits: Bool {
        switch self {
        case .bss, .sbss, .tbss, .customNobits:
            return true
        default:
            return false
        }
    }

    /// Standard ELF section flags associated with this kind by default.
    @inlinable
    public var defaultFlags: SectionFlags {
        switch self {
        case .null, .ssSymTypes, .ssDebug, .riscvAttributes, .customProgbits, .customNobits:
            return []
        case .text:
            return [.alloc, .execinstr]
        case .rodata, .ehFrame, .ssUnwind, .note:
            return [.alloc]
        case .data, .bss, .sdata, .sbss:
            return [.alloc, .write]
        case .tdata, .tbss:
            return [.alloc, .write, .tls]
        }
    }

    public var description: String {
        switch self {
        case .null: return "null"
        case .text: return "text"
        case .rodata: return "rodata"
        case .data: return "data"
        case .bss: return "bss"
        case .sdata: return "sdata"
        case .sbss: return "sbss"
        case .tdata: return "tdata"
        case .tbss: return "tbss"
        case .ehFrame: return "ehFrame"
        case .ssSymTypes: return "ssSymTypes"
        case .ssDebug: return "ssDebug"
        case .ssUnwind: return "ssUnwind"
        case .riscvAttributes: return "riscvAttributes"
        case .customProgbits: return "customProgbits"
        case .customNobits: return "customNobits"
        case .note: return "note"
        }
    }
}

/// ELF-compatible section flags (`sh_flags`).
@frozen
public struct SectionFlags: OptionSet, BitwiseCopyable, Sendable, Equatable, Hashable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// `SHF_WRITE` (0x1): Section contains writable data.
    public static let write = SectionFlags(rawValue: 0x1)
    /// `SHF_ALLOC` (0x2): Section occupies memory during execution.
    public static let alloc = SectionFlags(rawValue: 0x2)
    /// `SHF_EXECINSTR` (0x4): Section contains executable machine instructions.
    public static let execinstr = SectionFlags(rawValue: 0x4)
    public static let execInstr = SectionFlags(rawValue: 0x4)
    /// `SHF_MERGE` (0x10): Section data might be merged to eliminate duplication.
    public static let merge = SectionFlags(rawValue: 0x10)
    /// `SHF_STRINGS` (0x20): Section contains null-terminated character strings.
    public static let strings = SectionFlags(rawValue: 0x20)
    /// `SHF_INFO_LINK` (0x40): `sh_info` holds a section header table index.
    public static let infoLink = SectionFlags(rawValue: 0x40)
    /// `SHF_GROUP` (0x200): Section is member of a group.
    public static let group = SectionFlags(rawValue: 0x200)
    /// `SHF_TLS` (0x400): Section holds thread-local data.
    public static let tls = SectionFlags(rawValue: 0x400)
}

/// Contiguous byte slice inside `RelocatableObject.bytes`.
/// For `.bss`/`.tbss`/nobits sections, `start` is 0 and `count` stores the section size in bytes.
@frozen
public struct ByteRange: BitwiseCopyable, Sendable, Equatable, Hashable {
    public var start: UInt32
    public var count: UInt32

    @inlinable
    public init(start: UInt32 = 0, count: UInt32 = 0) {
        self.start = start
        self.count = count
    }
}

// MARK: - Symbol Types & Metadata

/// Symbol linkage binding (`STB_*`).
@frozen
public enum SymbolBinding: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case local = 0
    case global = 1
    case weak = 2

    public var description: String {
        switch self {
        case .local: return "local"
        case .global: return "global"
        case .weak: return "weak"
        }
    }
}

/// Symbol visibility (`STV_*`).
@frozen
public enum SymbolVisibility: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case defaultVis = 0
    case internalVis = 1
    case hidden = 2
    case protected = 3

    public static let defaultVisibility: SymbolVisibility = .defaultVis
    public static let internalVisibility: SymbolVisibility = .internalVis

    public var description: String {
        switch self {
        case .defaultVis: return "default"
        case .internalVis: return "internal"
        case .hidden: return "hidden"
        case .protected: return "protected"
        }
    }
}

/// Symbol classification (`STT_*`).
@frozen
public enum SymbolKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case noType = 0
    case object = 1
    case function = 2
    case section = 3
    case file = 4
    case common = 5
    case tls = 6

    public static let notype: SymbolKind = .noType
    public static let funcSymbol: SymbolKind = .function

    public var description: String {
        switch self {
        case .noType: return "noType"
        case .object: return "object"
        case .function: return "function"
        case .section: return "section"
        case .file: return "file"
        case .common: return "common"
        case .tls: return "tls"
        }
    }
}

/// Link-time type checking record stored in `.ss_symtypes` (06-linker.md §5.3).
/// Normative layout: 24 bytes, alignment 8.
@frozen
public struct SymbolTypeRecord: BitwiseCopyable, Sendable, Equatable, Hashable {
    public var symbolIndex: UInt32
    public var kind: UInt8
    public var language: UInt8
    public var flags: UInt16
    public var signatureHash: UInt64
    public var providerModule: UInt32
    public var reserved: UInt32

    @inlinable
    public init(
        symbolIndex: UInt32 = 0,
        kind: UInt8 = 0,
        language: UInt8 = 0,
        flags: UInt16 = 0,
        signatureHash: UInt64 = 0,
        providerModule: UInt32 = 0,
        reserved: UInt32 = 0
    ) {
        self.symbolIndex = symbolIndex
        self.kind = kind
        self.language = language
        self.flags = flags
        self.signatureHash = signatureHash
        self.providerModule = providerModule
        self.reserved = reserved
    }
}

// MARK: - Relocation Model

/// Target-neutral relocation enumeration with a 1:1 mapping to ELF64 relocation types
/// for x86-64, AArch64, and RISC-V 64 (06-linker.md §5.1, §5.5; 05-assembler.md §4.6-4.8).
@frozen
public enum RelocKind: UInt16, BitwiseCopyable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case none = 0

    // MARK: x86-64 ELF64 relocations
    case x86_64_64 = 1
    case x86_64_pc32 = 2
    case x86_64_got32 = 3
    case x86_64_plt32 = 4
    case x86_64_copy = 5
    case x86_64_globDat = 6
    case x86_64_jumpSlot = 7
    case x86_64_relative = 8
    case x86_64_gotpcrel = 9
    case x86_64_32 = 10
    case x86_64_32s = 11
    case x86_64_16 = 12
    case x86_64_pc16 = 13
    case x86_64_8 = 14
    case x86_64_pc8 = 15
    case x86_64_dtpmod64 = 16
    case x86_64_dtpoff64 = 17
    case x86_64_tpoff64 = 18
    case x86_64_tlsgd = 19
    case x86_64_tlsld = 20
    case x86_64_dtpoff32 = 21
    case x86_64_gottpoff = 22
    case x86_64_tpoff32 = 23
    case x86_64_pc64 = 24
    case x86_64_gotoff64 = 25
    case x86_64_gotpc32 = 26
    case x86_64_gotpcrelx = 41
    case x86_64_rexGotpcrelx = 42

    // MARK: AArch64 ELF64 relocations
    case aarch64_none = 100
    case aarch64_abs64 = 101
    case aarch64_abs32 = 102
    case aarch64_abs16 = 103
    case aarch64_prel64 = 104
    case aarch64_prel32 = 105
    case aarch64_prel16 = 106
    case aarch64_movwUabsG0 = 107
    case aarch64_movwUabsG0Nc = 108
    case aarch64_movwUabsG1 = 109
    case aarch64_movwUabsG1Nc = 110
    case aarch64_movwUabsG2 = 111
    case aarch64_movwUabsG2Nc = 112
    case aarch64_movwUabsG3 = 113
    case aarch64_movwSabsG0 = 114
    case aarch64_movwSabsG1 = 115
    case aarch64_movwSabsG2 = 116
    case aarch64_ldPrelLo19 = 117
    case aarch64_adrPrelLo21 = 118
    case aarch64_adrPrelPgHi21 = 119
    case aarch64_adrPrelPgHi21Nc = 120
    case aarch64_addAbsLo12Nc = 121
    case aarch64_ldst8AbsLo12Nc = 122
    case aarch64_tstbr14 = 123
    case aarch64_condbr19 = 124
    case aarch64_jump26 = 125
    case aarch64_call26 = 126
    case aarch64_ldst16AbsLo12Nc = 127
    case aarch64_ldst32AbsLo12Nc = 128
    case aarch64_ldst64AbsLo12Nc = 129
    case aarch64_ldst128AbsLo12Nc = 130
    case aarch64_adrGotPage = 131
    case aarch64_ld64GotLo12Nc = 132
    case aarch64_tlsleAddTprelHi12 = 133
    case aarch64_tlsleAddTprelLo12 = 134
    case aarch64_tlsleAddTprelLo12Nc = 135
    case aarch64_tlsieAdrGottprelPage21 = 136
    case aarch64_tlsieLd64GottprelLo12Nc = 137
    case aarch64_copy = 138
    case aarch64_globDat = 139
    case aarch64_jumpSlot = 140
    case aarch64_relative = 141

    // MARK: RISC-V ELF64 relocations
    case riscv_none = 200
    case riscv_32 = 201
    case riscv_64 = 202
    case riscv_relative = 203
    case riscv_copy = 204
    case riscv_jumpSlot = 205
    case riscv_tlsDtpmod32 = 206
    case riscv_tlsDtpmod64 = 207
    case riscv_tlsDtprel32 = 208
    case riscv_tlsDtprel64 = 209
    case riscv_tlsTprel32 = 210
    case riscv_tlsTprel64 = 211
    case riscv_branch = 216
    case riscv_jal = 217
    case riscv_call = 218
    case riscv_callPlt = 219
    case riscv_gotHi20 = 220
    case riscv_tlsGotHi20 = 221
    case riscv_tlsGdHi20 = 222
    case riscv_pcrelHi20 = 223
    case riscv_pcrelLo12I = 224
    case riscv_pcrelLo12S = 225
    case riscv_hi20 = 226
    case riscv_lo12I = 227
    case riscv_lo12S = 228
    case riscv_tprelHi20 = 229
    case riscv_tprelLo12I = 230
    case riscv_tprelLo12S = 231
    case riscv_tprelAdd = 232
    case riscv_add8 = 233
    case riscv_add16 = 234
    case riscv_add32 = 235
    case riscv_add64 = 236
    case riscv_sub8 = 237
    case riscv_sub16 = 238
    case riscv_sub32 = 239
    case riscv_sub64 = 240
    case riscv_align = 243
    case riscv_rvcBranch = 244
    case riscv_rvcJump = 245
    case riscv_relax = 251
    case riscv_sub6 = 252
    case riscv_set6 = 253
    case riscv_set8 = 254
    case riscv_set16 = 255
    case riscv_set32 = 256
    case riscv_32Pcrel = 257

    // Snake-case aliases for assembler & codegen ergonomics
    public static let aarch64_ld_prel_lo19: RelocKind = .aarch64_ldPrelLo19
    public static let aarch64_adr_prel_lo21: RelocKind = .aarch64_adrPrelLo21
    public static let aarch64_adr_prel_pg_hi21: RelocKind = .aarch64_adrPrelPgHi21
    public static let aarch64_adr_prel_pg_hi21_nc: RelocKind = .aarch64_adrPrelPgHi21Nc
    public static let aarch64_add_abs_lo12_nc: RelocKind = .aarch64_addAbsLo12Nc
    public static let aarch64_ldst8_abs_lo12_nc: RelocKind = .aarch64_ldst8AbsLo12Nc
    public static let aarch64_ldst16_abs_lo12_nc: RelocKind = .aarch64_ldst16AbsLo12Nc
    public static let aarch64_ldst32_abs_lo12_nc: RelocKind = .aarch64_ldst32AbsLo12Nc
    public static let aarch64_ldst64_abs_lo12_nc: RelocKind = .aarch64_ldst64AbsLo12Nc
    public static let aarch64_ldst128_abs_lo12_nc: RelocKind = .aarch64_ldst128AbsLo12Nc
    public static let aarch64_adr_got_page: RelocKind = .aarch64_adrGotPage
    public static let aarch64_ld64_got_lo12_nc: RelocKind = .aarch64_ld64GotLo12Nc
    public static let aarch64_tlsle_add_tprel_hi12: RelocKind = .aarch64_tlsleAddTprelHi12
    public static let aarch64_tlsle_add_tprel_lo12: RelocKind = .aarch64_tlsleAddTprelLo12
    public static let aarch64_tlsle_add_tprel_lo12_nc: RelocKind = .aarch64_tlsleAddTprelLo12Nc
    public static let aarch64_tlsie_adr_gottprel_page21: RelocKind = .aarch64_tlsieAdrGottprelPage21
    public static let aarch64_tlsie_ld64_gottprel_lo12_nc: RelocKind = .aarch64_tlsieLd64GottprelLo12Nc

    public static let riscv_call_plt: RelocKind = .riscv_callPlt
    public static let riscv_got_hi20: RelocKind = .riscv_gotHi20
    public static let riscv_pcrel_hi20: RelocKind = .riscv_pcrelHi20
    public static let riscv_pcrel_lo12_i: RelocKind = .riscv_pcrelLo12I
    public static let riscv_pcrel_lo12_s: RelocKind = .riscv_pcrelLo12S
    public static let riscv_lo12_i: RelocKind = .riscv_lo12I
    public static let riscv_lo12_s: RelocKind = .riscv_lo12S
    public static let riscv_tprel_hi20: RelocKind = .riscv_tprelHi20
    public static let riscv_tprel_lo12_i: RelocKind = .riscv_tprelLo12I
    public static let riscv_tprel_lo12_s: RelocKind = .riscv_tprelLo12S
    public static let riscv_tprel_add: RelocKind = .riscv_tprelAdd
    public static let riscv_rvc_branch: RelocKind = .riscv_rvcBranch
    public static let riscv_rvc_jump: RelocKind = .riscv_rvcJump
    public static let riscv_32_pcrel: RelocKind = .riscv_32Pcrel

    /// Converts this `RelocKind` to its architecture-specific ELF64 `r_type` code.
    public func toELFType(arch: ObjectArch) -> UInt32 {
        switch self {
        case .none, .aarch64_none, .riscv_none:
            return 0

        // x86-64
        case .x86_64_64: return 1
        case .x86_64_pc32: return 2
        case .x86_64_got32: return 3
        case .x86_64_plt32: return 4
        case .x86_64_copy: return 5
        case .x86_64_globDat: return 6
        case .x86_64_jumpSlot: return 7
        case .x86_64_relative: return 8
        case .x86_64_gotpcrel: return 9
        case .x86_64_32: return 10
        case .x86_64_32s: return 11
        case .x86_64_16: return 12
        case .x86_64_pc16: return 13
        case .x86_64_8: return 14
        case .x86_64_pc8: return 15
        case .x86_64_dtpmod64: return 16
        case .x86_64_dtpoff64: return 17
        case .x86_64_tpoff64: return 18
        case .x86_64_tlsgd: return 19
        case .x86_64_tlsld: return 20
        case .x86_64_dtpoff32: return 21
        case .x86_64_gottpoff: return 22
        case .x86_64_tpoff32: return 23
        case .x86_64_pc64: return 24
        case .x86_64_gotoff64: return 25
        case .x86_64_gotpc32: return 26
        case .x86_64_gotpcrelx: return 41
        case .x86_64_rexGotpcrelx: return 42

        // AArch64
        case .aarch64_abs64: return 257
        case .aarch64_abs32: return 258
        case .aarch64_abs16: return 259
        case .aarch64_prel64: return 260
        case .aarch64_prel32: return 261
        case .aarch64_prel16: return 262
        case .aarch64_movwUabsG0: return 263
        case .aarch64_movwUabsG0Nc: return 264
        case .aarch64_movwUabsG1: return 265
        case .aarch64_movwUabsG1Nc: return 266
        case .aarch64_movwUabsG2: return 267
        case .aarch64_movwUabsG2Nc: return 268
        case .aarch64_movwUabsG3: return 269
        case .aarch64_movwSabsG0: return 270
        case .aarch64_movwSabsG1: return 271
        case .aarch64_movwSabsG2: return 272
        case .aarch64_ldPrelLo19: return 273
        case .aarch64_adrPrelLo21: return 274
        case .aarch64_adrPrelPgHi21: return 275
        case .aarch64_adrPrelPgHi21Nc: return 276
        case .aarch64_addAbsLo12Nc: return 277
        case .aarch64_ldst8AbsLo12Nc: return 278
        case .aarch64_tstbr14: return 279
        case .aarch64_condbr19: return 280
        case .aarch64_jump26: return 282
        case .aarch64_call26: return 283
        case .aarch64_ldst16AbsLo12Nc: return 284
        case .aarch64_ldst32AbsLo12Nc: return 285
        case .aarch64_ldst64AbsLo12Nc: return 286
        case .aarch64_ldst128AbsLo12Nc: return 299
        case .aarch64_adrGotPage: return 311
        case .aarch64_ld64GotLo12Nc: return 312
        case .aarch64_tlsieAdrGottprelPage21: return 541
        case .aarch64_tlsieLd64GottprelLo12Nc: return 542
        case .aarch64_tlsleAddTprelHi12: return 549
        case .aarch64_tlsleAddTprelLo12: return 550
        case .aarch64_tlsleAddTprelLo12Nc: return 551
        case .aarch64_copy: return 1024
        case .aarch64_globDat: return 1025
        case .aarch64_jumpSlot: return 1026
        case .aarch64_relative: return 1027

        // RISC-V
        case .riscv_32: return 1
        case .riscv_64: return 2
        case .riscv_relative: return 3
        case .riscv_copy: return 4
        case .riscv_jumpSlot: return 5
        case .riscv_tlsDtpmod32: return 6
        case .riscv_tlsDtpmod64: return 7
        case .riscv_tlsDtprel32: return 8
        case .riscv_tlsDtprel64: return 9
        case .riscv_tlsTprel32: return 10
        case .riscv_tlsTprel64: return 11
        case .riscv_branch: return 16
        case .riscv_jal: return 17
        case .riscv_call: return 18
        case .riscv_callPlt: return 19
        case .riscv_gotHi20: return 20
        case .riscv_tlsGotHi20: return 21
        case .riscv_tlsGdHi20: return 22
        case .riscv_pcrelHi20: return 23
        case .riscv_pcrelLo12I: return 24
        case .riscv_pcrelLo12S: return 25
        case .riscv_hi20: return 26
        case .riscv_lo12I: return 27
        case .riscv_lo12S: return 28
        case .riscv_tprelHi20: return 29
        case .riscv_tprelLo12I: return 30
        case .riscv_tprelLo12S: return 31
        case .riscv_tprelAdd: return 32
        case .riscv_add8: return 33
        case .riscv_add16: return 34
        case .riscv_add32: return 35
        case .riscv_add64: return 36
        case .riscv_sub8: return 37
        case .riscv_sub16: return 38
        case .riscv_sub32: return 39
        case .riscv_sub64: return 40
        case .riscv_align: return 43
        case .riscv_rvcBranch: return 44
        case .riscv_rvcJump: return 45
        case .riscv_relax: return 51
        case .riscv_sub6: return 52
        case .riscv_set6: return 53
        case .riscv_set8: return 54
        case .riscv_set16: return 55
        case .riscv_set32: return 56
        case .riscv_32Pcrel: return 57
        }
    }

    /// Maps an architecture-specific ELF64 `r_type` code to its target-neutral `RelocKind`.
    public static func fromELFType(_ elfType: UInt32, arch: ObjectArch) -> RelocKind {
        switch arch {
        case .x86_64:
            switch elfType {
            case 0: return .none
            case 1: return .x86_64_64
            case 2: return .x86_64_pc32
            case 3: return .x86_64_got32
            case 4: return .x86_64_plt32
            case 5: return .x86_64_copy
            case 6: return .x86_64_globDat
            case 7: return .x86_64_jumpSlot
            case 8: return .x86_64_relative
            case 9: return .x86_64_gotpcrel
            case 10: return .x86_64_32
            case 11: return .x86_64_32s
            case 12: return .x86_64_16
            case 13: return .x86_64_pc16
            case 14: return .x86_64_8
            case 15: return .x86_64_pc8
            case 16: return .x86_64_dtpmod64
            case 17: return .x86_64_dtpoff64
            case 18: return .x86_64_tpoff64
            case 19: return .x86_64_tlsgd
            case 20: return .x86_64_tlsld
            case 21: return .x86_64_dtpoff32
            case 22: return .x86_64_gottpoff
            case 23: return .x86_64_tpoff32
            case 24: return .x86_64_pc64
            case 25: return .x86_64_gotoff64
            case 26: return .x86_64_gotpc32
            case 41: return .x86_64_gotpcrelx
            case 42: return .x86_64_rexGotpcrelx
            default: return .none
            }

        case .aarch64:
            switch elfType {
            case 0, 256: return .aarch64_none
            case 257: return .aarch64_abs64
            case 258: return .aarch64_abs32
            case 259: return .aarch64_abs16
            case 260: return .aarch64_prel64
            case 261: return .aarch64_prel32
            case 262: return .aarch64_prel16
            case 263: return .aarch64_movwUabsG0
            case 264: return .aarch64_movwUabsG0Nc
            case 265: return .aarch64_movwUabsG1
            case 266: return .aarch64_movwUabsG1Nc
            case 267: return .aarch64_movwUabsG2
            case 268: return .aarch64_movwUabsG2Nc
            case 269: return .aarch64_movwUabsG3
            case 270: return .aarch64_movwSabsG0
            case 271: return .aarch64_movwSabsG1
            case 272: return .aarch64_movwSabsG2
            case 273: return .aarch64_ldPrelLo19
            case 274: return .aarch64_adrPrelLo21
            case 275: return .aarch64_adrPrelPgHi21
            case 276: return .aarch64_adrPrelPgHi21Nc
            case 277: return .aarch64_addAbsLo12Nc
            case 278: return .aarch64_ldst8AbsLo12Nc
            case 279: return .aarch64_tstbr14
            case 280: return .aarch64_condbr19
            case 282: return .aarch64_jump26
            case 283: return .aarch64_call26
            case 284: return .aarch64_ldst16AbsLo12Nc
            case 285: return .aarch64_ldst32AbsLo12Nc
            case 286: return .aarch64_ldst64AbsLo12Nc
            case 299: return .aarch64_ldst128AbsLo12Nc
            case 311: return .aarch64_adrGotPage
            case 312: return .aarch64_ld64GotLo12Nc
            case 541: return .aarch64_tlsieAdrGottprelPage21
            case 542: return .aarch64_tlsieLd64GottprelLo12Nc
            case 549: return .aarch64_tlsleAddTprelHi12
            case 550: return .aarch64_tlsleAddTprelLo12
            case 551: return .aarch64_tlsleAddTprelLo12Nc
            case 1024: return .aarch64_copy
            case 1025: return .aarch64_globDat
            case 1026: return .aarch64_jumpSlot
            case 1027: return .aarch64_relative
            default: return .none
            }

        case .riscv64:
            switch elfType {
            case 0: return .riscv_none
            case 1: return .riscv_32
            case 2: return .riscv_64
            case 3: return .riscv_relative
            case 4: return .riscv_copy
            case 5: return .riscv_jumpSlot
            case 6: return .riscv_tlsDtpmod32
            case 7: return .riscv_tlsDtpmod64
            case 8: return .riscv_tlsDtprel32
            case 9: return .riscv_tlsDtprel64
            case 10: return .riscv_tlsTprel32
            case 11: return .riscv_tlsTprel64
            case 16: return .riscv_branch
            case 17: return .riscv_jal
            case 18: return .riscv_call
            case 19: return .riscv_callPlt
            case 20: return .riscv_gotHi20
            case 21: return .riscv_tlsGotHi20
            case 22: return .riscv_tlsGdHi20
            case 23: return .riscv_pcrelHi20
            case 24: return .riscv_pcrelLo12I
            case 25: return .riscv_pcrelLo12S
            case 26: return .riscv_hi20
            case 27: return .riscv_lo12I
            case 28: return .riscv_lo12S
            case 29: return .riscv_tprelHi20
            case 30: return .riscv_tprelLo12I
            case 31: return .riscv_tprelLo12S
            case 32: return .riscv_tprelAdd
            case 33: return .riscv_add8
            case 34: return .riscv_add16
            case 35: return .riscv_add32
            case 36: return .riscv_add64
            case 37: return .riscv_sub8
            case 38: return .riscv_sub16
            case 39: return .riscv_sub32
            case 40: return .riscv_sub64
            case 43: return .riscv_align
            case 44: return .riscv_rvcBranch
            case 45: return .riscv_rvcJump
            case 51: return .riscv_relax
            case 52: return .riscv_sub6
            case 53: return .riscv_set6
            case 54: return .riscv_set8
            case 55: return .riscv_set16
            case 56: return .riscv_set32
            case 57: return .riscv_32Pcrel
            default: return .none
            }
        }
    }

    public var description: String {
        switch self {
        case .none: return "R_NONE"
        case .x86_64_64: return "R_X86_64_64"
        case .x86_64_pc32: return "R_X86_64_PC32"
        case .x86_64_got32: return "R_X86_64_GOT32"
        case .x86_64_plt32: return "R_X86_64_PLT32"
        case .x86_64_copy: return "R_X86_64_COPY"
        case .x86_64_globDat: return "R_X86_64_GLOB_DAT"
        case .x86_64_jumpSlot: return "R_X86_64_JUMP_SLOT"
        case .x86_64_relative: return "R_X86_64_RELATIVE"
        case .x86_64_gotpcrel: return "R_X86_64_GOTPCREL"
        case .x86_64_32: return "R_X86_64_32"
        case .x86_64_32s: return "R_X86_64_32S"
        case .x86_64_16: return "R_X86_64_16"
        case .x86_64_pc16: return "R_X86_64_PC16"
        case .x86_64_8: return "R_X86_64_8"
        case .x86_64_pc8: return "R_X86_64_PC8"
        case .x86_64_dtpmod64: return "R_X86_64_DTPMOD64"
        case .x86_64_dtpoff64: return "R_X86_64_DTPOFF64"
        case .x86_64_tpoff64: return "R_X86_64_TPOFF64"
        case .x86_64_tlsgd: return "R_X86_64_TLSGD"
        case .x86_64_tlsld: return "R_X86_64_TLSLD"
        case .x86_64_dtpoff32: return "R_X86_64_DTPOFF32"
        case .x86_64_gottpoff: return "R_X86_64_GOTTPOFF"
        case .x86_64_tpoff32: return "R_X86_64_TPOFF32"
        case .x86_64_pc64: return "R_X86_64_PC64"
        case .x86_64_gotoff64: return "R_X86_64_GOTOFF64"
        case .x86_64_gotpc32: return "R_X86_64_GOTPC32"
        case .x86_64_gotpcrelx: return "R_X86_64_GOTPCRELX"
        case .x86_64_rexGotpcrelx: return "R_X86_64_REX_GOTPCRELX"

        case .aarch64_none: return "R_AARCH64_NONE"
        case .aarch64_abs64: return "R_AARCH64_ABS64"
        case .aarch64_abs32: return "R_AARCH64_ABS32"
        case .aarch64_abs16: return "R_AARCH64_ABS16"
        case .aarch64_prel64: return "R_AARCH64_PREL64"
        case .aarch64_prel32: return "R_AARCH64_PREL32"
        case .aarch64_prel16: return "R_AARCH64_PREL16"
        case .aarch64_movwUabsG0: return "R_AARCH64_MOVW_UABS_G0"
        case .aarch64_movwUabsG0Nc: return "R_AARCH64_MOVW_UABS_G0_NC"
        case .aarch64_movwUabsG1: return "R_AARCH64_MOVW_UABS_G1"
        case .aarch64_movwUabsG1Nc: return "R_AARCH64_MOVW_UABS_G1_NC"
        case .aarch64_movwUabsG2: return "R_AARCH64_MOVW_UABS_G2"
        case .aarch64_movwUabsG2Nc: return "R_AARCH64_MOVW_UABS_G2_NC"
        case .aarch64_movwUabsG3: return "R_AARCH64_MOVW_UABS_G3"
        case .aarch64_movwSabsG0: return "R_AARCH64_MOVW_SABS_G0"
        case .aarch64_movwSabsG1: return "R_AARCH64_MOVW_SABS_G1"
        case .aarch64_movwSabsG2: return "R_AARCH64_MOVW_SABS_G2"
        case .aarch64_ldPrelLo19: return "R_AARCH64_LD_PREL_LO19"
        case .aarch64_adrPrelLo21: return "R_AARCH64_ADR_PREL_LO21"
        case .aarch64_adrPrelPgHi21: return "R_AARCH64_ADR_PREL_PG_HI21"
        case .aarch64_adrPrelPgHi21Nc: return "R_AARCH64_ADR_PREL_PG_HI21_NC"
        case .aarch64_addAbsLo12Nc: return "R_AARCH64_ADD_ABS_LO12_NC"
        case .aarch64_ldst8AbsLo12Nc: return "R_AARCH64_LDST8_ABS_LO12_NC"
        case .aarch64_tstbr14: return "R_AARCH64_TSTBR14"
        case .aarch64_condbr19: return "R_AARCH64_CONDBR19"
        case .aarch64_jump26: return "R_AARCH64_JUMP26"
        case .aarch64_call26: return "R_AARCH64_CALL26"
        case .aarch64_ldst16AbsLo12Nc: return "R_AARCH64_LDST16_ABS_LO12_NC"
        case .aarch64_ldst32AbsLo12Nc: return "R_AARCH64_LDST32_ABS_LO12_NC"
        case .aarch64_ldst64AbsLo12Nc: return "R_AARCH64_LDST64_ABS_LO12_NC"
        case .aarch64_ldst128AbsLo12Nc: return "R_AARCH64_LDST128_ABS_LO12_NC"
        case .aarch64_adrGotPage: return "R_AARCH64_ADR_GOT_PAGE"
        case .aarch64_ld64GotLo12Nc: return "R_AARCH64_LD64_GOT_LO12_NC"
        case .aarch64_tlsleAddTprelHi12: return "R_AARCH64_TLSLE_ADD_TPREL_HI12"
        case .aarch64_tlsleAddTprelLo12: return "R_AARCH64_TLSLE_ADD_TPREL_LO12"
        case .aarch64_tlsleAddTprelLo12Nc: return "R_AARCH64_TLSLE_ADD_TPREL_LO12_NC"
        case .aarch64_tlsieAdrGottprelPage21: return "R_AARCH64_TLSIE_ADR_GOTTPREL_PAGE21"
        case .aarch64_tlsieLd64GottprelLo12Nc: return "R_AARCH64_TLSIE_LD64_GOTTPREL_LO12_NC"
        case .aarch64_copy: return "R_AARCH64_COPY"
        case .aarch64_globDat: return "R_AARCH64_GLOB_DAT"
        case .aarch64_jumpSlot: return "R_AARCH64_JUMP_SLOT"
        case .aarch64_relative: return "R_AARCH64_RELATIVE"

        case .riscv_none: return "R_RISCV_NONE"
        case .riscv_32: return "R_RISCV_32"
        case .riscv_64: return "R_RISCV_64"
        case .riscv_relative: return "R_RISCV_RELATIVE"
        case .riscv_copy: return "R_RISCV_COPY"
        case .riscv_jumpSlot: return "R_RISCV_JUMP_SLOT"
        case .riscv_tlsDtpmod32: return "R_RISCV_TLS_DTPMOD32"
        case .riscv_tlsDtpmod64: return "R_RISCV_TLS_DTPMOD64"
        case .riscv_tlsDtprel32: return "R_RISCV_TLS_DTPREL32"
        case .riscv_tlsDtprel64: return "R_RISCV_TLS_DTPREL64"
        case .riscv_tlsTprel32: return "R_RISCV_TLS_TPREL32"
        case .riscv_tlsTprel64: return "R_RISCV_TLS_TPREL64"
        case .riscv_branch: return "R_RISCV_BRANCH"
        case .riscv_jal: return "R_RISCV_JAL"
        case .riscv_call: return "R_RISCV_CALL"
        case .riscv_callPlt: return "R_RISCV_CALL_PLT"
        case .riscv_gotHi20: return "R_RISCV_GOT_HI20"
        case .riscv_tlsGotHi20: return "R_RISCV_TLS_GOT_HI20"
        case .riscv_tlsGdHi20: return "R_RISCV_TLS_GD_HI20"
        case .riscv_pcrelHi20: return "R_RISCV_PCREL_HI20"
        case .riscv_pcrelLo12I: return "R_RISCV_PCREL_LO12_I"
        case .riscv_pcrelLo12S: return "R_RISCV_PCREL_LO12_S"
        case .riscv_hi20: return "R_RISCV_HI20"
        case .riscv_lo12I: return "R_RISCV_LO12_I"
        case .riscv_lo12S: return "R_RISCV_LO12_S"
        case .riscv_tprelHi20: return "R_RISCV_TPREL_HI20"
        case .riscv_tprelLo12I: return "R_RISCV_TPREL_LO12_I"
        case .riscv_tprelLo12S: return "R_RISCV_TPREL_LO12_S"
        case .riscv_tprelAdd: return "R_RISCV_TPREL_ADD"
        case .riscv_add8: return "R_RISCV_ADD8"
        case .riscv_add16: return "R_RISCV_ADD16"
        case .riscv_add32: return "R_RISCV_ADD32"
        case .riscv_add64: return "R_RISCV_ADD64"
        case .riscv_sub8: return "R_RISCV_SUB8"
        case .riscv_sub16: return "R_RISCV_SUB16"
        case .riscv_sub32: return "R_RISCV_SUB32"
        case .riscv_sub64: return "R_RISCV_SUB64"
        case .riscv_align: return "R_RISCV_ALIGN"
        case .riscv_rvcBranch: return "R_RISCV_RVC_BRANCH"
        case .riscv_rvcJump: return "R_RISCV_RVC_JUMP"
        case .riscv_relax: return "R_RISCV_RELAX"
        case .riscv_sub6: return "R_RISCV_SUB6"
        case .riscv_set6: return "R_RISCV_SET6"
        case .riscv_set8: return "R_RISCV_SET8"
        case .riscv_set16: return "R_RISCV_SET16"
        case .riscv_set32: return "R_RISCV_SET32"
        case .riscv_32Pcrel: return "R_RISCV_32_PCREL"
        }
    }
}

/// 24-byte AoS relocation record (06-linker.md §5.1, 18-data-catalog.md §5.4).
@frozen
public struct Relocation: BitwiseCopyable, Sendable, Equatable, Hashable {
    public var offset: UInt64
    public var addend: Int64
    public var symbol: SymbolIndex
    public var kind: RelocKind
    public var flags: UInt16

    @inlinable
    public init(
        offset: UInt64 = 0,
        addend: Int64 = 0,
        symbol: SymbolIndex = .nilId,
        kind: RelocKind = .none,
        flags: UInt16 = 0
    ) {
        self.offset = offset
        self.addend = addend
        self.symbol = symbol
        self.kind = kind
        self.flags = flags
    }
}

// MARK: - Unwind & Debug Descriptors

/// Compact Unwind Descriptor (CUD) record (06-linker.md §5.1, §5.6; 07-debugging-and-sdi.md §5.5).
@frozen
public struct UnwindRecord: BitwiseCopyable, Sendable, Equatable, Hashable {
    public var functionOffset: UInt32
    public var functionLength: UInt32
    public var cudEncoding: UInt32
    public var section: SectionIndex

    @inlinable
    public init(
        functionOffset: UInt32 = 0,
        functionLength: UInt32 = 0,
        cudEncoding: UInt32 = 0,
        section: SectionIndex = .undefined
    ) {
        self.functionOffset = functionOffset
        self.functionLength = functionLength
        self.cudEncoding = cudEncoding
        self.section = section
    }
}

/// Per-module SDI debug fragment reference (06-linker.md §5.1, §5.7; 07-debugging-and-sdi.md §5.6).
@frozen
public struct SDIFragmentRef: BitwiseCopyable, Sendable, Equatable, Hashable {
    public var moduleHash: UInt64
    public var byteRange: ByteRange

    @inlinable
    public init(moduleHash: UInt64 = 0, byteRange: ByteRange = ByteRange()) {
        self.moduleHash = moduleHash
        self.byteRange = byteRange
    }
}

// MARK: - ObjectAtomTable

/// Deterministic interned string table mapping `AtomId <-> String` for a `RelocatableObject`.
/// Row 0 (`AtomId(0)`) is reserved as the empty string `""`.
@frozen
public struct ObjectAtomTable: Sendable, Equatable {
    @usableFromInline
    var strings: [String]
    @usableFromInline
    var indexByString: [String: AtomId]

    public init() {
        self.strings = [""]
        self.indexByString = ["": AtomId(0)]
    }

    /// Number of interned atoms (including row 0 `""`).
    @inlinable
    public var count: Int { strings.count }

    /// Interns `string` and returns its deterministic `AtomId`.
    @discardableResult
    public mutating func intern(_ string: String) -> AtomId {
        if let existing = indexByString[string] {
            return existing
        }
        let id = AtomId(UInt32(strings.count))
        strings.append(string)
        indexByString[string] = id
        return id
    }

    /// Looks up an existing `AtomId` for `string` without inserting it.
    @inlinable
    public func lookup(_ string: String) -> AtomId? {
        indexByString[string]
    }

    /// Resolves `id` to its string, returning `""` for `AtomId(0)` or out-of-range handles.
    @inlinable
    public func string(for id: AtomId) -> String {
        let idx = Int(id.rawIndex)
        guard idx >= 0 && idx < strings.count else { return "" }
        return strings[idx]
    }

    @inlinable
    public subscript(id: AtomId) -> String {
        string(for: id)
    }
}

// MARK: - RelocatableObject

/// Canonical in-memory relocatable object model (06-linker.md §5.1, 18-data-catalog.md §5.4).
/// Shared across Codegen, native assemblers, ELF/Mach-O object readers/writers, and the linker.
public struct RelocatableObject: ~Copyable {
    public var origin: ObjectOrigin
    public var arch: ObjectArch
    public var moduleId: ModuleId
    public var inputPriority: UInt32

    /// Interned string table for section and symbol names.
    public var atoms: ObjectAtomTable

    // Sections (indexed by `SectionIndex`; row 0 is the NULL section)
    public var sectionNames: Column<SectionIndex, AtomId>
    public var sectionKinds: Column<SectionIndex, SectionKind>
    public var sectionFlags: Column<SectionIndex, UInt32>
    public var sectionAligns: Column<SectionIndex, UInt8>
    public var sectionBytes: Column<SectionIndex, ByteRange>
    public var bytes: Column<ByteIndex, UInt8>

    // Symbols (indexed by `SymbolIndex`; row 0 is the STN_UNDEF nil symbol)
    public var symbolNames: Column<SymbolIndex, AtomId>
    public var symbolSections: Column<SymbolIndex, SectionIndex>
    public var symbolValues: Column<SymbolIndex, UInt64>
    public var symbolSizes: Column<SymbolIndex, UInt64>
    public var symbolBindings: Column<SymbolIndex, SymbolBinding>
    public var symbolVisibility: Column<SymbolIndex, SymbolVisibility>
    public var symbolKinds: Column<SymbolIndex, SymbolKind>
    public var symbolTypes: Column<SymbolIndex, SymbolTypeRecord>

    // Relocations grouped by section in CSR layout (indexed by `SectionIndex` -> `RelocIndex`)
    public var relocSectionStart: Column<SectionIndex, UInt32>
    public var relocSectionCount: Column<SectionIndex, UInt32>
    public var relocs: Column<RelocIndex, Relocation>

    // Unwind and debug
    public var unwind: Column<UnwindIndex, UnwindRecord>
    public var debugFragment: SDIFragmentRef?

    // Fast lookup tables maintained alongside columns
    @usableFromInline
    var sectionByName: [AtomId: SectionIndex]
    @usableFromInline
    var symbolByName: [AtomId: SymbolIndex]
    @usableFromInline
    var stagingRelocsBySection: [[Relocation]]

    public init(
        origin: ObjectOrigin = .compiled,
        arch: ObjectArch = .x86_64,
        moduleId: ModuleId = .foreign,
        inputPriority: UInt32 = 0,
        reservedSectionCapacity: Int = 1024,
        reservedSymbolCapacity: Int = 65536,
        reservedRelocCapacity: Int = 131072,
        reservedByteCapacity: Int = 4_194_304,
        reservedUnwindCapacity: Int = 16384
    ) {
        assert(MemoryLayout<Relocation>.stride == 24, "Relocation stride must be 24 bytes")
        assert(MemoryLayout<SymbolTypeRecord>.stride == 24, "SymbolTypeRecord stride must be 24 bytes")

        self.origin = origin
        self.arch = arch
        self.moduleId = moduleId
        self.inputPriority = inputPriority
        self.atoms = ObjectAtomTable()

        self.sectionNames = Column(reservedCapacity: reservedSectionCapacity)
        self.sectionKinds = Column(reservedCapacity: reservedSectionCapacity, defaultNilValue: .null)
        self.sectionFlags = Column(reservedCapacity: reservedSectionCapacity)
        self.sectionAligns = Column(reservedCapacity: reservedSectionCapacity)
        self.sectionBytes = Column(reservedCapacity: reservedSectionCapacity)
        self.bytes = Column(reservedCapacity: reservedByteCapacity)

        self.symbolNames = Column(reservedCapacity: reservedSymbolCapacity)
        self.symbolSections = Column(reservedCapacity: reservedSymbolCapacity, defaultNilValue: .undefined)
        self.symbolValues = Column(reservedCapacity: reservedSymbolCapacity)
        self.symbolSizes = Column(reservedCapacity: reservedSymbolCapacity)
        self.symbolBindings = Column(reservedCapacity: reservedSymbolCapacity, defaultNilValue: .local)
        self.symbolVisibility = Column(reservedCapacity: reservedSymbolCapacity, defaultNilValue: .defaultVis)
        self.symbolKinds = Column(reservedCapacity: reservedSymbolCapacity, defaultNilValue: .noType)
        self.symbolTypes = Column(reservedCapacity: reservedSymbolCapacity)

        self.relocSectionStart = Column(reservedCapacity: reservedSectionCapacity)
        self.relocSectionCount = Column(reservedCapacity: reservedSectionCapacity)
        self.relocs = Column(reservedCapacity: reservedRelocCapacity)

        self.unwind = Column(reservedCapacity: reservedUnwindCapacity)
        self.debugFragment = nil

        self.sectionByName = [:]
        self.symbolByName = [:]
        self.stagingRelocsBySection = [[]] // index 0 = null section
    }

    // MARK: - Section APIs

    /// Number of defined sections (excluding row 0 NULL section).
    @inlinable
    public var sectionCount: UInt32 {
        sectionNames.count > 0 ? sectionNames.count - 1 : 0
    }

    /// Adds a section to the object and returns its `SectionIndex`.
    /// For `.bss`/`.tbss`/nobits sections, pass `nobitsSize` (or `bytes.count` if provided).
    @discardableResult
    public mutating func addSection(
        name: String,
        kind: SectionKind,
        flags: SectionFlags? = nil,
        alignLog2: UInt8 = 0,
        bytes sectionData: [UInt8] = [],
        nobitsSize: UInt32 = 0
    ) -> SectionIndex {
        let nameAtom = atoms.intern(name)
        let resolvedFlags = flags ?? kind.defaultFlags

        let byteRange: ByteRange
        if kind.isNobits {
            let size = nobitsSize > 0 ? nobitsSize : UInt32(sectionData.count)
            byteRange = ByteRange(start: 0, count: size)
        } else if sectionData.isEmpty {
            byteRange = ByteRange(start: self.bytes.count, count: 0)
        } else {
            let appended = sectionData.withUnsafeBufferPointer { buf in
                self.bytes.appendRange(buf)
            }
            byteRange = ByteRange(start: appended.start.rawIndex, count: appended.count)
        }

        let secIdx = sectionNames.append(nameAtom)
        _ = sectionKinds.append(kind)
        _ = sectionFlags.append(resolvedFlags.rawValue)
        _ = sectionAligns.append(alignLog2)
        _ = sectionBytes.append(byteRange)
        _ = relocSectionStart.append(0)
        _ = relocSectionCount.append(0)
        stagingRelocsBySection.append([])

        if !name.isEmpty && sectionByName[nameAtom] == nil {
            sectionByName[nameAtom] = secIdx
        }
        return secIdx
    }

    /// Appends bytes to an existing section while keeping its `ByteRange` contiguous in `bytes`.
    public mutating func appendSectionBytes(_ section: SectionIndex, _ data: [UInt8]) {
        guard section.isValid && section.rawIndex < sectionNames.count else { return }
        guard !data.isEmpty else { return }

        let kind = sectionKinds[section]
        var currentRange = sectionBytes[section]

        if kind.isNobits {
            currentRange.count += UInt32(data.count)
            sectionBytes[section] = currentRange
            return
        }

        if currentRange.count == 0 {
            let appended = data.withUnsafeBufferPointer { buf in
                self.bytes.appendRange(buf)
            }
            sectionBytes[section] = ByteRange(start: appended.start.rawIndex, count: appended.count)
        } else if currentRange.start + currentRange.count == self.bytes.count {
            let appended = data.withUnsafeBufferPointer { buf in
                self.bytes.appendRange(buf)
            }
            currentRange.count += appended.count
            sectionBytes[section] = currentRange
        } else {
            // Reallocate contiguous slice at the end of `bytes`
            var combined = sectionData(section)
            combined.append(contentsOf: data)
            let appended = combined.withUnsafeBufferPointer { buf in
                self.bytes.appendRange(buf)
            }
            sectionBytes[section] = ByteRange(start: appended.start.rawIndex, count: appended.count)
        }
    }

    /// Reserves/increments size in a `.bss`/`.tbss` (nobits) section.
    public mutating func appendNobitsSize(_ section: SectionIndex, count: UInt32) {
        guard section.isValid && section.rawIndex < sectionNames.count else { return }
        var range = sectionBytes[section]
        range.count += count
        sectionBytes[section] = range
    }

    /// Sets the exact byte size of a `.bss`/`.tbss` (nobits) section.
    public mutating func setNobitsSectionSize(_ section: SectionIndex, size: UInt32) {
        guard section.isValid && section.rawIndex < sectionNames.count else { return }
        sectionBytes[section] = ByteRange(start: 0, count: size)
    }

    /// Looks up a section by name.
    public func findSection(name: String) -> SectionIndex? {
        guard let atom = atoms.lookup(name) else { return nil }
        return sectionByName[atom]
    }

    /// Returns the name of `section`.
    @inlinable
    public func sectionName(_ section: SectionIndex) -> String {
        atoms.string(for: sectionNames[section])
    }

    /// Returns a copy of the bytes belonging to `section` (empty for nobits sections).
    public func sectionData(_ section: SectionIndex) -> [UInt8] {
        guard section.isValid && section.rawIndex < sectionNames.count else { return [] }
        let kind = sectionKinds[section]
        if kind.isNobits {
            return []
        }
        let range = sectionBytes[section]
        guard range.count > 0 else { return [] }
        return bytes.withUnsafeBufferPointer { buf in
            let start = Int(range.start)
            let end = start + Int(range.count)
            guard start >= 0 && end <= buf.count else { return [] }
            return Array(buf[start..<end])
        }
    }

    // MARK: - Symbol APIs

    /// Number of symbols in the object (excluding row 0 nil symbol).
    @inlinable
    public var symbolCount: UInt32 {
        symbolNames.count > 0 ? symbolNames.count - 1 : 0
    }

    /// Adds a symbol to the object and returns its `SymbolIndex`.
    @discardableResult
    public mutating func addSymbol(
        name: String,
        section: SectionIndex,
        value: UInt64,
        size: UInt64 = 0,
        binding: SymbolBinding = .local,
        visibility: SymbolVisibility = .defaultVis,
        kind: SymbolKind = .noType,
        typeRecord: SymbolTypeRecord? = nil
    ) -> SymbolIndex {
        let nameAtom = atoms.intern(name)
        let symIdx = symbolNames.append(nameAtom)
        _ = symbolSections.append(section)
        _ = symbolValues.append(value)
        _ = symbolSizes.append(size)
        _ = symbolBindings.append(binding)
        _ = symbolVisibility.append(visibility)
        _ = symbolKinds.append(kind)

        if var rec = typeRecord {
            if rec.symbolIndex == 0 {
                rec.symbolIndex = symIdx.rawIndex
            }
            _ = symbolTypes.append(rec)
        } else {
            _ = symbolTypes.append(SymbolTypeRecord())
        }

        if !name.isEmpty {
            // Prefer non-local or first definition when indexing by name
            if let existing = symbolByName[nameAtom] {
                if symbolBindings[existing] == .local && binding != .local {
                    symbolByName[nameAtom] = symIdx
                }
            } else {
                symbolByName[nameAtom] = symIdx
            }
        }
        return symIdx
    }

    /// Updates or attaches a `.ss_symtypes` record for `symbol`.
    public mutating func setSymbolType(_ symbol: SymbolIndex, _ record: SymbolTypeRecord) {
        guard symbol.isValid && symbol.rawIndex < symbolTypes.count else { return }
        var updated = record
        if updated.symbolIndex == 0 {
            updated.symbolIndex = symbol.rawIndex
        }
        symbolTypes[symbol] = updated
    }

    /// Finds a symbol by name.
    public func findSymbol(name: String) -> SymbolIndex? {
        guard let atom = atoms.lookup(name) else { return nil }
        return symbolByName[atom]
    }

    /// Returns the name of `symbol`.
    @inlinable
    public func symbolName(_ symbol: SymbolIndex) -> String {
        atoms.string(for: symbolNames[symbol])
    }

    // MARK: - Relocation APIs

    /// Number of relocations in the object (excluding row 0 nil relocation).
    @inlinable
    public var relocCount: UInt32 {
        relocs.count > 0 ? relocs.count - 1 : 0
    }

    @discardableResult
    public mutating func addRelocation(
        to section: SectionIndex,
        offset: UInt64,
        symbol: SymbolIndex,
        kind: RelocKind,
        addend: Int64 = 0,
        flags: UInt16 = 0
    ) -> RelocIndex {
        addRelocation(section: section, offset: offset, symbol: symbol, kind: kind, addend: addend, flags: flags)
    }

    /// Adds a relocation to `section` and keeps the CSR columns (`relocSectionStart`,
    /// `relocSectionCount`, `relocs`) immediately consistent.
    @discardableResult
    public mutating func addRelocation(
        section: SectionIndex,
        offset: UInt64,
        symbol: SymbolIndex,
        kind: RelocKind,
        addend: Int64 = 0,
        flags: UInt16 = 0
    ) -> RelocIndex {
        guard section.isValid && section.rawIndex < sectionNames.count else {
            return .nilId
        }
        let reloc = Relocation(
            offset: offset,
            addend: addend,
            symbol: symbol,
            kind: kind,
            flags: flags
        )
        let secRaw = Int(section.rawIndex)
        stagingRelocsBySection[secRaw].append(reloc)

        let currentStart = relocSectionStart[section]
        let currentCount = relocSectionCount[section]

        // Fast path: this section's relocations are either empty or at the tail of `relocs`
        if currentCount == 0 {
            let newIdx = relocs.append(reloc)
            relocSectionStart[section] = newIdx.rawIndex
            relocSectionCount[section] = 1
            return newIdx
        } else if currentStart + currentCount == relocs.count {
            let newIdx = relocs.append(reloc)
            relocSectionCount[section] = currentCount + 1
            return newIdx
        } else {
            // Out-of-order section relocation addition: repack CSR columns deterministically by section
            finalizeRelocations()
            let updatedStart = relocSectionStart[section]
            let updatedCount = relocSectionCount[section]
            return RelocIndex(rawIndex: updatedStart + updatedCount - 1)
        }
    }

    /// Packs per-section relocations into contiguous CSR order in `relocs`, `relocSectionStart`,
    /// and `relocSectionCount`. Called automatically when relocations are added out of section order.
    public mutating func finalizeRelocations() {
        relocs.setCount(1) // Keep row 0 nil relocation
        let totalSecs = Int(sectionNames.count)
        for secIdx in 1..<totalSecs {
            let sec = SectionIndex(UInt32(secIdx))
            let list = stagingRelocsBySection[secIdx]
            if list.isEmpty {
                relocSectionStart[sec] = 0
                relocSectionCount[sec] = 0
            } else {
                let appended = list.withUnsafeBufferPointer { buf in
                    relocs.appendRange(buf)
                }
                relocSectionStart[sec] = appended.start.rawIndex
                relocSectionCount[sec] = appended.count
            }
        }
    }

    /// Returns all relocations for `section` in deterministic order.
    public func relocs(for section: SectionIndex) -> [Relocation] {
        guard section.isValid && section.rawIndex < sectionNames.count else { return [] }
        let start = relocSectionStart[section]
        let count = relocSectionCount[section]
        guard count > 0 else { return [] }
        return relocs.withUnsafeBufferPointer { buf in
            let s = Int(start)
            let e = s + Int(count)
            guard s >= 1 && e <= buf.count else { return [] }
            return Array(buf[s..<e])
        }
    }

    // MARK: - Unwind APIs

    /// Appends a Compact Unwind Descriptor (CUD) record.
    @discardableResult
    public mutating func addUnwindRecord(_ record: UnwindRecord) -> UnwindIndex {
        unwind.append(record)
    }

    // MARK: - Observability & Statistics (18-data-catalog.md §4 Rule 4)

    /// Total physical bytes committed across all columns in this object.
    public var bytesCommitted: Int {
        sectionNames.bytesCommitted
            + sectionKinds.bytesCommitted
            + sectionFlags.bytesCommitted
            + sectionAligns.bytesCommitted
            + sectionBytes.bytesCommitted
            + bytes.bytesCommitted
            + symbolNames.bytesCommitted
            + symbolSections.bytesCommitted
            + symbolValues.bytesCommitted
            + symbolSizes.bytesCommitted
            + symbolBindings.bytesCommitted
            + symbolVisibility.bytesCommitted
            + symbolKinds.bytesCommitted
            + symbolTypes.bytesCommitted
            + relocSectionStart.bytesCommitted
            + relocSectionCount.bytesCommitted
            + relocs.bytesCommitted
            + unwind.bytesCommitted
    }

    /// Total virtual address space bytes reserved across all columns in this object.
    public var bytesReserved: Int {
        sectionNames.bytesReserved
            + sectionKinds.bytesReserved
            + sectionFlags.bytesReserved
            + sectionAligns.bytesReserved
            + sectionBytes.bytesReserved
            + bytes.bytesReserved
            + symbolNames.bytesReserved
            + symbolSections.bytesReserved
            + symbolValues.bytesReserved
            + symbolSizes.bytesReserved
            + symbolBindings.bytesReserved
            + symbolVisibility.bytesReserved
            + symbolKinds.bytesReserved
            + symbolTypes.bytesReserved
            + relocSectionStart.bytesReserved
            + relocSectionCount.bytesReserved
            + relocs.bytesReserved
            + unwind.bytesReserved
    }
}
