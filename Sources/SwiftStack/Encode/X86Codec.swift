// Sources/SwiftStack/Encode/X86Codec.swift
//
// Table-driven x86-64 instruction encoder and disassembler (04-backend.md §4.9, 05-assembler.md §4.6).
// Covers legacy prefixes, REX, 2-byte (C5) and 3-byte (C4) VEX, ModR/M, SIB,
// opcode maps (primary, 0F, 0F 38, 0F 3A), GPR, system/privileged, SSE, and AVX instructions.
//
// Layering rule: Encode/ MUST NOT reference Parse/, Sem/, AIR/, Opt/, LIR/, Codegen/, Object/, Asm/, or Linker/.

import Foundation

// MARK: - 1. Register, Operand, and Mode Definitions

/// Register class for x86-64 registers.
@frozen
public enum X86RegClass: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case gpr8       = 0
    case gpr8High   = 1 // ah, ch, dh, bh (cannot be used with REX prefix)
    case gpr16      = 2
    case gpr32      = 3
    case gpr64      = 4
    case rip        = 5
    case xmm        = 6
    case ymm        = 7
    case seg        = 8 // es=0, cs=1, ss=2, ds=3, fs=4, gs=5
    case cr         = 9 // cr0..cr15
    case dr         = 10 // dr0..dr15
}

/// Explicit or inferred operand size in bytes.
@frozen
public enum X86OperandSize: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case unsized = 0
    case byte    = 1
    case word    = 2
    case dword   = 4
    case qword   = 8
    case xmm128  = 16
    case ymm256  = 32

    public var attSuffix: String {
        switch self {
        case .byte:  return "b"
        case .word:  return "w"
        case .dword: return "l"
        case .qword: return "q"
        default:     return ""
        }
    }

    /// General-purpose register class of this size, if any.
    public var gprClass: X86RegClass? {
        switch self {
        case .byte:  return .gpr8
        case .word:  return .gpr16
        case .dword: return .gpr32
        case .qword: return .gpr64
        default:     return nil
        }
    }

    public init?(attSuffix: Character) {
        switch attSuffix {
        case "b", "B": self = .byte
        case "w", "W": self = .word
        case "l", "L": self = .dword
        case "q", "Q": self = .qword
        default: return nil
        }
    }
}

/// Code emission / disassembly mode (`.code16`, `.code32`, `.code64`).
@frozen
public enum X86CodeMode: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case mode16 = 16
    case mode32 = 32
    case mode64 = 64
}

/// String repeat prefix (`rep`/`repe` 0xF3, `repne` 0xF2).
@frozen
public enum X86RepPrefix: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case none  = 0
    case rep   = 0xF3 // rep / repe / repz
    case repne = 0xF2 // repne / repnz
}

/// All architectural x86-64 registers.
@frozen
public enum X86Reg: UInt8, BitwiseCopyable, Sendable, CaseIterable, Equatable, Hashable, CustomStringConvertible {
    // 64-bit GPRs (0..15)
    case rax = 0, rcx = 1, rdx = 2, rbx = 3, rsp = 4, rbp = 5, rsi = 6, rdi = 7
    case r8 = 8, r9 = 9, r10 = 10, r11 = 11, r12 = 12, r13 = 13, r14 = 14, r15 = 15

    // 32-bit GPRs (16..31)
    case eax = 16, ecx = 17, edx = 18, ebx = 19, esp = 20, ebp = 21, esi = 22, edi = 23
    case r8d = 24, r9d = 25, r10d = 26, r11d = 27, r12d = 28, r13d = 29, r14d = 30, r15d = 31

    // 16-bit GPRs (32..47)
    case ax = 32, cx = 33, dx = 34, bx = 35, sp = 36, bp = 37, si = 38, di = 39
    case r8w = 40, r9w = 41, r10w = 42, r11w = 43, r12w = 44, r13w = 45, r14w = 46, r15w = 47

    // 8-bit low GPRs (48..63)
    case al = 48, cl = 49, dl = 50, bl = 51, spl = 52, bpl = 53, sil = 54, dil = 55
    case r8b = 56, r9b = 57, r10b = 58, r11b = 59, r12b = 60, r13b = 61, r14b = 62, r15b = 63

    // 8-bit high GPRs (64..67 -> hardware 4..7 without REX)
    case ah = 64, ch = 65, dh = 66, bh = 67

    // Instruction pointer (68)
    case rip = 68

    // 128-bit XMM registers (80..95)
    case xmm0 = 80, xmm1 = 81, xmm2 = 82, xmm3 = 83, xmm4 = 84, xmm5 = 85, xmm6 = 86, xmm7 = 87
    case xmm8 = 88, xmm9 = 89, xmm10 = 90, xmm11 = 91, xmm12 = 92, xmm13 = 93, xmm14 = 94, xmm15 = 95

    // 256-bit YMM registers (96..111)
    case ymm0 = 96, ymm1 = 97, ymm2 = 98, ymm3 = 99, ymm4 = 100, ymm5 = 101, ymm6 = 102, ymm7 = 103
    case ymm8 = 104, ymm9 = 105, ymm10 = 106, ymm11 = 107, ymm12 = 108, ymm13 = 109, ymm14 = 110, ymm15 = 111

    // Segment registers (112..117 -> es=0, cs=1, ss=2, ds=3, fs=4, gs=5)
    case es = 112, cs = 113, ss = 114, ds = 115, fs = 116, gs = 117

    // Control registers (128..143)
    case cr0 = 128, cr1 = 129, cr2 = 130, cr3 = 131, cr4 = 132, cr5 = 133, cr6 = 134, cr7 = 135
    case cr8 = 136, cr9 = 137, cr10 = 138, cr11 = 139, cr12 = 140, cr13 = 141, cr14 = 142, cr15 = 143

    // Debug registers (144..159)
    case dr0 = 144, dr1 = 145, dr2 = 146, dr3 = 147, dr4 = 148, dr5 = 149, dr6 = 150, dr7 = 151
    case dr8 = 152, dr9 = 153, dr10 = 154, dr11 = 155, dr12 = 156, dr13 = 157, dr14 = 158, dr15 = 159

    /// The register's size / functional class.
    @inlinable
    public var regClass: X86RegClass {
        let r = rawValue
        if r < 16 { return .gpr64 }
        if r < 32 { return .gpr32 }
        if r < 48 { return .gpr16 }
        if r < 64 { return .gpr8 }
        if r < 68 { return .gpr8High }
        if r == 68 { return .rip }
        if r >= 80 && r < 96 { return .xmm }
        if r >= 96 && r < 112 { return .ymm }
        if r >= 112 && r < 118 { return .seg }
        if r >= 128 && r < 144 { return .cr }
        return .dr
    }

    /// 4-bit hardware encoding (0..15, or 4..7 for ah..bh, 0..5 for seg).
    @inlinable
    public var hwEncoding: UInt8 {
        let r = rawValue
        if r < 64 { return r & 0x0F }
        if r < 68 { return (r - 64) + 4 }
        if r == 68 { return 5 }
        if r >= 80 && r < 96 { return r - 80 }
        if r >= 96 && r < 112 { return r - 96 }
        if r >= 112 && r < 118 { return r - 112 }
        if r >= 128 && r < 144 { return r - 128 }
        return r - 144
    }

    /// Low 3 bits of the hardware register number for ModR/M or SIB fields.
    @inlinable
    public var low3: UInt8 {
        hwEncoding & 0x07
    }

    /// True if this register's hardware number is 8..15 (requires REX.R / REX.X / REX.B).
    @inlinable
    public var needsRexExtension: Bool {
        hwEncoding >= 8
    }

    /// True for `%spl`, `%bpl`, `%sil`, `%dil`, which require a REX prefix (at least 0x40)
    /// to distinguish them from `%ah`, `%ch`, `%dh`, `%bh`.
    @inlinable
    public var requiresRexByte: Bool {
        rawValue >= 52 && rawValue <= 55
    }

    /// True if this is any general-purpose register (8, 16, 32, or 64-bit).
    @inlinable
    public var isGPR: Bool {
        rawValue < 68
    }

    /// Operand size corresponding to this register.
    @inlinable
    public var operandSize: X86OperandSize {
        switch regClass {
        case .gpr8, .gpr8High: return .byte
        case .gpr16, .seg:     return .word
        case .gpr32:           return .dword
        case .gpr64, .rip, .cr, .dr: return .qword
        case .xmm:             return .xmm128
        case .ymm:             return .ymm256
        }
    }

    /// Segment override prefix byte if this is a segment register.
    @inlinable
    public var segmentPrefixByte: UInt8? {
        switch self {
        case .es: return 0x26
        case .cs: return 0x2E
        case .ss: return 0x36
        case .ds: return 0x3E
        case .fs: return 0x64
        case .gs: return 0x65
        default:  return nil
        }
    }

    public static func fromSegmentPrefix(_ byte: UInt8) -> X86Reg? {
        switch byte {
        case 0x26: return .es
        case 0x2E: return .cs
        case 0x36: return .ss
        case 0x3E: return .ds
        case 0x64: return .fs
        case 0x65: return .gs
        default:   return nil
        }
    }

    @inlinable
    public static func gpr64(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: hw & 0x0F)!
    }

    @inlinable
    public static func gpr32(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 16 + (hw & 0x0F))!
    }

    @inlinable
    public static func gpr16(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 32 + (hw & 0x0F))!
    }

    @inlinable
    public static func gpr8(_ hw: UInt8, hasRex: Bool = true) -> X86Reg {
        let masked = hw & 0x0F
        if !hasRex && masked >= 4 && masked <= 7 {
            return X86Reg(rawValue: 64 + (masked - 4))!
        }
        return X86Reg(rawValue: 48 + masked)!
    }

    @inlinable
    public static func gpr(size: X86OperandSize, hw: UInt8, hasRex: Bool = true) -> X86Reg {
        switch size {
        case .byte:  return gpr8(hw, hasRex: hasRex)
        case .word:  return gpr16(hw)
        case .dword: return gpr32(hw)
        default:     return gpr64(hw)
        }
    }

    @inlinable
    public static func xmm(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 80 + (hw & 0x0F))!
    }

    @inlinable
    public static func ymm(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 96 + (hw & 0x0F))!
    }

    @inlinable
    public static func seg(_ hw: UInt8) -> X86Reg? {
        guard hw < 6 else { return nil }
        return X86Reg(rawValue: 112 + hw)
    }

    @inlinable
    public static func cr(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 128 + (hw & 0x0F))!
    }

    @inlinable
    public static func dr(_ hw: UInt8) -> X86Reg {
        X86Reg(rawValue: 144 + (hw & 0x0F))!
    }

    /// Bare register name without leading `%`.
    public var name: String {
        switch self {
        case .rax: return "rax"; case .rcx: return "rcx"; case .rdx: return "rdx"; case .rbx: return "rbx"
        case .rsp: return "rsp"; case .rbp: return "rbp"; case .rsi: return "rsi"; case .rdi: return "rdi"
        case .r8:  return "r8";  case .r9:  return "r9";  case .r10: return "r10"; case .r11: return "r11"
        case .r12: return "r12"; case .r13: return "r13"; case .r14: return "r14"; case .r15: return "r15"

        case .eax: return "eax"; case .ecx: return "ecx"; case .edx: return "edx"; case .ebx: return "ebx"
        case .esp: return "esp"; case .ebp: return "ebp"; case .esi: return "esi"; case .edi: return "edi"
        case .r8d: return "r8d"; case .r9d: return "r9d"; case .r10d: return "r10d"; case .r11d: return "r11d"
        case .r12d: return "r12d"; case .r13d: return "r13d"; case .r14d: return "r14d"; case .r15d: return "r15d"

        case .ax: return "ax"; case .cx: return "cx"; case .dx: return "dx"; case .bx: return "bx"
        case .sp: return "sp"; case .bp: return "bp"; case .si: return "si"; case .di: return "di"
        case .r8w: return "r8w"; case .r9w: return "r9w"; case .r10w: return "r10w"; case .r11w: return "r11w"
        case .r12w: return "r12w"; case .r13w: return "r13w"; case .r14w: return "r14w"; case .r15w: return "r15w"

        case .al: return "al"; case .cl: return "cl"; case .dl: return "dl"; case .bl: return "bl"
        case .spl: return "spl"; case .bpl: return "bpl"; case .sil: return "sil"; case .dil: return "dil"
        case .r8b: return "r8b"; case .r9b: return "r9b"; case .r10b: return "r10b"; case .r11b: return "r11b"
        case .r12b: return "r12b"; case .r13b: return "r13b"; case .r14b: return "r14b"; case .r15b: return "r15b"

        case .ah: return "ah"; case .ch: return "ch"; case .dh: return "dh"; case .bh: return "bh"
        case .rip: return "rip"

        case .xmm0: return "xmm0"; case .xmm1: return "xmm1"; case .xmm2: return "xmm2"; case .xmm3: return "xmm3"
        case .xmm4: return "xmm4"; case .xmm5: return "xmm5"; case .xmm6: return "xmm6"; case .xmm7: return "xmm7"
        case .xmm8: return "xmm8"; case .xmm9: return "xmm9"; case .xmm10: return "xmm10"; case .xmm11: return "xmm11"
        case .xmm12: return "xmm12"; case .xmm13: return "xmm13"; case .xmm14: return "xmm14"; case .xmm15: return "xmm15"

        case .ymm0: return "ymm0"; case .ymm1: return "ymm1"; case .ymm2: return "ymm2"; case .ymm3: return "ymm3"
        case .ymm4: return "ymm4"; case .ymm5: return "ymm5"; case .ymm6: return "ymm6"; case .ymm7: return "ymm7"
        case .ymm8: return "ymm8"; case .ymm9: return "ymm9"; case .ymm10: return "ymm10"; case .ymm11: return "ymm11"
        case .ymm12: return "ymm12"; case .ymm13: return "ymm13"; case .ymm14: return "ymm14"; case .ymm15: return "ymm15"

        case .es: return "es"; case .cs: return "cs"; case .ss: return "ss"
        case .ds: return "ds"; case .fs: return "fs"; case .gs: return "gs"

        case .cr0: return "cr0"; case .cr1: return "cr1"; case .cr2: return "cr2"; case .cr3: return "cr3"
        case .cr4: return "cr4"; case .cr5: return "cr5"; case .cr6: return "cr6"; case .cr7: return "cr7"
        case .cr8: return "cr8"; case .cr9: return "cr9"; case .cr10: return "cr10"; case .cr11: return "cr11"
        case .cr12: return "cr12"; case .cr13: return "cr13"; case .cr14: return "cr14"; case .cr15: return "cr15"

        case .dr0: return "dr0"; case .dr1: return "dr1"; case .dr2: return "dr2"; case .dr3: return "dr3"
        case .dr4: return "dr4"; case .dr5: return "dr5"; case .dr6: return "dr6"; case .dr7: return "dr7"
        case .dr8: return "dr8"; case .dr9: return "dr9"; case .dr10: return "dr10"; case .dr11: return "dr11"
        case .dr12: return "dr12"; case .dr13: return "dr13"; case .dr14: return "dr14"; case .dr15: return "dr15"
        }
    }

    /// AT&T syntax register name with leading `%`.
    public var attName: String {
        "%\(name)"
    }

    public var description: String {
        attName
    }

    private static let nameLookupTable: [String: X86Reg] = {
        var map: [String: X86Reg] = [:]
        map.reserveCapacity(X86Reg.allCases.count * 2)
        for reg in X86Reg.allCases {
            map[reg.name] = reg
            map[reg.attName] = reg
        }
        return map
    }()

    /// Parses an AT&T register name (with or without leading `%`, case-insensitive).
    public init?(attName: String) {
        let key = attName.lowercased()
        guard let found = Self.nameLookupTable[key] else { return nil }
        self = found
    }

    public static func parse(_ text: String) -> X86Reg? {
        X86Reg(attName: text)
    }
}

/// Memory operand `seg:disp(base, index, scale)` or `sym(%rip)` / `%fs:0`.
@frozen
public struct X86Mem: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Segment override prefix byte (`0x64` `%fs`, `0x65` `%gs`, `0x2E` `%cs`, `0x3E` `%ds`, `0x26` `%es`, `0x36` `%ss`).
    public var segment: UInt8?
    public var base: X86Reg?
    public var index: X86Reg?
    public var scale: UInt8
    public var disp: Int64
    public var symbol: String?
    public var forceDisp32: Bool

    public init(
        segment: UInt8? = nil,
        base: X86Reg? = nil,
        index: X86Reg? = nil,
        scale: UInt8 = 1,
        disp: Int64 = 0,
        symbol: String? = nil,
        forceDisp32: Bool = false
    ) {
        if let seg = segment {
            // Normalize 0..5 segment hardware index if passed, otherwise preserve prefix byte
            if seg < 6, let segReg = X86Reg.seg(seg) {
                self.segment = segReg.segmentPrefixByte
            } else {
                self.segment = seg
            }
        } else {
            self.segment = nil
        }
        self.base = base
        self.index = index
        self.scale = scale == 0 ? 1 : scale
        self.disp = disp
        self.symbol = symbol
        self.forceDisp32 = forceDisp32
    }

    public static func ripRelative(symbol: String? = nil, disp: Int64 = 0, segment: UInt8? = nil) -> X86Mem {
        X86Mem(segment: segment, base: .rip, index: nil, scale: 1, disp: disp, symbol: symbol, forceDisp32: true)
    }

    public static func baseDisp(
        _ base: X86Reg,
        disp: Int64 = 0,
        symbol: String? = nil,
        segment: UInt8? = nil,
        forceDisp32: Bool = false
    ) -> X86Mem {
        X86Mem(segment: segment, base: base, index: nil, scale: 1, disp: disp, symbol: symbol, forceDisp32: forceDisp32)
    }

    public static func absolute(disp: Int64 = 0, symbol: String? = nil, segment: UInt8? = nil) -> X86Mem {
        X86Mem(segment: segment, base: nil, index: nil, scale: 1, disp: disp, symbol: symbol, forceDisp32: false)
    }

    public var attString: String {
        var result = ""
        if let segByte = segment, let segReg = X86Reg.fromSegmentPrefix(segByte) {
            result += "\(segReg.attName):"
        }
        if let sym = symbol {
            result += sym
            if disp > 0 {
                result += "+\(disp)"
            } else if disp < 0 {
                result += "\(disp)"
            }
        } else if base == nil && index == nil {
            result += "\(disp)"
        } else if disp != 0 {
            result += "\(disp)"
        }

        if base != nil || index != nil {
            result += "("
            if let b = base {
                result += b.attName
            }
            if let idx = index {
                result += ",\(idx.attName),\(scale)"
            }
            result += ")"
        }
        return result
    }

    public var description: String {
        attString
    }
}

/// Operand of an x86-64 instruction.
@frozen
public enum X86Operand: Sendable, Equatable, Hashable, CustomStringConvertible {
    case reg(X86Reg)
    case imm(Int64, symbol: String?)
    case mem(X86Mem)
    case relTarget(Int64, symbol: String?)
    case indirectReg(X86Reg)
    case indirectMem(X86Mem)

    @inlinable
    public static func imm(_ value: Int64) -> X86Operand {
        .imm(value, symbol: nil)
    }

    @inlinable
    public static func relTarget(_ value: Int64) -> X86Operand {
        .relTarget(value, symbol: nil)
    }

    public var attString: String {
        switch self {
        case .reg(let r):
            return r.attName
        case .imm(let val, let sym):
            if let sym = sym {
                if val == 0 { return "$\(sym)" }
                return val > 0 ? "$\(sym)+\(val)" : "$\(sym)\(val)"
            }
            return "$\(val)"
        case .mem(let m):
            return m.attString
        case .relTarget(let val, let sym):
            if let sym = sym {
                if val == 0 { return sym }
                return val > 0 ? "\(sym)+\(val)" : "\(sym)\(val)"
            }
            return "\(val)"
        case .indirectReg(let r):
            return "*\(r.attName)"
        case .indirectMem(let m):
            return "*\(m.attString)"
        }
    }

    public var description: String {
        attString
    }
}

/// Structured representation of an x86-64 instruction (AT&T operand ordering).
@frozen
public struct X86Instruction: Sendable, Equatable, Hashable, CustomStringConvertible {
    public var mnemonic: String
    public var sizeSuffix: X86OperandSize
    public var operands: [X86Operand]
    public var lockPrefix: Bool
    public var repPrefix: X86RepPrefix
    public var codeMode: X86CodeMode

    public init(
        mnemonic: String,
        sizeSuffix: X86OperandSize = .unsized,
        operands: [X86Operand] = [],
        lockPrefix: Bool = false,
        repPrefix: X86RepPrefix = .none,
        codeMode: X86CodeMode = .mode64
    ) {
        self.mnemonic = mnemonic.lowercased()
        self.sizeSuffix = sizeSuffix
        self.operands = operands
        self.lockPrefix = lockPrefix
        self.repPrefix = repPrefix
        self.codeMode = codeMode
    }

    public var attString: String {
        var prefixStr = ""
        if lockPrefix { prefixStr += "lock " }
        switch repPrefix {
        case .none:  break
        case .rep:   prefixStr += "rep "
        case .repne: prefixStr += "repne "
        }
        let fullMnemonic: String
        if sizeSuffix != .unsized && !X86InstructionTable.mnemonicCarriesSize(mnemonic, sizeSuffix) {
            fullMnemonic = mnemonic + sizeSuffix.attSuffix
        } else {
            fullMnemonic = mnemonic
        }
        if operands.isEmpty {
            return prefixStr + fullMnemonic
        }
        let ops = operands.map { $0.attString }.joined(separator: ", ")
        return "\(prefixStr)\(fullMnemonic) \(ops)"
    }

    public var description: String {
        attString
    }
}

// MARK: - 2. Relocation & Encoding Result Types

/// Relocation kind emitted by the x86-64 encoder.
@frozen
public enum X86RelocKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case pc32     = 0 // R_X86_64_PC32
    case plt32    = 1 // R_X86_64_PLT32
    case gotpcrel = 2 // R_X86_64_GOTPCREL
    case abs64    = 3 // R_X86_64_64
    case abs32s   = 4 // R_X86_64_32S
    case abs32    = 5 // R_X86_64_32
    case abs16    = 6 // R_X86_64_16
    case tpoff32  = 7 // R_X86_64_TPOFF32
}

/// Relocation produced while encoding a single instruction.
@frozen
public struct X86EncodedReloc: Sendable, Equatable, Hashable {
    public var offset: Int
    public var kind: X86RelocKind
    public var symbol: String
    public var addend: Int64

    public init(offset: Int, kind: X86RelocKind, symbol: String, addend: Int64) {
        self.offset = offset
        self.kind = kind
        self.symbol = symbol
        self.addend = addend
    }
}

/// Output of encoding a single `X86Instruction`.
@frozen
public struct X86EncodedInstruction: Sendable, Equatable, Hashable {
    public var bytes: [UInt8]
    public var relocations: [X86EncodedReloc]

    public init(bytes: [UInt8], relocations: [X86EncodedReloc] = []) {
        self.bytes = bytes
        self.relocations = relocations
    }
}

/// Error raised when an instruction cannot be encoded or decoded.
@frozen
public enum X86CodecError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownMnemonic(String)
    case invalidOperands(mnemonic: String, operands: [X86Operand])
    case invalidMemoryAddressing(X86Mem)
    case highByteRegWithRex(X86Reg)
    case immediateOutOfRange(Int64, expectedBytes: Int)
    case unexpectedEndOfBytes(offset: Int)
    case unknownOpcode(offset: Int, byte: UInt8)

    public var description: String {
        switch self {
        case .unknownMnemonic(let m):
            return "Unknown x86 mnemonic '\(m)'"
        case .invalidOperands(let m, let ops):
            return "Invalid operands for '\(m)': \(ops.map(\.attString).joined(separator: ", "))"
        case .invalidMemoryAddressing(let mem):
            return "Invalid x86 memory addressing mode: \(mem.attString)"
        case .highByteRegWithRex(let reg):
            return "High byte register \(reg.attName) cannot be encoded with a REX prefix"
        case .immediateOutOfRange(let val, let bytes):
            return "Immediate \(val) out of range for \(bytes)-byte field"
        case .unexpectedEndOfBytes(let off):
            return "Unexpected end of instruction bytes at offset \(off)"
        case .unknownOpcode(let off, let b):
            return String(format: "Unknown opcode 0x%02X at offset %d", b, off)
        }
    }
}

// MARK: - 3. Shared Table-Driven Instruction Descriptors

/// Opcode map selector (`primary`, `0F`, `0F 38`, `0F 3A`).
@frozen
public enum X86OpcodeMap: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case primary = 0
    case map0F   = 1 // 0x0F (VEX m_mmmm = 1)
    case map0F38 = 2 // 0x0F 0x38 (VEX m_mmmm = 2)
    case map0F3A = 3 // 0x0F 0x3A (VEX m_mmmm = 3)
}

/// Mandatory SIMD/extension prefix (`none`, `0x66`, `0xF3`, `0xF2`).
@frozen
public enum X86MandatoryPrefix: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case none = 0 // VEX pp = 0
    case p66  = 1 // 0x66, VEX pp = 1
    case pF3  = 2 // 0xF3, VEX pp = 2
    case pF2  = 3 // 0xF2, VEX pp = 3
    case p66F2 = 4 // 0x66 + 0xF2 (used by crc32w)

    @inlinable
    public var vexPP: UInt8 {
        rawValue & 0x03
    }
}

