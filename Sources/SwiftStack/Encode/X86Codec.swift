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
        if sizeSuffix != .unsized && !mnemonic.hasSuffix(sizeSuffix.attSuffix) {
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

/// Operand encoding template for an `X86InstrDesc`.
@frozen
public enum X86OperandFormat: Sendable, Equatable, Hashable {
    /// 0 operands (`ret`, `syscall`, `ud2`, `cpuid`, `vzeroupper`, etc.).
    case implied
    /// 1 register encoded in `opcode + (reg & 7)` (`push %reg`, `pop %reg`, `bswap %reg`).
    case opcodePlusReg(X86RegClass)
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
    /// 4-operand VEX `$imm8, src2_rm, src1_vvvv, dst_reg` (`vpclmulqdq`).
    case vexImmRmVvvvReg(rmClass: X86RegClass, vvvvClass: X86RegClass, regClass: X86RegClass)
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
        operandFormat: X86OperandFormat
    ) {
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

    /// All instruction descriptors in priority order.
    public static let descriptors: [X86InstrDesc] = buildDescriptors()

    /// Lookup table mapping lowercase mnemonic (and sized/alias variants) to indices into `descriptors`.
    public static let mnemonicMap: [String: [Int]] = {
        var map: [String: [Int]] = [:]
        for (idx, desc) in descriptors.enumerated() {
            map[desc.mnemonic, default: []].append(idx)
            if desc.operandSize != .unsized {
                let suffixed = desc.mnemonic + desc.operandSize.attSuffix
                if suffixed != desc.mnemonic {
                    map[suffixed, default: []].append(idx)
                }
            }
            for alias in desc.aliases {
                map[alias, default: []].append(idx)
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

        // MOV segment, control, debug registers
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movw", "movl", "movq"],
            opcode: 0x8C,
            suppressOperandSizePrefix: true,
            operandFormat: .segToRm
        ))
        list.append(X86InstrDesc(
            mnemonic: "mov",
            aliases: ["movw", "movl", "movq"],
            opcode: 0x8E,
            suppressOperandSizePrefix: true,
            operandFormat: .rmToSeg
        ))
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
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .qword, opcode: 0x8D, rexW: true, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .gpr64)))
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .dword, opcode: 0x8D, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .gpr32)))
        list.append(X86InstrDesc(mnemonic: "lea", operandSize: .word, opcode: 0x8D, operandFormat: .rmToReg(rmClass: .gpr16, regClass: .gpr16)))

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

        // XCHG, CMPXCHG, CMPXCHG16B, BSWAP
        for (sz, rc, w) in gprSizes {
            list.append(X86InstrDesc(
                mnemonic: "xchg",
                operandSize: sz,
                opcode: sz == .byte ? 0x86 : 0x87,
                rexW: w,
                operandFormat: .regToRm(regClass: rc, rmClass: rc)
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

        list.append(X86InstrDesc(mnemonic: "str", aliases: ["strw"], operandSize: .word, opcodeMap: .map0F, opcode: 0x00, modrmSlash: 1, operandFormat: .rm(.gprOrMem)))
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
        // 4.7 SSE & AVX (VEX) Vector / Scalar Instructions (04-backend.md §4.9)
        // -----------------------------------------------------------------

        // Vector Moves: load (r/m -> reg) and store (reg -> r/m)
        let vecMoves: [(name: String, prefix: X86MandatoryPrefix, loadOp: UInt8, storeOp: UInt8)] = [
            ("movaps", .none, 0x28, 0x29),
            ("movups", .none, 0x10, 0x11),
            ("movapd", .p66,  0x28, 0x29),
            ("movupd", .p66,  0x10, 0x11),
            ("movdqa", .p66,  0x6F, 0x7F),
            ("movdqu", .pF3,  0x6F, 0x7F)
        ]
        for vm in vecMoves {
            // Legacy SSE (128-bit XMM)
            list.append(X86InstrDesc(mnemonic: vm.name, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.loadOp, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vm.name, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.storeOp, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))
            // VEX 128-bit (XMM) and 256-bit (YMM)
            let vName = "v" + vm.name
            list.append(X86InstrDesc(mnemonic: vName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.loadOp, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.storeOp, vexL: 0, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vName, operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.loadOp, vexL: 1, operandFormat: .rmToReg(rmClass: .ymm, regClass: .ymm)))
            list.append(X86InstrDesc(mnemonic: vName, operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: vm.prefix, opcode: vm.storeOp, vexL: 1, operandFormat: .regToRm(regClass: .ymm, rmClass: .ymm)))
        }

        // Scalar FP Moves: movss/vmovss, movsd/vmovsd
        for (scName, scPref) in [("movss", X86MandatoryPrefix.pF3), ("movsd", X86MandatoryPrefix.pF2)] {
            list.append(X86InstrDesc(mnemonic: scName, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: scPref, opcode: 0x10, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: scName, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: scPref, opcode: 0x11, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))
            let vScName = "v" + scName
            list.append(X86InstrDesc(mnemonic: vScName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: scPref, opcode: 0x10, vexL: 0, operandFormat: .vexRmVvvvReg(rmClass: .xmm, vvvvClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vScName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: scPref, opcode: 0x10, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vScName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: scPref, opcode: 0x11, vexL: 0, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))
        }

        // MOVD / VMOVD and MOVQ / VMOVQ (GPR <-> XMM and XMM <-> XMM)
        list.append(X86InstrDesc(mnemonic: "movd", operandSize: .dword, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x6E, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "movd", operandSize: .dword, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x7E, operandFormat: .regToRm(regClass: .xmm, rmClass: .gpr32)))
        list.append(X86InstrDesc(mnemonic: "vmovd", operandSize: .dword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x6E, vexL: 0, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "vmovd", operandSize: .dword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x7E, vexL: 0, operandFormat: .regToRm(regClass: .xmm, rmClass: .gpr32)))

        list.append(X86InstrDesc(mnemonic: "movq", aliases: ["mov"], operandSize: .qword, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x6E, rexW: true, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "movq", aliases: ["mov"], operandSize: .qword, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x7E, rexW: true, operandFormat: .regToRm(regClass: .xmm, rmClass: .gpr64)))
        list.append(X86InstrDesc(mnemonic: "movq", operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: .pF3, opcode: 0x7E, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "movq", operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0xD6, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))

        list.append(X86InstrDesc(mnemonic: "vmovq", operandSize: .qword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x6E, rexW: true, vexL: 0, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "vmovq", operandSize: .qword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x7E, rexW: true, vexL: 0, operandFormat: .regToRm(regClass: .xmm, rmClass: .gpr64)))
        list.append(X86InstrDesc(mnemonic: "vmovq", operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .pF3, opcode: 0x7E, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "vmovq", operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0xD6, vexL: 0, operandFormat: .regToRm(regClass: .xmm, rmClass: .xmm)))

        // Packed Binary SSE / VEX (128-bit XMM & 256-bit YMM)
        let packedBinOps: [(name: String, map: X86OpcodeMap, prefix: X86MandatoryPrefix, op: UInt8)] = [
            ("addps",    .map0F,   .none, 0x58),
            ("subps",    .map0F,   .none, 0x5C),
            ("mulps",    .map0F,   .none, 0x59),
            ("divps",    .map0F,   .none, 0x5E),
            ("addpd",    .map0F,   .p66,  0x58),
            ("subpd",    .map0F,   .p66,  0x5C),
            ("mulpd",    .map0F,   .p66,  0x59),
            ("divpd",    .map0F,   .p66,  0x5E),
            ("maxps",    .map0F,   .none, 0x5F),
            ("minps",    .map0F,   .none, 0x5D),
            ("andps",    .map0F,   .none, 0x54),
            ("orps",     .map0F,   .none, 0x56),
            ("xorps",    .map0F,   .none, 0x57),
            ("pxor",     .map0F,   .p66,  0xEF),
            ("por",      .map0F,   .p66,  0xEB),
            ("pand",     .map0F,   .p66,  0xDB),
            ("pandn",    .map0F,   .p66,  0xDF),
            ("paddb",    .map0F,   .p66,  0xFC),
            ("paddw",    .map0F,   .p66,  0xFD),
            ("paddd",    .map0F,   .p66,  0xFE),
            ("paddq",    .map0F,   .p66,  0xD4),
            ("psubb",    .map0F,   .p66,  0xF8),
            ("psubw",    .map0F,   .p66,  0xF9),
            ("psubd",    .map0F,   .p66,  0xFA),
            ("psubq",    .map0F,   .p66,  0xFB),
            ("pmullw",   .map0F,   .p66,  0xD5),
            ("pmulld",   .map0F38, .p66,  0x40),
            ("pshufb",   .map0F38, .p66,  0x00),
            ("pcmpeqb",  .map0F,   .p66,  0x74),
            ("pcmpeqd",  .map0F,   .p66,  0x76),
            ("pcmpgtb",  .map0F,   .p66,  0x64),
            ("pcmpgtd",  .map0F,   .p66,  0x66)
        ]
        for pb in packedBinOps {
            // Legacy SSE (2-operand XMM)
            list.append(X86InstrDesc(
                mnemonic: pb.name,
                operandSize: .xmm128,
                opcodeMap: pb.map,
                mandatoryPrefix: pb.prefix,
                opcode: pb.op,
                operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)
            ))
            // VEX 128-bit (3-operand XMM) & 256-bit (3-operand YMM)
            let vName = "v" + pb.name
            list.append(X86InstrDesc(
                mnemonic: vName,
                operandSize: .xmm128,
                encodingKind: .vex,
                opcodeMap: pb.map,
                mandatoryPrefix: pb.prefix,
                opcode: pb.op,
                vexL: 0,
                operandFormat: .vexRmVvvvReg(rmClass: .xmm, vvvvClass: .xmm, regClass: .xmm)
            ))
            list.append(X86InstrDesc(
                mnemonic: vName,
                operandSize: .ymm256,
                encodingKind: .vex,
                opcodeMap: pb.map,
                mandatoryPrefix: pb.prefix,
                opcode: pb.op,
                vexL: 1,
                operandFormat: .vexRmVvvvReg(rmClass: .ymm, vvvvClass: .ymm, regClass: .ymm)
            ))
        }

        // Scalar Binary FP SSE (2-op) / VEX (3-op)
        let scalarBinOps: [(name: String, prefix: X86MandatoryPrefix, op: UInt8)] = [
            ("addss",  .pF3, 0x58),
            ("subss",  .pF3, 0x5C),
            ("mulss",  .pF3, 0x59),
            ("divss",  .pF3, 0x5E),
            ("addsd",  .pF2, 0x58),
            ("subsd",  .pF2, 0x5C),
            ("mulsd",  .pF2, 0x59),
            ("divsd",  .pF2, 0x5E),
            ("sqrtss", .pF3, 0x51),
            ("sqrtsd", .pF2, 0x51),
            ("cvtss2sd", .pF3, 0x5A),
            ("cvtsd2ss", .pF2, 0x5A)
        ]
        for sb in scalarBinOps {
            list.append(X86InstrDesc(
                mnemonic: sb.name,
                operandSize: .xmm128,
                opcodeMap: .map0F,
                mandatoryPrefix: sb.prefix,
                opcode: sb.op,
                operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)
            ))
            list.append(X86InstrDesc(
                mnemonic: "v" + sb.name,
                operandSize: .xmm128,
                encodingKind: .vex,
                opcodeMap: .map0F,
                mandatoryPrefix: sb.prefix,
                opcode: sb.op,
                vexL: 0,
                operandFormat: .vexRmVvvvReg(rmClass: .xmm, vvvvClass: .xmm, regClass: .xmm)
            ))
        }

        // Unary Packed SQRT: sqrtps/vsqrtps, sqrtpd/vsqrtpd (2-operand in both SSE and VEX)
        for (sqName, sqPref) in [("sqrtps", X86MandatoryPrefix.none), ("sqrtpd", X86MandatoryPrefix.p66)] {
            list.append(X86InstrDesc(mnemonic: sqName, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: sqPref, opcode: 0x51, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: "v" + sqName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: sqPref, opcode: 0x51, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: "v" + sqName, operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: sqPref, opcode: 0x51, vexL: 1, operandFormat: .rmToReg(rmClass: .ymm, regClass: .ymm)))
        }

        // UCOMISS / VUCOMISS, UCOMISD / VUCOMISD (2-operand in both SSE and VEX)
        for (ucName, ucPref) in [("ucomiss", X86MandatoryPrefix.none), ("ucomisd", X86MandatoryPrefix.p66)] {
            list.append(X86InstrDesc(mnemonic: ucName, operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: ucPref, opcode: 0x2E, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: "v" + ucName, operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: ucPref, opcode: 0x2E, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
        }

        // PSHUFD / VPSHUFD ($imm8, r/m, dst)
        list.append(X86InstrDesc(mnemonic: "pshufd", operandSize: .xmm128, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x70, operandFormat: .immRmToReg(rmClass: .xmm, regClass: .xmm, immSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "vpshufd", operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x70, vexL: 0, operandFormat: .immRmToReg(rmClass: .xmm, regClass: .xmm, immSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "vpshufd", operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .p66, opcode: 0x70, vexL: 1, operandFormat: .immRmToReg(rmClass: .ymm, regClass: .ymm, immSize: .byte)))

        // CVTSI2SS / VCVTSI2SS, CVTSI2SD / VCVTSI2SD (32-bit and 64-bit GPR/mem)
        for (cvName, cvPref) in [("cvtsi2ss", X86MandatoryPrefix.pF3), ("cvtsi2sd", X86MandatoryPrefix.pF2)] {
            list.append(X86InstrDesc(mnemonic: cvName, aliases: [cvName + "l"], operandSize: .dword, opcodeMap: .map0F, mandatoryPrefix: cvPref, opcode: 0x2A, operandFormat: .rmToReg(rmClass: .gpr32, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: cvName, aliases: [cvName + "q"], operandSize: .qword, opcodeMap: .map0F, mandatoryPrefix: cvPref, opcode: 0x2A, rexW: true, operandFormat: .rmToReg(rmClass: .gpr64, regClass: .xmm)))
            let vCvName = "v" + cvName
            list.append(X86InstrDesc(mnemonic: vCvName, aliases: [vCvName + "l"], operandSize: .dword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: cvPref, opcode: 0x2A, rexW: false, vexL: 0, operandFormat: .vexRmVvvvReg(rmClass: .gpr32, vvvvClass: .xmm, regClass: .xmm)))
            list.append(X86InstrDesc(mnemonic: vCvName, aliases: [vCvName + "q"], operandSize: .qword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: cvPref, opcode: 0x2A, rexW: true, vexL: 0, operandFormat: .vexRmVvvvReg(rmClass: .gpr64, vvvvClass: .xmm, regClass: .xmm)))
        }

        // CVTTSS2SI / VCVTTSS2SI, CVTTSD2SI / VCVTTSD2SI (to 32-bit or 64-bit GPR)
        for (ctName, ctPref) in [("cvttss2si", X86MandatoryPrefix.pF3), ("cvttsd2si", X86MandatoryPrefix.pF2)] {
            list.append(X86InstrDesc(mnemonic: ctName, aliases: [ctName + "l"], operandSize: .dword, opcodeMap: .map0F, mandatoryPrefix: ctPref, opcode: 0x2C, operandFormat: .rmToReg(rmClass: .xmm, regClass: .gpr32)))
            list.append(X86InstrDesc(mnemonic: ctName, aliases: [ctName + "q"], operandSize: .qword, opcodeMap: .map0F, mandatoryPrefix: ctPref, opcode: 0x2C, rexW: true, operandFormat: .rmToReg(rmClass: .xmm, regClass: .gpr64)))
            let vCtName = "v" + ctName
            list.append(X86InstrDesc(mnemonic: vCtName, aliases: [vCtName + "l"], operandSize: .dword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: ctPref, opcode: 0x2C, rexW: false, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .gpr32)))
            list.append(X86InstrDesc(mnemonic: vCtName, aliases: [vCtName + "q"], operandSize: .qword, encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: ctPref, opcode: 0x2C, rexW: true, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .gpr64)))
        }

        // VZEROUPPER, VZEROALL
        list.append(X86InstrDesc(mnemonic: "vzeroupper", encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .none, opcode: 0x77, vexL: 0, operandFormat: .implied))
        list.append(X86InstrDesc(mnemonic: "vzeroall", encodingKind: .vex, opcodeMap: .map0F, mandatoryPrefix: .none, opcode: 0x77, vexL: 1, operandFormat: .implied))

        // AES-NI (VEX) & PCLMULQDQ (VEX) & F16C (VEX)
        let aesOps: [(name: String, op: UInt8)] = [
            ("vaesenc",     0xDC),
            ("vaesenclast", 0xDD),
            ("vaesdec",     0xDE),
            ("vaesdeclast", 0xDF)
        ]
        for aes in aesOps {
            list.append(X86InstrDesc(
                mnemonic: aes.name,
                operandSize: .xmm128,
                encodingKind: .vex,
                opcodeMap: .map0F38,
                mandatoryPrefix: .p66,
                opcode: aes.op,
                vexL: 0,
                operandFormat: .vexRmVvvvReg(rmClass: .xmm, vvvvClass: .xmm, regClass: .xmm)
            ))
        }
        list.append(X86InstrDesc(
            mnemonic: "vpclmulqdq",
            operandSize: .xmm128,
            encodingKind: .vex,
            opcodeMap: .map0F3A,
            mandatoryPrefix: .p66,
            opcode: 0x44,
            vexL: 0,
            operandFormat: .vexImmRmVvvvReg(rmClass: .xmm, vvvvClass: .xmm, regClass: .xmm)
        ))

        // F16C: vcvtph2ps, vcvtps2ph
        list.append(X86InstrDesc(mnemonic: "vcvtph2ps", operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F38, mandatoryPrefix: .p66, opcode: 0x13, vexL: 0, operandFormat: .rmToReg(rmClass: .xmm, regClass: .xmm)))
        list.append(X86InstrDesc(mnemonic: "vcvtph2ps", operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F38, mandatoryPrefix: .p66, opcode: 0x13, vexL: 1, operandFormat: .rmToReg(rmClass: .xmm, regClass: .ymm)))
        list.append(X86InstrDesc(mnemonic: "vcvtps2ph", operandSize: .xmm128, encodingKind: .vex, opcodeMap: .map0F3A, mandatoryPrefix: .p66, opcode: 0x1D, vexL: 0, operandFormat: .immRegToRm(regClass: .xmm, rmClass: .xmm, immSize: .byte)))
        list.append(X86InstrDesc(mnemonic: "vcvtps2ph", operandSize: .ymm256, encodingKind: .vex, opcodeMap: .map0F3A, mandatoryPrefix: .p66, opcode: 0x1D, vexL: 1, operandFormat: .immRegToRm(regClass: .ymm, rmClass: .xmm, immSize: .byte)))

        return list
    }
}

// MARK: - 5. Table-Driven x86-64 Encoder (X86TableEncoder)

/// Encodes structured `X86Instruction` values into machine code bytes and relocations using `X86InstructionTable`.
public struct X86TableEncoder: Sendable {

    public init() {}

    /// Encodes a single `X86Instruction`.
    public func encode(_ instruction: X86Instruction) throws -> X86EncodedInstruction {
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

        // Resolve candidate descriptors
        let (candidates, explicitSize) = try resolveCandidates(for: inst)
        for descIdx in candidates {
            let desc = X86InstructionTable.descriptors[descIdx]
            if let encoded = try tryEncode(inst: inst, desc: desc, explicitSize: explicitSize) {
                return encoded
            }
        }

        throw X86CodecError.invalidOperands(mnemonic: inst.mnemonic, operands: inst.operands)
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
                    // Also include any direct entries for `mnem` (e.g. `movslq`, `sysretq`, `iretq`, `lgdtl`)
                    if let direct = X86InstructionTable.mnemonicMap[mnem] {
                        var combined = matchingBase
                        for dIdx in direct where !combined.contains(dIdx) {
                            let d = X86InstructionTable.descriptors[dIdx]
                            if d.operandSize == suffixSize || d.operandSize == .unsized || d.mnemonic == mnem {
                                combined.insert(dIdx, at: 0)
                            }
                        }
                        return (combined, suffixSize)
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
            // Allow crc32q/crc32b/movzbl etc. when mnemonic explicitly matches desc.mnemonic
            if desc.mnemonic != inst.mnemonic && !desc.aliases.contains(inst.mnemonic) {
                return nil
            }
        }

        let ops = inst.operands
        let mode = inst.codeMode

        let rexW = desc.rexW
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
        func encodeRM(_ operand: X86Operand, regField: UInt8, expectedClass: X86RegClass?, rmKind: X86RMKind = .gprOrMem) throws -> Bool {
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

        func encodeMemory(_ m: X86Mem, regField: UInt8) throws -> Bool {
            hasModRM = true
            if let seg = m.segment {
                segmentOverride = seg
            }

            // Check address size override
            if let base = m.base, base != .rip {
                if mode == .mode64 && base.regClass == .gpr32 {
                    addressSizeOverride = true
                } else if mode == .mode16 && base.regClass == .gpr32 {
                    addressSizeOverride = true
                }
            }
            if let index = m.index {
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
                if targetSize != .byte {
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
            // For vmovss/vmovsd 3-operand form, require register as first operand
            if (desc.mnemonic == "vmovss" || desc.mnemonic == "vmovsd"), case .mem = ops[0] {
                return nil
            }
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
            guard try encodeRM(ops[1], regField: segReg.hwEncoding, expectedClass: nil) else { return nil }

        case .rmToSeg:
            guard ops.count == 2, case .reg(let segReg) = ops[1], segReg.regClass == .seg else { return nil }
            guard try encodeRM(ops[0], regField: segReg.hwEncoding, expectedClass: nil) else { return nil }

        case .crToReg:
            guard ops.count == 2,
                  case .reg(let crReg) = ops[0], crReg.regClass == .cr,
                  case .reg(let gprReg) = ops[1], (gprReg.regClass == .gpr64 || gprReg.regClass == .gpr32) else { return nil }
            hasModRM = true
            if crReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (crReg.low3 << 3) | gprReg.low3

        case .regToCr:
            guard ops.count == 2,
                  case .reg(let gprReg) = ops[0], (gprReg.regClass == .gpr64 || gprReg.regClass == .gpr32),
                  case .reg(let crReg) = ops[1], crReg.regClass == .cr else { return nil }
            hasModRM = true
            if crReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (crReg.low3 << 3) | gprReg.low3

        case .drToReg:
            guard ops.count == 2,
                  case .reg(let drReg) = ops[0], drReg.regClass == .dr,
                  case .reg(let gprReg) = ops[1], (gprReg.regClass == .gpr64 || gprReg.regClass == .gpr32) else { return nil }
            hasModRM = true
            if drReg.needsRexExtension { rexR = true }
            if gprReg.needsRexExtension { rexB = true }
            modrmByte = (0x03 << 6) | (drReg.low3 << 3) | gprReg.low3

        case .regToDr:
            guard ops.count == 2,
                  case .reg(let gprReg) = ops[0], (gprReg.regClass == .gpr64 || gprReg.regClass == .gpr32),
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

        // 1. Legacy prefixes (lock, rep, segment, address size)
        if inst.lockPrefix { out.append(0xF0) }
        if inst.repPrefix != .none { out.append(inst.repPrefix.rawValue) }
        if let seg = segmentOverride { out.append(seg) }
        if addressSizeOverride { out.append(0x67) }

        if desc.encodingKind == .vex {
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
            // Legacy operand-size override prefix (0x66)
            if !desc.suppressOperandSizePrefix && desc.mandatoryPrefix == .none {
                if (mode == .mode64 || mode == .mode32) && desc.operandSize == .word {
                    out.append(0x66)
                } else if mode == .mode16 && desc.operandSize == .dword {
                    out.append(0x66)
                }
            }

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
            case .opcodePlusReg, .immToOpcodePlusReg:
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
            guard desc.vexL == vexL && desc.mandatoryPrefix.vexPP == vexPP else { return nil }
            // Check W-sensitive VEX instructions
            if desc.opcodeMap == .map0F && (desc.opcode == 0x6E || desc.opcode == 0x7E || desc.opcode == 0x2A || desc.opcode == 0x2C) {
                guard desc.rexW == rexW else { return nil }
            }
        } else {
            // Legacy mandatory prefix matching
            switch desc.mandatoryPrefix {
            case .p66F2:
                guard has66 && hasF2 && !hasF3 else { return nil }
            case .pF2:
                guard hasF2 && !has66 && !hasF3 else { return nil }
            case .pF3:
                guard hasF3 && !has66 && !hasF2 else { return nil }
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

            if desc.mandatoryPrefix == .none && !desc.suppressOperandSizePrefix {
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
        func decodeModRM(rmClass: X86RegClass?, rmKind: X86RMKind = .gprOrMem) throws -> (regBits: UInt8, rmOperand: X86Operand)? {
            guard cursor < bytes.count else { return nil }
            let modrm = bytes[cursor]
            let mod = (modrm >> 6) & 0x03
            let regField = (modrm >> 3) & 0x07
            let rmField = modrm & 0x07

            if let expectedSlash = desc.modrmSlash, regField != expectedSlash {
                return nil
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

        func decodeMemoryOperand(mod: UInt8, rmField: UInt8) throws -> X86Mem {
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
                if !rexX && idxBits == 4 {
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
            case .byte:  return Int64(try readInt8(at: &cursor))
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
            if (desc.mnemonic == "vmovss" || desc.mnemonic == "vmovsd"), case .mem = rmOp {
                return nil
            }
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [rmOp, .reg(vReg), .reg(dstReg)]

        case .vexImmRmVvvvReg(let rmClass, let vvvvClass, let regClass):
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmClass) else { return nil }
            let immVal = try readImm(size: .byte)
            let vReg = makeReg(for: vvvvClass, hw: vexVvvv, hasRex: true)
            let dstReg = makeReg(for: regClass, hw: (rexR ? 8 : 0) | regBits, hasRex: true)
            operands = [.imm(immVal), rmOp, .reg(vReg), .reg(dstReg)]

        case .relBranch(let relSz):
            let relVal = try readImm(size: relSz)
            operands = [.relTarget(relVal)]

        case .immOnly(let immSz):
            let immVal = try readImm(size: immSz)
            operands = [.imm(immVal)]

        case .segToRm:
            let rmCls: X86RegClass = codeMode == .mode16 ? .gpr16 : (rexW ? .gpr64 : .gpr32)
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmCls) else { return nil }
            guard let segReg = X86Reg.seg(regBits) else { return nil }
            operands = [.reg(segReg), rmOp]

        case .rmToSeg:
            let rmCls: X86RegClass = codeMode == .mode16 ? .gpr16 : (rexW ? .gpr64 : .gpr32)
            guard let (regBits, rmOp) = try decodeModRM(rmClass: rmCls) else { return nil }
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
        let needsSuffix: Bool = {
            guard desc.operandSize == .byte || desc.operandSize == .word || desc.operandSize == .dword || desc.operandSize == .qword else {
                return false
            }
            if desc.mnemonic.hasSuffix(desc.operandSize.attSuffix) { return false }
            let hasGPR = operands.contains { op in
                if case .reg(let r) = op, r.isGPR { return true }
                return false
            }
            return !hasGPR && !operands.isEmpty
        }()

        let inst = X86Instruction(
            mnemonic: desc.mnemonic,
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
                    if desc.operandSize == .word || desc.operandSize == .qword {
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

            case .relBranch(let relSz):
                let targetVal: Int64 = (relSz == .byte) ? 16 : 0x1000
                ops = [.relTarget(targetVal)]

            case .immOnly(let immSz):
                let immVal: Int64 = (immSz == .byte) ? 12 : 0x1000
                ops = [.imm(immVal)]

            case .segToRm:
                ops = [.reg(.ds), .reg(.eax)]

            case .rmToSeg:
                ops = [.reg(.eax), .reg(.ds)]

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

            let inst = X86Instruction(mnemonic: desc.mnemonic, sizeSuffix: suffix, operands: ops, codeMode: mode)
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