/// Encoding family (`legacy` vs `vex`).
@frozen
public enum X86EncodingKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case legacy = 0
    case vex    = 1
}

/// Allowed operand kind for single `r/m` instructions.
@frozen
public enum X86RMKind: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case gprOrMem         = 0
    case gprOnly          = 1
    case memOnly          = 2
    case indirectRegOrMem = 3
    case indirectMemOnly  = 4
}

/// Restriction on the ModR/M `r/m` operand of an otherwise register-or-memory format. It separates
/// encodings that share an opcode (`movhlps` reg-only vs `movlps` mem-only, `0F 12`), and rejects forms
/// the hardware does not define (`movntdq` reg, `pmovmskb` mem).
@frozen
public enum X86RMConstraint: UInt8, BitwiseCopyable, Sendable, Equatable, Hashable {
    case any     = 0
    case regOnly = 1 // ModR/M.mod == 3
    case memOnly = 2 // ModR/M.mod != 3
}

/// Operand encoding template for an `X86InstrDesc`.
@frozen
public enum X86OperandFormat: Sendable, Equatable, Hashable {
    /// 0 operands (`ret`, `syscall`, `ud2`, `cpuid`, `vzeroupper`, etc.).
    case implied
    /// 1 register encoded in `opcode + (reg & 7)` (`push %reg`, `pop %reg`, `bswap %reg`).
    case opcodePlusReg(X86RegClass)
    /// 2 registers `%reg, %acc` (either order) encoded in `opcode + (reg & 7)` (`xchg %ebx, %eax` = 0x93).
    case opcodePlusRegWithAcc(X86RegClass)
    /// 2 operands `$imm, %reg` encoded in `opcode + (reg & 7)` + `imm` (`mov $imm, %reg`).
    case immToOpcodePlusReg(X86RegClass, immSize: X86OperandSize)
    /// 1 `r/m` operand with `/digit` in `ModRM.reg` (`inc`, `dec`, `not`, `neg`, `idiv`, `lgdt`, `setcc`, `jmp *r/m`).
    case rm(X86RMKind)
    /// 2 operands `src_reg, dst_rm` -> `ModRM.reg = op[0]`, `ModRM.rm = op[1]` (`mov reg, r/m`, `add reg, r/m`, etc.).
    case regToRm(regClass: X86RegClass, rmClass: X86RegClass)
    /// 2 operands `src_rm, dst_reg` -> `ModRM.rm = op[0]`, `ModRM.reg = op[1]` (`mov mem, reg`, `lea`, `imul r/m, reg`, SSE 2-op).
    case rmToReg(rmClass: X86RegClass, regClass: X86RegClass)
    /// 2 operands `$imm, dst_rm` -> `ModRM.reg = slash`, `ModRM.rm = op[1]`, followed by `imm`.
    case immToRm(rmClass: X86RegClass, immSize: X86OperandSize)
    /// 2 operands `$imm, %al/%ax/%eax/%rax` accumulator short form (`0x04/0x05`, `0xA8/0xA9`, etc.).
    case immToAcc(immSize: X86OperandSize)
    /// Shift/rotate by `$1` (`0xD0 /d` or `0xD1 /d`).
    case shiftBy1
    /// Shift/rotate by `%cl` (`0xD2 /d` or `0xD3 /d`).
    case shiftByCl
    /// 3 operands `$imm, src_rm, dst_reg` (`imul $imm, r/m, reg`, `pshufd`, `vpshufd`).
    case immRmToReg(rmClass: X86RegClass, regClass: X86RegClass, immSize: X86OperandSize)
    /// 3 operands `$imm, src_reg, dst_rm` (`vcvtps2ph $imm8, %xmm/%ymm, %xmm/m64`).
    case immRegToRm(regClass: X86RegClass, rmClass: X86RegClass, immSize: X86OperandSize)
    /// 3-operand VEX `src2_rm, src1_vvvv, dst_reg` (`vaddps`, `vpxor`, `vaesenc`, etc.).
    case vexRmVvvvReg(rmClass: X86RegClass, vvvvClass: X86RegClass, regClass: X86RegClass)
    /// 4-operand VEX `$imm8, src2_rm, src1_vvvv, dst_reg` (`vpclmulqdq`, `vshufps`, `vinsertf128`, `vpinsrd`).
    case vexImmRmVvvvReg(rmClass: X86RegClass, vvvvClass: X86RegClass, regClass: X86RegClass)
    /// 3-operand VEX `src2_vvvv, src1_rm, dst_reg` (BMI `bextr`, `bzhi`, `sarx`, `shlx`, `shrx`).
    case vexVvvvRmReg(vvvvClass: X86RegClass, rmClass: X86RegClass, regClass: X86RegClass)
    /// 2-operand VEX `src_rm, dst_vvvv` with `/digit` in `ModRM.reg` (`blsr`, `blsi`, `blsmsk`).
    case vexRmToVvvv(rmClass: X86RegClass, vvvvClass: X86RegClass)
    /// 3-operand VEX `$imm8, src_rm, dst_vvvv` with `/digit` in `ModRM.reg` (`vpsrlw $imm`, `vpslldq`).
    case vexImmRmToVvvv(rmClass: X86RegClass, vvvvClass: X86RegClass)
    /// 3-operand VEX `src_reg, src1_vvvv, dst_rm` (`vmaskmovps` store, `vmovss` register store form).
    case vexRegVvvvToRm(regClass: X86RegClass, vvvvClass: X86RegClass, rmClass: X86RegClass)
    /// 4-operand VEX `src3_is4, src2_rm, src1_vvvv, dst_reg`; `src3` is in `imm8[7:4]` (`vblendvps`, `vpblendvb`).
    case vexIs4RmVvvvReg(rmClass: X86RegClass, vvvvClass: X86RegClass, regClass: X86RegClass)
    /// 3-operand VEX gather `mask_vvvv, vsib_mem, dst_reg`; the memory index is a vector register (`vgatherdps`).
    case vexVsib(vvvvClass: X86RegClass, indexClass: X86RegClass, regClass: X86RegClass)
    /// 3-operand legacy `%xmm0, src_rm, dst_reg` with an implicit `%xmm0` (`blendvps`, `pblendvb`, `sha256rnds2`).
    case xmm0RmToReg(rmClass: X86RegClass, regClass: X86RegClass)
    /// 1 relative branch target (`rel8` or `rel32`).
    case relBranch(relSize: X86OperandSize)
    /// 1 immediate operand (`push $imm8/32`, `int $imm8`, `ret $imm16`).
    case immOnly(immSize: X86OperandSize)
    /// Segment register moves (`mov %seg, r/m` `0x8C`, `mov r/m, %seg` `0x8E`).
    case segToRm
    case rmToSeg
    /// Control / Debug register moves (`0F 20`..`0F 23`).
    case crToReg
    case regToCr
    case drToReg
    case regToDr
    /// Port I/O (`in %dx, %al/%ax/%eax`, `out %al/%ax/%eax, %dx`).
    case ioDxToAcc
    case ioAccToDx
    case ioImmToAcc
    case ioAccToImm
}

/// Descriptor for a single x86-64 instruction encoding template.
@frozen
public struct X86InstrDesc: Sendable, Equatable, Hashable {
    public let mnemonic: String
    public let aliases: [String]
    public let operandSize: X86OperandSize
    public let encodingKind: X86EncodingKind
    public let opcodeMap: X86OpcodeMap
    public let mandatoryPrefix: X86MandatoryPrefix
    public let opcode: UInt8
    public let secondaryOpcode: UInt8?
    public let modrmSlash: UInt8?
    public let rexW: Bool
    public let vexL: UInt8
    public let default64BitInMode64: Bool
    public let suppressOperandSizePrefix: Bool
    public let operandFormat: X86OperandFormat
    /// Restriction on the `r/m` operand (register-only or memory-only forms).
    public let rmConstraint: X86RMConstraint
    /// VEX source operands may be swapped to move an extended register out of `r/m` and allow the
    /// 2-byte VEX prefix, as LLVM MC does for commutable map-0F instructions (05-assembler.md §4.11).
    public let commutable: Bool
    /// AT&T spelling required when the `r/m` operand is memory and the plain mnemonic would be
    /// ambiguous (`vcvtpd2psx` / `vcvtpd2psy`). It is also accepted for register forms.
    public let memMnemonic: String?

    public init(
        mnemonic: String,
        aliases: [String] = [],
        operandSize: X86OperandSize = .unsized,
        encodingKind: X86EncodingKind = .legacy,
        opcodeMap: X86OpcodeMap = .primary,
        mandatoryPrefix: X86MandatoryPrefix = .none,
        opcode: UInt8,
        secondaryOpcode: UInt8? = nil,
        modrmSlash: UInt8? = nil,
        rexW: Bool = false,
        vexL: UInt8 = 0,
        default64BitInMode64: Bool = false,
        suppressOperandSizePrefix: Bool = false,
        operandFormat: X86OperandFormat,
        rmConstraint: X86RMConstraint = .any,
        commutable: Bool = false,
        memMnemonic: String? = nil
    ) {
        self.rmConstraint = rmConstraint
        self.commutable = commutable
        self.memMnemonic = memMnemonic
        self.mnemonic = mnemonic
        self.aliases = aliases
        self.operandSize = operandSize
        self.encodingKind = encodingKind
        self.opcodeMap = opcodeMap
        self.mandatoryPrefix = mandatoryPrefix
        self.opcode = opcode
        self.secondaryOpcode = secondaryOpcode
        self.modrmSlash = modrmSlash
        self.rexW = rexW
        self.vexL = vexL
        self.default64BitInMode64 = default64BitInMode64
        self.suppressOperandSizePrefix = suppressOperandSizePrefix
        self.operandFormat = operandFormat
    }
}

// MARK: - 4. Shared Instruction Table (X86InstructionTable)

/// Shared x86-64 instruction table driving the backend encoder, assembler, and disassembler.
public enum X86InstructionTable {

    /// Condition code definitions `(ccNib, primarySuffix, aliases)`.
    public static let conditionCodes: [(cc: UInt8, primary: String, aliases: [String])] = [
        (0x0, "o",  []),
        (0x1, "no", []),
        (0x2, "b",  ["c", "nae"]),
        (0x3, "ae", ["nc", "nb"]),
        (0x4, "e",  ["z"]),
        (0x5, "ne", ["nz"]),
        (0x6, "be", ["na"]),
        (0x7, "a",  ["nbe"]),
        (0x8, "s",  []),
        (0x9, "ns", []),
        (0xA, "p",  ["pe"]),
        (0xB, "np", ["po"]),
        (0xC, "l",  ["nge"]),
        (0xD, "ge", ["nl"]),
        (0xE, "le", ["ng"]),
        (0xF, "g",  ["nle"])
    ]

    /// True if `mnemonic` already ends in the AT&T suffix for `size` (`movzbl`, `crc32q`, `ljmpw`, `lgdtl`),
    /// as opposed to a base name that happens to end in that letter (`sbb`, `sub`, `shl`, `imul`).
    public static func mnemonicCarriesSize(_ mnemonic: String, _ size: X86OperandSize) -> Bool {
        let suffix = size.attSuffix
        guard !suffix.isEmpty, mnemonic.hasSuffix(suffix) else { return false }
        return mnemonicMap[String(mnemonic.dropLast())] != nil
    }

    /// All instruction descriptors in priority order.
    public static let descriptors: [X86InstrDesc] = buildDescriptors()

    /// Lookup table mapping lowercase mnemonic (and sized/alias variants) to indices into `descriptors`.
    /// Each list is in ascending (table preference) order without duplicates.
    public static let mnemonicMap: [String: [Int]] = {
        var map: [String: [Int]] = [:]
        func add(_ name: String, _ idx: Int) {
            if map[name]?.last != idx { map[name, default: []].append(idx) }
        }
        for (idx, desc) in descriptors.enumerated() {
            add(desc.mnemonic, idx)
            if desc.operandSize != .unsized {
                let suffixed = desc.mnemonic + desc.operandSize.attSuffix
                if suffixed != desc.mnemonic {
                    add(suffixed, idx)
                }
            }
            for alias in desc.aliases {
                add(alias, idx)
            }
            if let memMnem = desc.memMnemonic {
                add(memMnem, idx)
            }
        }
        return map
    }()

    private static func buildDescriptors() -> [X86InstrDesc] {
        var list: [X86InstrDesc] = []
        list.reserveCapacity(750)

        // Helper for standard 4-size GPR instructions
        let gprSizes: [(X86OperandSize, X86RegClass, Bool)] = [
            (.byte,  .gpr8,  false),
            (.word,  .gpr16, false),
            (.dword, .gpr32, false),
            (.qword, .gpr64, true)
        ]

        // -----------------------------------------------------------------
        // 4.1 Data Movement: MOV, MOVABS, MOVZX, MOVSX, LEA, PUSH, POP, XCHG, CMPXCHG, BSWAP
        // -----------------------------------------------------------------

        // MOV reg -> r/m (0x88 / 0x89) — listed BEFORE r/m -> reg (0x8A / 0x8B) to match GNU `as`
        for (sz, rc, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "mov",
                operandSize: sz,
                opcode: sz == .byte ? 0x88 : 0x89,
                rexW: w,
                operandFormat: .regToRm(regClass: rc, rmClass: rc)
            ))
        }

        // MOV r/m -> reg (0x8A / 0x8B)
        for (sz, rc, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "mov",
                operandSize: sz,
                opcode: sz == .byte ? 0x8A : 0x8B,
                rexW: w,
                operandFormat: .rmToReg(rmClass: rc, regClass: rc)
            ))
        }

        // MOV $imm, %reg8/16/32 (0xB0+r ib, 0xB8+r iw/id)
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .byte,
            opcode: 0xB0,
            operandFormat: .immToOpcodePlusReg(.gpr8, immSize: .byte)
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .word,
            opcode: 0xB8,
            operandFormat: .immToOpcodePlusReg(.gpr16, immSize: .word)
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .dword,
            opcode: 0xB8,
            operandFormat: .immToOpcodePlusReg(.gpr32, immSize: .dword)
        ))

        // MOV $imm32 (sign-extended), r/m64 (48 C7 /0 id) — preferred by GNU `as` when imm fits in Int32
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .qword,
            opcode: 0xC7,
            modrmSlash: 0,
            rexW: true,
            operandFormat: .immToRm(rmClass: .gpr64, immSize: .dword)
        ))

        // MOVABS $imm64, %reg64 (48 B8+r iq) — also fallback for `mov $imm64, %reg64`
        list.append(X86InstrDesc(
            mnemonic: "movabs",
            aliases: ["movabsq", "mov", "movq"],
            operandSize: .qword,
            opcode: 0xB8,
            rexW: true,
            operandFormat: .immToOpcodePlusReg(.gpr64, immSize: .qword)
        ))

        // MOV $imm, r/m8/16/32 (0xC6 /0 ib, 0xC7 /0 iw/id)
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .byte,
            opcode: 0xC6,
            modrmSlash: 0,
            operandFormat: .immToRm(rmClass: .gpr8, immSize: .byte)
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .word,
            opcode: 0xC7,
            modrmSlash: 0,
            operandFormat: .immToRm(rmClass: .gpr16, immSize: .word)
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            operandSize: .dword,
            opcode: 0xC7,
            modrmSlash: 0,
            operandFormat: .immToRm(rmClass: .gpr32, immSize: .dword)
        ))

        // MOV segment registers. Sreg -> r16 takes 0x66, but Sreg -> m16 and r16/m16 -> Sreg do not
        // (LLVM MC and GNU `as` both omit it, since the operation is 16-bit regardless).
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .word, opcode: 0x8C, operandFormat: .segToRm, rmConstraint: .regOnly))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .word, opcode: 0x8C, suppressOperandSizePrefix: true, operandFormat: .segToRm, rmConstraint: .memOnly))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .dword, opcode: 0x8C, operandFormat: .segToRm, rmConstraint: .regOnly))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .qword, opcode: 0x8C, rexW: true, operandFormat: .segToRm, rmConstraint: .regOnly))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .word, opcode: 0x8E, suppressOperandSizePrefix: true, operandFormat: .rmToSeg))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .dword, opcode: 0x8E, operandFormat: .rmToSeg, rmConstraint: .regOnly))
        list.append(X86InstrDesc(mnemonic: "mov", operandSize: .qword, opcode: 0x8E, rexW: true, operandFormat: .rmToSeg, rmConstraint: .regOnly))

        // MOV control and debug registers
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movq", "movl"],
            opcodeMap: .map0F,
            opcode: 0x20,
            default64BitInMode64: true,
            suppressOperandSizePrefix: true,
            operandFormat: .crToReg
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movq", "movl"],
            opcodeMap: .map0F,
            opcode: 0x22,
            default64BitInMode64: true,
            suppressOperandSizePrefix: true,
            operandFormat: .regToCr
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movq", "movl"],
            opcodeMap: .map0F,
            opcode: 0x21,
            default64BitInMode64: true,
            suppressOperandSizePrefix: true,
            operandFormat: .drToReg
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movq", "movl"],
            opcodeMap: .map0F,
            opcode: 0x23,
            default64BitInMode64: true,
            suppressOperandSizePrefix: true,
            operandFormat: .regToDr
        ))

        // MOVZX (0F B6 /r byte->word/dword/qword, 0F B7 /r word->dword/qword)
        list.append(X86InstrDesc(
            mnemonic: "movzbw",
            aliases: ["movzx", "movzb"],
            operandSize: .word,
            opcodeMap: .map0F,
            opcode: 0xB6,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr16)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movzbl",
            aliases: ["movzx", "movzb"],
            operandSize: .dword,
            opcodeMap: .map0F,
            opcode: 0xB6,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr32)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movzbq",
            aliases: ["movzx", "movzb"],
            operandSize: .qword,
            opcodeMap: .map0F,
            opcode: 0xB6,
            rexW: true,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr64)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movzwl",
            aliases: ["movzx", "movzw"],
            operandSize: .dword,
            opcodeMap: .map0F,
            opcode: 0xB7,
            operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr32)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movzwq",
            aliases: ["movzx", "movzw"],
            operandSize: .qword,
            opcodeMap: .map0F,
            opcode: 0xB7,
            rexW: true,
            operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr64)
        ))

        // MOVSX / MOVSLQ (0F BE /r, 0F BF /r, REX.W 63 /r)
        list.append(X86InstrDesc(
            mnemonic: "movsbw",
            aliases: ["movsx"],
            operandSize: .word,
            opcodeMap: .map0F,
            opcode: 0xBE,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr16)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movsbl",
            aliases: ["movsx"],
            operandSize: .dword,
            opcodeMap: .map0F,
            opcode: 0xBE,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr32)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movsbq",
            aliases: ["movsx"],
            operandSize: .qword,
            opcodeMap: .map0F,
            opcode: 0xBE,
            rexW: true,
            operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr64)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movswl",
            aliases: ["movsx"],
            operandSize: .dword,
            opcodeMap: .map0F,
            opcode: 0xBF,
            operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr32)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movswq",
            aliases: ["movsx"],
            operandSize: .qword,
            opcodeMap: .map0F,
            opcode: 0xBF,
            rexW: true,
            operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr64)
        ))
        list.append(X86InstrDesc(
            mnemonic: "movslq",
            aliases: ["movsxd", "movsx"],
            operandSize: .qword,
            opcode: 0x63,
            rexW: true,
            operandFormat: .rmToReg(rmClass: .gpr32, regClass: .gpr64)
        ))

        // Sign-extension accumulator instructions
        list.append(X86InstrDesc(mnemonic: "cbtw", aliases: ["cbw"], operandSize: .word, opcode: 0x98, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cwtl", aliases: ["cwde"], operandSize: .dword, opcode: 0x98, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cltq", aliases: ["cdqe"], operandSize: .qword, opcode: 0x98, rexW: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cwtd", aliases: ["cwd"], operandSize: .word, opcode: 0x99, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cltd", aliases: ["cdq"], operandSize: .dword, opcode: 0x99, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cqto", aliases: ["cqo"], operandSize: .qword, opcode: 0x99, rexW: true, operandFormat: .implied))

        // LEA (0x8D /r)
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .qword, opcode: 0x8D, rexW: true, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .gpr64), rmConstraint: .memOnly))
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .dword, opcode: 0x8D, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .gpr32), rmConstraint: .memOnly))
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .word, opcode: 0x8D, operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr16), rmConstraint: .memOnly))

        // PUSH / POP / PUSHFQ / POPFQ
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushq"], operandSize: .qword, opcode: 0x50, default64BitInMode64: true, operandFormat: .opcodePlusReg(.gpr64)))
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushw"], operandSize: .word, opcode: 0x50, operandFormat: .opcodePlusReg(.gpr16)))
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushq"], operandSize: .qword, opcode: 0x6A, default64BitInMode64: true, operandFormat: .immOnly(immSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushq"], operandSize: .qword, opcode: 0x68, default64BitInMode64: true, operandFormat: .immOnly(immSize: .dword)))
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushq"], operandSize: .qword, opcode: 0xFF, modrmSlash: 6, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "push", aliases: ["pushw"], operandSize: .word, opcode: 0xFF, modrmSlash: 6, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "pushfq", aliases: ["pushf"], operandSize: .qword, opcode: 0x9C, default64BitInMode64: true, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "pop", aliases: ["popq"], operandSize: .qword, opcode: 0x58, default64BitInMode64: true, operandFormat: .opcodePlusReg(.gpr64)))
        list.append(X86InstrDesc(mnemonic: "pop", aliases: ["popw"], operandSize: .word, opcode: 0x58, operandFormat: .opcodePlusReg(.gpr16)))
        list.append(X86InstrDesc(mnemonic: "pop", aliases: ["popq"], operandSize: .qword, opcode: 0x8F, modrmSlash: 0, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "pop", aliases: ["popw"], operandSize: .word, opcode: 0x8F, modrmSlash: 0, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "popfq", aliases: ["popf"], operandSize: .qword, opcode: 0x9D, default64BitInMode64: true, operandFormat: .implied))

        // XCHG: accumulator short form (0x90 + r), then `%a, %b` with ModRM.reg = %b (as LLVM MC encodes it),
        // then `%reg, mem`. CMPXCHG, CMPXCHG16B, BSWAP.
        for (sz, rc, w) in gprSizes where sz != .byte {
            list.append(X86InstrDesc(mnemonic: "xchg", operandSize: sz, opcode: 0x90, rexW: w, operandFormat: .opcodePlusRegWithAcc(rc)))
        }
        for (sz, rc, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "xchg",
                operandSize: sz,
                opcode: sz == .byte ? 0x86 : 0x87,
                rexW: w,
                operandFormat: .rmToReg(rmClass: rc, regClass: rc)
            ))
            list.append(X86InstrDesc(
                mnemonic: "xchg",
                operandSize: sz,
                opcode: sz == .byte ? 0x86 : 0x87,
                rexW: w,
                operandFormat: .regToRm(regClass: rc, rmClass: rc),
                rmConstraint: .memOnly
            ))
            list.append(X86InstrDesc(
                mnemonic: "cmpxchg",
                operandSize: sz,
                opcodeMap: .map0F,
                opcode: sz == .byte ? 0xB0 : 0xB1,
                rexW: w,
                operandFormat: .regToRm(regClass: rc, rmClass: rc)
            ))
        }
        list.append(X86InstrDesc(
            mnemonic: "cmpxchg16b",
            operandSize: .qword,
            opcodeMap: .map0F,
            opcode: 0xC7,
            modrmSlash: 1,
            rexW: true,
            operandFormat: .rm(.memOnly)
        ))
        list.append(X86InstrDesc(mnemonic: "bswap", operandSize: .qword, opcodeMap: .map0F, opcode: 0xC8, rexW: true, operandFormat: .opcodePlusReg(.gpr64)))
        list.append(X86InstrDesc(mnemonic: "bswap", operandSize: .dword, opcodeMap: .map0F, opcode: 0xC8, operandFormat: .opcodePlusReg(.gpr32)))

        // -----------------------------------------------------------------
        // 4.2 Standard ALU Operations: ADD, OR, ADC, SBB, AND, SUB, XOR, CMP
        // -----------------------------------------------------------------
        let aluOps: [(name: String, slash: UInt8, baseOp: UInt8)] = [
            ("add", 0, 0x00),
            ("or",  1, 0x08),
            ("adc", 2, 0x10),
            ("sbb", 3, 0x18),
            ("and", 4, 0x20),
            ("sub", 5, 0x28),
            ("xor", 6, 0x30),
            ("cmp", 7, 0x38)
        ]

        for alu in aluOps {
            // 1. reg -> r/m (0x00/0x01, etc.) — preferred by GNU `as` for reg-reg
            for (sz, rc, w) in gprSizes {
                list.append(X86InstrDesc(
                    mnemonic: alu.name,
                    operandSize: sz,
                    opcode: sz == .byte ? alu.baseOp : (alu.baseOp + 1),
                    rexW: w,
                    operandFormat: .regToRm(regClass: rc, rmClass: rc)
                ))
            }
            // 2. r/m -> reg (0x02/0x03, etc.) — used when memory is source
            for (sz, rc, w) in gprSizes {
                list.append(X86InstrDesc(
                    mnemonic: alu.name,
                    operandSize: sz,
                    opcode: sz == .byte ? (alu.baseOp + 2) : (alu.baseOp + 3),
                    rexW: w,
                    operandFormat: .rmToReg(rmClass: rc, regClass: rc)
                ))
            }
            // 3. Sign-extended imm8 -> r/m16/32/64 (0x83 /digit ib) — preferred by GNU `as` when imm fits in Int8
            for (sz, rc, w) in gprSizes where sz != .byte {
                list.append(X86InstrDesc(
                    mnemonic: alu.name,
                    operandSize: sz,
                    opcode: 0x83,
                    modrmSlash: alu.slash,
                    rexW: w,
                    operandFormat: .immToRm(rmClass: rc, immSize: .byte)
                ))
            }
            // 4. Accumulator immediate short form (`%al`, `%ax`, `%eax`, `%rax`: 0x04 ib, 0x05 iw/id)
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .byte,
                opcode: alu.baseOp + 4,
                operandFormat: .immToAcc(immSize: .byte)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .word,
                opcode: alu.baseOp + 5,
                operandFormat: .immToAcc(immSize: .word)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .dword,
                opcode: alu.baseOp + 5,
                operandFormat: .immToAcc(immSize: .dword)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .qword,
                opcode: alu.baseOp + 5,
                rexW: true,
                operandFormat: .immToAcc(immSize: .dword)
            ))
            // 5. Full immediate -> r/m (0x80 /digit ib, 0x81 /digit iw/id)
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .byte,
                opcode: 0x80,
                modrmSlash: alu.slash,
                operandFormat: .immToRm(rmClass: .gpr8, immSize: .byte)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .word,
                opcode: 0x81,
                modrmSlash: alu.slash,
                operandFormat: .immToRm(rmClass: .gpr16, immSize: .word)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .dword,
                opcode: 0x81,
                modrmSlash: alu.slash,
                operandFormat: .immToRm(rmClass: .gpr32, immSize: .dword)
            ))
            list.append(X86InstrDesc(
                mnemonic: alu.name,
                operandSize: .qword,
                opcode: 0x81,
                modrmSlash: alu.slash,
                rexW: true,
                operandFormat: .immToRm(rmClass: .gpr64, immSize: .dword)
            ))
        }

        // TEST (0x84/0x85 reg, r/m; 0xA8/0xA9 imm, acc; 0xF6/0xF7 /0 imm, r/m)
        for (sz, rc, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "test",
                operandSize: sz,
                opcode: sz == .byte ? 0x84 : 0x85,
                rexW: w,
                operandFormat: .regToRm(regClass: rc, rmClass: rc)
            ))
            let immSz: X86OperandSize = sz == .qword ? .dword : sz
            list.append(X86InstrDesc(
                mnemonic: "test",
                operandSize: sz,
                opcode: sz == .byte ? 0xA8 : 0xA9,
                rexW: w,
                operandFormat: .immToAcc(immSize: immSz)
            ))
            list.append(X86InstrDesc(
                mnemonic: "test",
                operandSize: sz,
                opcode: sz == .byte ? 0xF6 : 0xF7,
                modrmSlash: 0,
                rexW: w,
                operandFormat: .immToRm(rmClass: rc, immSize: immSz)
            ))
        }

        // Unary & Multiply/Divide: INC, DEC, NOT, NEG, MUL, IMUL, DIV, IDIV
        let unaryF6F7: [(name: String, slash: UInt8)] = [
            ("not",  2),
            ("neg",  3),
            ("mul",  4),
            ("imul", 5),
            ("div",  6),
            ("idiv", 7)
        ]
        for u in unaryF6F7 {
            for (sz, _, w) in gprSizes {
                list.append(X86InstrDesc(
                    mnemonic: u.name,
                    operandSize: sz,
                    opcode: sz == .byte ? 0xF6 : 0xF7,
                    modrmSlash: u.slash,
                    rexW: w,
                    operandFormat: .rm(.gprOrMem)
                ))
            }
        }
        // IMUL 2-operand (0F AF /r) and 3-operand (0x6B /r ib, 0x69 /r iw/id)
        for (sz, rc, w) in gprSizes where sz != .byte {
            list.append(X86InstrDesc(
                mnemonic: "imul",
                operandSize: sz,
                opcodeMap: .map0F,
                opcode: 0xAF,
                rexW: w,
                operandFormat: .rmToReg(rmClass: rc, regClass: rc)
            ))
            list.append(X86InstrDesc(
                mnemonic: "imul",
                operandSize: sz,
                opcode: 0x6B,
                rexW: w,
                operandFormat: .immRmToReg(rmClass: rc, regClass: rc, immSize: .byte)
            ))
            list.append(X86InstrDesc(
                mnemonic: "imul",
                operandSize: sz,
                opcode: 0x69,
                rexW: w,
                operandFormat: .immRmToReg(rmClass: rc, regClass: rc, immSize: sz == .word ? .word : .dword)
            ))
        }

        // INC / DEC (0xFE /0..1, 0xFF /0..1)
        for (sz, _, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "inc",
                operandSize: sz,
                opcode: sz == .byte ? 0xFE : 0xFF,
                modrmSlash: 0,
                rexW: w,
                operandFormat: .rm(.gprOrMem)
            ))
            list.append(X86InstrDesc(
                mnemonic: "dec",
                operandSize: sz,
                opcode: sz == .byte ? 0xFE : 0xFF,
                modrmSlash: 1,
                rexW: w,
                operandFormat: .rm(.gprOrMem)
            ))
        }

        // -----------------------------------------------------------------
        // 4.3 Shifts, Rotates, and Bit Manipulation
        // -----------------------------------------------------------------
        let shiftOps: [(name: String, aliases: [String], slash: UInt8)] = [
            ("rol", [], 0),
            ("ror", [], 1),
            ("rcl", [], 2),
            ("rcr", [], 3),
            ("shl", ["sal", "salb", "salw", "sall", "salq"], 4),
            ("shr", [], 5),
            ("sar", [], 7)
        ]
        for sh in shiftOps {
            for (sz, rc, w) in gprSizes {
                // Shift by 1 (0xD0 /d, 0xD1 /d)
                list.append(X86InstrDesc(
                    mnemonic: sh.name,
                    aliases: sh.aliases,
                    operandSize: sz,
                    opcode: sz == .byte ? 0xD0 : 0xD1,
                    modrmSlash: sh.slash,
                    rexW: w,
                    operandFormat: .shiftBy1
                ))
                // Shift by %cl (0xD2 /d, 0xD3 /d)
                list.append(X86InstrDesc(
                    mnemonic: sh.name,
                    aliases: sh.aliases,
                    operandSize: sz,
                    opcode: sz == .byte ? 0xD2 : 0xD3,
                    modrmSlash: sh.slash,
                    rexW: w,
                    operandFormat: .shiftByCl
                ))
                // Shift by $imm8 (0xC0 /d ib, 0xC1 /d ib)
                list.append(X86InstrDesc(
                    mnemonic: sh.name,
                    aliases: sh.aliases,
                    operandSize: sz,
                    opcode: sz == .byte ? 0xC0 : 0xC1,
                    modrmSlash: sh.slash,
                    rexW: w,
                    operandFormat: .immToRm(rmClass: rc, immSize: .byte)
                ))
            }
        }

        // BT, BTS, BTR, BTC (reg and imm8)
        let bitOps: [(name: String, regOp: UInt8, immSlash: UInt8)] = [
            ("bt",  0xA3, 4),
            ("bts", 0xAB, 5),
            ("btr", 0xB3, 6),
            ("btc", 0xBB, 7)
        ]
        for bt in bitOps {
            for (sz, rc, w) in gprSizes where sz != .byte {
                list.append(X86InstrDesc(
                    mnemonic: bt.name,
                    operandSize: sz,
                    opcodeMap: .map0F,
                    opcode: bt.regOp,
                    rexW: w,
                    operandFormat: .regToRm(regClass: rc, rmClass: rc)
                ))
                list.append(X86InstrDesc(
                    mnemonic: bt.name,
                    operandSize: sz,
                    opcodeMap: .map0F,
                    opcode: 0xBA,
                    modrmSlash: bt.immSlash,
                    rexW: w,
                    operandFormat: .immToRm(rmClass: rc, immSize: .byte)
                ))
            }
        }

        // BSF, BSR, TZCNT, LZCNT, POPCNT
        let bitCountOps: [(name: String, prefix: X86MandatoryPrefix, op: UInt8)] = [
            ("bsf",    .none, 0xBC),
            ("bsr",    .none, 0xBD),
            ("tzcnt",  .pF3,  0xBC),
            ("lzcnt",  .pF3,  0xBD),
            ("popcnt", .pF3,  0xB8)
        ]
        for bc in bitCountOps {
            for (sz, rc, w) in gprSizes where sz != .byte {
                list.append(X86InstrDesc(
                    mnemonic: bc.name,
                    operandSize: sz,
                    opcodeMap: .map0F,
                    mandatoryPrefix: bc.prefix,
                    opcode: bc.op,
                    rexW: w,
                    operandFormat: .rmToReg(rmClass: rc, regClass: rc)
                ))
            }
        }

        // -----------------------------------------------------------------
        // 4.4 Control Flow & Conditionals: JMP, LJMP, Jcc, SETcc, CMOVcc, CALL, RET, LEAVE
        // -----------------------------------------------------------------
        list.append(X86InstrDesc(mnemonic: "jmp", aliases: ["jmpq"], opcode: 0xEB, default64BitInMode64: true, operandFormat: .relBranch(relSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "jmp", aliases: ["jmpq"], opcode: 0xE9, default64BitInMode64: true, operandFormat: .relBranch(relSize: .dword)))
        list.append(X86InstrDesc(mnemonic: "jmp", aliases: ["jmpq"], operandSize: .qword, opcode: 0xFF, modrmSlash: 4, default64BitInMode64: true, operandFormat: .rm(.indirectRegOrMem)))
        list.append(X86InstrDesc(mnemonic: "ljmpl", aliases: ["ljmp"], operandSize: .dword, opcode: 0xFF, modrmSlash: 5, operandFormat: .rm(.indirectMemOnly)))
        list.append(X86InstrDesc(mnemonic: "ljmpw", operandSize: .word, opcode: 0xFF, modrmSlash: 5, operandFormat: .rm(.indirectMemOnly)))

        list.append(X86InstrDesc(mnemonic: "call", aliases: ["callq"], opcode: 0xE8, default64BitInMode64: true, operandFormat: .relBranch(relSize: .dword)))
        list.append(X86InstrDesc(mnemonic: "call", aliases: ["callq"], operandSize: .qword, opcode: 0xFF, modrmSlash: 2, default64BitInMode64: true, operandFormat: .rm(.indirectRegOrMem)))

        list.append(X86InstrDesc(mnemonic: "ret", aliases: ["retq"], operandSize: .qword, opcode: 0xC3, default64BitInMode64: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "ret", aliases: ["retq"], operandSize: .qword, opcode: 0xC2, default64BitInMode64: true, operandFormat: .immOnly(immSize: .word)))
        list.append(X86InstrDesc(mnemonic: "lretq", operandSize: .qword, opcode: 0xCB, rexW: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "lret", aliases: ["lretl"], operandSize: .dword, opcode: 0xCB, default64BitInMode64: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "leave", aliases: ["leaveq"], operandSize: .qword, opcode: 0xC9, default64BitInMode64: true, operandFormat: .implied))

        for ccEntry in conditionCodes {
            let jAliases = ccEntry.aliases.map { "j" + $0 }
            // rel8 (0x70 + cc) and rel32 (0F 80 + cc)
            list.append(X86InstrDesc(
                mnemonic: "j" + ccEntry.primary,
                aliases: jAliases,
                opcode: 0x70 + ccEntry.cc,
                default64BitInMode64: true,
                operandFormat: .relBranch(relSize: .byte)
            ))
            list.append(X86InstrDesc(
                mnemonic: "j" + ccEntry.primary,
                aliases: jAliases,
                opcodeMap: .map0F,
                opcode: 0x80 + ccEntry.cc,
                default64BitInMode64: true,
                operandFormat: .relBranch(relSize: .dword)
            ))

            // setcc (0F 90 + cc /0)
            let setAliases = ccEntry.aliases.map { "set" + $0 }
            list.append(X86InstrDesc(
                mnemonic: "set" + ccEntry.primary,
                aliases: setAliases,
                operandSize: .byte,
                opcodeMap: .map0F,
                opcode: 0x90 + ccEntry.cc,
                modrmSlash: 0,
                operandFormat: .rm(.gprOrMem)
            ))

            // cmovcc (0F 40 + cc /r)
            let cmovAliases = ccEntry.aliases.map { "cmov" + $0 }
            for (sz, rc, w) in gprSizes where sz != .byte {
                let szAliases = cmovAliases + cmovAliases.map { $0 + sz.attSuffix }
                list.append(X86InstrDesc(
                    mnemonic: "cmov" + ccEntry.primary,
                    aliases: szAliases,
                    operandSize: sz,
                    opcodeMap: .map0F,
                    opcode: 0x40 + ccEntry.cc,
                    rexW: w,
                    operandFormat: .rmToReg(rmClass: rc, regClass: rc)
                ))
            }
        }

        // -----------------------------------------------------------------
        // 4.5 String & Flag Instructions
        // -----------------------------------------------------------------
        list.append(X86InstrDesc(mnemonic: "movsb", operandSize: .byte, opcode: 0xA4, suppressOperandSizePrefix: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "movsw", operandSize: .word, opcode: 0xA5, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "movsl", aliases: ["movsd"], operandSize: .dword, opcode: 0xA5, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "movsq", operandSize: .qword, opcode: 0xA5, rexW: true, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "stosb", operandSize: .byte, opcode: 0xAA, suppressOperandSizePrefix: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "stosw", operandSize: .word, opcode: 0xAB, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "stosl", aliases: ["stosd"], operandSize: .dword, opcode: 0xAB, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "stosq", operandSize: .qword, opcode: 0xAB, rexW: true, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "cld", opcode: 0xFC, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "std", opcode: 0xFD, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "lahf", opcode: 0x9F, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "sahf", opcode: 0x9E, operandFormat: .implied))

        // -----------------------------------------------------------------
        // 4.6 System, Privileged, and Miscellaneous Instructions
        // -----------------------------------------------------------------
        list.append(X86InstrDesc(mnemonic: "syscall", opcodeMap: .map0F, opcode: 0x05, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "sysretq", operandSize: .qword, opcodeMap: .map0F, opcode: 0x07, rexW: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "sysretl", aliases: ["sysret"], operandSize: .dword, opcodeMap: .map0F, opcode: 0x07, suppressOperandSizePrefix: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "iretq", operandSize: .qword, opcode: 0xCF, rexW: true, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "iret", aliases: ["iretl"], operandSize: .dword, opcode: 0xCF, suppressOperandSizePrefix: true, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "swapgs", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xF8, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "rdtscp", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xF9, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "monitor", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xC8, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "mwait", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xC9, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "clac", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xCA, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "stac", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xCB, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "xgetbv", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xD0, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "xsetbv", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xD1, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "rdpkru", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xEE, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "wrpkru", opcodeMap: .map0F, opcode: 0x01, secondaryOpcode: 0xEF, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "sgdt", aliases: ["sgdtq"], opcodeMap: .map0F, opcode: 0x01, modrmSlash: 0, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "sidt", aliases: ["sidtq"], opcodeMap: .map0F, opcode: 0x01, modrmSlash: 1, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "lgdt", aliases: ["lgdtq"], opcodeMap: .map0F, opcode: 0x01, modrmSlash: 2, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "lgdtl", operandSize: .dword, opcodeMap: .map0F, opcode: 0x01, modrmSlash: 2, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "lidt", aliases: ["lidtq", "lidtl"], opcodeMap: .map0F, opcode: 0x01, modrmSlash: 3, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "invlpg", opcodeMap: .map0F, opcode: 0x01, modrmSlash: 7, default64BitInMode64: true, operandFormat: .rm(.memOnly)))

        list.append(X86InstrDesc(mnemonic: "str", operandSize: .word, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 1, operandFormat: .rm(.gprOrMem), rmConstraint: .regOnly))
        list.append(X86InstrDesc(mnemonic: "str", operandSize: .word, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 1, suppressOperandSizePrefix: true, operandFormat: .rm(.gprOrMem), rmConstraint: .memOnly))
        list.append(X86InstrDesc(mnemonic: "str", operandSize: .dword, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 1, operandFormat: .rm(.gprOnly)))
        list.append(X86InstrDesc(mnemonic: "str", operandSize: .qword, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 1, rexW: true, operandFormat: .rm(.gprOnly)))
        list.append(X86InstrDesc(mnemonic: "ltr", aliases: ["ltrw"], operandSize: .word, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 3, suppressOperandSizePrefix: true, operandFormat: .rm(.gprOrMem)))

        list.append(X86InstrDesc(mnemonic: "wrmsr", opcodeMap: .map0F, opcode: 0x30, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "rdtsc", opcodeMap: .map0F, opcode: 0x31, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "rdmsr", opcodeMap: .map0F, opcode: 0x32, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "cpuid", opcodeMap: .map0F, opcode: 0xA2, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "wbinvd", opcodeMap: .map0F, opcode: 0x09, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "ud2", opcodeMap: .map0F, opcode: 0x0B, operandFormat: .implied))

        list.append(X86InstrDesc(mnemonic: "lfence", opcodeMap: .map0F, opcode: 0xAE, secondaryOpcode: 0xE8, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "mfence", opcodeMap: .map0F, opcode: 0xAE, secondaryOpcode: 0xF0, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "sfence", opcodeMap: .map0F, opcode: 0xAE, secondaryOpcode: 0xF8, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "clflush", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 7, default64BitInMode64: true, operandFormat: .rm(.memOnly)))

        list.append(X86InstrDesc(mnemonic: "fxsave64", operandSize: .qword, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 0, rexW: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "fxsave", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 0, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "fxrstor64", operandSize: .qword, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 1, rexW: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "fxrstor", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 1, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xsave64", operandSize: .qword, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 4, rexW: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xsave", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 4, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xrstor64", operandSize: .qword, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 5, rexW: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xrstor", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 5, default64BitInMode64: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xsaveopt64", operandSize: .qword, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 6, rexW: true, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "xsaveopt", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 6, default64BitInMode64: true, operandFormat: .rm(.memOnly)))

        for (sz, _, w) in gprSizes where sz != .byte {
            list.append(X86InstrDesc(mnemonic: "rdrand", operandSize: sz, opcodeMap: .map0F, opcode: 0xC7, modrmSlash: 6, rexW: w, operandFormat: .rm(.gprOnly)))
            list.append(X86InstrDesc(mnemonic: "rdseed", operandSize: sz, opcodeMap: .map0F, opcode: 0xC7, modrmSlash: 7, rexW: w, operandFormat: .rm(.gprOnly)))
        }

        list.append(X86InstrDesc(mnemonic: "pause", mandatoryPrefix: .pF3, opcode: 0x90, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "endbr64", opcodeMap: .map0F, mandatoryPrefix: .pF3, opcode: 0x1E, secondaryOpcode: 0xFA, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "endbr32", opcodeMap: .map0F, mandatoryPrefix: .pF3, opcode: 0x1E, secondaryOpcode: 0xFB, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "nop", opcode: 0x90, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "int3", opcode: 0xCC, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "int", opcode: 0xCD, operandFormat: .immOnly(immSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "cli", opcode: 0xFA, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "sti", opcode: 0xFB, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "hlt", opcode: 0xF4, operandFormat: .implied))

        // Port I/O: IN, OUT
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inb"], operandSize: .byte, opcode: 0xEC, operandFormat: .ioDxToAcc))
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inw"], operandSize: .word, opcode: 0xED, operandFormat: .ioDxToAcc))
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inl"], operandSize: .dword, opcode: 0xED, operandFormat: .ioDxToAcc))
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inb"], operandSize: .byte, opcode: 0xE4, operandFormat: .ioImmToAcc))
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inw"], operandSize: .word, opcode: 0xE5, operandFormat: .ioImmToAcc))
        list.append(X86InstrDesc(mnemonic: "in", aliases: ["inl"], operandSize: .dword, opcode: 0xE5, operandFormat: .ioImmToAcc))

        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outb"], operandSize: .byte, opcode: 0xEE, operandFormat: .ioAccToDx))
        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outw"], operandSize: .word, opcode: 0xEF, operandFormat: .ioAccToDx))
        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outl"], operandSize: .dword, opcode: 0xEF, operandFormat: .ioAccToDx))
        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outb"], operandSize: .byte, opcode: 0xE6, operandFormat: .ioAccToImm))
        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outw"], operandSize: .word, opcode: 0xE7, operandFormat: .ioAccToImm))
        list.append(X86InstrDesc(mnemonic: "out", aliases: ["outl"], operandSize: .dword, opcode: 0xE7, operandFormat: .ioAccToImm))

        // CRC32 (SSE4.2)
        list.append(X86InstrDesc(mnemonic: "crc32b", aliases: ["crc32"], operandSize: .byte, opcodeMap: .map0F38, mandatoryPrefix: .pF2, opcode: 0xF0, operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr32)))
        list.append(X86InstrDesc(mnemonic: "crc32b", aliases: ["crc32"], operandSize: .byte, opcodeMap: .map0F38, mandatoryPrefix: .pF2, opcode: 0xF0, rexW: true, operandFormat: .rmToReg(rmClass: .gpr8, regClass: .gpr64)))
        list.append(X86InstrDesc(mnemonic: "crc32w", aliases: ["crc32"], operandSize: .word, opcodeMap: .map0F38, mandatoryPrefix: .p66F2, opcode: 0xF1, suppressOperandSizePrefix: true, operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr32)))
        list.append(X86InstrDesc(mnemonic: "crc32l", aliases: ["crc32"], operandSize: .dword, opcodeMap: .map0F38, mandatoryPrefix: .pF2, opcode: 0xF1, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .gpr32)))
        list.append(X86InstrDesc(mnemonic: "crc32q", aliases: ["crc32"], operandSize: .qword, opcodeMap: .map0F38, mandatoryPrefix: .pF2, opcode: 0xF1, rexW: true, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .gpr64)))

        // -----------------------------------------------------------------
        // 4.7 GPR extensions: BMI1, BMI2, ADX, MOVBE, cache control
        // -----------------------------------------------------------------
        let gpr3264: [(X86OperandSize, X86RegClass, Bool)] = [(.dword, .gpr32, false), (.qword, .gpr64, true)]
        for (sz, rc, w) in gpr3264 {
            func bmi(_ name: String, _ pfx: X86MandatoryPrefix, map: X86OpcodeMap = .map0F38, _ op: UInt8, slash: UInt8? = nil, _ format: X86OperandFormat) {
                list.append(X86InstrDesc(mnemonic: name, operandSize: sz, encodingKind: .vex, opcodeMap: map, mandatoryPrefix: pfx, opcode: op, modrmSlash: slash, rexW: w, operandFormat: format))
            }
            // BMI1
            bmi("andn",   .none, 0xF2, .vexRmVvvvReg(rmClass: rc, vvvvClass: rc, regClass: rc))
            bmi("bextr",  .none, 0xF7, .vexVvvvRmReg(vvvvClass: rc, rmClass: rc, regClass: rc))
            bmi("blsr",   .none, 0xF3, slash: 1, .vexRmToVvvv(rmClass: rc, vvvvClass: rc))
            bmi("blsmsk", .none, 0xF3, slash: 2, .vexRmToVvvv(rmClass: rc, vvvvClass: rc))
            bmi("blsi",   .none, 0xF3, slash: 3, .vexRmToVvvv(rmClass: rc, vvvvClass: rc))
            // BMI2
            bmi("bzhi",   .none, 0xF5, .vexVvvvRmReg(vvvvClass: rc, rmClass: rc, regClass: rc))
            bmi("pdep",   .pF2,  0xF5, .vexRmVvvvReg(rmClass: rc, vvvvClass: rc, regClass: rc))
            bmi("pext",   .pF3,  0xF5, .vexRmVvvvReg(rmClass: rc, vvvvClass: rc, regClass: rc))
            bmi("mulx",   .pF2,  0xF6, .vexRmVvvvReg(rmClass: rc, vvvvClass: rc, regClass: rc))
            bmi("sarx",   .pF3,  0xF7, .vexVvvvRmReg(vvvvClass: rc, rmClass: rc, regClass: rc))
            bmi("shlx",   .p66,  0xF7, .vexVvvvRmReg(vvvvClass: rc, rmClass: rc, regClass: rc))
            bmi("shrx",   .pF2,  0xF7, .vexVvvvRmReg(vvvvClass: rc, rmClass: rc, regClass: rc))
            bmi("rorx",   .pF2, map: .map0F3A, 0xF0, .immRmToReg(rmClass: rc, regClass: rc, immSize: .byte))
            // ADX
            list.append(X86InstrDesc(mnemonic: "adcx", operandSize: sz, opcodeMap: .map0F38, mandatoryPrefix: .p66, opcode: 0xF6, rexW: w, operandFormat: .rmToReg(rmClass: rc, regClass: rc)))
            list.append(X86InstrDesc(mnemonic: "adox", operandSize: sz, opcodeMap: .map0F38, mandatoryPrefix: .pF3, opcode: 0xF6, rexW: w, operandFormat: .rmToReg(rmClass: rc, regClass: rc)))
            // MOVNTI
            list.append(X86InstrDesc(mnemonic: "movnti", operandSize: sz, opcodeMap: .map0F, opcode: 0xC3, rexW: w, operandFormat: .regToRm(regClass: rc, rmClass: rc), rmConstraint: .memOnly))
        }
        // MOVBE (memory only; load 0F 38 F0, store 0F 38 F1)
        for (sz, rc, w) in gprSizes where sz != .byte {
            list.append(X86InstrDesc(mnemonic: "movbe", operandSize: sz, opcodeMap: .map0F38, opcode: 0xF0, rexW: w, operandFormat: .rmToReg(rmClass: rc, regClass: rc), rmConstraint: .memOnly))
            list.append(X86InstrDesc(mnemonic: "movbe", operandSize: sz, opcodeMap: .map0F38, opcode: 0xF1, rexW: w, operandFormat: .regToRm(regClass: rc, rmClass: rc), rmConstraint: .memOnly))
        }
        // Prefetch, cache-line flush/write-back, MXCSR
        for (name, op, slash) in [("prefetchnta", UInt8(0x18), UInt8(0)), ("prefetcht0", 0x18, 1), ("prefetcht1", 0x18, 2), ("prefetcht2", 0x18, 3), ("prefetchw", 0x0D, 1)] {
            list.append(X86InstrDesc(mnemonic: name, opcodeMap: .map0F, opcode: op, modrmSlash: slash, operandFormat: .rm(.memOnly)))
        }
        list.append(X86InstrDesc(mnemonic: "clflushopt", opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0xAE, modrmSlash: 7, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "clwb", opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0xAE, modrmSlash: 6, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "ldmxcsr", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 2, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "stmxcsr", opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 3, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "vldmxcsr", encodingKind: .vex, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 2, operandFormat: .rm(.memOnly)))
        list.append(X86InstrDesc(mnemonic: "vstmxcsr", encodingKind: .vex, opcodeMap: .map0F, opcode: 0xAE, modrmSlash: 3, operandFormat: .rm(.memOnly)))

        // -----------------------------------------------------------------
        // 4.8 SSE..SSE4.2, AVX, AVX2, FMA, F16C, AES, PCLMUL, SHA (04-backend.md §4.9, 17 §2)
        // -----------------------------------------------------------------
        // Each SIMD instruction has up to three forms: legacy SSE (`xmm`, destructive 2-operand), VEX.128
        // (`v` prefix, non-destructive 3-operand) and VEX.256 (`ymm`; AVX for FP, AVX2 for integer).
        let X = X86RegClass.xmm
        let Y = X86RegClass.ymm

        func sse(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, w: Bool = false,
                 size: X86OperandSize = .xmm128, slash: UInt8? = nil, rm: X86RMConstraint = .any,
                 aliases: [String] = [], _ format: X86OperandFormat) {
            list.append(X86InstrDesc(mnemonic: name, aliases: aliases, operandSize: size, opcodeMap: map, mandatoryPrefix: pfx,
                                     opcode: op, modrmSlash: slash, rexW: w, operandFormat: format, rmConstraint: rm))
        }
        func vex(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, l: UInt8 = 0, w: Bool = false,
                 size: X86OperandSize? = nil, slash: UInt8? = nil, rm: X86RMConstraint = .any, commutable: Bool = false,
                 aliases: [String] = [], memMnemonic: String? = nil, _ format: X86OperandFormat) {
            list.append(X86InstrDesc(mnemonic: name, aliases: aliases, operandSize: size ?? (l == 1 ? .ymm256 : .xmm128),
                                     encodingKind: .vex, opcodeMap: map, mandatoryPrefix: pfx, opcode: op, modrmSlash: slash,
                                     rexW: w, vexL: l, operandFormat: format, rmConstraint: rm, commutable: commutable,
                                     memMnemonic: memMnemonic))
        }

        /// `op xmm/m, xmm` + `vop xmm/m, xmm, xmm` [+ `vop ymm/m, ymm, ymm`].
        func binary(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, legacy: Bool = true,
                    ymm: Bool = true, w: Bool = false, rm: X86RMConstraint = .any, commutable: Bool = false, ymmRm: X86RegClass = .ymm) {
            if legacy { sse(name, map, pfx, op, rm: rm, .rmToReg(rmClass: X, regClass: X)) }
            vex("v" + name, map, pfx, op, w: w, rm: rm, commutable: commutable, .vexRmVvvvReg(rmClass: X, vvvvClass: X, regClass: X))
            if ymm { vex("v" + name, map, pfx, op, l: 1, w: w, rm: rm, commutable: commutable, .vexRmVvvvReg(rmClass: ymmRm, vvvvClass: Y, regClass: Y)) }
        }
        /// `op xmm/m, xmm` + `vop xmm/m, xmm` [+ `vop ymm/m (or xmm/m), ymm (or xmm)`].
        func unary(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, legacy: Bool = true,
                   v128: Bool = true, ymm: Bool = true, w: Bool = false, rm: X86RMConstraint = .any,
                   ymmRm: X86RegClass = .ymm, ymmReg: X86RegClass = .ymm, memMnemonics: (String, String)? = nil) {
            if legacy { sse(name, map, pfx, op, rm: rm, .rmToReg(rmClass: X, regClass: X)) }
            if v128 { vex("v" + name, map, pfx, op, w: w, rm: rm, memMnemonic: memMnemonics?.0, .rmToReg(rmClass: X, regClass: X)) }
            if ymm { vex("v" + name, map, pfx, op, l: 1, w: w, rm: rm, memMnemonic: memMnemonics?.1, .rmToReg(rmClass: ymmRm, regClass: ymmReg)) }
        }
        /// `op $imm8, xmm/m, xmm` + `vop $imm8, xmm/m, xmm` [+ `vop $imm8, ymm/m, ymm`].
        func unaryImm(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, legacy: Bool = true,
                      v128: Bool = true, ymm: Bool = true, w: Bool = false) {
            if legacy { sse(name, map, pfx, op, .immRmToReg(rmClass: X, regClass: X, immSize: .byte)) }
            if v128 { vex("v" + name, map, pfx, op, w: w, .immRmToReg(rmClass: X, regClass: X, immSize: .byte)) }
            if ymm { vex("v" + name, map, pfx, op, l: 1, w: w, .immRmToReg(rmClass: Y, regClass: Y, immSize: .byte)) }
        }
        /// `op $imm8, xmm/m, xmm` + `vop $imm8, xmm/m, xmm, xmm` [+ `vop $imm8, ymm/m, ymm, ymm`].
        func binaryImm(_ name: String, _ map: X86OpcodeMap, _ pfx: X86MandatoryPrefix, _ op: UInt8, legacy: Bool = true,
                       v128: Bool = true, ymm: Bool = true, w: Bool = false, commutable: Bool = false, ymmRm: X86RegClass = .ymm) {
            if legacy { sse(name, map, pfx, op, .immRmToReg(rmClass: X, regClass: X, immSize: .byte)) }
            if v128 { vex("v" + name, map, pfx, op, w: w, commutable: commutable, .vexImmRmVvvvReg(rmClass: X, vvvvClass: X, regClass: X)) }
            if ymm { vex("v" + name, map, pfx, op, l: 1, w: w, commutable: commutable, .vexImmRmVvvvReg(rmClass: ymmRm, vvvvClass: Y, regClass: Y)) }
        }

        // Vector moves: load (r/m -> reg) is listed before store (reg -> r/m); for register-to-register
        // moves the encoder takes the store direction only to avoid a 3-byte VEX prefix.
        let vecMoves: [(name: String, prefix: X86MandatoryPrefix, loadOp: UInt8, storeOp: UInt8)] = [
            ("movaps", .none, 0x28, 0x29),
            ("movups", .none, 0x10, 0x11),
            ("movapd", .p66,  0x28, 0x29),
            ("movupd", .p66,  0x10, 0x11),
            ("movdqa", .p66,  0x6F, 0x7F),
            ("movdqu", .pF3,  0x6F, 0x7F)
        ]
        for vm in vecMoves {
            sse(vm.name, .map0F, vm.prefix, vm.loadOp, .rmToReg(rmClass: X, regClass: X))
            sse(vm.name, .map0F, vm.prefix, vm.storeOp, .regToRm(regClass: X, rmClass: X))
            vex("v" + vm.name, .map0F, vm.prefix, vm.loadOp, .rmToReg(rmClass: X, regClass: X))
            vex("v" + vm.name, .map0F, vm.prefix, vm.storeOp, .regToRm(regClass: X, rmClass: X))
            vex("v" + vm.name, .map0F, vm.prefix, vm.loadOp, l: 1, .rmToReg(rmClass: Y, regClass: Y))
            vex("v" + vm.name, .map0F, vm.prefix, vm.storeOp, l: 1, .regToRm(regClass: Y, rmClass: Y))
        }

        // Scalar FP moves: movss/vmovss, movsd/vmovsd. VEX register forms take three operands (merge into the
        // upper lanes of src1); VEX memory forms take two.
        for (scName, scPref) in [("movss", X86MandatoryPrefix.pF3), ("movsd", X86MandatoryPrefix.pF2)] {
            sse(scName, .map0F, scPref, 0x10, .rmToReg(rmClass: X, regClass: X))
            sse(scName, .map0F, scPref, 0x11, .regToRm(regClass: X, rmClass: X))
            vex("v" + scName, .map0F, scPref, 0x10, rm: .regOnly, .vexRmVvvvReg(rmClass: X, vvvvClass: X, regClass: X))
            vex("v" + scName, .map0F, scPref, 0x10, rm: .memOnly, .rmToReg(rmClass: X, regClass: X))
            vex("v" + scName, .map0F, scPref, 0x11, rm: .memOnly, .regToRm(regClass: X, rmClass: X))
            vex("v" + scName, .map0F, scPref, 0x11, rm: .regOnly, .vexRegVvvvToRm(regClass: X, vvvvClass: X, rmClass: X))
        }

        // MOVD / VMOVD and MOVQ / VMOVQ (GPR <-> XMM and XMM <-> XMM)
        sse("movd", .map0F, .p66, 0x6E, size: .dword, .rmToReg(rmClass: .gpr32, regClass: X))
        sse("movd", .map0F, .p66, 0x7E, size: .dword, .regToRm(regClass: X, rmClass: .gpr32))
        vex("vmovd", .map0F, .p66, 0x6E, size: .dword, .rmToReg(rmClass: .gpr32, regClass: X))
        vex("vmovd", .map0F, .p66, 0x7E, size: .dword, .regToRm(regClass: X, rmClass: .gpr32))
        sse("movq", .map0F, .p66, 0x6E, w: true, size: .qword, rm: .regOnly, aliases: ["mov"], .rmToReg(rmClass: .gpr64, regClass: X))
        sse("movq", .map0F, .p66, 0x7E, w: true, size: .qword, rm: .regOnly, aliases: ["mov"], .regToRm(regClass: X, rmClass: .gpr64))
        sse("movq", .map0F, .pF3, 0x7E, .rmToReg(rmClass: X, regClass: X))
        sse("movq", .map0F, .p66, 0xD6, .regToRm(regClass: X, rmClass: X))
        vex("vmovq", .map0F, .p66, 0x6E, w: true, size: .qword, rm: .regOnly, .rmToReg(rmClass: .gpr64, regClass: X))
        vex("vmovq", .map0F, .p66, 0x7E, w: true, size: .qword, rm: .regOnly, .regToRm(regClass: X, rmClass: .gpr64))
        vex("vmovq", .map0F, .pF3, 0x7E, .rmToReg(rmClass: X, regClass: X))
        vex("vmovq", .map0F, .p66, 0xD6, .regToRm(regClass: X, rmClass: X))

        // Half-register moves: movlps/movhps/movlpd/movhpd (memory only) and movhlps/movlhps (registers only)
        for (name, pfx, op) in [("movlps", X86MandatoryPrefix.none, UInt8(0x12)), ("movhps", .none, 0x16), ("movlpd", .p66, 0x12), ("movhpd", .p66, 0x16)] {
            sse(name, .map0F, pfx, op, rm: .memOnly, .rmToReg(rmClass: X, regClass: X))
            sse(name, .map0F, pfx, op + 1, rm: .memOnly, .regToRm(regClass: X, rmClass: X))
            vex("v" + name, .map0F, pfx, op, rm: .memOnly, .vexRmVvvvReg(rmClass: X, vvvvClass: X, regClass: X))
            vex("v" + name, .map0F, pfx, op + 1, rm: .memOnly, .regToRm(regClass: X, rmClass: X))
        }
        for (name, op) in [("movhlps", UInt8(0x12)), ("movlhps", 0x16)] {
            sse(name, .map0F, .none, op, rm: .regOnly, .rmToReg(rmClass: X, regClass: X))
            vex("v" + name, .map0F, .none, op, rm: .regOnly, .vexRmVvvvReg(rmClass: X, vvvvClass: X, regClass: X))
        }
        unary("movddup", .map0F, .pF2, 0x12)
        unary("movsldup", .map0F, .pF3, 0x12)
        unary("movshdup", .map0F, .pF3, 0x16)
        unary("lddqu", .map0F, .pF2, 0xF0, rm: .memOnly)
        unary("movntdqa", .map0F38, .p66, 0x2A, rm: .memOnly)
        // Non-temporal stores
        for (name, pfx, op) in [("movntps", X86MandatoryPrefix.none, UInt8(0x2B)), ("movntpd", .p66, 0x2B), ("movntdq", .p66, 0xE7)] {
            sse(name, .map0F, pfx, op, rm: .memOnly, .regToRm(regClass: X, rmClass: X))
            vex("v" + name, .map0F, pfx, op, rm: .memOnly, .regToRm(regClass: X, rmClass: X))
            vex("v" + name, .map0F, pfx, op, l: 1, rm: .memOnly, .regToRm(regClass: Y, rmClass: Y))
        }
        // Sign-mask extraction (registers only)
        for (name, pfx, op) in [("movmskps", X86MandatoryPrefix.none, UInt8(0x50)), ("movmskpd", .p66, 0x50), ("pmovmskb", .p66, 0xD7)] {
            sse(name, .map0F, pfx, op, size: .dword, rm: .regOnly, .rmToReg(rmClass: X, regClass: .gpr32))
            vex("v" + name, .map0F, pfx, op, size: .dword, rm: .regOnly, .rmToReg(rmClass: X, regClass: .gpr32))
            vex("v" + name, .map0F, pfx, op, l: 1, size: .dword, rm: .regOnly, .rmToReg(rmClass: Y, regClass: .gpr32))
        }
        sse("maskmovdqu", .map0F, .p66, 0xF7, rm: .regOnly, .rmToReg(rmClass: X, regClass: X))
        vex("vmaskmovdqu", .map0F, .p66, 0xF7, rm: .regOnly, .rmToReg(rmClass: X, regClass: X))
        // AVX masked loads (src1_vvvv = mask) and stores
        for (name, load, store, w) in [("vmaskmovps", UInt8(0x2C), UInt8(0x2E), false), ("vmaskmovpd", 0x2D, 0x2F, false),
                                       ("vpmaskmovd", 0x8C, 0x8E, false), ("vpmaskmovq", 0x8C, 0x8E, true)] {
            for (l, rc) in [(UInt8(0), X), (1, Y)] {
                vex(name, .map0F38, .p66, load, l: l, w: w, rm: .memOnly, .vexRmVvvvReg(rmClass: rc, vvvvClass: rc, regClass: rc))
                vex(name, .map0F38, .p66, store, l: l, w: w, rm: .memOnly, .vexRegVvvvToRm(regClass: rc, vvvvClass: rc, rmClass: rc))
            }
        }

        // Packed FP arithmetic and logic (`ps` no prefix, `pd` 0x66); commutable per LLVM MC.
        let packedFP: [(name: String, op: UInt8, commutable: Bool)] = [
            ("add", 0x58, true), ("mul", 0x59, true), ("sub", 0x5C, false), ("min", 0x5D, false),
            ("div", 0x5E, false), ("max", 0x5F, false), ("and", 0x54, true), ("andn", 0x55, false),
            ("or", 0x56, true), ("xor", 0x57, true), ("unpckl", 0x14, false), ("unpckh", 0x15, false)
        ]
        for fp in packedFP {
            binary(fp.name + "ps", .map0F, .none, fp.op, commutable: fp.commutable)
            binary(fp.name + "pd", .map0F, .p66, fp.op, commutable: fp.commutable)
        }
        for (name, pfx, op) in [("addsubps", X86MandatoryPrefix.pF2, UInt8(0xD0)), ("addsubpd", .p66, 0xD0),
                                ("haddps", .pF2, 0x7C), ("haddpd", .p66, 0x7C), ("hsubps", .pF2, 0x7D), ("hsubpd", .p66, 0x7D)] {
            binary(name, .map0F, pfx, op)
        }
        // Scalar FP arithmetic (SSE 2-operand, VEX 3-operand merging into src1)
        let scalarFP: [(name: String, op: UInt8)] = [
            ("add", 0x58), ("mul", 0x59), ("sub", 0x5C), ("min", 0x5D), ("div", 0x5E), ("max", 0x5F), ("sqrt", 0x51)
        ]
        for sc in scalarFP {
            binary(sc.name + "ss", .map0F, .pF3, sc.op, ymm: false)
            binary(sc.name + "sd", .map0F, .pF2, sc.op, ymm: false)
        }
        binary("rsqrtss", .map0F, .pF3, 0x52, ymm: false)
        binary("rcpss", .map0F, .pF3, 0x53, ymm: false)
        binary("cvtss2sd", .map0F, .pF3, 0x5A, ymm: false)
        binary("cvtsd2ss", .map0F, .pF2, 0x5A, ymm: false)
        // Packed FP unary
        unary("sqrtps", .map0F, .none, 0x51)
        unary("sqrtpd", .map0F, .p66, 0x51)
        unary("rsqrtps", .map0F, .none, 0x52)
        unary("rcpps", .map0F, .none, 0x53)
        // FP compares: `cmpps $pred` (pseudo-ops `cmpltps` etc. are expanded by the encoder), `(u)comiss`
        binaryImm("cmpps", .map0F, .none, 0xC2, commutable: true)
        binaryImm("cmppd", .map0F, .p66, 0xC2, commutable: true)
        binaryImm("cmpss", .map0F, .pF3, 0xC2, ymm: false)
        binaryImm("cmpsd", .map0F, .pF2, 0xC2, ymm: false)
        unary("ucomiss", .map0F, .none, 0x2E, ymm: false)
        unary("ucomisd", .map0F, .p66, 0x2E, ymm: false)
        unary("comiss", .map0F, .none, 0x2F, ymm: false)
        unary("comisd", .map0F, .p66, 0x2F, ymm: false)
        // FP shuffles, blends, rounding, dot products
        binaryImm("shufps", .map0F, .none, 0xC6)
        binaryImm("shufpd", .map0F, .p66, 0xC6)
        binaryImm("blendps", .map0F3A, .p66, 0x0C)
        binaryImm("blendpd", .map0F3A, .p66, 0x0D)
        unaryImm("roundps", .map0F3A, .p66, 0x08)
        unaryImm("roundpd", .map0F3A, .p66, 0x09)
        binaryImm("roundss", .map0F3A, .p66, 0x0A, ymm: false)
        binaryImm("roundsd", .map0F3A, .p66, 0x0B, ymm: false)
        binaryImm("dpps", .map0F3A, .p66, 0x40)
        binaryImm("dppd", .map0F3A, .p66, 0x41, ymm: false)
        binaryImm("insertps", .map0F3A, .p66, 0x21, ymm: false)
        sse("extractps", .map0F3A, .p66, 0x17, .immRegToRm(regClass: X, rmClass: .gpr32, immSize: .byte))
        vex("vextractps", .map0F3A, .p66, 0x17, .immRegToRm(regClass: X, rmClass: .gpr32, immSize: .byte))
        // Variable blends: SSE4.1 with implicit %xmm0, AVX with the selector in imm8[7:4]
        for (name, sseOp, vexOp) in [("blendvps", UInt8(0x14), UInt8(0x4A)), ("blendvpd", 0x15, 0x4B), ("pblendvb", 0x10, 0x4C)] {
            sse(name, .map0F38, .p66, sseOp, .xmm0RmToReg(rmClass: X, regClass: X))
            vex("v" + name, .map0F3A, .p66, vexOp, .vexIs4RmVvvvReg(rmClass: X, vvvvClass: X, regClass: X))
            vex("v" + name, .map0F3A, .p66, vexOp, l: 1, .vexIs4RmVvvvReg(rmClass: Y, vvvvClass: Y, regClass: Y))
        }

        // FP conversions
        unary("cvtdq2ps", .map0F, .none, 0x5B)
        unary("cvtps2dq", .map0F, .p66, 0x5B)
        unary("cvttps2dq", .map0F, .pF3, 0x5B)
        unary("cvtps2pd", .map0F, .none, 0x5A, ymmRm: X)
        unary("cvtdq2pd", .map0F, .pF3, 0xE6, ymmRm: X)
        unary("cvtpd2ps", .map0F, .p66, 0x5A, ymmReg: X, memMnemonics: ("vcvtpd2psx", "vcvtpd2psy"))
        unary("cvtpd2dq", .map0F, .pF2, 0xE6, ymmReg: X, memMnemonics: ("vcvtpd2dqx", "vcvtpd2dqy"))
        unary("cvttpd2dq", .map0F, .p66, 0xE6, ymmReg: X, memMnemonics: ("vcvttpd2dqx", "vcvttpd2dqy"))
        // CVTSI2SS / VCVTSI2SS, CVTSI2SD / VCVTSI2SD (32-bit and 64-bit GPR/mem)
        for (cvName, cvPref) in [("cvtsi2ss", X86MandatoryPrefix.pF3), ("cvtsi2sd", X86MandatoryPrefix.pF2)] {
            sse(cvName, .map0F, cvPref, 0x2A, size: .dword, aliases: [cvName + "l"], .rmToReg(rmClass: .gpr32, regClass: X))
            sse(cvName, .map0F, cvPref, 0x2A, w: true, size: .qword, aliases: [cvName + "q"], .rmToReg(rmClass: .gpr64, regClass: X))
            vex("v" + cvName, .map0F, cvPref, 0x2A, size: .dword, aliases: ["v" + cvName + "l"], .vexRmVvvvReg(rmClass: .gpr32, vvvvClass: X, regClass: X))
            vex("v" + cvName, .map0F, cvPref, 0x2A, w: true, size: .qword, aliases: ["v" + cvName + "q"], .vexRmVvvvReg(rmClass: .gpr64, vvvvClass: X, regClass: X))
        }
        // CVT(T)SS2SI / CVT(T)SD2SI (to 32-bit or 64-bit GPR)
        for (ctName, ctPref, op) in [("cvttss2si", X86MandatoryPrefix.pF3, UInt8(0x2C)), ("cvttsd2si", .pF2, 0x2C),
                                     ("cvtss2si", .pF3, 0x2D), ("cvtsd2si", .pF2, 0x2D)] {
            sse(ctName, .map0F, ctPref, op, size: .dword, aliases: [ctName + "l"], .rmToReg(rmClass: X, regClass: .gpr32))
            sse(ctName, .map0F, ctPref, op, w: true, size: .qword, aliases: [ctName + "q"], .rmToReg(rmClass: X, regClass: .gpr64))
            vex("v" + ctName, .map0F, ctPref, op, size: .dword, aliases: ["v" + ctName + "l"], .rmToReg(rmClass: X, regClass: .gpr32))
            vex("v" + ctName, .map0F, ctPref, op, w: true, size: .qword, aliases: ["v" + ctName + "q"], .rmToReg(rmClass: X, regClass: .gpr64))
        }
        // F16C: vcvtph2ps, vcvtps2ph
        vex("vcvtph2ps", .map0F38, .p66, 0x13, .rmToReg(rmClass: X, regClass: X))
        vex("vcvtph2ps", .map0F38, .p66, 0x13, l: 1, .rmToReg(rmClass: X, regClass: Y))
        vex("vcvtps2ph", .map0F3A, .p66, 0x1D, .immRegToRm(regClass: X, rmClass: X, immSize: .byte))
        vex("vcvtps2ph", .map0F3A, .p66, 0x1D, l: 1, .immRegToRm(regClass: Y, rmClass: X, immSize: .byte))

        // Packed integer arithmetic, logic, compares, packs and unpacks (66 0F / 66 0F 38)
        let packedInt: [(name: String, map: X86OpcodeMap, op: UInt8, commutable: Bool)] = [
            ("punpcklbw", .map0F, 0x60, false), ("punpcklwd", .map0F, 0x61, false), ("punpckldq", .map0F, 0x62, false),
            ("packsswb", .map0F, 0x63, false), ("pcmpgtb", .map0F, 0x64, false), ("pcmpgtw", .map0F, 0x65, false),
            ("pcmpgtd", .map0F, 0x66, false), ("packuswb", .map0F, 0x67, false), ("punpckhbw", .map0F, 0x68, false),
            ("punpckhwd", .map0F, 0x69, false), ("punpckhdq", .map0F, 0x6A, false), ("packssdw", .map0F, 0x6B, false),
            ("punpcklqdq", .map0F, 0x6C, false), ("punpckhqdq", .map0F, 0x6D, false),
            ("pcmpeqb", .map0F, 0x74, true), ("pcmpeqw", .map0F, 0x75, true), ("pcmpeqd", .map0F, 0x76, true),
            ("paddq", .map0F, 0xD4, true), ("pmullw", .map0F, 0xD5, true), ("psubusb", .map0F, 0xD8, false),
            ("psubusw", .map0F, 0xD9, false), ("pminub", .map0F, 0xDA, true), ("pand", .map0F, 0xDB, true),
            ("paddusb", .map0F, 0xDC, true), ("paddusw", .map0F, 0xDD, true), ("pmaxub", .map0F, 0xDE, true),
            ("pandn", .map0F, 0xDF, false), ("pavgb", .map0F, 0xE0, true), ("pavgw", .map0F, 0xE3, true),
            ("pmulhuw", .map0F, 0xE4, true), ("pmulhw", .map0F, 0xE5, true), ("psubsb", .map0F, 0xE8, false),
            ("psubsw", .map0F, 0xE9, false), ("pminsw", .map0F, 0xEA, true), ("por", .map0F, 0xEB, true),
            ("paddsb", .map0F, 0xEC, true), ("paddsw", .map0F, 0xED, true), ("pmaxsw", .map0F, 0xEE, true),
            ("pxor", .map0F, 0xEF, true), ("pmuludq", .map0F, 0xF4, true), ("pmaddwd", .map0F, 0xF5, true),
            ("psadbw", .map0F, 0xF6, true), ("psubb", .map0F, 0xF8, false), ("psubw", .map0F, 0xF9, false),
            ("psubd", .map0F, 0xFA, false), ("psubq", .map0F, 0xFB, false), ("paddb", .map0F, 0xFC, true),
            ("paddw", .map0F, 0xFD, true), ("paddd", .map0F, 0xFE, true),
            ("pshufb", .map0F38, 0x00, false), ("phaddw", .map0F38, 0x01, false), ("phaddd", .map0F38, 0x02, false),
            ("phaddsw", .map0F38, 0x03, false), ("pmaddubsw", .map0F38, 0x04, false), ("phsubw", .map0F38, 0x05, false),
            ("phsubd", .map0F38, 0x06, false), ("phsubsw", .map0F38, 0x07, false), ("psignb", .map0F38, 0x08, false),
            ("psignw", .map0F38, 0x09, false), ("psignd", .map0F38, 0x0A, false), ("pmulhrsw", .map0F38, 0x0B, false),
            ("pmuldq", .map0F38, 0x28, false), ("pcmpeqq", .map0F38, 0x29, false), ("packusdw", .map0F38, 0x2B, false),
            ("pcmpgtq", .map0F38, 0x37, false), ("pminsb", .map0F38, 0x38, false), ("pminsd", .map0F38, 0x39, false),
            ("pminuw", .map0F38, 0x3A, false), ("pminud", .map0F38, 0x3B, false), ("pmaxsb", .map0F38, 0x3C, false),
            ("pmaxsd", .map0F38, 0x3D, false), ("pmaxuw", .map0F38, 0x3E, false), ("pmaxud", .map0F38, 0x3F, false),
            ("pmulld", .map0F38, 0x40, false)
        ]
        for pi in packedInt {
            binary(pi.name, pi.map, .p66, pi.op, commutable: pi.commutable)
        }
        // Shifts by an xmm count (the VEX.256 forms still take the count in an xmm register)
        for (name, op) in [("psrlw", UInt8(0xD1)), ("psrld", 0xD2), ("psrlq", 0xD3), ("psraw", 0xE1), ("psrad", 0xE2),
                           ("psllw", 0xF1), ("pslld", 0xF2), ("psllq", 0xF3)] {
            binary(name, .map0F, .p66, op, ymmRm: X)
        }
        // Shifts by an immediate (66 0F 71..73 /digit ib; the VEX destination is in vvvv)
        for (name, op, slash) in [("psrlw", UInt8(0x71), UInt8(2)), ("psraw", 0x71, 4), ("psllw", 0x71, 6),
                                  ("psrld", 0x72, 2), ("psrad", 0x72, 4), ("pslld", 0x72, 6),
                                  ("psrlq", 0x73, 2), ("psrldq", 0x73, 3), ("psllq", 0x73, 6), ("pslldq", 0x73, 7)] {
            sse(name, .map0F, .p66, op, slash: slash, rm: .regOnly, .immToRm(rmClass: X, immSize: .byte))
            vex("v" + name, .map0F, .p66, op, slash: slash, rm: .regOnly, .vexImmRmToVvvv(rmClass: X, vvvvClass: X))
            vex("v" + name, .map0F, .p66, op, l: 1, slash: slash, rm: .regOnly, .vexImmRmToVvvv(rmClass: Y, vvvvClass: Y))
        }
        // AVX2 per-element variable shifts
        for (name, op, w) in [("psrlvd", UInt8(0x45), false), ("psrlvq", 0x45, true), ("psravd", 0x46, false),
                              ("psllvd", 0x47, false), ("psllvq", 0x47, true)] {
            binary(name, .map0F38, .p66, op, legacy: false, w: w)
        }
        // Packed integer unary: absolute value, sign/zero extension, test, horizontal minimum
        for (name, op) in [("pabsb", UInt8(0x1C)), ("pabsw", 0x1D), ("pabsd", 0x1E)] {
            unary(name, .map0F38, .p66, op)
        }
        for (name, op) in [("pmovsxbw", UInt8(0x20)), ("pmovsxbd", 0x21), ("pmovsxbq", 0x22), ("pmovsxwd", 0x23),
                           ("pmovsxwq", 0x24), ("pmovsxdq", 0x25), ("pmovzxbw", 0x30), ("pmovzxbd", 0x31),
                           ("pmovzxbq", 0x32), ("pmovzxwd", 0x33), ("pmovzxwq", 0x34), ("pmovzxdq", 0x35)] {
            unary(name, .map0F38, .p66, op, ymmRm: X)
        }
        unary("ptest", .map0F38, .p66, 0x17)
        unary("testps", .map0F38, .p66, 0x0E, legacy: false)
        unary("testpd", .map0F38, .p66, 0x0F, legacy: false)
        unary("phminposuw", .map0F38, .p66, 0x41, ymm: false)
        // Integer shuffles, aligns, blends
        unaryImm("pshufd", .map0F, .p66, 0x70)
        unaryImm("pshufhw", .map0F, .pF3, 0x70)
        unaryImm("pshuflw", .map0F, .pF2, 0x70)
        binaryImm("palignr", .map0F3A, .p66, 0x0F)
        binaryImm("pblendw", .map0F3A, .p66, 0x0E)
        binaryImm("mpsadbw", .map0F3A, .p66, 0x42)
        binaryImm("pblendd", .map0F3A, .p66, 0x02, legacy: false)
        // SSE4.2 string compares
        for (name, op) in [("pcmpestrm", UInt8(0x60)), ("pcmpestri", 0x61), ("pcmpistrm", 0x62), ("pcmpistri", 0x63)] {
            unaryImm(name, .map0F3A, .p66, op, ymm: false)
        }
        // Element insert / extract
        for (name, op, rc, w) in [("pextrb", UInt8(0x14), X86RegClass.gpr32, false), ("pextrd", 0x16, .gpr32, false), ("pextrq", 0x16, .gpr64, true)] {
            sse(name, .map0F3A, .p66, op, w: w, .immRegToRm(regClass: X, rmClass: rc, immSize: .byte))
            vex("v" + name, .map0F3A, .p66, op, w: w, .immRegToRm(regClass: X, rmClass: rc, immSize: .byte))
        }
        sse("pextrw", .map0F, .p66, 0xC5, rm: .regOnly, .immRmToReg(rmClass: X, regClass: .gpr32, immSize: .byte))
        sse("pextrw", .map0F3A, .p66, 0x15, rm: .memOnly, .immRegToRm(regClass: X, rmClass: .gpr32, immSize: .byte))
        vex("vpextrw", .map0F, .p66, 0xC5, rm: .regOnly, .immRmToReg(rmClass: X, regClass: .gpr32, immSize: .byte))
        vex("vpextrw", .map0F3A, .p66, 0x15, rm: .memOnly, .immRegToRm(regClass: X, rmClass: .gpr32, immSize: .byte))
        for (name, map, op, rc, w) in [("pinsrb", X86OpcodeMap.map0F3A, UInt8(0x20), X86RegClass.gpr32, false), ("pinsrw", .map0F, 0xC4, .gpr32, false),
                                       ("pinsrd", .map0F3A, 0x22, .gpr32, false), ("pinsrq", .map0F3A, 0x22, .gpr64, true)] {
            sse(name, map, .p66, op, w: w, .immRmToReg(rmClass: rc, regClass: X, immSize: .byte))
            vex("v" + name, map, .p66, op, w: w, .vexImmRmVvvvReg(rmClass: rc, vvvvClass: X, regClass: X))
        }

        // AVX / AVX2 lane and element permutes, broadcasts, 128-bit lane insert/extract
        vex("vbroadcastss", .map0F38, .p66, 0x18, .rmToReg(rmClass: X, regClass: X))
        vex("vbroadcastss", .map0F38, .p66, 0x18, l: 1, .rmToReg(rmClass: X, regClass: Y))
        vex("vbroadcastsd", .map0F38, .p66, 0x19, l: 1, .rmToReg(rmClass: X, regClass: Y))
        vex("vbroadcastf128", .map0F38, .p66, 0x1A, l: 1, rm: .memOnly, .rmToReg(rmClass: X, regClass: Y))
        vex("vbroadcasti128", .map0F38, .p66, 0x5A, l: 1, rm: .memOnly, .rmToReg(rmClass: X, regClass: Y))
        for (name, op) in [("vpbroadcastb", UInt8(0x78)), ("vpbroadcastw", 0x79), ("vpbroadcastd", 0x58), ("vpbroadcastq", 0x59)] {
            vex(name, .map0F38, .p66, op, .rmToReg(rmClass: X, regClass: X))
            vex(name, .map0F38, .p66, op, l: 1, .rmToReg(rmClass: X, regClass: Y))
        }
        for (name, op) in [("vinsertf128", UInt8(0x18)), ("vinserti128", 0x38)] {
            vex(name, .map0F3A, .p66, op, l: 1, .vexImmRmVvvvReg(rmClass: X, vvvvClass: Y, regClass: Y))
        }
        for (name, op) in [("vextractf128", UInt8(0x19)), ("vextracti128", 0x39)] {
            vex(name, .map0F3A, .p66, op, l: 1, .immRegToRm(regClass: Y, rmClass: X, immSize: .byte))
        }
        for (name, op) in [("vperm2f128", UInt8(0x06)), ("vperm2i128", 0x46)] {
            vex(name, .map0F3A, .p66, op, l: 1, .vexImmRmVvvvReg(rmClass: Y, vvvvClass: Y, regClass: Y))
        }
        vex("vpermq", .map0F3A, .p66, 0x00, l: 1, w: true, .immRmToReg(rmClass: Y, regClass: Y, immSize: .byte))
        vex("vpermpd", .map0F3A, .p66, 0x01, l: 1, w: true, .immRmToReg(rmClass: Y, regClass: Y, immSize: .byte))
        vex("vpermd", .map0F38, .p66, 0x36, l: 1, .vexRmVvvvReg(rmClass: Y, vvvvClass: Y, regClass: Y))
        vex("vpermps", .map0F38, .p66, 0x16, l: 1, .vexRmVvvvReg(rmClass: Y, vvvvClass: Y, regClass: Y))
        binary("permilps", .map0F38, .p66, 0x0C, legacy: false)
        binary("permilpd", .map0F38, .p66, 0x0D, legacy: false)
        unaryImm("permilps", .map0F3A, .p66, 0x04, legacy: false)
        unaryImm("permilpd", .map0F3A, .p66, 0x05, legacy: false)

        // AVX2 gathers: `mask_vvvv, vsib, dst`. Index width follows d/q; data width follows ps/pd (dd/dq).
        let gathers: [(name: String, op: UInt8, w: Bool, qIndex: Bool)] = [
            ("vgatherdps", 0x92, false, false), ("vgatherdpd", 0x92, true, false),
            ("vgatherqps", 0x93, false, true), ("vgatherqpd", 0x93, true, true),
            ("vpgatherdd", 0x90, false, false), ("vpgatherdq", 0x90, true, false),
            ("vpgatherqd", 0x91, false, true), ("vpgatherqq", 0x91, true, true)
        ]
        for g in gathers {
            vex(g.name, .map0F38, .p66, g.op, w: g.w, .vexVsib(vvvvClass: X, indexClass: X, regClass: X))
            // 256-bit: 32-bit data with 64-bit indices only fills an xmm; 64-bit data with 32-bit indices reads an xmm of indices.
            let dataClass: X86RegClass = (g.qIndex && !g.w) ? X : Y
            let indexClass: X86RegClass = (!g.qIndex && g.w) ? X : Y
            vex(g.name, .map0F38, .p66, g.op, l: 1, w: g.w, .vexVsib(vvvvClass: dataClass, indexClass: indexClass, regClass: dataClass))
        }

        // FMA3: 132/213/231 operand orders; packed `ps`/`pd` (W0/W1) and scalar `ss`/`sd`
        let fmaOps: [(name: String, base: UInt8, scalar: Bool)] = [
            ("vfmaddsub", 0x96, false), ("vfmsubadd", 0x97, false), ("vfmadd", 0x98, true),
            ("vfmsub", 0x9A, true), ("vfnmadd", 0x9C, true), ("vfnmsub", 0x9E, true)
        ]
        for fma in fmaOps {
            for (order, delta) in [("132", UInt8(0x00)), ("213", 0x10), ("231", 0x20)] {
                for (t, w) in [("ps", false), ("pd", true)] {
                    binary(String((fma.name + order + t).dropFirst()), .map0F38, .p66, fma.base + delta, legacy: false, w: w)
                }
                if fma.scalar {
                    for (t, w) in [("ss", false), ("sd", true)] {
                        binary(String((fma.name + order + t).dropFirst()), .map0F38, .p66, fma.base + delta + 1, legacy: false, ymm: false, w: w)
                    }
                }
            }
        }

        // VZEROUPPER, VZEROALL
        vex("vzeroupper", .map0F, .none, 0x77, size: .unsized, .implied)
        vex("vzeroall", .map0F, .none, 0x77, l: 1, size: .unsized, .implied)

        // AES-NI, PCLMULQDQ (SSE and VEX.128)
        for (name, op) in [("aesenc", UInt8(0xDC)), ("aesenclast", 0xDD), ("aesdec", 0xDE), ("aesdeclast", 0xDF)] {
            binary(name, .map0F38, .p66, op, ymm: false)
        }
        unary("aesimc", .map0F38, .p66, 0xDB, ymm: false)
        unaryImm("aeskeygenassist", .map0F3A, .p66, 0xDF, ymm: false)
        binaryImm("pclmulqdq", .map0F3A, .p66, 0x44, ymm: false)

        // SHA (legacy encoding only)
        sse("sha1rnds4", .map0F3A, .none, 0xCC, .immRmToReg(rmClass: X, regClass: X, immSize: .byte))
        for (name, op) in [("sha1nexte", UInt8(0xC8)), ("sha1msg1", 0xC9), ("sha1msg2", 0xCA), ("sha256msg1", 0xCC), ("sha256msg2", 0xCD)] {
            sse(name, .map0F38, .none, op, .rmToReg(rmClass: X, regClass: X))
        }
        sse("sha256rnds2", .map0F38, .none, 0xCB, .xmm0RmToReg(rmClass: X, regClass: X))

        return list
    }
}

// MARK: - 5. Table-Driven x86-64 Encoder (X86TableEncoder)

/// Encodes structured `X86Instruction` values into machine code bytes and relocations using `X86InstructionTable`.
public struct X86TableEncoder: Sendable {

    public init() {}

    /// Encodes a single `X86Instruction`.
    public func encode(_ instruction: X86Instruction) throws -> X86EncodedInstruction {
        try encodeWithDescriptor(instruction).encoded
    }

    /// Encodes `instruction` and also returns the index of the `X86InstructionTable.descriptors` entry
    /// that produced the bytes (used by the exhaustive table sweep to account for coverage).
    public func encodeWithDescriptor(_ instruction: X86Instruction) throws -> (encoded: X86EncodedInstruction, descriptorIndex: Int) {
        try encodeSelecting(Self.normalized(instruction))
    }

    /// Splits inline prefixes out of the mnemonic and expands assembler shorthands into table forms.
    private static func normalized(_ instruction: X86Instruction) -> X86Instruction {
        var inst = instruction
        // Extract inline "rep ", "repne ", "lock " prefixes if passed in mnemonic string
        while true {
            if inst.mnemonic.hasPrefix("lock ") {
                inst.lockPrefix = true
                inst.mnemonic = String(inst.mnemonic.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if inst.mnemonic.hasPrefix("rep ") || inst.mnemonic.hasPrefix("repe ") || inst.mnemonic.hasPrefix("repz ") {
                inst.repPrefix = .rep
                let dropCount = inst.mnemonic.hasPrefix("rep ") ? 4 : 5
                inst.mnemonic = String(inst.mnemonic.dropFirst(dropCount)).trimmingCharacters(in: .whitespaces)
            } else if inst.mnemonic.hasPrefix("repne ") || inst.mnemonic.hasPrefix("repnz ") {
                inst.repPrefix = .repne
                inst.mnemonic = String(inst.mnemonic.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }

        // Normalize 2-operand `imul $imm, %reg` -> 3-operand `imul $imm, %reg, %reg`
        if (inst.mnemonic == "imul" || inst.mnemonic == "imulw" || inst.mnemonic == "imull" || inst.mnemonic == "imulq"),
           inst.operands.count == 2,
           case .imm = inst.operands[0],
           case .reg(let dstReg) = inst.operands[1] {
            inst.operands = [inst.operands[0], .reg(dstReg), .reg(dstReg)]
        }

        // Expand SSE/AVX compare-predicate pseudo-ops (`cmpltps`, `vcmpeq_uqpd`) into `$imm8` form
        expandComparePredicate(&inst)
        return inst
    }

    /// Tries candidate descriptors in table order and returns the first encoding. A VEX encoding that needs
    /// the 3-byte prefix only because an extended register sits in `r/m` is replaced by an equivalent 2-byte
    /// form where one exists: the register-to-`r/m` "store" direction of a register move, or swapped sources
    /// of a commutable instruction. This is LLVM MC's `optimizeInstFromVEX3ToVEX2`; GNU `as` only does
    /// the move half without `-O2` (05-assembler.md §4.11).
    private func encodeSelecting(_ inst: X86Instruction) throws -> (encoded: X86EncodedInstruction, descriptorIndex: Int) {
        let (candidates, explicitSize) = try resolveCandidates(for: inst)
        for (pos, descIdx) in candidates.enumerated() {
            let desc = X86InstructionTable.descriptors[descIdx]
            guard let encoded = try tryEncode(inst: inst, desc: desc, explicitSize: explicitSize) else { continue }
            guard desc.encodingKind == .vex, Self.isAvoidableVex3(encoded, desc: desc) else { return (encoded, descIdx) }
            if desc.commutable, let swapped = Self.commuted(inst, desc: desc),
               let alt = try tryEncode(inst: swapped, desc: desc, explicitSize: explicitSize),
               alt.bytes.count < encoded.bytes.count {
                return (alt, descIdx)
            }
            for altIdx in candidates[(pos + 1)...] where X86InstructionTable.descriptors[altIdx].encodingKind == .vex {
                if let alt = try tryEncode(inst: inst, desc: X86InstructionTable.descriptors[altIdx], explicitSize: explicitSize),
                   alt.bytes.count < encoded.bytes.count {
                    return (alt, altIdx)
                }
            }
            return (encoded, descIdx)
        }
        throw X86CodecError.invalidOperands(mnemonic: inst.mnemonic, operands: inst.operands)
    }

    /// True for a 3-byte VEX encoding of a map-0F, W0 instruction whose only reason for the 3-byte form is
    /// VEX.B (an extended register in `r/m`); VEX.R is also available in the 2-byte form.
    private static func isAvoidableVex3(_ encoded: X86EncodedInstruction, desc: X86InstrDesc) -> Bool {
        guard desc.opcodeMap == .map0F, !desc.rexW else { return false }
        let bytes = encoded.bytes
        guard let c4 = bytes.firstIndex(of: 0xC4), c4 + 1 < bytes.count else { return false }
        let b1 = bytes[c4 + 1]
        let x = (b1 & 0x40) == 0, b = (b1 & 0x20) == 0
        return b && !x
    }

    /// The instruction with its two VEX sources swapped, if `desc` allows it for these operands.
    private static func commuted(_ inst: X86Instruction, desc: X86InstrDesc) -> X86Instruction? {
        var ops = inst.operands
        switch desc.operandFormat {
        case .vexRmVvvvReg:
            guard ops.count == 3 else { return nil }
            guard case .reg = ops[0], case .reg(let v) = ops[1], !v.needsRexExtension else { return nil }
            ops.swapAt(0, 1)
        case .vexImmRmVvvvReg:
            // `vcmpps`: only the symmetric predicates (EQ, UNORD, NEQ, ORD and their variants) commute.
            guard ops.count == 4, case .imm(let pred, nil) = ops[0], [0, 3, 4, 7].contains(pred & 7) else { return nil }
            guard case .reg = ops[1], case .reg(let v) = ops[2], !v.needsRexExtension else { return nil }
            ops.swapAt(1, 2)
        default:
            return nil
        }
        var out = inst
        out.operands = ops
        return out
    }

    /// Compare predicates of `cmpps` & co. (`0..7` for SSE, `0..31` for AVX).
    private static let comparePredicates: [String: Int64] = {
        let names = ["eq", "lt", "le", "unord", "neq", "nlt", "nle", "ord",
                     "eq_uq", "nge", "ngt", "false", "neq_oq", "ge", "gt", "true",
                     "eq_os", "lt_oq", "le_oq", "unord_s", "neq_us", "nlt_uq", "nle_uq", "ord_s",
                     "eq_us", "nge_uq", "ngt_uq", "false_os", "neq_os", "ge_oq", "gt_oq", "true_us"]
        var map: [String: Int64] = [:]
        for (i, n) in names.enumerated() { map[n] = Int64(i) }
        // Explicit spellings of the default ordered/signaling variants of predicates 0-7.
        for (i, n) in ["eq_oq", "lt_os", "le_os", "unord_q", "neq_uq", "nlt_us", "nle_us", "ord_q"].enumerated() { map[n] = Int64(i) }
        return map
    }()

    /// Rewrites `cmp<pred>{ps,pd,ss,sd}` / `vcmp<pred>…` into `cmp…` with an explicit `$imm8` predicate.
    private static func expandComparePredicate(_ inst: inout X86Instruction) {
        let m = inst.mnemonic
        let isVex = m.hasPrefix("vcmp")
        guard isVex || m.hasPrefix("cmp"), m.count > 5 else { return }
        let typeSuffix = String(m.suffix(2))
        guard typeSuffix == "ps" || typeSuffix == "pd" || typeSuffix == "ss" || typeSuffix == "sd" else { return }
        let predName = String(m.dropFirst(isVex ? 4 : 3).dropLast(2))
        guard !predName.isEmpty, let pred = comparePredicates[predName], isVex || pred < 8 else { return }
        if inst.operands.first.map({ if case .imm = $0 { return true } else { return false } }) == true { return }
        inst.mnemonic = (isVex ? "vcmp" : "cmp") + typeSuffix
        inst.operands.insert(.imm(pred), at: 0)
    }

    private func resolveCandidates(for inst: X86Instruction) throws -> ([Int], X86OperandSize) {
        let mnem = inst.mnemonic
        let explicitSize = inst.sizeSuffix

        // Check if mnemonic ends with b/w/l/q size suffix when base mnemonic is in table
        if explicitSize == .unsized, mnem.count > 1, let lastChar = mnem.last, let suffixSize = X86OperandSize(attSuffix: lastChar) {
            let base = String(mnem.dropLast())
            // Only treat as size suffix if `base` has entries that take `suffixSize` and `mnem` is not a standalone SIMD/system op
            if let baseIndices = X86InstructionTable.mnemonicMap[base] {
                let matchingBase = baseIndices.filter { idx in
                    let d = X86InstructionTable.descriptors[idx]
                    return d.operandSize == suffixSize && (d.mnemonic == base || d.aliases.contains(base))
                }
                if !matchingBase.isEmpty {
                    // Also include any direct entries for `mnem` (e.g. `movslq`, `sysretq`, `iretq`, `lgdtl`).
                    // Candidates stay in table order, which is the encoding preference order.
                    if let direct = X86InstructionTable.mnemonicMap[mnem] {
                        var combined = Set(matchingBase)
                        for dIdx in direct {
                            let d = X86InstructionTable.descriptors[dIdx]
                            if d.operandSize == suffixSize || d.operandSize == .unsized || d.mnemonic == mnem {
                                combined.insert(dIdx)
                            }
                        }
                        return (combined.sorted(), suffixSize)
                    }
                    return (matchingBase, suffixSize)
                }
            }
        }

        if let indices = X86InstructionTable.mnemonicMap[mnem] {
            return (indices, explicitSize)
        }

        throw X86CodecError.unknownMnemonic(mnem)
    }

    private func tryEncode(
        inst: X86Instruction,
        desc: X86InstrDesc,
        explicitSize: X86OperandSize
    ) throws -> X86EncodedInstruction? {
        if explicitSize != .unsized && desc.operandSize != .unsized && desc.operandSize != explicitSize {
            // A size implied by a mnemonic's last letter (`movq`, `crc32b`) does not exclude a descriptor
            // spelled exactly that way (`movq %xmm0, %xmm1`); an explicit `sizeSuffix` always does.
            if inst.sizeSuffix != .unsized || (desc.mnemonic != inst.mnemonic && !desc.aliases.contains(inst.mnemonic)) {
                return nil
            }
        }

        let ops = inst.operands
        let mode = inst.codeMode

        // `vcvtpd2ps (%rax), %xmm0` is ambiguous (128- or 256-bit source): memory needs `vcvtpd2psx`/`…y`.
        if desc.memMnemonic != nil && inst.mnemonic == desc.mnemonic && ops.contains(where: \.isMemory) {
            return nil
        }

        var rexW = desc.rexW
        var rexR = false
        var rexX = false
        var rexB = false
        var needsMandatoryRex = false
        var vexVvvv: UInt8 = 0

        var opcodeByte = desc.opcode
        var hasModRM = false
        var modrmByte: UInt8 = 0
        var sibByte: UInt8? = nil
        var dispBytes: [UInt8] = []
        var dispReloc: (kind: X86RelocKind, symbol: String, addend: Int64)? = nil

        var immBytes: [UInt8] = []
        var immReloc: (kind: X86RelocKind, symbol: String, addend: Int64)? = nil

        var segmentOverride: UInt8? = nil
        var addressSizeOverride = false

        // Helper to match a register against an expected class
        func matchReg(_ reg: X86Reg, expected: X86RegClass) -> Bool {
            if reg.regClass == expected { return true }
            if expected == .gpr8 && reg.regClass == .gpr8High { return true }
            return false
        }

        // Helper to encode an r/m operand into ModR/M + SIB + disp
        func encodeRM(
            _ operand: X86Operand,
            regField: UInt8,
            expectedClass: X86RegClass?,
            rmKind: X86RMKind = .gprOrMem,
            vsibIndex: X86RegClass? = nil
        ) throws -> Bool {
            if case .reg = operand, desc.rmConstraint == .memOnly { return false }
            if case .mem = operand, desc.rmConstraint == .regOnly { return false }
            if let vsib = vsibIndex {
                guard case .mem(let m) = operand, let idx = m.index, idx.regClass == vsib, m.base != .rip else { return false }
                return try encodeMemory(m, regField: regField, vsib: true)
            }
            switch operand {
            case .reg(let r):
                guard rmKind == .gprOrMem || rmKind == .gprOnly else { return false }
                if let exp = expectedClass, !matchReg(r, expected: exp) { return false }
                hasModRM = true
                modrmByte = (0x03 << 6) | ((regField & 0x07) << 3) | r.low3
                if r.needsRexExtension { rexB = true }
                if r.requiresRexByte { needsMandatoryRex = true }
                return true

            case .indirectReg(let r):
                guard rmKind == .indirectRegOrMem else { return false }
                if let exp = expectedClass, !matchReg(r, expected: exp) { return false }
                hasModRM = true
                modrmByte = (0x03 << 6) | ((regField & 0x07) << 3) | r.low3
                if r.needsRexExtension { rexB = true }
                if r.requiresRexByte { needsMandatoryRex = true }
                return true

            case .mem(let m):
                guard rmKind == .gprOrMem || rmKind == .memOnly else { return false }
                return try encodeMemory(m, regField: regField)

            case .indirectMem(let m):
                guard rmKind == .indirectRegOrMem || rmKind == .indirectMemOnly else { return false }
                return try encodeMemory(m, regField: regField)

            default:
                return false
            }
        }

        func encodeMemory(_ m: X86Mem, regField: UInt8, vsib: Bool = false) throws -> Bool {
            hasModRM = true
            if let seg = m.segment {
                segmentOverride = seg
            }

            // Check address size override
            if let base = m.base, base != .rip {
                guard base.isGPR else { return false }
                if mode == .mode64 && base.regClass == .gpr32 {
                    addressSizeOverride = true
                } else if mode == .mode16 && base.regClass == .gpr32 {
                    addressSizeOverride = true
                }
            }
            if let index = m.index, !vsib {
                guard index.isGPR else { return false }
                if index.low3 == 4 && !index.needsRexExtension {
                    // %rsp / %esp cannot be an index register in SIB
                    throw X86CodecError.invalidMemoryAddressing(m)
                }
                if mode == .mode64 && index.regClass == .gpr32 {
                    addressSizeOverride = true
                } else if mode == .mode16 && index.regClass == .gpr32 {
                    addressSizeOverride = true
                }
            }

            // 1. RIP-relative addressing: sym(%rip) or disp(%rip)
            if m.base == .rip {
                guard m.index == nil else { throw X86CodecError.invalidMemoryAddressing(m) }
                modrmByte = (0x00 << 6) | ((regField & 0x07) << 3) | 0x05
                let val: Int32 = m.symbol != nil ? 0 : Int32(truncatingIfNeeded: m.disp)
                appendInt32(val, to: &dispBytes)
                if let sym = m.symbol {
                    dispReloc = (.pc32, sym, m.disp)
                }
                return true
            }

            // 2. 16-bit addressing mode without 32-bit base/index
            if mode == .mode16 && !addressSizeOverride && !m.forceDisp32 {
                if m.base == nil && m.index == nil {
                    modrmByte = (0x00 << 6) | ((regField & 0x07) << 3) | 0x06
                    let val: Int16 = m.symbol != nil ? 0 : Int16(truncatingIfNeeded: m.disp)
                    appendInt16(val, to: &dispBytes)
                    if let sym = m.symbol {
                        dispReloc = (.abs16, sym, m.disp)
                    }
                    return true
                }
            }

            // 3. No base register: absolute address `disp` or scaled index `(, %index, scale)`
            if m.base == nil {
                if mode == .mode32 && m.index == nil {
                    // In 32-bit mode, mod=0, rm=5 is direct disp32 without SIB
                    modrmByte = (0x00 << 6) | ((regField & 0x07) << 3) | 0x05
                } else {
                    // In 64-bit mode (or whenever index is present), use SIB with base=5 and mod=0
                    modrmByte = (0x00 << 6) | ((regField & 0x07) << 3) | 0x04
                    let scaleBits = try encodeScale(m.scale, mem: m)
                    let idxBits: UInt8
                    if let idx = m.index {
                        idxBits = idx.low3
                        if idx.needsRexExtension { rexX = true }
                    } else {
                        idxBits = 0x04 // no index
                    }
                    sibByte = (scaleBits << 6) | (idxBits << 3) | 0x05
                }
                let val: Int32 = m.symbol != nil ? 0 : Int32(truncatingIfNeeded: m.disp)
                appendInt32(val, to: &dispBytes)
                if let sym = m.symbol {
                    let relKind: X86RelocKind = (m.segment == 0x64) ? .tpoff32 : .abs32s
                    dispReloc = (relKind, sym, m.disp)
                }
                return true
            }

            // 4. General base register (with optional index)
            let base = m.base!
            if base.needsRexExtension { rexB = true }

            let mod: UInt8
            if m.symbol != nil || m.forceDisp32 {
                mod = 2
            } else if m.disp == 0 && base.low3 != 5 {
                mod = 0
            } else if m.disp >= -128 && m.disp <= 127 {
                mod = 1
            } else {
                mod = 2
            }

            let needsSIB = (m.index != nil) || (base.low3 == 4)
            if needsSIB {
                modrmByte = (mod << 6) | ((regField & 0x07) << 3) | 0x04
                if let idx = m.index {
                    if idx.needsRexExtension { rexX = true }
                    let scaleBits = try encodeScale(m.scale, mem: m)
                    sibByte = (scaleBits << 6) | (idx.low3 << 3) | base.low3
                } else {
                    // %rsp / %r12 base with no index -> SIB 0x24
                    sibByte = (0x00 << 6) | (0x04 << 3) | base.low3
                }
            } else {
                modrmByte = (mod << 6) | ((regField & 0x07) << 3) | base.low3
            }

            if mod == 1 {
                dispBytes.append(UInt8(bitPattern: Int8(truncatingIfNeeded: m.disp)))
            } else if mod == 2 {
                let val: Int32 = m.symbol != nil ? 0 : Int32(truncatingIfNeeded: m.disp)
                appendInt32(val, to: &dispBytes)
                if let sym = m.symbol {
                    dispReloc = (.abs32s, sym, m.disp)
                }
            }
            return true
        }

        // Helper to encode an immediate operand
        func encodeImm(_ operand: X86Operand, immSize: X86OperandSize, signExtendedTo targetSize: X86OperandSize) -> Bool {
            guard case .imm(let val, let sym) = operand else { return false }
            switch immSize {
            case .byte:
                guard sym == nil else { return false }
                if targetSize != .byte && !desc.imm8IsZeroExtended {
                    // Sign-extended 8-bit immediate (e.g. 0x83, 0x6B, push $imm8): must fit in Int8 [-128, 127]
                    // Also check 32-bit truncated value in .mode32/.mode16 if needed
                    let fitsSigned8: Bool
                    if targetSize == .dword {
                        let v32 = Int32(truncatingIfNeeded: val)
                        fitsSigned8 = (v32 >= -128 && v32 <= 127)
                    } else if targetSize == .word {
                        let v16 = Int16(truncatingIfNeeded: val)
                        fitsSigned8 = (v16 >= -128 && v16 <= 127)
                    } else {
                        fitsSigned8 = (val >= -128 && val <= 127)
                    }
                    guard fitsSigned8 else { return false }
                } else {
                    guard val >= -128 && val <= 255 else { return false }
                }
                immBytes.append(UInt8(truncatingIfNeeded: val))
                return true

            case .word:
                if sym == nil {
                    guard val >= -32768 && val <= 65535 else { return false }
                }
                let v16: Int16 = sym != nil ? 0 : Int16(truncatingIfNeeded: val)
                appendInt16(v16, to: &immBytes)
                if let sym = sym {
                    immReloc = (.abs16, sym, val)
                }
                return true

            case .dword:
                if sym == nil {
                    if targetSize == .qword {
                        // Sign-extended 32-bit immediate into 64-bit destination (e.g. mov $imm32, %r64 or add $imm32, %r64)
                        guard val >= Int64(Int32.min) && val <= Int64(Int32.max) else { return false }
                    } else {
                        guard val >= Int64(Int32.min) && val <= Int64(UInt32.max) else { return false }
                    }
                }
                let v32: Int32 = sym != nil ? 0 : Int32(truncatingIfNeeded: val)
                appendInt32(v32, to: &immBytes)
                if let sym = sym {
                    let kind: X86RelocKind = (targetSize == .qword) ? .abs32s : .abs32
                    immReloc = (kind, sym, val)
                }
                return true

            case .qword:
                let v64: Int64 = sym != nil ? 0 : val
                appendInt64(v64, to: &immBytes)
                if let sym = sym {
                    immReloc = (.abs64, sym, val)
                }
                return true

            default:
                return false
            }
        }

        // Match operands against `desc.operandFormat`
        switch desc.operandFormat {
        case .implied:
            guard ops.isEmpty else { return nil }

        case .opcodePlusReg(let rc):
            guard ops.count == 1, case .reg(let r) = ops[0], matchReg(r, expected: rc) else { return nil }
            opcodeByte = desc.opcode + r.low3
            if r.needsRexExtension { rexB = true }
            if r.requiresRexByte { needsMandatoryRex = true }

        case .opcodePlusRegWithAcc(let rc):
            guard ops.count == 2, case .reg(let a) = ops[0], case .reg(let b) = ops[1],
                  matchReg(a, expected: rc), matchReg(b, expected: rc) else { return nil }
            let acc = X86Reg.gpr(size: desc.operandSize, hw: 0)
            guard a == acc || b == acc else { return nil }
            let r = (b == acc) ? a : b
            if r == acc {
                // 0x90 is `nop`: `xchg %eax, %eax` (which zero-extends) needs 0x87; LLVM MC folds
                // `xchg %rax, %rax` to a plain 0x90.
                guard desc.operandSize != .dword else { return nil }
                if desc.operandSize == .qword { rexW = false }
            }
            opcodeByte = desc.opcode + r.low3
            if r.needsRexExtension { rexB = true }

        case .immToOpcodePlusReg(let rc, let immSz):
            guard ops.count == 2, case .reg(let r) = ops[1], matchReg(r, expected: rc) else { return nil }
            // If `mov $imm, %r64` is used with a 64-bit immediate that fits in Int32, prefer C7 /0 unless mnemonic is `movabs`/`movabsq`
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: desc.operandSize) else { return nil }
            opcodeByte = desc.opcode + r.low3
            if r.needsRexExtension { rexB = true }
            if r.requiresRexByte { needsMandatoryRex = true }

        case .rm(let rmKind):
            guard ops.count == 1 else { return nil }
            let slash = desc.modrmSlash ?? 0
            let expClass: X86RegClass?
            switch desc.operandSize {
            case .byte:  expClass = .gpr8
            case .word:  expClass = .gpr16
            case .dword: expClass = .gpr32
            case .qword: expClass = .gpr64
            default:     expClass = nil
            }
            guard try encodeRM(ops[0], regField: slash, expectedClass: expClass, rmKind: rmKind) else { return nil }

        case .regToRm(let regClass, let rmClass):
            guard ops.count == 2, case .reg(let srcReg) = ops[0], matchReg(srcReg, expected: regClass) else { return nil }
            if srcReg.needsRexExtension { rexR = true }
            if srcReg.requiresRexByte { needsMandatoryRex = true }
            guard try encodeRM(ops[1], regField: srcReg.low3, expectedClass: rmClass) else { return nil }
            // Check high-byte register conflict with REX
            if try hasHighByteRegRexConflict(ops: ops, rexW: rexW, rexR: rexR, rexX: rexX, rexB: rexB, needsMandatoryRex: needsMandatoryRex) {
                throw X86CodecError.highByteRegWithRex(srcReg)
            }

        case .rmToReg(let rmClass, let regClass):
            guard ops.count == 2, case .reg(let dstReg) = ops[1], matchReg(dstReg, expected: regClass) else { return nil }
            if dstReg.needsRexExtension { rexR = true }
            if dstReg.requiresRexByte { needsMandatoryRex = true }
            guard try encodeRM(ops[0], regField: dstReg.low3, expectedClass: rmClass) else { return nil }

        case .immToRm(let rmClass, let immSz):
            guard ops.count == 2 else { return nil }
            // For memory operands without register size, require explicit size suffix unless default is unambiguous
            if case .mem = ops[1], explicitSize == .unsized && desc.operandSize != .qword && desc.mnemonic != "bt" && desc.mnemonic != "bts" && desc.mnemonic != "btr" && desc.mnemonic != "btc" {
                return nil
            }
            let slash = desc.modrmSlash ?? 0
            guard try encodeRM(ops[1], regField: slash, expectedClass: rmClass) else { return nil }
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: desc.operandSize) else { return nil }

        case .immToAcc(let immSz):
            guard ops.count == 2, case .reg(let accReg) = ops[1] else { return nil }
            let expectedAcc: X86Reg
            switch desc.operandSize {
            case .byte:  expectedAcc = .al
            case .word:  expectedAcc = .ax
            case .dword: expectedAcc = .eax
            case .qword: expectedAcc = .rax
            default: return nil
            }
            guard accReg == expectedAcc else { return nil }
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: desc.operandSize) else { return nil }

        case .shiftBy1:
            let rmOp: X86Operand
            if ops.count == 1 {
                rmOp = ops[0]
            } else if ops.count == 2, case .imm(1, nil) = ops[0] {
                rmOp = ops[1]
            } else {
                return nil
            }
            let expClass: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
            guard try encodeRM(rmOp, regField: desc.modrmSlash ?? 0, expectedClass: expClass) else { return nil }

        case .shiftByCl:
            guard ops.count == 2, case .reg(.cl) = ops[0] else { return nil }
            let expClass: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
            guard try encodeRM(ops[1], regField: desc.modrmSlash ?? 0, expectedClass: expClass) else { return nil }

        case .immRmToReg(let rmClass, let regClass, let immSz):
            guard ops.count == 3, case .reg(let dstReg) = ops[2], matchReg(dstReg, expected: regClass) else { return nil }
            if dstReg.needsRexExtension { rexR = true }
            if dstReg.requiresRexByte { needsMandatoryRex = true }
            guard try encodeRM(ops[1], regField: dstReg.low3, expectedClass: rmClass) else { return nil }
            let targetSz: X86OperandSize = (desc.encodingKind == .vex || rmClass == .xmm || rmClass == .ymm) ? .byte : desc.operandSize
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: targetSz) else { return nil }

        case .immRegToRm(let regClass, let rmClass, let immSz):
            guard ops.count == 3, case .reg(let srcReg) = ops[1], matchReg(srcReg, expected: regClass) else { return nil }
            if srcReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[2], regField: srcReg.low3, expectedClass: rmClass) else { return nil }
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: .byte) else { return nil }

        case .vexRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard ops.count == 3,
                  case .reg(let vReg) = ops[1], matchReg(vReg, expected: vvvvClass),
                  case .reg(let dstReg) = ops[2], matchReg(dstReg, expected: regClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[0], regField: dstReg.low3, expectedClass: rmClass) else { return nil }

        case .vexImmRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard ops.count == 4,
                  case .reg(let vReg) = ops[2], matchReg(vReg, expected: vvvvClass),
                  case .reg(let dstReg) = ops[3], matchReg(dstReg, expected: regClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[1], regField: dstReg.low3, expectedClass: rmClass) else { return nil }
            guard encodeImm(ops[0], immSize: .byte, signExtendedTo: .byte) else { return nil }

        case .vexVvvvRmReg(let vvvvClass, let rmClass, let regClass):
            guard ops.count == 3,
                  case .reg(let vReg) = ops[0], matchReg(vReg, expected: vvvvClass),
                  case .reg(let dstReg) = ops[2], matchReg(dstReg, expected: regClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[1], regField: dstReg.low3, expectedClass: rmClass) else { return nil }

        case .vexRmToVvvv(let rmClass, let vvvvClass):
            guard ops.count == 2, case .reg(let vReg) = ops[1], matchReg(vReg, expected: vvvvClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            guard try encodeRM(ops[0], regField: desc.modrmSlash ?? 0, expectedClass: rmClass) else { return nil }

        case .vexImmRmToVvvv(let rmClass, let vvvvClass):
            guard ops.count == 3, case .reg(let vReg) = ops[2], matchReg(vReg, expected: vvvvClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            guard try encodeRM(ops[1], regField: desc.modrmSlash ?? 0, expectedClass: rmClass) else { return nil }
            guard encodeImm(ops[0], immSize: .byte, signExtendedTo: .byte) else { return nil }

        case .vexRegVvvvToRm(let regClass, let vvvvClass, let rmClass):
            guard ops.count == 3,
                  case .reg(let srcReg) = ops[0], matchReg(srcReg, expected: regClass),
                  case .reg(let vReg) = ops[1], matchReg(vReg, expected: vvvvClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            if srcReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[2], regField: srcReg.low3, expectedClass: rmClass) else { return nil }

        case .vexIs4RmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard ops.count == 4,
                  case .reg(let is4Reg) = ops[0], matchReg(is4Reg, expected: regClass),
                  case .reg(let vReg) = ops[2], matchReg(vReg, expected: vvvvClass),
                  case .reg(let dstReg) = ops[3], matchReg(dstReg, expected: regClass) else { return nil }
            vexVvvv = vReg.hwEncoding
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[1], regField: dstReg.low3, expectedClass: rmClass) else { return nil }
            immBytes.append(is4Reg.hwEncoding << 4)

        case .vexVsib(let vvvvClass, let indexClass, let regClass):
            guard ops.count == 3,
                  case .reg(let maskReg) = ops[0], matchReg(maskReg, expected: vvvvClass),
                  case .reg(let dstReg) = ops[2], matchReg(dstReg, expected: regClass) else { return nil }
            vexVvvv = maskReg.hwEncoding
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(ops[1], regField: dstReg.low3, expectedClass: nil, vsibIndex: indexClass) else { return nil }

        case .xmm0RmToReg(let rmClass, let regClass):
            // The `%xmm0` operand may also be omitted (`blendvps %xmm2, %xmm1`), as GNU `as` and LLVM MC allow.
            let explicitOps = ops.count == 3 ? Array(ops.dropFirst()) : ops
            if ops.count == 3 { guard case .reg(.xmm0) = ops[0] else { return nil } }
            guard explicitOps.count == 2, case .reg(let dstReg) = explicitOps[1], matchReg(dstReg, expected: regClass) else { return nil }
            if dstReg.needsRexExtension { rexR = true }
            guard try encodeRM(explicitOps[0], regField: dstReg.low3, expectedClass: rmClass) else { return nil }

        case .relBranch(let relSz):
            guard ops.count == 1 else { return nil }
            let val: Int64
            let sym: String?
            switch ops[0] {
            case .relTarget(let v, let s):
                val = v; sym = s
            case .imm(let v, let s):
                val = v; sym = s
            default:
                return nil
            }
            if relSz == .byte {
                // Symbolic targets always use rel32
                guard sym == nil && val >= -128 && val <= 127 else { return nil }
                immBytes.append(UInt8(bitPattern: Int8(truncatingIfNeeded: val)))
            } else {
                let v32: Int32 = sym != nil ? 0 : Int32(truncatingIfNeeded: val)
                appendInt32(v32, to: &immBytes)
                if let sym = sym {
                    let kind: X86RelocKind = (desc.mnemonic == "call") ? .plt32 : .pc32
                    immReloc = (kind, sym, val - 4)
                }
            }

        case .immOnly(let immSz):
            guard ops.count == 1 else { return nil }
            let targetSz: X86OperandSize = (desc.mnemonic == "push") ? .qword : immSz
            guard encodeImm(ops[0], immSize: immSz, signExtendedTo: targetSz) else { return nil }

        case .segToRm:
            guard ops.count == 2, case .reg(let segReg) = ops[0], segReg.regClass == .seg else { return nil }
            guard try encodeRM(ops[1], regField: segReg.hwEncoding, expectedClass: desc.operandSize.gprClass) else { return nil }

        case .rmToSeg:
            guard ops.count == 2, case .reg(let segReg) = ops[1], segReg.regClass == .seg else { return nil }
            guard try encodeRM(ops[0], regField: segReg.hwEncoding, expectedClass: desc.operandSize.gprClass) else { return nil }

        case .crToReg:
            guard ops.count == 2,
                  case .reg(let crReg) = ops[0], crReg.regClass == .cr,
                  case .reg(let gprReg) = ops[1], gprReg.regClass == (mode == .mode64 ? .gpr64 : .gpr32) else { return nil }
            hasModRM = true
            if crReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (crReg.low3 << 3) | gprReg.low3

        case .regToCr:
            guard ops.count == 2,
                  case .reg(let gprReg) = ops[0], gprReg.regClass == (mode == .mode64 ? .gpr64 : .gpr32),
                  case .reg(let crReg) = ops[1], crReg.regClass == .cr else { return nil }
            hasModRM = true
            if crReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (crReg.low3 << 3) | gprReg.low3

        case .drToReg:
            guard ops.count == 2,
                  case .reg(let drReg) = ops[0], drReg.regClass == .dr,
                  case .reg(let gprReg) = ops[1], gprReg.regClass == (mode == .mode64 ? .gpr64 : .gpr32) else { return nil }
            hasModRM = true
            if drReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (drReg.low3 << 3) | gprReg.low3

        case .regToDr:
            guard ops.count == 2,
                  case .reg(let gprReg) = ops[0], gprReg.regClass == (mode == .mode64 ? .gpr64 : .gpr32),
                  case .reg(let drReg) = ops[1], drReg.regClass == .dr else { return nil }
            hasModRM = true
            if drReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (drReg.low3 << 3) | gprReg.low3

        case .ioDxToAcc:
            guard ops.count == 2, case .reg(.dx) = ops[0], case .reg(let acc) = ops[1] else { return nil }
            let expAcc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            guard acc == expAcc else { return nil }

        case .ioAccToDx:
            guard ops.count == 2, case .reg(let acc) = ops[0], case .reg(.dx) = ops[1] else { return nil }
            let expAcc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            guard acc == expAcc else { return nil }

        case .ioImmToAcc:
            guard ops.count == 2, case .reg(let acc) = ops[1] else { return nil }
            let expAcc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            guard acc == expAcc else { return nil }
            guard encodeImm(ops[0], immSize: .byte, signExtendedTo: .byte) else { return nil }

        case .ioAccToImm:
            guard ops.count == 2, case .reg(let acc) = ops[0] else { return nil }
            let expAcc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            guard acc == expAcc else { return nil }
            guard encodeImm(ops[1], immSize: .byte, signExtendedTo: .byte) else { return nil }
        }

        // Assemble final instruction bytes
        var out: [UInt8] = []
        out.reserveCapacity(15)

        // 1. Legacy prefixes in LLVM MC / GNU `as` order: rep, segment, address size, operand size, lock
        if inst.repPrefix != .none { out.append(inst.repPrefix.rawValue) }
        if let seg = segmentOverride { out.append(seg) }
        if addressSizeOverride { out.append(0x67) }

        if desc.encodingKind == .vex {
            guard !inst.lockPrefix else { return nil }
            // VEX 2-byte (C5) vs 3-byte (C4)
            let rInv: UInt8 = rexR ? 0 : 1
            let xInv: UInt8 = rexX ? 0 : 1
            let bInv: UInt8 = rexB ? 0 : 1
            let wBit: UInt8 = rexW ? 1 : 0
            let vvvvInv: UInt8 = (~vexVvvv) & 0x0F
            let lBit: UInt8 = desc.vexL & 0x01
            let ppBits: UInt8 = desc.mandatoryPrefix.vexPP
            let mapBits: UInt8 = desc.opcodeMap.rawValue

            if xInv == 1 && bInv == 1 && wBit == 0 && mapBits == 1 {
                // 2-byte VEX: C5 [R ~vvvv L pp]
                out.append(0xC5)
                out.append((rInv << 7) | (vvvvInv << 3) | (lBit << 2) | ppBits)
            } else {
                // 3-byte VEX: C4 [R X B m_mmmm] [W ~vvvv L pp]
                out.append(0xC4)
                out.append((rInv << 7) | (xInv << 6) | (bInv << 5) | (mapBits & 0x1F))
                out.append((wBit << 7) | (vvvvInv << 3) | (lBit << 2) | ppBits)
            }
            out.append(opcodeByte)
        } else {
            // Legacy operand-size override prefix (0x66). It also applies under an F3/F2 mandatory prefix
            // (16-bit `tzcnt`/`lzcnt`/`popcnt` are `66 F3 0F ..`); only a mandatory 0x66 replaces it.
            if desc.usesOperandSizeOverride {
                if (mode == .mode64 || mode == .mode32) && desc.operandSize == .word {
                    out.append(0x66)
                } else if mode == .mode16 && desc.operandSize == .dword {
                    out.append(0x66)
                }
            }
            if inst.lockPrefix { out.append(0xF0) }

            // Mandatory SIMD / extension prefix
            switch desc.mandatoryPrefix {
            case .none:  break
            case .p66:   out.append(0x66)
            case .pF3:   out.append(0xF3)
            case .pF2:   out.append(0xF2)
            case .p66F2: out.append(0x66); out.append(0xF2)
            }

            // REX prefix (in 64-bit mode)
            if mode == .mode64 && (rexW || rexR || rexX || rexB || needsMandatoryRex) {
                if try hasHighByteRegRexConflict(ops: ops, rexW: rexW, rexR: rexR, rexX: rexX, rexB: rexB, needsMandatoryRex: needsMandatoryRex) {
                    throw X86CodecError.highByteRegWithRex(.ah)
                }
                var rex: UInt8 = 0x40
                if rexW { rex |= 0x08 }
                if rexR { rex |= 0x04 }
                if rexX { rex |= 0x02 }
                if rexB { rex |= 0x01 }
                out.append(rex)
            }

            // Opcode map escape bytes
            switch desc.opcodeMap {
            case .primary: break
            case .map0F:   out.append(0x0F)
            case .map0F38: out.append(0x0F); out.append(0x38)
            case .map0F3A: out.append(0x0F); out.append(0x3A)
            }

            out.append(opcodeByte)
            if let sec = desc.secondaryOpcode {
                out.append(sec)
            }
        }

        // ModR/M and SIB
        if hasModRM {
            out.append(modrmByte)
            if let sib = sibByte {
                out.append(sib)
            }
        }

        // Displacement & Immediates + Relocations
        var relocs: [X86EncodedReloc] = []
        let dispOffset = out.count
        out.append(contentsOf: dispBytes)
        let immOffset = out.count
        out.append(contentsOf: immBytes)

        if let dr = dispReloc {
            let finalAddend: Int64
            if dr.kind == .pc32 {
                // RIP-relative addend accounts for distance from dispOffset to end of instruction
                finalAddend = dr.addend - Int64(out.count - dispOffset)
            } else {
                finalAddend = dr.addend
            }
            relocs.append(X86EncodedReloc(offset: dispOffset, kind: dr.kind, symbol: dr.symbol, addend: finalAddend))
        }
        if let ir = immReloc {
            relocs.append(X86EncodedReloc(offset: immOffset, kind: ir.kind, symbol: ir.symbol, addend: ir.addend))
        }

        return X86EncodedInstruction(bytes: out, relocations: relocs)
    }

    private func encodeScale(_ scale: UInt8, mem: X86Mem) throws -> UInt8 {
        switch scale {
        case 1: return 0
        case 2: return 1
        case 4: return 2
        case 8: return 3
        default: throw X86CodecError.invalidMemoryAddressing(mem)
        }
    }

    private func hasHighByteRegRexConflict(
        ops: [X86Operand],
        rexW: Bool,
        rexR: Bool,
        rexX: Bool,
        rexB: Bool,
        needsMandatoryRex: Bool
    ) throws -> Bool {
        guard rexW || rexR || rexX || rexB || needsMandatoryRex else { return false }
        for op in ops {
            if case .reg(let r) = op, r.regClass == .gpr8High {
                return true
            }
        }
        return false
    }

    private func appendInt16(_ val: Int16, to bytes: inout [UInt8]) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }

    private func appendInt32(_ val: Int32, to bytes: inout [UInt8]) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }

    private func appendInt64(_ val: Int64, to bytes: inout [UInt8]) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }
}

// MARK: - 6. Table-Driven x86-64 Disassembler (X86Disassembler)

/// Decodes x86-64 machine code bytes back into `X86Instruction` values using `X86InstructionTable`.
public struct X86Disassembler: Sendable {

    private struct DecodeKey: Hashable, Sendable {
        let encodingKind: X86EncodingKind
        let opcodeMap: X86OpcodeMap
        let opcode: UInt8
    }

    /// Precomputed lookup table from `(encodingKind, opcodeMap, opcode)` to descriptor indices.
    private static let decodeTable: [DecodeKey: [Int]] = {
        var map: [DecodeKey: [Int]] = [:]
        for (idx, desc) in X86InstructionTable.descriptors.enumerated() {
            switch desc.operandFormat {
            case .opcodePlusReg, .opcodePlusRegWithAcc, .immToOpcodePlusReg:
                for r: UInt8 in 0..<8 {
                    let key = DecodeKey(encodingKind: desc.encodingKind, opcodeMap: desc.opcodeMap, opcode: desc.opcode + r)
                    map[key, default: []].append(idx)
                }
            default:
                let key = DecodeKey(encodingKind: desc.encodingKind, opcodeMap: desc.opcodeMap, opcode: desc.opcode)
                map[key, default: []].append(idx)
            }
        }
        return map
    }()

    public init() {}

    /// Disassembles a buffer of machine code bytes into a sequence of instructions.
    public func disassemble(_ bytes: [UInt8], codeMode: X86CodeMode = .mode64) throws -> [X86Instruction] {
        var result: [X86Instruction] = []
        var offset = 0
        while offset < bytes.count {
            let (inst, len) = try disassembleOne(bytes, at: offset, codeMode: codeMode)
            result.append(inst)
            offset += len
        }
        return result
    }

    /// Disassembles a single instruction starting at `offset` in `bytes`.
    public func disassembleOne(
        _ bytes: [UInt8],
        at startOffset: Int = 0,
        codeMode: X86CodeMode = .mode64
    ) throws -> (instruction: X86Instruction, byteLength: Int) {
        var cursor = startOffset
        guard cursor < bytes.count else {
            throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
        }

        var lockPrefix = false
        var hasF2 = false
        var hasF3 = false
        var has66 = false
        var has67 = false
        var segmentOverride: UInt8? = nil

        // 1. Parse legacy prefixes
        while cursor < bytes.count {
            let b = bytes[cursor]
            switch b {
            case 0xF0: lockPrefix = true; cursor += 1
            case 0xF2: hasF2 = true; cursor += 1
            case 0xF3: hasF3 = true; cursor += 1
            case 0x66: has66 = true; cursor += 1
            case 0x67: has67 = true; cursor += 1
            case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65:
                segmentOverride = b
                cursor += 1
            default:
                break
            }
            if b != 0xF0 && b != 0xF2 && b != 0xF3 && b != 0x66 && b != 0x67 &&
               b != 0x26 && b != 0x2E && b != 0x36 && b != 0x3E && b != 0x64 && b != 0x65 {
                break
            }
        }

        guard cursor < bytes.count else {
            throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
        }

        var encodingKind: X86EncodingKind = .legacy
        var opcodeMap: X86OpcodeMap = .primary
        var hasRex = false
        var rexW = false
        var rexR = false
        var rexX = false
        var rexB = false
        var vexVvvv: UInt8 = 0
        var vexL: UInt8 = 0
        var vexPP: UInt8 = 0

        // 2. Check VEX (0xC5 / 0xC4) or REX (0x40..0x4F)
        let firstByte = bytes[cursor]
        if firstByte == 0xC5 && (codeMode == .mode64 || (cursor + 1 < bytes.count && (bytes[cursor + 1] & 0xC0) == 0xC0)) {
            // 2-byte VEX: C5 [R ~vvvv L pp]
            guard cursor + 2 < bytes.count else {
                throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
            }
            encodingKind = .vex
            let b1 = bytes[cursor + 1]
            rexR = ((b1 >> 7) & 1) == 0
            vexVvvv = (~(b1 >> 3)) & 0x0F
            vexL = (b1 >> 2) & 1
            vexPP = b1 & 0x03
            opcodeMap = .map0F
            cursor += 2
        } else if firstByte == 0xC4 && (codeMode == .mode64 || (cursor + 1 < bytes.count && (bytes[cursor + 1] & 0xC0) == 0xC0)) {
            // 3-byte VEX: C4 [R X B m_mmmm] [W ~vvvv L pp]
            guard cursor + 3 < bytes.count else {
                throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
            }
            encodingKind = .vex
            let b1 = bytes[cursor + 1]
            let b2 = bytes[cursor + 2]
            rexR = ((b1 >> 7) & 1) == 0
            rexX = ((b1 >> 6) & 1) == 0
            rexB = ((b1 >> 5) & 1) == 0
            switch b1 & 0x1F {
            case 1: opcodeMap = .map0F
            case 2: opcodeMap = .map0F38
            case 3: opcodeMap = .map0F3A
            default: throw X86CodecError.unknownOpcode(offset: cursor, byte: b1)
            }
            rexW = ((b2 >> 7) & 1) != 0
            vexVvvv = (~(b2 >> 3)) & 0x0F
            vexL = (b2 >> 2) & 1
            vexPP = b2 & 0x03
            cursor += 3
        } else {
            if codeMode == .mode64 && firstByte >= 0x40 && firstByte <= 0x4F {
                hasRex = true
                rexW = (firstByte & 0x08) != 0
                rexR = (firstByte & 0x04) != 0
                rexX = (firstByte & 0x02) != 0
                rexB = (firstByte & 0x01) != 0
                cursor += 1
            }
            guard cursor < bytes.count else {
                throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
            }
            if bytes[cursor] == 0x0F {
                cursor += 1
                guard cursor < bytes.count else {
                    throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
                }
                if bytes[cursor] == 0x38 {
                    opcodeMap = .map0F38
                    cursor += 1
                } else if bytes[cursor] == 0x3A {
                    opcodeMap = .map0F3A
                    cursor += 1
                } else {
                    opcodeMap = .map0F
                }
            }
        }

        guard cursor < bytes.count else {
            throw X86CodecError.unexpectedEndOfBytes(offset: cursor)
        }
        let opcodeByte = bytes[cursor]
        cursor += 1

        let key = DecodeKey(encodingKind: encodingKind, opcodeMap: opcodeMap, opcode: opcodeByte)
        guard let candidateIndices = Self.decodeTable[key] else {
            throw X86CodecError.unknownOpcode(offset: cursor - 1, byte: opcodeByte)
        }

        for idx in candidateIndices {
            let desc = X86InstructionTable.descriptors[idx]
            if let (inst, endCursor) = try tryDecode(
                bytes: bytes,
                afterOpcodeCursor: cursor,
                opcodeByte: opcodeByte,
                desc: desc,
                codeMode: codeMode,
                lockPrefix: lockPrefix,
                hasF2: hasF2,
                hasF3: hasF3,
                has66: has66,
                has67: has67,
                segmentOverride: segmentOverride,
                hasRex: hasRex,
                rexW: rexW,
                rexR: rexR,
                rexX: rexX,
                rexB: rexB,
                vexVvvv: vexVvvv,
                vexL: vexL,
                vexPP: vexPP
            ) {
                return (inst, endCursor - startOffset)
            }
        }

        throw X86CodecError.unknownOpcode(offset: cursor - 1, byte: opcodeByte)
    }

    private func tryDecode(
        bytes: [UInt8],
        afterOpcodeCursor: Int,
        opcodeByte: UInt8,
        desc: X86InstrDesc,
        codeMode: X86CodeMode,
        lockPrefix: Bool,
        hasF2: Bool,
        hasF3: Bool,
        has66: Bool,
        has67: Bool,
        segmentOverride: UInt8?,
        hasRex: Bool,
        rexW: Bool,
        rexR: Bool,
        rexX: Bool,
        rexB: Bool,
        vexVvvv: UInt8,
        vexL: UInt8,
        vexPP: UInt8
    ) throws -> (X86Instruction, Int)? {
        var cursor = afterOpcodeCursor
        var repPrefix: X86RepPrefix = .none

        // 1. Verify prefix & VEX constraints
        if desc.encodingKind == .vex {
            // VEX.W is matched exactly: the encoder writes W0 for W-ignored instructions, as GNU `as` and LLVM MC do.
            guard desc.vexL == vexL && desc.mandatoryPrefix.vexPP == vexPP && desc.rexW == rexW else { return nil }
            // Formats without a VEX.vvvv operand require VEX.vvvv = 1111b.
            guard desc.operandFormat.usesVvvv || vexVvvv == 0 else { return nil }
            guard !lockPrefix && !hasF2 && !hasF3 && !has66 else { return nil }
        } else {
            // Legacy mandatory prefix matching
            switch desc.mandatoryPrefix {
            case .p66F2:
                guard has66 && hasF2 && !hasF3 else { return nil }
            case .pF2:
                guard hasF2 && !hasF3 else { return nil }
            case .pF3:
                guard hasF3 && !hasF2 else { return nil }
            case .p66:
                guard has66 && !hasF2 && !hasF3 else { return nil }
            case .none:
                let isStringOp = (desc.opcodeMap == .primary && (opcodeByte == 0xA4 || opcodeByte == 0xA5 || opcodeByte == 0xAA || opcodeByte == 0xAB))
                if isStringOp {
                    if hasF3 { repPrefix = .rep }
                    else if hasF2 { repPrefix = .repne }
                } else {
                    guard !hasF2 && !hasF3 else { return nil }
                }
            }

            // Check operand size (rexW / 0x66)
            if desc.rexW {
                guard rexW else { return nil }
            } else {
                guard !rexW else { return nil }
            }

            if desc.usesOperandSizeOverride {
                if desc.operandSize == .word {
                    let expects66 = (codeMode != .mode16)
                    guard has66 == expects66 else { return nil }
                } else if desc.operandSize == .dword {
                    let expects66 = (codeMode == .mode16)
                    guard has66 == expects66 else { return nil }
                } else {
                    guard !has66 else { return nil }
                }
            }
        }

        // 2. Check secondary opcode byte (e.g. 0F 01 F8 swapgs, 0F AE F0 mfence)
        if let sec = desc.secondaryOpcode {
            guard cursor < bytes.count, bytes[cursor] == sec else { return nil }
            cursor += 1
        }

        func readInt8(at cursor: inout Int) throws -> Int8 {
            guard cursor < bytes.count else { throw X86CodecError.unexpectedEndOfBytes(offset: cursor) }
            let b = bytes[cursor]
            cursor += 1
            return Int8(bitPattern: b)
        }

        func readInt16(at cursor: inout Int) throws -> Int16 {
            guard cursor + 2 <= bytes.count else { throw X86CodecError.unexpectedEndOfBytes(offset: cursor) }
            let lo = UInt16(bytes[cursor])
            let hi = UInt16(bytes[cursor + 1]) << 8
            cursor += 2
            return Int16(bitPattern: lo | hi)
        }

        func readInt32(at cursor: inout Int) throws -> Int32 {
            guard cursor + 4 <= bytes.count else { throw X86CodecError.unexpectedEndOfBytes(offset: cursor) }
            let b0 = UInt32(bytes[cursor])
            let b1 = UInt32(bytes[cursor + 1]) << 8
            let b2 = UInt32(bytes[cursor + 2]) << 16
            let b3 = UInt32(bytes[cursor + 3]) << 24
            cursor += 4
            return Int32(bitPattern: b0 | b1 | b2 | b3)
        }

        func readInt64(at cursor: inout Int) throws -> Int64 {
            let lo = UInt64(UInt32(bitPattern: try readInt32(at: &cursor)))
            let hi = UInt64(UInt32(bitPattern: try readInt32(at: &cursor))) << 32
            return Int64(bitPattern: lo | hi)
        }

        // 3. Helper to decode ModR/M + SIB + disp
        func decodeModRM(
            rmClass: X86RegClass?,
            rmKind: X86RMKind = .gprOrMem,
            vsibIndex: X86RegClass? = nil
        ) throws -> (regBits: UInt8, rmOperand: X86Operand)? {
            guard cursor < bytes.count else { return nil }
            let modrm = bytes[cursor]
            let mod = (modrm >> 6) & 0x03
            let regField = (modrm >> 3) & 0x07
            let rmField = modrm & 0x07

            if let expectedSlash = desc.modrmSlash, regField != expectedSlash {
                return nil
            }
            if mod == 3 && desc.rmConstraint == .memOnly { return nil }
            if mod != 3 && desc.rmConstraint == .regOnly { return nil }

            if let vsib = vsibIndex {
                // VSIB: memory only, always with a SIB byte whose index field names a vector register.
                guard mod != 3, rmField == 4 else { return nil }
                cursor += 1
                let mem = try decodeMemoryOperand(mod: mod, rmField: rmField, vsibIndex: vsib)
                return (regField, .mem(mem))
            }

            if mod == 3 {
                guard rmKind != .memOnly && rmKind != .indirectMemOnly else { return nil }
                cursor += 1
                let hw = (rexB ? 8 : 0) | rmField
                let reg = makeReg(for: rmClass ?? .gpr64, hw: hw, hasRex: hasRex)
                let op: X86Operand = (rmKind == .indirectRegOrMem) ? .indirectReg(reg) : .reg(reg)
                return (regField, op)
            } else {
                guard rmKind != .gprOnly else { return nil }
                cursor += 1
                let mem = try decodeMemoryOperand(mod: mod, rmField: rmField)
                let op: X86Operand = (rmKind == .indirectRegOrMem || rmKind == .indirectMemOnly) ? .indirectMem(mem) : .mem(mem)
                return (regField, op)
            }
        }

        func decodeMemoryOperand(mod: UInt8, rmField: UInt8, vsibIndex: X86RegClass? = nil) throws -> X86Mem {
            // 16-bit addressing mode
            if codeMode == .mode16 && !has67 {
                if mod == 0 && rmField == 6 {
                    let d16 = try readInt16(at: &cursor)
                    return X86Mem(segment: segmentOverride, base: nil, index: nil, scale: 1, disp: Int64(d16))
                }
                let base16: X86Reg?
                let index16: X86Reg?
                switch rmField {
                case 0: base16 = .bx; index16 = .si
                case 1: base16 = .bx; index16 = .di
                case 2: base16 = .bp; index16 = .si
                case 3: base16 = .bp; index16 = .di
                case 4: base16 = .si; index16 = nil
                case 5: base16 = .di; index16 = nil
                case 6: base16 = .bp; index16 = nil
                default: base16 = .bx; index16 = nil
                }
                var disp: Int64 = 0
                if mod == 1 { disp = Int64(try readInt8(at: &cursor)) }
                else if mod == 2 { disp = Int64(try readInt16(at: &cursor)) }
                return X86Mem(segment: segmentOverride, base: base16, index: index16, scale: 1, disp: disp)
            }

            let use32BitAddr = (codeMode == .mode32 && !has67) || (codeMode == .mode64 && has67) || (codeMode == .mode16 && has67)
            func makeAddrReg(_ id: UInt8) -> X86Reg {
                use32BitAddr ? X86Reg.gpr32(id) : X86Reg.gpr64(id)
            }

            if rmField == 4 {
                // SIB byte follows
                guard cursor < bytes.count else { throw X86CodecError.unexpectedEndOfBytes(offset: cursor) }
                let sib = bytes[cursor]
                cursor += 1
                let scale: UInt8 = 1 << ((sib >> 6) & 0x03)
                let idxBits = (sib >> 3) & 0x07
                let baseBits = sib & 0x07

                let indexReg: X86Reg?
                if let vsib = vsibIndex {
                    indexReg = makeReg(for: vsib, hw: (rexX ? 8 : 0) | idxBits, hasRex: true)
                } else if !rexX && idxBits == 4 {
                    indexReg = nil
                } else {
                    indexReg = makeAddrReg((rexX ? 8 : 0) | idxBits)
                }

                if mod == 0 && baseBits == 5 {
                    let d32 = try readInt32(at: &cursor)
                    return X86Mem(segment: segmentOverride, base: nil, index: indexReg, scale: scale, disp: Int64(d32))
                } else {
                    let baseReg = makeAddrReg((rexB ? 8 : 0) | baseBits)
                    var disp: Int64 = 0
                    if mod == 1 { disp = Int64(try readInt8(at: &cursor)) }
                    else if mod == 2 { disp = Int64(try readInt32(at: &cursor)) }
                    return X86Mem(segment: segmentOverride, base: baseReg, index: indexReg, scale: scale, disp: disp)
                }
            } else if mod == 0 && rmField == 5 {
                let d32 = try readInt32(at: &cursor)
                if codeMode == .mode64 {
                    return X86Mem(segment: segmentOverride, base: .rip, index: nil, scale: 1, disp: Int64(d32), forceDisp32: true)
                } else {
                    return X86Mem(segment: segmentOverride, base: nil, index: nil, scale: 1, disp: Int64(d32))
                }
            } else {
                let baseReg = makeAddrReg((rexB ? 8 : 0) | rmField)
                var disp: Int64 = 0
                if mod == 1 { disp = Int64(try readInt8(at: &cursor)) }
                else if mod == 2 { disp = Int64(try readInt32(at: &cursor)) }
                return X86Mem(segment: segmentOverride, base: baseReg, index: nil, scale: 1, disp: disp)
            }
        }

        func readImm(size: X86OperandSize) throws -> Int64 {
            switch size {
            case .byte:
                // Zero-extended imm8 (shift counts, SIMD selectors) prints as 0..255, signed imm8 as -128..127.
                let b = try readInt8(at: &cursor)
                return desc.imm8IsZeroExtended ? Int64(UInt8(bitPattern: b)) : Int64(b)
            case .word:  return Int64(try readInt16(at: &cursor))
            case .dword: return Int64(try readInt32(at: &cursor))
            case .qword: return try readInt64(at: &cursor)
            default:     return 0
            }
        }

        var operands: [X86Operand] = []

        switch desc.operandFormat {
        case .implied:
            break

        case .opcodePlusReg(let rc):
            let hw = (rexB ? 8 : 0) | (opcodeByte - desc.opcode)
            operands = [.reg(makeReg(for: rc, hw: hw, hasRex: hasRex))]

        case .opcodePlusRegWithAcc(let rc):
            let hw = (rexB ? 8 : 0) | (opcodeByte - desc.opcode)
            // 0x90 / REX.W 0x90 are `nop`; only 0x66 0x90 decodes as `xchg %ax, %ax`.
            guard hw != 0 || desc.operandSize == .word else { return nil }
            operands = [.reg(makeReg(for: rc, hw: hw, hasRex: hasRex)), .reg(X86Reg.gpr(size: desc.operandSize, hw: 0))]

        case .immToOpcodePlusReg(let rc, let immSz):
            let hw = (rexB ? 8 : 0) | (opcodeByte - desc.opcode)
            let immVal = try readImm(size: immSz)
            operands = [.imm(immVal), .reg(makeReg(for: rc, hw: hw, hasRex: hasRex))]

        case .rm(let rmKind):
            let expClass: X86RegClass?
            switch desc.operandSize {
            case .byte:  expClass = .gpr8
            case .word:  expClass = .gpr16
            case .dword: expClass = .gpr32
            case .qword: expClass = .gpr64
            default:     expClass = nil
            }
            guard let (_, rmOp) = try decodeModRM(rmClass: expClass, rmKind: rmKind) else { return nil }
            operands = [rmOp]

        case .regToRm(let regClass, let rmClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let regHw = (rexR ? 8 : 0) | regBits
            let regOp = X86Operand.reg(makeReg(for: regClass, hw: regHw, hasRex: hasRex))
            operands = [regOp, rmOp]

        case .rmToReg(let rmClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let regHw = (rexR ? 8 : 0) | regBits
            let regOp = X86Operand.reg(makeReg(for: regClass, hw: regHw, hasRex: hasRex))
            operands = [rmOp, regOp]

        case .immToRm(let rmClass, let immSz):
            guard let (_, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: immSz)
            operands = [.imm(immVal), rmOp]

        case .immToAcc(let immSz):
            let immVal = try readImm(size: immSz)
            let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : (desc.operandSize == .dword ? .eax : .rax))
            operands = [.imm(immVal), .reg(acc)]

        case .shiftBy1:
            let rmClass: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
            guard let (_, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            operands = [.imm(1), rmOp]

        case .shiftByCl:
            let rmClass: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
            guard let (_, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            operands = [.reg(.cl), rmOp]

        case .immRmToReg(let rmClass, let regClass, let immSz):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: immSz)
            let regHw = (rexR ? 8 : 0) | regBits
            let dstReg = makeReg(for: regClass, hw: regHw, hasRex: hasRex)
            operands = [.imm(immVal), rmOp, .reg(dstReg)]

        case .immRegToRm(let regClass, let rmClass, let immSz):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: immSz)
            let regHw = (rexR ? 8 : 0) | regBits
            let srcReg = makeReg(for: regClass, hw: regHw, hasRex: hasRex)
            operands = [.imm(immVal), .reg(srcReg), rmOp]

        case .vexRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [rmOp, .reg(vReg), .reg(dstReg)]

        case .vexImmRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: .byte)
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.imm(immVal), rmOp, .reg(vReg), .reg(dstReg)]

        case .vexVvvvRmReg(let vvvvClass, let rmClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.reg(vReg), rmOp, .reg(dstReg)]

        case .vexRmToVvvv(let rmClass, let vvvvClass):
            guard let (_, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            operands = [rmOp, .reg(makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true))]

        case .vexImmRmToVvvv(let rmClass, let vvvvClass):
            guard let (_, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: .byte)
            operands = [.imm(immVal), rmOp, .reg(makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true))]

        case .vexRegVvvvToRm(let regClass, let vvvvClass, let rmClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let srcReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.reg(srcReg), .reg(makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)), rmOp]

        case .vexIs4RmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            guard cursor < bytes.count, bytes[cursor] & 0x0F == 0 else { return nil }
            let is4Reg = makeReg(for: regClass, hw: bytes[cursor] >> 4, hasRex: true)
            cursor += 1
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.reg(is4Reg), rmOp, .reg(vReg), .reg(dstReg)]

        case .vexVsib(let vvvvClass, let indexClass, let regClass):
            guard let (regBits, memOp) = try decodeModRM(rmClass: nil, vsibIndex: indexClass) else { return nil }
            let maskReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.reg(maskReg), memOp, .reg(dstReg)]

        case .xmm0RmToReg(let rmClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: hasRex)
            operands = [.reg(.xmm0), rmOp, .reg(dstReg)]

        case .relBranch(let relSz):
            let relVal = try readImm(size: relSz)
            operands = [.relTarget(relVal)]

        case .immOnly(let immSz):
            let immVal = try readImm(size: immSz)
            operands = [.imm(immVal)]

        case .segToRm:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: desc.operandSize.gprClass) else { return nil }
            guard let segReg = X86Reg.seg(regBits) else { return nil }
            operands = [.reg(segReg), rmOp]

        case .rmToSeg:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: desc.operandSize.gprClass) else { return nil }
            guard let segReg = X86Reg.seg(regBits) else { return nil }
            operands = [rmOp, .reg(segReg)]

        case .crToReg:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: codeMode == .mode64 ? .gpr64 : .gpr32, rmKind: .gprOnly) else { return nil }
            let crReg = X86Reg.cr((rexR ? 8 : 0) | regBits)
            operands = [.reg(crReg), rmOp]

        case .regToCr:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: codeMode == .mode64 ? .gpr64 : .gpr32, rmKind: .gprOnly) else { return nil }
            let crReg = X86Reg.cr((rexR ? 8 : 0) | regBits)
            operands = [rmOp, .reg(crReg)]

        case .drToReg:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: codeMode == .mode64 ? .gpr64 : .gpr32, rmKind: .gprOnly) else { return nil }
            let drReg = X86Reg.dr((rexR ? 8 : 0) | regBits)
            operands = [.reg(drReg), rmOp]

        case .regToDr:
            guard let (regBits, rmOp) = try decodeModRM(rmClass: codeMode == .mode64 ? .gpr64 : .gpr32, rmKind: .gprOnly) else { return nil }
            let drReg = X86Reg.dr((rexR ? 8 : 0) | regBits)
            operands = [rmOp, .reg(drReg)]

        case .ioDxToAcc:
            let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            operands = [.reg(.dx), .reg(acc)]

        case .ioAccToDx:
            let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            operands = [.reg(acc), .reg(.dx)]

        case .ioImmToAcc:
            let immVal = try readImm(size: .byte)
            let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            operands = [.imm(immVal & 0xFF), .reg(acc)]

        case .ioAccToImm:
            let immVal = try readImm(size: .byte)
            let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
            operands = [.reg(acc), .imm(immVal & 0xFF)]
        }

        // Include explicit size suffix when needed (e.g. memory destination without register operand)
        let needsSuffix = desc.needsSizeSuffix(operands: operands)

        let mnemonic: String
        if let memMnem = desc.memMnemonic, operands.contains(where: \.isMemory) {
            mnemonic = memMnem
        } else {
            mnemonic = desc.mnemonic
        }
        let inst = X86Instruction(
            mnemonic: mnemonic,
            sizeSuffix: needsSuffix ? desc.operandSize : .unsized,
            operands: operands,
            lockPrefix: lockPrefix,
            repPrefix: repPrefix,
            codeMode: codeMode
        )
        return (inst, cursor)
    }

    private func makeReg(for rc: X86RegClass, hw: UInt8, hasRex: Bool) -> X86Reg {
        switch rc {
        case .gpr8:     return .gpr8(hw, hasRex: hasRex)
        case .gpr8High: return .gpr8(hw, hasRex: false)
        case .gpr16:    return .gpr16(hw)
        case .gpr32:    return .gpr32(hw)
        case .gpr64:    return .gpr64(hw)
        case .rip:      return .rip
        case .xmm:      return .xmm(hw)
        case .ymm:      return .ymm(hw)
        case .seg:      return .seg(hw) ?? .ds
        case .cr:       return .cr(hw)
        case .dr:       return .dr(hw)
        }
    }
}

// MARK: - 7. Exhaustive Round-Trip Verification (04-backend.md §4.9, 09-roadmap.md §M2)

extension X86InstructionTable {

    /// Constructs representative instructions across `X86InstructionTable` (including GPR, SIB/RIP/segment
    /// memory addressing, system/privileged, SSE, and 2-byte/3-byte VEX 128-bit & 256-bit AVX instructions),
    /// encodes them, disassembles them, re-encodes the disassembled instruction, and verifies byte-for-byte identity.
    public static func verifyRoundTrip() throws -> [(mnemonic: String, bytes: [UInt8], disassembled: String)] {
        let encoder = X86TableEncoder()
        let disassembler = X86Disassembler()
        var results: [(mnemonic: String, bytes: [UInt8], disassembled: String)] = []
        results.reserveCapacity(descriptors.count + 32)

        func sampleReg(_ rc: X86RegClass, index: UInt8 = 1) -> X86Reg {
            switch rc {
            case .gpr8:     return .gpr8(index)
            case .gpr8High: return .ah
            case .gpr16:    return .gpr16(index)
            case .gpr32:    return .gpr32(index)
            case .gpr64:    return .gpr64(index)
            case .rip:      return .rip
            case .xmm:      return .xmm(index)
            case .ymm:      return .ymm(index)
            case .seg:      return .ds
            case .cr:       return .cr3
            case .dr:       return .dr6
            }
        }

        for desc in descriptors {
            let mode: X86CodeMode = (desc.mnemonic == "lgdtl") ? .mode16 : .mode64
            let sampleMem: X86Mem = (mode == .mode16) ? .absolute(disp: 8) : .baseDisp(.rdi, disp: 8)
            var ops: [X86Operand] = []
            var suffix: X86OperandSize = .unsized

            switch desc.operandFormat {
            case .implied:
                ops = []

            case .opcodePlusReg(let rc):
                ops = [.reg(sampleReg(rc, index: 3))]

            case .opcodePlusRegWithAcc(let rc):
                ops = [.reg(sampleReg(rc, index: 3)), .reg(X86Reg.gpr(size: desc.operandSize, hw: 0))]

            case .immToOpcodePlusReg(let rc, let immSz):
                let immVal: Int64 = (immSz == .qword) ? 0x1122334455667788 : 42
                ops = [.imm(immVal), .reg(sampleReg(rc, index: 2))]

            case .rm(let rmKind):
                switch rmKind {
                case .gprOrMem, .gprOnly:
                    let rc: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
                    ops = [.reg(sampleReg(rc, index: 1))]
                case .memOnly:
                    ops = [.mem(sampleMem)]
                    if (desc.operandSize == .word || desc.operandSize == .qword) && !desc.hasImplicitSizeMnemonic {
                        suffix = desc.operandSize
                    }
                case .indirectRegOrMem:
                    ops = [.indirectReg(.r9)]
                case .indirectMemOnly:
                    ops = [.indirectMem(sampleMem)]
                }

            case .regToRm(let regClass, let rmClass):
                let useMemDest = (desc.opcode == 0xD6) ||
                    (desc.encodingKind == .vex && (desc.opcode == 0x29 || desc.opcode == 0x11 || desc.opcode == 0x7F)) ||
                    (desc.encodingKind == .legacy && desc.opcodeMap == .map0F && (desc.opcode == 0x29 || desc.opcode == 0x11 || desc.opcode == 0x7F))
                let rmOp: X86Operand = useMemDest ? .mem(sampleMem) : .reg(sampleReg(rmClass, index: 2))
                ops = [.reg(sampleReg(regClass, index: 1)), rmOp]

            case .rmToReg(let rmClass, let regClass):
                let useMemSrc = (desc.opcodeMap == .primary) ||
                    (desc.encodingKind == .vex && (desc.mnemonic == "vmovss" || desc.mnemonic == "vmovsd"))
                let rmOp: X86Operand = useMemSrc ? .mem(sampleMem) : .reg(sampleReg(rmClass, index: 1))
                ops = [rmOp, .reg(sampleReg(regClass, index: 2))]

            case .immToRm(let rmClass, let immSz):
                let isMovMemOnly = (desc.mnemonic == "mov" && desc.operandSize != .qword)
                let rmOp: X86Operand = isMovMemOnly ? .mem(sampleMem) : .reg(sampleReg(rmClass, index: 1))
                if isMovMemOnly { suffix = desc.operandSize }
                let immVal: Int64
                if immSz == .byte {
                    immVal = 5
                } else if immSz == .word {
                    immVal = 0x1234
                } else {
                    immVal = (desc.mnemonic == "mov" && desc.operandSize == .qword) ? 0x1111 : 0x123456
                }
                ops = [.imm(immVal), rmOp]

            case .immToAcc(let immSz):
                let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : (desc.operandSize == .dword ? .eax : .rax))
                let immVal: Int64 = immSz == .byte ? 7 : (immSz == .word ? 0x1234 : 0x123456)
                ops = [.imm(immVal), .reg(acc)]

            case .shiftBy1:
                let rc: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
                ops = [.imm(1), .reg(sampleReg(rc, index: 2))]

            case .shiftByCl:
                let rc: X86RegClass = desc.operandSize == .byte ? .gpr8 : (desc.operandSize == .word ? .gpr16 : (desc.operandSize == .dword ? .gpr32 : .gpr64))
                ops = [.reg(.cl), .reg(sampleReg(rc, index: 2))]

            case .immRmToReg(let rmClass, let regClass, let immSz):
                let immVal: Int64 = immSz == .byte ? 3 : (immSz == .word ? 0x1234 : 0x123456)
                ops = [.imm(immVal), .reg(sampleReg(rmClass, index: 1)), .reg(sampleReg(regClass, index: 2))]

            case .immRegToRm(let regClass, let rmClass, _):
                ops = [.imm(2), .reg(sampleReg(regClass, index: 1)), .reg(sampleReg(rmClass, index: 2))]

            case .vexRmVvvvReg(let rmClass, let vvvvClass, let regClass):
                ops = [.reg(sampleReg(rmClass, index: 3)), .reg(sampleReg(vvvvClass, index: 2)), .reg(sampleReg(regClass, index: 1))]

            case .vexImmRmVvvvReg(let rmClass, let vvvvClass, let regClass):
                ops = [.imm(0x11), .reg(sampleReg(rmClass, index: 3)), .reg(sampleReg(vvvvClass, index: 2)), .reg(sampleReg(regClass, index: 1))]

            case .vexVvvvRmReg(let vvvvClass, let rmClass, let regClass):
                ops = [.reg(sampleReg(vvvvClass, index: 3)), .reg(sampleReg(rmClass, index: 2)), .reg(sampleReg(regClass, index: 1))]

            case .vexRmToVvvv(let rmClass, let vvvvClass):
                ops = [.reg(sampleReg(rmClass, index: 2)), .reg(sampleReg(vvvvClass, index: 1))]

            case .vexImmRmToVvvv(let rmClass, let vvvvClass):
                ops = [.imm(3), .reg(sampleReg(rmClass, index: 2)), .reg(sampleReg(vvvvClass, index: 1))]

            case .vexRegVvvvToRm(let regClass, let vvvvClass, let rmClass):
                let rmOp: X86Operand = desc.rmConstraint == .regOnly ? .reg(sampleReg(rmClass, index: 3)) : .mem(sampleMem)
                ops = [.reg(sampleReg(regClass, index: 1)), .reg(sampleReg(vvvvClass, index: 2)), rmOp]

            case .vexIs4RmVvvvReg(let rmClass, let vvvvClass, let regClass):
                ops = [.reg(sampleReg(regClass, index: 4)), .reg(sampleReg(rmClass, index: 3)), .reg(sampleReg(vvvvClass, index: 2)), .reg(sampleReg(regClass, index: 1))]

            case .vexVsib(let vvvvClass, let indexClass, let regClass):
                let vsib = X86Mem(base: .rdi, index: sampleReg(indexClass, index: 5), scale: 4, disp: 8)
                ops = [.reg(sampleReg(vvvvClass, index: 2)), .mem(vsib), .reg(sampleReg(regClass, index: 1))]

            case .xmm0RmToReg(let rmClass, let regClass):
                ops = [.reg(.xmm0), .reg(sampleReg(rmClass, index: 2)), .reg(sampleReg(regClass, index: 1))]

            case .relBranch(let relSz):
                let targetVal: Int64 = (relSz == .byte) ? 16 : 0x1000
                ops = [.relTarget(targetVal)]

            case .immOnly(let immSz):
                let immVal: Int64 = (immSz == .byte) ? 12 : 0x1000
                ops = [.imm(immVal)]

            case .segToRm:
                ops = [.reg(.ds), desc.rmConstraint == .memOnly ? .mem(sampleMem) : .reg(sampleReg(desc.operandSize.gprClass ?? .gpr32))]
                if desc.rmConstraint == .memOnly { suffix = desc.operandSize }

            case .rmToSeg:
                ops = [.reg(sampleReg(desc.operandSize.gprClass ?? .gpr32)), .reg(.ds)]

            case .crToReg:
                ops = [.reg(.cr4), .reg(.rax)]

            case .regToCr:
                ops = [.reg(.rax), .reg(.cr4)]

            case .drToReg:
                ops = [.reg(.dr6), .reg(.rax)]

            case .regToDr:
                ops = [.reg(.rsi), .reg(.dr6)]

            case .ioDxToAcc:
                let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
                ops = [.reg(.dx), .reg(acc)]

            case .ioAccToDx:
                let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
                ops = [.reg(acc), .reg(.dx)]

            case .ioImmToAcc:
                let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
                ops = [.imm(0x60), .reg(acc)]

            case .ioAccToImm:
                let acc: X86Reg = desc.operandSize == .byte ? .al : (desc.operandSize == .word ? .ax : .eax)
                ops = [.reg(acc), .imm(0x60)]
            }

            // Respect register-only / memory-only `r/m` forms.
            if let slot = desc.operandFormat.rmSlot(operandCount: ops.count), slot.index < ops.count {
                switch desc.rmConstraint {
                case .memOnly:
                    if case .reg = ops[slot.index] { ops[slot.index] = .mem(sampleMem) }
                case .regOnly:
                    if case .mem = ops[slot.index], let rc = slot.rmClass { ops[slot.index] = .reg(sampleReg(rc, index: 3)) }
                case .any:
                    break
                }
            }
            let inst = X86Instruction(mnemonic: desc.memMnemonic ?? desc.mnemonic, sizeSuffix: suffix, operands: ops, codeMode: mode)
            let encoded = try encoder.encode(inst)
            let (decoded, len) = try disassembler.disassembleOne(encoded.bytes, at: 0, codeMode: mode)
            let reencoded = try encoder.encode(decoded)

            guard len == encoded.bytes.count && reencoded.bytes == encoded.bytes else {
                throw X86CodecError.invalidOperands(mnemonic: desc.mnemonic, operands: ops)
            }
            results.append((mnemonic: desc.mnemonic, bytes: encoded.bytes, disassembled: decoded.attString))
        }

        // Additional special-case addressing & prefix round-trip checks from todhchai/croi .S files
        let specialCases: [X86Instruction] = [
            // %rsp base (SIB 0x24)
            X86Instruction(mnemonic: "mov", operands: [.mem(.baseDisp(.rsp, disp: 8)), .reg(.r9)]),
            // %rbp base with disp == 0 (mod=1, disp8=0)
            X86Instruction(mnemonic: "mov", operands: [.mem(.baseDisp(.rbp, disp: 0)), .reg(.rax)]),
            // Scale-index with no base: lea (, %rbx, 8), %rax
            X86Instruction(mnemonic: "lea", operands: [.mem(X86Mem(base: nil, index: .rbx, scale: 8, disp: 0)), .reg(.rax)]),
            // Segment override %fs:0 and %gs:disp
            X86Instruction(mnemonic: "mov", operands: [.mem(.absolute(disp: 0, segment: 0x64)), .reg(.rax)]),
            X86Instruction(mnemonic: "mov", operands: [.mem(.absolute(disp: 16, segment: 0x65)), .reg(.rax)]),
            // RIP-relative: lea disp(%rip), %rax
            X86Instruction(mnemonic: "lea", operands: [.mem(.ripRelative(disp: 64)), .reg(.rax)]),
            // Mandatory REX 8-bit registers (%spl, %bpl, %sil, %dil) and high 8-bit (%ah, %ch, %dh, %bh)
            X86Instruction(mnemonic: "mov", operands: [.reg(.sil), .reg(.dil)]),
            X86Instruction(mnemonic: "mov", operands: [.reg(.ah), .reg(.al)]),
            // Lock prefix & Rep prefix
            X86Instruction(mnemonic: "cmpxchg", operands: [.reg(.rcx), .mem(.baseDisp(.rdi, disp: 0))], lockPrefix: true),
            X86Instruction(mnemonic: "movsb", repPrefix: .rep),
            X86Instruction(mnemonic: "stosb", repPrefix: .rep),
            // 3-byte VEX with extended XMM/YMM registers (%xmm10, %ymm12)
            X86Instruction(mnemonic: "vaddps", operands: [.reg(.xmm10), .reg(.xmm9), .reg(.xmm8)]),
            X86Instruction(mnemonic: "vaddps", operands: [.reg(.ymm12), .reg(.ymm11), .reg(.ymm10)])
        ]

        for sc in specialCases {
            let encoded = try encoder.encode(sc)
            let (decoded, len) = try disassembler.disassembleOne(encoded.bytes, at: 0, codeMode: sc.codeMode)
            let reencoded = try encoder.encode(decoded)
            guard len == encoded.bytes.count && reencoded.bytes == encoded.bytes else {
                throw X86CodecError.invalidOperands(mnemonic: sc.mnemonic, operands: sc.operands)
            }
            results.append((mnemonic: sc.mnemonic, bytes: encoded.bytes, disassembled: decoded.attString))
        }

        return results
    }
}

extension X86InstrDesc {
    /// Mnemonics whose name already fixes the operand size (`cmpxchg16b`, `fxsave64`, `xsave64`, ...);
    /// AT&T syntax never adds a `b`/`w`/`l`/`q` suffix to them.
    @inlinable
    var hasImplicitSizeMnemonic: Bool {
        mnemonic.hasSuffix("64") || mnemonic == "cmpxchg8b" || mnemonic == "cmpxchg16b"
            || mnemonic == "movd" || mnemonic == "vmovd" || (mnemonic.hasPrefix("set") && operandSize == .byte)
    }

    /// True if AT&T syntax needs a `b`/`w`/`l`/`q` suffix to fix the operand size of `operands`: no
    /// operand that sets the size is a general-purpose register (`addl $1, (%rax)`, `pushq (%rax)`).
    public func needsSizeSuffix(operands: [X86Operand]) -> Bool {
        guard operandSize == .byte || operandSize == .word || operandSize == .dword || operandSize == .qword else {
            return false
        }
        if X86InstructionTable.mnemonicCarriesSize(mnemonic, operandSize) || hasImplicitSizeMnemonic || operands.isEmpty {
            return false
        }
        // `%cl` (shift count) and `%dx` (port) do not determine the operand size.
        let sizing: ArraySlice<X86Operand>
        switch operandFormat {
        case .shiftByCl, .ioDxToAcc: sizing = operands.dropFirst()
        case .ioAccToDx:             sizing = operands.dropLast()
        default:                     sizing = operands[...]
        }
        return !sizing.contains { op in
            if case .reg(let r) = op, r.isGPR { return true }
            return false
        }
    }

    /// True if an 8-bit immediate is zero-extended (shift/rotate counts, bit indices, SIMD selectors and
    /// predicates). Such immediates accept -128...255 and disassemble as 0...255; the others are sign-extended.
    @inlinable
    var imm8IsZeroExtended: Bool {
        switch opcodeMap {
        case .map0F, .map0F38, .map0F3A: return true
        case .primary: return opcode == 0xC0 || opcode == 0xC1 || opcode == 0xCD
        }
    }

    /// True if the operand size is selected with the legacy 0x66 override (rather than a mandatory 0x66 prefix).
    @inlinable
    var usesOperandSizeOverride: Bool {
        guard !suppressOperandSizePrefix else { return false }
        switch mandatoryPrefix {
        case .none, .pF3, .pF2: return true
        case .p66, .p66F2:      return false
        }
    }
}

extension X86OperandFormat {
    /// Position of the ModR/M `r/m` operand among `operandCount` AT&T operands, with its register class
    /// (`nil` when the class follows the descriptor's operand size), or `nil` if the format has no `r/m`.
    public func rmSlot(operandCount: Int) -> (index: Int, rmClass: X86RegClass?)? {
        switch self {
        case .rm:                                  return (0, nil)
        case .regToRm(_, let rc):                  return (1, rc)
        case .rmToReg(let rc, _):                  return (0, rc)
        case .immToRm(let rc, _):                  return (1, rc)
        case .shiftBy1:                            return (operandCount - 1, nil)
        case .shiftByCl:                           return (1, nil)
        case .immRmToReg(let rc, _, _):            return (1, rc)
        case .immRegToRm(_, let rc, _):            return (2, rc)
        case .vexRmVvvvReg(let rc, _, _):          return (0, rc)
        case .vexImmRmVvvvReg(let rc, _, _):       return (1, rc)
        case .vexVvvvRmReg(_, let rc, _):          return (1, rc)
        case .vexRmToVvvv(let rc, _):              return (0, rc)
        case .vexImmRmToVvvv(let rc, _):           return (1, rc)
        case .vexRegVvvvToRm(_, _, let rc):        return (2, rc)
        case .vexIs4RmVvvvReg(let rc, _, _):       return (1, rc)
        case .vexVsib:                             return (1, nil)
        case .xmm0RmToReg(let rc, _):              return (operandCount - 2, rc)
        case .segToRm:                             return (1, nil)
        case .rmToSeg:                             return (0, nil)
        default:                                   return nil
        }
    }

    /// True if the format encodes an operand in VEX.vvvv (all others require VEX.vvvv = 1111b).
    @inlinable
    var usesVvvv: Bool {
        switch self {
        case .vexRmVvvvReg, .vexImmRmVvvvReg, .vexVvvvRmReg, .vexRmToVvvv, .vexImmRmToVvvv,
             .vexRegVvvvToRm, .vexIs4RmVvvvReg, .vexVsib:
            return true
        default:
            return false
        }
    }
}

extension X86Operand {
    /// True for a (non-indirect) memory operand.
    @inlinable
    public var isMemory: Bool {
        if case .mem = self { return true }
        return false
    }
}
