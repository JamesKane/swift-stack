// Sources/SwiftStack/Encode/AArch64Codec.swift
import Foundation

// MARK: - 1. AArch64 Registers and Operand Types (04-backend.md §4.9, 05-assembler.md §4.7)

/// General-purpose AArch64 register identifier (0..30 for x0..x30/w0..w30, 31 for sp/wsp or xzr/wzr).
@frozen
public struct A64GPR: RawRepresentable, Equatable, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x1F
    }

    public static let x0  = A64GPR(rawValue: 0)
    public static let x1  = A64GPR(rawValue: 1)
    public static let x2  = A64GPR(rawValue: 2)
    public static let x3  = A64GPR(rawValue: 3)
    public static let x4  = A64GPR(rawValue: 4)
    public static let x5  = A64GPR(rawValue: 5)
    public static let x6  = A64GPR(rawValue: 6)
    public static let x7  = A64GPR(rawValue: 7)
    public static let x8  = A64GPR(rawValue: 8)
    public static let x9  = A64GPR(rawValue: 9)
    public static let x10 = A64GPR(rawValue: 10)
    public static let x11 = A64GPR(rawValue: 11)
    public static let x12 = A64GPR(rawValue: 12)
    public static let x13 = A64GPR(rawValue: 13)
    public static let x14 = A64GPR(rawValue: 14)
    public static let x15 = A64GPR(rawValue: 15)
    public static let x16 = A64GPR(rawValue: 16)
    public static let x17 = A64GPR(rawValue: 17)
    public static let x18 = A64GPR(rawValue: 18)
    public static let x19 = A64GPR(rawValue: 19)
    public static let x20 = A64GPR(rawValue: 20)
    public static let x21 = A64GPR(rawValue: 21)
    public static let x22 = A64GPR(rawValue: 22)
    public static let x23 = A64GPR(rawValue: 23)
    public static let x24 = A64GPR(rawValue: 24)
    public static let x25 = A64GPR(rawValue: 25)
    public static let x26 = A64GPR(rawValue: 26)
    public static let x27 = A64GPR(rawValue: 27)
    public static let x28 = A64GPR(rawValue: 28)
    public static let x29 = A64GPR(rawValue: 29)
    public static let x30 = A64GPR(rawValue: 30)
    public static let fp  = A64GPR(rawValue: 29)
    public static let lr  = A64GPR(rawValue: 30)
    public static let sp  = A64GPR(rawValue: 31)
    public static let xzr = A64GPR(rawValue: 31)
    public static let wsp = A64GPR(rawValue: 31)
    public static let wzr = A64GPR(rawValue: 31)

    /// Parses an AArch64 general-purpose register name and returns `(reg, is64Bit, isSP)`.
    public static func parse(_ name: Substring) -> (reg: A64GPR, is64Bit: Bool, isSP: Bool)? {
        let lower = name.lowercased()
        switch lower {
        case "fp":  return (.fp, true, false)
        case "lr":  return (.lr, true, false)
        case "sp":  return (.sp, true, true)
        case "wsp": return (.wsp, false, true)
        case "xzr": return (.xzr, true, false)
        case "wzr": return (.wzr, false, false)
        default:
            if lower.hasPrefix("x"), let num = UInt8(lower.dropFirst()), num <= 30 {
                return (A64GPR(rawValue: num), true, false)
            }
            if lower.hasPrefix("w"), let num = UInt8(lower.dropFirst()), num <= 30 {
                return (A64GPR(rawValue: num), false, false)
            }
            return nil
        }
    }

    public static func parse(_ name: String) -> (reg: A64GPR, is64Bit: Bool, isSP: Bool)? {
        parse(Substring(name))
    }

    /// Formats the register name given width and whether register 31 denotes SP or ZR.
    public func format(is64Bit: Bool, r31IsSP: Bool = false) -> String {
        if rawValue == 31 {
            if r31IsSP {
                return is64Bit ? "sp" : "wsp"
            } else {
                return is64Bit ? "xzr" : "wzr"
            }
        }
        return is64Bit ? "x\(rawValue)" : "w\(rawValue)"
    }
}

/// Scalar width for SIMD/FP registers (`b`, `h`, `s`, `d`, `q`).
@frozen
public enum A64ScalarWidth: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case b = 0 // 8-bit
    case h = 1 // 16-bit
    case s = 2 // 32-bit
    case d = 3 // 64-bit
    case q = 4 // 128-bit

    public var prefix: String {
        switch self {
        case .b: return "b"
        case .h: return "h"
        case .s: return "s"
        case .d: return "d"
        case .q: return "q"
        }
    }
}

/// Vector arrangement specifier for Advanced SIMD (`v0.8b`, `v0.16b`, `v0.4h`, `v0.8h`, `v0.2s`, `v0.4s`, `v0.1d`, `v0.2d`, `v0.1q`).
@frozen
public enum A64Arrangement: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable, CaseIterable {
    case b8  = 0
    case b16 = 1
    case h4  = 2
    case h8  = 3
    case s2  = 4
    case s4  = 5
    case d1  = 6
    case d2  = 7
    case q1  = 8

    /// The `Q` bit (bit 30) in Advanced SIMD encodings (1 for 128-bit, 0 for 64-bit).
    public var qBit: UInt32 {
        switch self {
        case .b8, .h4, .s2, .d1: return 0
        case .b16, .h8, .s4, .d2, .q1: return 1
        }
    }

    /// The 2-bit `size` field (bits 23:22) in Advanced SIMD three-same encodings.
    public var sizeBits: UInt32 {
        switch self {
        case .b8, .b16: return 0b00
        case .h4, .h8:  return 0b01
        case .s2, .s4:  return 0b10
        case .d1, .d2:  return 0b11
        case .q1:       return 0b00
        }
    }

    public var suffix: String {
        switch self {
        case .b8:  return "8b"
        case .b16: return "16b"
        case .h4:  return "4h"
        case .h8:  return "8h"
        case .s2:  return "2s"
        case .s4:  return "4s"
        case .d1:  return "1d"
        case .d2:  return "2d"
        case .q1:  return "1q"
        }
    }

    public static func from(qBit: UInt32, sizeBits: UInt32) -> A64Arrangement {
        switch (qBit & 1, sizeBits & 3) {
        case (0, 0): return .b8
        case (1, 0): return .b16
        case (0, 1): return .h4
        case (1, 1): return .h8
        case (0, 2): return .s2
        case (1, 2): return .s4
        case (0, 3): return .d1
        default:     return .d2
        }
    }

    public static func parse(_ text: Substring) -> A64Arrangement? {
        switch text.lowercased() {
        case "8b":  return .b8
        case "16b": return .b16
        case "4h":  return .h4
        case "8h":  return .h8
        case "2s":  return .s2
        case "4s":  return .s4
        case "1d":  return .d1
        case "2d":  return .d2
        case "1q":  return .q1
        default:    return nil
        }
    }
}

/// Advanced SIMD / FP register identifier (0..31 for `v0`..`v31`, `q0`..`q31`, `d0`..`d31`, `s0`..`s31`, `h0`..`h31`, `b0`..`b31`).
@frozen
public struct A64VReg: RawRepresentable, Equatable, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x1F
    }

    public static let v0  = A64VReg(rawValue: 0)
    public static let v1  = A64VReg(rawValue: 1)
    public static let v2  = A64VReg(rawValue: 2)
    public static let v3  = A64VReg(rawValue: 3)
    public static let v4  = A64VReg(rawValue: 4)
    public static let v5  = A64VReg(rawValue: 5)
    public static let v6  = A64VReg(rawValue: 6)
    public static let v7  = A64VReg(rawValue: 7)
    public static let v8  = A64VReg(rawValue: 8)
    public static let v9  = A64VReg(rawValue: 9)
    public static let v10 = A64VReg(rawValue: 10)
    public static let v11 = A64VReg(rawValue: 11)
    public static let v12 = A64VReg(rawValue: 12)
    public static let v13 = A64VReg(rawValue: 13)
    public static let v14 = A64VReg(rawValue: 14)
    public static let v15 = A64VReg(rawValue: 15)
    public static let v16 = A64VReg(rawValue: 16)
    public static let v17 = A64VReg(rawValue: 17)
    public static let v18 = A64VReg(rawValue: 18)
    public static let v19 = A64VReg(rawValue: 19)
    public static let v20 = A64VReg(rawValue: 20)
    public static let v21 = A64VReg(rawValue: 21)
    public static let v22 = A64VReg(rawValue: 22)
    public static let v23 = A64VReg(rawValue: 23)
    public static let v24 = A64VReg(rawValue: 24)
    public static let v25 = A64VReg(rawValue: 25)
    public static let v26 = A64VReg(rawValue: 26)
    public static let v27 = A64VReg(rawValue: 27)
    public static let v28 = A64VReg(rawValue: 28)
    public static let v29 = A64VReg(rawValue: 29)
    public static let v30 = A64VReg(rawValue: 30)
    public static let v31 = A64VReg(rawValue: 31)

    /// Parses a scalar FP/SIMD register (`b0`..`b31`, `h0`..`h31`, `s0`..`s31`, `d0`..`d31`, `q0`..`q31`)
    /// or a vector register with optional arrangement (`v0`, `v0.4s`, `v1.16b`).
    public static func parse(_ text: Substring) -> (reg: A64VReg, scalarWidth: A64ScalarWidth?, arrangement: A64Arrangement?)? {
        let lower = text.lowercased()
        if let dotIdx = lower.firstIndex(of: ".") {
            let base = lower[..<dotIdx]
            let arrPart = lower[lower.index(after: dotIdx)...]
            guard base.hasPrefix("v"), let num = UInt8(base.dropFirst()), num <= 31,
                  let arr = A64Arrangement.parse(Substring(arrPart)) else {
                return nil
            }
            return (A64VReg(rawValue: num), nil, arr)
        }
        guard let first = lower.first, let num = UInt8(lower.dropFirst()), num <= 31 else {
            return nil
        }
        switch first {
        case "v": return (A64VReg(rawValue: num), nil, nil)
        case "b": return (A64VReg(rawValue: num), .b, nil)
        case "h": return (A64VReg(rawValue: num), .h, nil)
        case "s": return (A64VReg(rawValue: num), .s, nil)
        case "d": return (A64VReg(rawValue: num), .d, nil)
        case "q": return (A64VReg(rawValue: num), .q, nil)
        default:  return nil
        }
    }

    public static func parse(_ text: String) -> (reg: A64VReg, scalarWidth: A64ScalarWidth?, arrangement: A64Arrangement?)? {
        parse(Substring(text))
    }

    public func formatScalar(_ width: A64ScalarWidth) -> String {
        "\(width.prefix)\(rawValue)"
    }

    public func formatVector(_ arrangement: A64Arrangement) -> String {
        "v\(rawValue).\(arrangement.suffix)"
    }
}

/// SVE scalable vector register (`z0`..`z31`).
@frozen
public struct A64ZReg: RawRepresentable, Equatable, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x1F
    }

    public static func parse(_ text: Substring) -> A64ZReg? {
        let lower = text.lowercased()
        guard lower.hasPrefix("z"), let num = UInt8(lower.dropFirst()), num <= 31 else { return nil }
        return A64ZReg(rawValue: num)
    }

    public var formatted: String { "z\(rawValue)" }
}

/// SVE predicate register (`p0`..`p15`).
@frozen
public struct A64PReg: RawRepresentable, Equatable, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x0F
    }

    public static func parse(_ text: Substring) -> A64PReg? {
        let lower = text.lowercased()
        let base = lower.hasSuffix(".b") ? Substring(lower.dropLast(2)) : Substring(lower)
        guard base.hasPrefix("p"), let num = UInt8(base.dropFirst()), num <= 15 else { return nil }
        return A64PReg(rawValue: num)
    }

    public var formatted: String { "p\(rawValue)" }
}

/// AArch64 condition codes (0..15).
@frozen
public enum A64Cond: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable, CaseIterable {
    case eq = 0
    case ne = 1
    case cs = 2 // alias hs
    case cc = 3 // alias lo
    case mi = 4
    case pl = 5
    case vs = 6
    case vc = 7
    case hi = 8
    case ls = 9
    case ge = 10
    case lt = 11
    case gt = 12
    case le = 13
    case al = 14
    case nv = 15

    public static let hs: A64Cond = .cs
    public static let lo: A64Cond = .cc

    /// Inverts the condition code by flipping bit 0 (per Arm ARM).
    @inlinable
    public var inverted: A64Cond {
        A64Cond(rawValue: rawValue ^ 1)!
    }

    public var mnemonic: String {
        switch self {
        case .eq: return "eq"
        case .ne: return "ne"
        case .cs: return "hs"
        case .cc: return "lo"
        case .mi: return "mi"
        case .pl: return "pl"
        case .vs: return "vs"
        case .vc: return "vc"
        case .hi: return "hi"
        case .ls: return "ls"
        case .ge: return "ge"
        case .lt: return "lt"
        case .gt: return "gt"
        case .le: return "le"
        case .al: return "al"
        case .nv: return "nv"
        }
    }

    public static func parse(_ text: Substring) -> A64Cond? {
        switch text.lowercased() {
        case "eq": return .eq
        case "ne": return .ne
        case "cs", "hs": return .cs
        case "cc", "lo": return .cc
        case "mi": return .mi
        case "pl": return .pl
        case "vs": return .vs
        case "vc": return .vc
        case "hi": return .hi
        case "ls": return .ls
        case "ge": return .ge
        case "lt": return .lt
        case "gt": return .gt
        case "le": return .le
        case "al": return .al
        case "nv": return .nv
        default:   return nil
        }
    }

    public static func parse(_ text: String) -> A64Cond? {
        parse(Substring(text))
    }
}

/// Shift kind for shifted register operands (`lsl=0, lsr=1, asr=2, ror=3`).
@frozen
public enum A64ShiftKind: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case lsl = 0
    case lsr = 1
    case asr = 2
    case ror = 3

    public var mnemonic: String {
        switch self {
        case .lsl: return "lsl"
        case .lsr: return "lsr"
        case .asr: return "asr"
        case .ror: return "ror"
        }
    }

    public static func parse(_ text: Substring) -> A64ShiftKind? {
        switch text.lowercased() {
        case "lsl": return .lsl
        case "lsr": return .lsr
        case "asr": return .asr
        case "ror": return .ror
        default:    return nil
        }
    }
}

/// Extend kind for extended register operands (`uxtb=0, uxth=1, uxtw/uxtl=2, uxtx=3, sxtb=4, sxth=5, sxtw=6, sxtx=7`).
@frozen
public enum A64ExtendKind: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case uxtb = 0
    case uxth = 1
    case uxtw = 2
    case uxtx = 3
    case sxtb = 4
    case sxth = 5
    case sxtw = 6
    case sxtx = 7

    public static let uxtl: A64ExtendKind = .uxtw

    public var mnemonic: String {
        switch self {
        case .uxtb: return "uxtb"
        case .uxth: return "uxth"
        case .uxtw: return "uxtw"
        case .uxtx: return "uxtx"
        case .sxtb: return "sxtb"
        case .sxth: return "sxth"
        case .sxtw: return "sxtw"
        case .sxtx: return "sxtx"
        }
    }

    /// Whether the source index/extended register uses the 64-bit `xN` name (`uxtx`/`sxtx`).
    public var uses64BitRegister: Bool {
        self == .uxtx || self == .sxtx
    }

    public static func parse(_ text: Substring) -> A64ExtendKind? {
        switch text.lowercased() {
        case "uxtb": return .uxtb
        case "uxth": return .uxth
        case "uxtw", "uxtl": return .uxtw
        case "uxtx": return .uxtx
        case "sxtb": return .sxtb
        case "sxth": return .sxth
        case "sxtw": return .sxtw
        case "sxtx": return .sxtx
        default:     return nil
        }
    }
}

/// Memory barrier option for `dmb`, `dsb`, `isb` (4-bit `CRm` field).
@frozen
public enum A64BarrierOption: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case oshld = 0b0001
    case oshst = 0b0010
    case osh   = 0b0011
    case nshld = 0b0101
    case nshst = 0b0110
    case nsh   = 0b0111
    case ishld = 0b1001
    case ishst = 0b1010
    case ish   = 0b1011
    case ld    = 0b1101
    case st    = 0b1110
    case sy    = 0b1111

    public var mnemonic: String {
        switch self {
        case .oshld: return "oshld"
        case .oshst: return "oshst"
        case .osh:   return "osh"
        case .nshld: return "nshld"
        case .nshst: return "nshst"
        case .nsh:   return "nsh"
        case .ishld: return "ishld"
        case .ishst: return "ishst"
        case .ish:   return "ish"
        case .ld:    return "ld"
        case .st:    return "st"
        case .sy:    return "sy"
        }
    }

    public static func parse(_ text: Substring) -> A64BarrierOption? {
        switch text.lowercased() {
        case "oshld": return .oshld
        case "oshst": return .oshst
        case "osh":   return .osh
        case "nshld": return .nshld
        case "nshst": return .nshst
        case "nsh":   return .nsh
        case "ishld": return .ishld
        case "ishst": return .ishst
        case "ish":   return .ish
        case "ld":    return .ld
        case "st":    return .st
        case "sy":    return .sy
        default:      return nil
        }
    }
}

/// PSTATE immediate field for `msr <pstatefield>, #<imm4>`.
@frozen
public enum A64PStateField: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case spsel   = 0 // op1=000, op2=101
    case daifset = 1 // op1=011, op2=110
    case daifclr = 2 // op1=011, op2=111
    case pan     = 3 // op1=000, op2=100

    public var op1: UInt32 {
        switch self {
        case .spsel, .pan: return 0b000
        case .daifset, .daifclr: return 0b011
        }
    }

    public var op2: UInt32 {
        switch self {
        case .pan:     return 0b100
        case .spsel:   return 0b101
        case .daifset: return 0b110
        case .daifclr: return 0b111
        }
    }

    public var name: String {
        switch self {
        case .spsel:   return "spsel"
        case .daifset: return "daifset"
        case .daifclr: return "daifclr"
        case .pan:     return "pan"
        }
    }

    public static func from(op1: UInt32, op2: UInt32) -> A64PStateField? {
        switch (op1 & 7, op2 & 7) {
        case (0b000, 0b100): return .pan
        case (0b000, 0b101): return .spsel
        case (0b011, 0b110): return .daifset
        case (0b011, 0b111): return .daifclr
        default: return nil
        }
    }

    public static func parse(_ text: Substring) -> A64PStateField? {
        switch text.lowercased() {
        case "spsel":   return .spsel
        case "daifset": return .daifset
        case "daifclr": return .daifclr
        case "pan":     return .pan
        default:        return nil
        }
    }
}

/// System maintenance instruction category (`tlbi`, `ic`, `dc`).
@frozen
public enum A64SysMaintKind: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case tlbi = 0
    case ic   = 1
    case dc   = 2
}

/// System maintenance operation for `tlbi`, `ic`, and `dc`.
@frozen
public enum A64SysMaintOp: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable, CaseIterable {
    // TLBI
    case vmalle1   // op1=0, CRn=8, CRm=7, op2=0, no reg (Rt=31)
    case vmalle1is // op1=0, CRn=8, CRm=3, op2=0, no reg (Rt=31)
    case vae1is    // op1=0, CRn=8, CRm=3, op2=1, Rt
    case aside1is  // op1=0, CRn=8, CRm=3, op2=2, Rt
    case vaae1is   // op1=0, CRn=8, CRm=3, op2=3, Rt
    case vale1is   // op1=0, CRn=8, CRm=3, op2=5, Rt
    // IC
    case ialluis   // op1=0, CRn=7, CRm=1, op2=0, no reg (Rt=31)
    case iallu     // op1=0, CRn=7, CRm=5, op2=0, no reg (Rt=31)
    case ivau      // op1=3, CRn=7, CRm=5, op2=1, Rt
    // DC
    case zva       // op1=3, CRn=7, CRm=4, op2=1, Rt
    case ivac      // op1=0, CRn=7, CRm=6, op2=1, Rt
    case cvac      // op1=3, CRn=7, CRm=10, op2=1, Rt
    case cvau      // op1=3, CRn=7, CRm=11, op2=1, Rt
    case civac     // op1=3, CRn=7, CRm=14, op2=1, Rt

    public var kind: A64SysMaintKind {
        switch self {
        case .vmalle1, .vmalle1is, .vae1is, .aside1is, .vaae1is, .vale1is:
            return .tlbi
        case .ialluis, .iallu, .ivau:
            return .ic
        case .zva, .ivac, .cvac, .cvau, .civac:
            return .dc
        }
    }

    public var takesRegister: Bool {
        switch self {
        case .vmalle1, .vmalle1is, .ialluis, .iallu:
            return false
        default:
            return true
        }
    }

    public var operandName: String {
        switch self {
        case .vmalle1:   return "vmalle1"
        case .vmalle1is: return "vmalle1is"
        case .vae1is:    return "vae1is"
        case .aside1is:  return "aside1is"
        case .vaae1is:   return "vaae1is"
        case .vale1is:   return "vale1is"
        case .ialluis:   return "ialluis"
        case .iallu:     return "iallu"
        case .ivau:      return "ivau"
        case .zva:       return "zva"
        case .ivac:      return "ivac"
        case .cvac:      return "cvac"
        case .cvau:      return "cvau"
        case .civac:     return "civac"
        }
    }

    /// Returns `(op1, crn, crm, op2)` for the `SYS` instruction encoding (`0xD5080000` base).
    public var sysFields: (op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32) {
        switch self {
        case .vmalle1:   return (0, 8, 7, 0)
        case .vmalle1is: return (0, 8, 3, 0)
        case .vae1is:    return (0, 8, 3, 1)
        case .aside1is:  return (0, 8, 3, 2)
        case .vaae1is:   return (0, 8, 3, 3)
        case .vale1is:   return (0, 8, 3, 5)
        case .ialluis:   return (0, 7, 1, 0)
        case .iallu:     return (0, 7, 5, 0)
        case .ivau:      return (3, 7, 5, 1)
        case .zva:       return (3, 7, 4, 1)
        case .ivac:      return (0, 7, 6, 1)
        case .cvac:      return (3, 7, 10, 1)
        case .cvau:      return (3, 7, 11, 1)
        case .civac:     return (3, 7, 14, 1)
        }
    }

    public static func from(op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32) -> A64SysMaintOp? {
        for candidate in A64SysMaintOp.allCases {
            let f = candidate.sysFields
            if f.op1 == op1 && f.crn == crn && f.crm == crm && f.op2 == op2 {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - 1b. AArch64 System Registers (`A64SysReg`)

/// Represents an AArch64 15-bit system register encoding `(op0, op1, crn, crm, op2)` for `MRS`/`MSR`.
@frozen
public struct A64SysReg: Equatable, Hashable, Sendable, BitwiseCopyable {
    public var op0: UInt8
    public var op1: UInt8
    public var crn: UInt8
    public var crm: UInt8
    public var op2: UInt8

    @inlinable
    public init(op0: UInt8, op1: UInt8, crn: UInt8, crm: UInt8, op2: UInt8) {
        self.op0 = op0 & 0x3
        self.op1 = op1 & 0x7
        self.crn = crn & 0xF
        self.crm = crm & 0xF
        self.op2 = op2 & 0x7
    }

    /// The packed 16-bit representation placed in bits [20:5] of `MRS`/`MSR` (shifted right by 5).
    @inlinable
    public var encoded15Bit: UInt16 {
        (UInt16(op0 & 0x3) << 14) |
        (UInt16(op1 & 0x7) << 11) |
        (UInt16(crn & 0xF) << 7)  |
        (UInt16(crm & 0xF) << 3)  |
        UInt16(op2 & 0x7)
    }

    /// Constructs an `A64SysReg` from the 16-bit field at bits [20:5] of an `MRS`/`MSR` word.
    @inlinable
    public init(encoded15Bit: UInt16) {
        self.op0 = UInt8((encoded15Bit >> 14) & 0x3)
        self.op1 = UInt8((encoded15Bit >> 11) & 0x7)
        self.crn = UInt8((encoded15Bit >> 7) & 0xF)
        self.crm = UInt8((encoded15Bit >> 3) & 0xF)
        self.op2 = UInt8(encoded15Bit & 0x7)
    }

    /// Named system register table covering Todhchai and Croi (verified against Arm ARM / llvm-mc).
    public static let namedTable: [(name: String, reg: A64SysReg)] = {
        var list: [(name: String, reg: A64SysReg)] = [
            ("tpidr_el0",        A64SysReg(op0: 3, op1: 3, crn: 13, crm: 0,  op2: 2)),
            ("tpidrro_el0",      A64SysReg(op0: 3, op1: 3, crn: 13, crm: 0,  op2: 3)),
            ("tpidr_el1",        A64SysReg(op0: 3, op1: 0, crn: 13, crm: 0,  op2: 4)),
            ("tpidr_el2",        A64SysReg(op0: 3, op1: 4, crn: 13, crm: 0,  op2: 2)),
            ("daif",             A64SysReg(op0: 3, op1: 3, crn: 4,  crm: 2,  op2: 1)),
            ("nzcv",             A64SysReg(op0: 3, op1: 3, crn: 4,  crm: 2,  op2: 0)),
            ("currentel",        A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 2,  op2: 2)),
            ("spsel",            A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 2,  op2: 0)),
            ("vbar_el1",         A64SysReg(op0: 3, op1: 0, crn: 12, crm: 0,  op2: 0)),
            ("vbar_el2",         A64SysReg(op0: 3, op1: 4, crn: 12, crm: 0,  op2: 0)),
            ("ttbr0_el1",        A64SysReg(op0: 3, op1: 0, crn: 2,  crm: 0,  op2: 0)),
            ("ttbr1_el1",        A64SysReg(op0: 3, op1: 0, crn: 2,  crm: 0,  op2: 1)),
            ("sctlr_el1",        A64SysReg(op0: 3, op1: 0, crn: 1,  crm: 0,  op2: 0)),
            ("sctlr_el2",        A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 0,  op2: 0)),
            ("esr_el1",          A64SysReg(op0: 3, op1: 0, crn: 5,  crm: 2,  op2: 0)),
            ("esr_el2",          A64SysReg(op0: 3, op1: 4, crn: 5,  crm: 2,  op2: 0)),
            ("elr_el1",          A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 0,  op2: 1)),
            ("elr_el2",          A64SysReg(op0: 3, op1: 4, crn: 4,  crm: 0,  op2: 1)),
            ("spsr_el1",         A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 0,  op2: 0)),
            ("spsr_el2",         A64SysReg(op0: 3, op1: 4, crn: 4,  crm: 0,  op2: 0)),
            ("far_el1",          A64SysReg(op0: 3, op1: 0, crn: 6,  crm: 0,  op2: 0)),
            ("far_el2",          A64SysReg(op0: 3, op1: 4, crn: 6,  crm: 0,  op2: 0)),
            ("mair_el1",         A64SysReg(op0: 3, op1: 0, crn: 10, crm: 2,  op2: 0)),
            ("tcr_el1",          A64SysReg(op0: 3, op1: 0, crn: 2,  crm: 0,  op2: 2)),
            ("hcr_el2",          A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 1,  op2: 0)),
            ("cnthctl_el2",      A64SysReg(op0: 3, op1: 4, crn: 14, crm: 1,  op2: 0)),
            ("cntvoff_el2",      A64SysReg(op0: 3, op1: 4, crn: 14, crm: 0,  op2: 3)),
            ("cptr_el2",         A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 1,  op2: 2)),
            ("hstr_el2",         A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 1,  op2: 3)),
            ("vttbr_el2",        A64SysReg(op0: 3, op1: 4, crn: 2,  crm: 1,  op2: 0)),
            ("midr_el1",         A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 0,  op2: 0)),
            ("vpidr_el2",        A64SysReg(op0: 3, op1: 4, crn: 0,  crm: 0,  op2: 0)),
            ("mpidr_el1",        A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 0,  op2: 5)),
            ("vmpidr_el2",       A64SysReg(op0: 3, op1: 4, crn: 0,  crm: 0,  op2: 5)),
            ("mdcr_el2",         A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 1,  op2: 1)),
            ("id_aa64pfr0_el1",  A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 4,  op2: 0)),
            ("id_aa64pfr1_el1",  A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 4,  op2: 1)),
            ("id_aa64zfr0_el1",  A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 4,  op2: 4)),
            ("id_aa64smfr0_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 4,  op2: 5)),
            ("id_aa64dfr0_el1",  A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 5,  op2: 0)),
            ("id_aa64mmfr0_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 7,  op2: 0)),
            ("id_aa64mmfr1_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 7,  op2: 1)),
            ("id_aa64mmfr2_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 7,  op2: 2)),
            ("id_aa64mmfr3_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 7,  op2: 3)),
            ("id_aa64isar0_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 6,  op2: 0)),
            ("id_aa64isar1_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 6,  op2: 1)),
            ("id_aa64isar2_el1", A64SysReg(op0: 3, op1: 0, crn: 0,  crm: 6,  op2: 2)),
            ("zcr_el1",          A64SysReg(op0: 3, op1: 0, crn: 1,  crm: 2,  op2: 0)),
            ("zcr_el2",          A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 2,  op2: 0)),
            ("smcr_el1",         A64SysReg(op0: 3, op1: 0, crn: 1,  crm: 2,  op2: 6)),
            ("smcr_el2",         A64SysReg(op0: 3, op1: 4, crn: 1,  crm: 2,  op2: 6)),
            ("apiakeylo_el1",    A64SysReg(op0: 3, op1: 0, crn: 2,  crm: 1,  op2: 0)),
            ("apiakeyhi_el1",    A64SysReg(op0: 3, op1: 0, crn: 2,  crm: 1,  op2: 1)),
            ("rndr",             A64SysReg(op0: 3, op1: 3, crn: 2,  crm: 4,  op2: 0)),
            ("pmcr_el0",         A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 0)),
            ("pmcntenset_el0",   A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 1)),
            ("pmcntenclr_el0",   A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 2)),
            ("pmintenset_el1",   A64SysReg(op0: 3, op1: 0, crn: 9,  crm: 14, op2: 1)),
            ("pmintenclr_el1",   A64SysReg(op0: 3, op1: 0, crn: 9,  crm: 14, op2: 2)),
            ("pmovsclr_el0",     A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 3)),
            ("pmceid0_el0",      A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 6)),
            ("pmccfiltr_el0",    A64SysReg(op0: 3, op1: 3, crn: 14, crm: 15, op2: 7)),
            ("pmuserenr_el0",    A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 14, op2: 0)),
            ("pmselr_el0",       A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 12, op2: 5)),
            ("pmxevcntr_el0",    A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 13, op2: 2)),
            ("pmxevtyper_el0",   A64SysReg(op0: 3, op1: 3, crn: 9,  crm: 13, op2: 1)),
            ("cntvct_el0",       A64SysReg(op0: 3, op1: 3, crn: 14, crm: 0,  op2: 2)),
            ("cntfrq_el0",       A64SysReg(op0: 3, op1: 3, crn: 14, crm: 0,  op2: 0)),
            ("cntv_cval_el0",    A64SysReg(op0: 3, op1: 3, crn: 14, crm: 3,  op2: 2)),
            ("cntv_ctl_el0",     A64SysReg(op0: 3, op1: 3, crn: 14, crm: 3,  op2: 1)),
            ("cntkctl_el1",      A64SysReg(op0: 3, op1: 0, crn: 14, crm: 1,  op2: 0)),
            ("cpacr_el1",        A64SysReg(op0: 3, op1: 0, crn: 1,  crm: 0,  op2: 2)),
            ("ctr_el0",          A64SysReg(op0: 3, op1: 3, crn: 0,  crm: 0,  op2: 1)),
            ("mdscr_el1",        A64SysReg(op0: 2, op1: 0, crn: 0,  crm: 2,  op2: 2)),
            ("oslar_el1",        A64SysReg(op0: 2, op1: 0, crn: 1,  crm: 0,  op2: 4)),
            ("fpsr",             A64SysReg(op0: 3, op1: 3, crn: 4,  crm: 4,  op2: 1)),
            ("fpcr",             A64SysReg(op0: 3, op1: 3, crn: 4,  crm: 4,  op2: 0)),
            ("sp_el0",           A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 1,  op2: 0)),
            ("sp_el1",           A64SysReg(op0: 3, op1: 4, crn: 4,  crm: 1,  op2: 0)),
            ("icc_sre_el1",      A64SysReg(op0: 3, op1: 0, crn: 12, crm: 12, op2: 5)),
            ("icc_sre_el2",      A64SysReg(op0: 3, op1: 4, crn: 12, crm: 9,  op2: 5)),
            ("ich_hcr_el2",      A64SysReg(op0: 3, op1: 4, crn: 12, crm: 11, op2: 0)),
            ("icc_pmr_el1",      A64SysReg(op0: 3, op1: 0, crn: 4,  crm: 6,  op2: 0)),
            ("icc_bpr1_el1",     A64SysReg(op0: 3, op1: 0, crn: 12, crm: 12, op2: 3)),
            ("icc_igrpen1_el1",  A64SysReg(op0: 3, op1: 0, crn: 12, crm: 12, op2: 7)),
            ("icc_iar1_el1",     A64SysReg(op0: 3, op1: 0, crn: 12, crm: 12, op2: 0)),
            ("icc_eoir1_el1",    A64SysReg(op0: 3, op1: 0, crn: 12, crm: 12, op2: 1)),
            ("icc_sgi1r_el1",    A64SysReg(op0: 3, op1: 0, crn: 12, crm: 11, op2: 5)),
        ]
        for i: UInt8 in 0...15 {
            list.append(("dbgbvr\(i)_el1", A64SysReg(op0: 2, op1: 0, crn: 0, crm: i, op2: 4)))
            list.append(("dbgbcr\(i)_el1", A64SysReg(op0: 2, op1: 0, crn: 0, crm: i, op2: 5)))
            list.append(("dbgwvr\(i)_el1", A64SysReg(op0: 2, op1: 0, crn: 0, crm: i, op2: 6)))
            list.append(("dbgwcr\(i)_el1", A64SysReg(op0: 2, op1: 0, crn: 0, crm: i, op2: 7)))
        }
        return list
    }()

    private static let byName: [String: A64SysReg] = {
        var map: [String: A64SysReg] = [:]
        map.reserveCapacity(namedTable.count)
        for entry in namedTable {
            map[entry.name] = entry.reg
        }
        return map
    }()

    private static let byEncoding: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        map.reserveCapacity(namedTable.count)
        for entry in namedTable {
            if map[entry.reg.encoded15Bit] == nil {
                map[entry.reg.encoded15Bit] = entry.name
            }
        }
        return map
    }()

    /// Parses either a named system register (case-insensitive) or generic `S<op0>_<op1>_<Cn>_<Cm>_<op2>` syntax.
    public static func parse(_ text: Substring) -> A64SysReg? {
        let lower = text.lowercased()
        if let known = byName[lower] {
            return known
        }
        // Generic format: s<op0>_<op1>_c<crn>_c<crm>_<op2>
        guard lower.hasPrefix("s") else { return nil }
        let parts = lower.dropFirst().split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 5,
              let op0 = UInt8(parts[0]), op0 <= 3,
              let op1 = UInt8(parts[1]), op1 <= 7,
              parts[2].hasPrefix("c"), let crn = UInt8(parts[2].dropFirst()), crn <= 15,
              parts[3].hasPrefix("c"), let crm = UInt8(parts[3].dropFirst()), crm <= 15,
              let op2 = UInt8(parts[4]), op2 <= 7 else {
            return nil
        }
        return A64SysReg(op0: op0, op1: op1, crn: crn, crm: crm, op2: op2)
    }

    public static func parse(_ text: String) -> A64SysReg? {
        parse(Substring(text))
    }

    /// Formats the system register as its canonical name if known, or `s<op0>_<op1>_c<crn>_c<crm>_<op2>`.
    public var formatted: String {
        if let name = Self.byEncoding[encoded15Bit] {
            return name
        }
        return "s\(op0)_\(op1)_c\(crn)_c\(crm)_\(op2)"
    }
}

// MARK: - 2. Logical Immediate (Bitmask Immediate) Encoder and Decoder

/// Encodes and decodes AArch64 13-bit `(N, immr, imms)` logical bitmask immediates (Arm ARM `DecodeBitMasks`).
public enum A64BitmaskImmediate {
    /// Encodes a 32-bit or 64-bit constant into `(n, immr, imms)` if it is a valid AArch64 bitmask immediate.
    public static func encode(value: UInt64, is64Bit: Bool) -> (n: UInt32, immr: UInt32, imms: UInt32)? {
        let regSize = is64Bit ? 64 : 32
        let val: UInt64
        if is64Bit {
            val = value
        } else {
            let low32 = value & 0xFFFF_FFFF
            val = low32 | (low32 << 32)
        }

        // All-0 and all-1 bitmasks are reserved/invalid in AArch64 logical immediates.
        if val == 0 || val == UInt64.max {
            return nil
        }

        // Find the smallest repeating element size (2, 4, 8, 16, 32, or 64).
        var size = regSize
        while size > 2 {
            let half = size >> 1
            let mask: UInt64 = (half == 64) ? UInt64.max : ((1 << half) - 1)
            if (val & mask) != ((val >> half) & mask) {
                break
            }
            size = half
        }

        let elemMask: UInt64 = (size == 64) ? UInt64.max : ((1 << size) - 1)
        let elem = val & elemMask

        // An element is valid iff it is a rotated run of 1s of length 1..<(size).
        // Rotate right so that bit 0 is 1 and bit (size - 1) is 0, or check contiguous transitions.
        let doubled = elem | (elem << (size < 64 ? size : 0))
        // Find right-rotation `r` in 0..<size such that the rotated element is `(1 << ones) - 1`.
        let ones = elem.nonzeroBitCount
        if ones == 0 || ones == size {
            return nil
        }

        let lowRunMask: UInt64 = (1 << ones) - 1
        var foundRot: Int? = nil
        for r in 0..<size {
            // Rotating a `size`-bit element right by `r` in the instruction decoding corresponds to
            // rotating `lowRunMask` right by `r` within `size` bits.
            let rRight = r
            let rotated: UInt64
            if rRight == 0 {
                rotated = lowRunMask
            } else {
                rotated = ((lowRunMask >> rRight) | (lowRunMask << (size - rRight))) & elemMask
            }
            if rotated == elem {
                foundRot = rRight
                break
            }
        }
        guard let immrVal = foundRot else {
            return nil
        }
        let _ = doubled

        let n: UInt32 = (size == 64) ? 1 : 0
        let immr = UInt32(immrVal)
        // `imms` encodes both the element size and `ones - 1`:
        // High bits of `imms` are `~(2*size - 1)` masked to 6 bits, low bits are `ones - 1`.
        let nimmsTop = UInt32((~(size * 2 - 1)) & 0x3F)
        let imms = nimmsTop | UInt32(ones - 1)
        return (n: n, immr: immr, imms: imms)
    }

    /// Decodes `(n, immr, imms)` into a 64-bit (or zero-extended 32-bit) bitmask immediate.
    public static func decode(n: UInt32, immr: UInt32, imms: UInt32, is64Bit: Bool) -> UInt64? {
        if !is64Bit && n != 0 {
            return nil
        }
        let nBit = Int(n & 1)
        let immsBits = Int(imms & 0x3F)
        let immrBits = Int(immr & 0x3F)

        // Highest set bit of `(n << 6) | (~imms & 0x3F)` determines element size `1 << len`.
        let combined = (nBit << 6) | ((~immsBits) & 0x3F)
        if combined <= 1 {
            return nil
        }
        let len = 63 - UInt64(combined).leadingZeroBitCount
        if len < 1 {
            return nil
        }
        let size = 1 << len
        if !is64Bit && size > 32 {
            return nil
        }
        let levels = size - 1
        let s = immsBits & levels
        let r = immrBits & levels
        if s == levels {
            // All-ones element is reserved.
            return nil
        }

        let ones = s + 1
        let elemMask: UInt64 = (size == 64) ? UInt64.max : ((1 << size) - 1)
        let welem: UInt64 = (ones == 64) ? UInt64.max : ((1 << ones) - 1)
        let rotated: UInt64
        if r == 0 {
            rotated = welem
        } else {
            rotated = ((welem >> r) | (welem << (size - r))) & elemMask
        }

        var result: UInt64 = 0
        let totalBits = is64Bit ? 64 : 32
        var pos = 0
        while pos < totalBits {
            result |= (rotated << pos)
            pos += size
        }
        return result
    }
}

// MARK: - 3. Shared Instruction Descriptor Table & Structured Instruction Model

/// Encoding format classes for the AArch64 table-driven encoder and disassembler.
@frozen
public enum A64InstrFormat: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    // Data processing — immediate
    case addSubImm          // add, adds, sub, subs (Rd/Rn, imm12, opt lsl #12)
    case movWide            // movz, movk, movn (Rd, imm16, lsl #(hw*16))
    case pcRel              // adr, adrp (Rd, signed label offset)
    case logicalImm         // and, orr, eor, ands (Rd, Rn, bitmask imm)
    case bitfield           // sbfm, bfm, ubfm (Rd, Rn, immr, imms)
    case extract            // extr (Rd, Rn, Rm, lsb)

    // Data processing — register
    case addSubShifted      // add, adds, sub, subs (Rd, Rn, Rm, shift #imm6)
    case addSubExtended     // add, adds, sub, subs (Rd/SP, Rn/SP, Rm, extend #imm3)
    case logicalShifted     // and, bic, orr, orn, eor, eon, ands, bics (Rd, Rn, Rm, shift #imm6)
    case dp2Source          // lslv, lsrv, asrv, rorv, udiv, sdiv (Rd, Rn, Rm)
    case dp1Source          // clz, rbit, rev, rev16, rev32 (Rd, Rn)
    case dp3Source          // madd, msub (Rd, Rn, Rm, Ra)
    case mulHigh            // smulh, umulh (Xd, Xn, Xm)
    case condSelect         // csel, csinc, csinv, csneg (Rd, Rn, Rm, cond)
    case condCompareReg     // ccmp (Rn, Rm, #nzcv, cond)
    case condCompareImm     // ccmp (Rn, #imm5, #nzcv, cond)

    // Branches, exceptions, system
    case branchImm26        // b, bl (imm26 * 4)
    case branchCond19       // b.cond (imm19 * 4, cond)
    case compareBranch19    // cbz, cbnz (Rt, imm19 * 4)
    case testBranch14       // tbz, tbnz (Rt, #bit, imm14 * 4)
    case branchReg          // br, blr, ret (Rn)
    case exceptionImm16     // svc, hvc, smc, brk, hlt (#imm16)
    case udfImm16           // udf (#imm16)
    case fixedSystem        // eret, nop, yield, wfe, wfi, sev, sevl
    case hintImm7           // hint (#imm7)
    case barrier            // dmb, dsb, isb, clrex
    case mrs                // mrs Xt, <sysreg>
    case msrReg             // msr <sysreg>, Xt
    case msrPState          // msr <pstatefield>, #imm4
    case sysMaint           // tlbi, ic, dc

    // Loads and stores
    case ldstUnsignedImm12  // ldr, str, ldrb, strb, ldrh, strh, ldrsb, ldrsh, ldrsw (unsigned scaled offset)
    case ldstPreImm9        // ldr, str, ... [Xn, #simm9]!
    case ldstPostImm9       // ldr, str, ... [Xn], #simm9
    case ldstUnscaledImm9   // ldur, stur, ldurb, sturb, ldurh, sturh, ldursb, ldursh, ldursw
    case ldstUnprivImm9     // ldtr, sttr, ldtrb, sttrb, ldtrh, sttrh, ldtrsb, ldtrsh, ldtrsw
    case ldstRegOffset      // ldr, str, ... [Xn, Rm, extend #shift]
    case ldrLiteral         // ldr Wt/Xt, label (imm19 * 4)
    case ldpStpSigned       // ldp, stp (Wt/Xt/Qt, [Xn, #simm7 * scale])
    case ldpStpPre          // ldp, stp (Wt/Xt/Qt, [Xn, #simm7 * scale]!)
    case ldpStpPost         // ldp, stp (Wt/Xt/Qt, [Xn], #simm7 * scale)
    case atomicLoad         // ldxr, ldaxr, ldar, ldarb, ldarh (Rt, [Xn])
    case atomicStore        // stlr, stlrb, stlrh (Rt, [Xn])
    case atomicStoreExcl    // stxr, stlxr (Ws, Rt, [Xn])

    // Scalar FP
    case fpMovGprToFp       // fmov s0, w0 / fmov d0, x0
    case fpMovFpToGpr       // fmov w0, s0 / fmov x0, d0
    case fpMovReg           // fmov s0, s1 / fmov d0, d1
    case fpCvtReg           // fcvt d0, s1 / fcvt s0, d1
    case fpIntToFp          // scvtf s0, w1 / scvtf d0, x1
    case fpToInt            // fcvtzs w0, s1 / fcvtzs x0, d1
    case fpBinary           // fadd, fsub, fmul, fdiv (scalar s/d)
    case fpCmpReg           // fcmp s0, s1 / fcmp d0, d1
    case fpCmpZero          // fcmp s0, #0.0 / fcmp d0, #0.0

    // Advanced SIMD (NEON)
    case simdThreeSameInt   // add, sub, mul, cmeq, cmgt, cmge
    case simdThreeSameBit   // and, bic, orr, orn, eor (8b/16b)
    case simdThreeSameFp    // fadd, fsub, fmul, fdiv (2s/4s/2d)
    case simdPermute        // uzp1, uzp2, zip1, zip2
    case simdTwoRegMisc     // cnt, rev64
    case simdShiftImm       // shl, ushr, sshr
    case simdDupGpr         // dup v0.<T>, w1/x1
    case simdInsGpr         // ins v0.<ts>[idx], w1/x1
    case simdUmovSmov       // umov, smov w0/x0, v1.<ts>[idx]
    case simdLd1St1One      // ld1, st1 {v0.<T>}, [x1]
    case simdTblOne         // tbl v0.<8b|16b>, {v1.16b}, v2.<8b|16b>
    case simdExt            // ext v0.<8b|16b>, v1.<8b|16b>, v2.<8b|16b>, #imm4

    // SVE (croi/kernel/arch/arm64/cpu.S subset)
    case sveLdrStrZ         // ldr/str zN, [xBase, #simm9, mul vl]
    case sveLdrStrP         // ldr/str pN, [xBase, #simm9, mul vl]
    case sveAddVlPl         // addvl/addpl xRd, xRn, #simm6
    case sveRdffr           // rdffr pN.b
    case sveWrffr           // wrffr pN.b
}

/// Unique identifier for every instruction entry in `A64InstructionTable`.
@frozen
public enum A64OpcodeId: UInt16, Equatable, Hashable, Sendable, BitwiseCopyable, CaseIterable {
    // Data processing — immediate
    case addImm, addsImm, subImm, subsImm
    case movz, movk, movn
    case adr, adrp
    case andImm, orrImm, eorImm, andsImm
    case sbfm, bfm, ubfm
    case extr

    // Data processing — register
    case addShifted, addsShifted, subShifted, subsShifted
    case addExtended, addsExtended, subExtended, subsExtended
    case andShifted, bicShifted, orrShifted, ornShifted, eorShifted, eonShifted, andsShifted, bicsShifted
    case lslv, lsrv, asrv, rorv, udiv, sdiv
    case rbit, rev16, rev32, rev, clz
    case madd, msub, smulh, umulh
    case csel, csinc, csinv, csneg
    case ccmpReg, ccmpImm

    // Branches & system
    case b, bl, bCond, cbz, cbnz, tbz, tbnz
    case br, blr, ret
    case svc, hvc, smc, brk, hlt, udf
    case eret, nop, yield, wfe, wfi, sev, sevl, hint
    case clrex, dsb, dmb, isb
    case mrs, msrReg, msrPState
    case sysMaint

    // Loads and stores — unsigned immediate
    case ldrImm, strImm, ldrbImm, strbImm, ldrhImm, strhImm
    case ldrsbImm64, ldrsbImm32, ldrshImm64, ldrshImm32, ldrswImm
    case ldrFpImmB, strFpImmB, ldrFpImmH, strFpImmH, ldrFpImmS, strFpImmS, ldrFpImmD, strFpImmD, ldrFpImmQ, strFpImmQ

    // Loads and stores — pre-index & post-index
    case ldrPre, strPre, ldrbPre, strbPre, ldrhPre, strhPre, ldrsbPre64, ldrshPre64, ldrswPre
    case ldrPost, strPost, ldrbPost, strbPost, ldrhPost, strhPost, ldrsbPost64, ldrshPost64, ldrswPost

    // Loads and stores — unscaled (`ldur`/`stur`)
    case ldur, stur, ldurb, sturb, ldurh, sturh, ldursb64, ldursb32, ldursh64, ldursh32, ldursw

    // Loads and stores — unprivileged (`ldtr`/`sttr`)
    case ldtr, sttr, ldtrb, sttrb, ldtrh, sttrh, ldtrsb64, ldtrsb32, ldtrsh64, ldtrsh32, ldtrsw

    // Loads and stores — register offset & literal
    case ldrReg, strReg, ldrbReg, strbReg, ldrhReg, strhReg, ldrsbReg64, ldrshReg64, ldrswReg
    case ldrLit

    // Loads and stores — pairs (`ldp`/`stp`)
    case ldpSigned, stpSigned, ldpPre, stpPre, ldpPost, stpPost
    case ldpSignedQ, stpSignedQ, ldpPreQ, stpPreQ, ldpPostQ, stpPostQ

    // Atomics / exclusives
    case ldxr, stxr, ldaxr, stlxr, ldar, stlr, ldarb, stlrb, ldarh, stlrh

    // Scalar FP
    case fmovGprToFp, fmovFpToGpr, fmovReg
    case fcvtStoD, fcvtDtoS, scvtf, fcvtzs
    case faddScalar, fsubScalar, fmulScalar, fdivScalar
    case fcmpReg, fcmpZero

    // Advanced SIMD (NEON)
    case simdAdd, simdSub, simdMul, simdCmeq, simdCmgt, simdCmge
    case simdAnd, simdBic, simdOrr, simdOrn, simdEor
    case simdFadd, simdFsub, simdFmul, simdFdiv
    case simdUzp1, simdUzp2, simdZip1, simdZip2
    case simdCnt, simdRev64
    case simdShl, simdUshr, simdSshr
    case simdDupGpr, simdInsGpr, simdUmov, simdSmov
    case simdLd1One, simdSt1One, simdTblOne, simdExt

    // SVE
    case sveLdrZ, sveStrZ, sveLdrP, sveStrP
    case sveAddvl, sveAddpl, sveRdffr, sveWrffr
}

/// A single entry in `A64InstructionTable`.
@frozen
public struct A64InstrDesc: Equatable, Sendable {
    public let id: A64OpcodeId
    public let mnemonic: String
    public let format: A64InstrFormat
    public let opcodeMask: UInt32
    public let opcodeBits: UInt32
    /// Log2 of byte scale for scaled immediate offsets (0=1B, 1=2B, 2=4B, 3=8B, 4=16B; 255=depends on `is64Bit`).
    public let scaleLog2: UInt8
    /// Optional scalar width for SIMD/FP loads/stores.
    public let scalarWidth: A64ScalarWidth?

    public init(
        id: A64OpcodeId,
        mnemonic: String,
        format: A64InstrFormat,
        opcodeMask: UInt32,
        opcodeBits: UInt32,
        scaleLog2: UInt8 = 0,
        scalarWidth: A64ScalarWidth? = nil
    ) {
        self.id = id
        self.mnemonic = mnemonic
        self.format = format
        self.opcodeMask = opcodeMask
        self.opcodeBits = opcodeBits
        self.scaleLog2 = scaleLog2
        self.scalarWidth = scalarWidth
    }
}

/// Structured representation of a single AArch64 instruction, used by `A64Encoder` and `A64Disassembler`.
@frozen
public struct A64Instruction: Equatable, Hashable, Sendable {
    public var opcode: A64OpcodeId
    public var is64Bit: Bool
    public var rd: A64GPR
    public var rn: A64GPR
    public var rm: A64GPR
    public var ra: A64GPR
    public var vd: A64VReg
    public var vn: A64VReg
    public var vm: A64VReg
    public var zd: A64ZReg
    public var pd: A64PReg
    public var scalarWidth: A64ScalarWidth
    public var arrangement: A64Arrangement
    public var cond: A64Cond
    public var shiftKind: A64ShiftKind
    public var extendKind: A64ExtendKind
    public var amount: UInt8
    public var index: UInt8
    public var imm: Int64
    public var imm2: UInt8
    public var sysReg: A64SysReg
    public var pstateField: A64PStateField
    public var barrierOption: A64BarrierOption
    public var sysMaintOp: A64SysMaintOp

    public init(
        opcode: A64OpcodeId,
        is64Bit: Bool = true,
        rd: A64GPR = .x0,
        rn: A64GPR = .x0,
        rm: A64GPR = .x0,
        ra: A64GPR = .x0,
        vd: A64VReg = .v0,
        vn: A64VReg = .v0,
        vm: A64VReg = .v0,
        zd: A64ZReg = A64ZReg(rawValue: 0),
        pd: A64PReg = A64PReg(rawValue: 0),
        scalarWidth: A64ScalarWidth = .d,
        arrangement: A64Arrangement = .b16,
        cond: A64Cond = .eq,
        shiftKind: A64ShiftKind = .lsl,
        extendKind: A64ExtendKind = .uxtw,
        amount: UInt8 = 0,
        index: UInt8 = 0,
        imm: Int64 = 0,
        imm2: UInt8 = 0,
        sysReg: A64SysReg = A64SysReg(op0: 3, op1: 3, crn: 13, crm: 0, op2: 2),
        pstateField: A64PStateField = .daifset,
        barrierOption: A64BarrierOption = .sy,
        sysMaintOp: A64SysMaintOp = .vmalle1
    ) {
        self.opcode = opcode
        self.is64Bit = is64Bit
        self.rd = rd
        self.rn = rn
        self.rm = rm
        self.ra = ra
        self.vd = vd
        self.vn = vn
        self.vm = vm
        self.zd = zd
        self.pd = pd
        self.scalarWidth = scalarWidth
        self.arrangement = arrangement
        self.cond = cond
        self.shiftKind = shiftKind
        self.extendKind = extendKind
        self.amount = amount
        self.index = index
        self.imm = imm
        self.imm2 = imm2
        self.sysReg = sysReg
        self.pstateField = pstateField
        self.barrierOption = barrierOption
        self.sysMaintOp = sysMaintOp
    }

    // MARK: Canonical Alias Builders (04-backend.md §4.9, 05-assembler.md §4.7)

    /// `cmp Rn, #imm` -> `subs xzr/wzr, Rn, #imm`
    public static func cmpImm(is64Bit: Bool = true, rn: A64GPR, imm12: UInt16, lsl12: Bool = false) -> A64Instruction {
        A64Instruction(opcode: .subsImm, is64Bit: is64Bit, rd: .xzr, rn: rn, amount: lsl12 ? 12 : 0, imm: Int64(imm12))
    }

    /// `cmp Rn, Rm {, shift #amount}` -> `subs xzr/wzr, Rn, Rm, shift #amount`
    public static func cmpShifted(is64Bit: Bool = true, rn: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .subsShifted, is64Bit: is64Bit, rd: .xzr, rn: rn, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `cmn Rn, #imm` -> `adds xzr/wzr, Rn, #imm`
    public static func cmnImm(is64Bit: Bool = true, rn: A64GPR, imm12: UInt16, lsl12: Bool = false) -> A64Instruction {
        A64Instruction(opcode: .addsImm, is64Bit: is64Bit, rd: .xzr, rn: rn, amount: lsl12 ? 12 : 0, imm: Int64(imm12))
    }

    /// `cmn Rn, Rm {, shift #amount}` -> `adds xzr/wzr, Rn, Rm, shift #amount`
    public static func cmnShifted(is64Bit: Bool = true, rn: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .addsShifted, is64Bit: is64Bit, rd: .xzr, rn: rn, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `tst Rn, #bitmask` -> `ands xzr/wzr, Rn, #bitmask`
    public static func tstImm(is64Bit: Bool = true, rn: A64GPR, bitmask: UInt64) -> A64Instruction {
        A64Instruction(opcode: .andsImm, is64Bit: is64Bit, rd: .xzr, rn: rn, imm: Int64(bitPattern: bitmask))
    }

    /// `tst Rn, Rm {, shift #amount}` -> `ands xzr/wzr, Rn, Rm, shift #amount`
    public static func tstShifted(is64Bit: Bool = true, rn: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .andsShifted, is64Bit: is64Bit, rd: .xzr, rn: rn, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `mov Rd, Rn` -> `add Rd, Rn, #0` if either involves SP, otherwise `orr Rd, xzr, Rn`
    public static func movReg(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, involvesSP: Bool = false) -> A64Instruction {
        if involvesSP {
            return A64Instruction(opcode: .addImm, is64Bit: is64Bit, rd: rd, rn: rn, amount: 0, imm: 0)
        }
        return A64Instruction(opcode: .orrShifted, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: rn, shiftKind: .lsl, amount: 0)
    }

    /// `mvn Rd, Rm {, shift #amount}` -> `orn Rd, xzr/wzr, Rm, shift #amount`
    public static func mvn(is64Bit: Bool = true, rd: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .ornShifted, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `neg Rd, Rm {, shift #amount}` -> `sub Rd, xzr/wzr, Rm, shift #amount`
    public static func neg(is64Bit: Bool = true, rd: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .subShifted, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `negs Rd, Rm {, shift #amount}` -> `subs Rd, xzr/wzr, Rm, shift #amount`
    public static func negs(is64Bit: Bool = true, rd: A64GPR, rm: A64GPR, shift: A64ShiftKind = .lsl, amount: UInt8 = 0) -> A64Instruction {
        A64Instruction(opcode: .subsShifted, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: rm, shiftKind: shift, amount: amount)
    }

    /// `mul Rd, Rn, Rm` -> `madd Rd, Rn, Rm, xzr/wzr`
    public static func mul(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, rm: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .madd, is64Bit: is64Bit, rd: rd, rn: rn, rm: rm, ra: .xzr)
    }

    /// `cset Rd, cond` -> `csinc Rd, xzr, xzr, cond.inverted`
    public static func cset(is64Bit: Bool = true, rd: A64GPR, cond: A64Cond) -> A64Instruction {
        A64Instruction(opcode: .csinc, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: .xzr, cond: cond.inverted)
    }

    /// `csetm Rd, cond` -> `csinv Rd, xzr, xzr, cond.inverted`
    public static func csetm(is64Bit: Bool = true, rd: A64GPR, cond: A64Cond) -> A64Instruction {
        A64Instruction(opcode: .csinv, is64Bit: is64Bit, rd: rd, rn: .xzr, rm: .xzr, cond: cond.inverted)
    }

    /// `lsl Rd, Rn, #shift` -> `ubfm Rd, Rn, #(-shift mod width), #(width - 1 - shift)`
    public static func lslImm(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, shift: UInt8) -> A64Instruction {
        let width: UInt8 = is64Bit ? 64 : 32
        let s = shift % width
        let immr = (width - s) % width
        let imms = width - 1 - s
        return A64Instruction(opcode: .ubfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(immr), imm2: imms)
    }

    /// `lsr Rd, Rn, #shift` -> `ubfm Rd, Rn, #shift, #(width - 1)`
    public static func lsrImm(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, shift: UInt8) -> A64Instruction {
        let width: UInt8 = is64Bit ? 64 : 32
        return A64Instruction(opcode: .ubfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(shift), imm2: width - 1)
    }

    /// `asr Rd, Rn, #shift` -> `sbfm Rd, Rn, #shift, #(width - 1)`
    public static func asrImm(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, shift: UInt8) -> A64Instruction {
        let width: UInt8 = is64Bit ? 64 : 32
        return A64Instruction(opcode: .sbfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(shift), imm2: width - 1)
    }

    /// `ror Rd, Rn, #shift` -> `extr Rd, Rn, Rn, #shift`
    public static func rorImm(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, shift: UInt8) -> A64Instruction {
        A64Instruction(opcode: .extr, is64Bit: is64Bit, rd: rd, rn: rn, rm: rn, amount: shift)
    }

    /// `ubfx Rd, Rn, #lsb, #width` -> `ubfm Rd, Rn, #lsb, #(lsb + width - 1)`
    public static func ubfx(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, lsb: UInt8, width: UInt8) -> A64Instruction {
        A64Instruction(opcode: .ubfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(lsb), imm2: lsb + width - 1)
    }

    /// `sbfx Rd, Rn, #lsb, #width` -> `sbfm Rd, Rn, #lsb, #(lsb + width - 1)`
    public static func sbfx(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, lsb: UInt8, width: UInt8) -> A64Instruction {
        A64Instruction(opcode: .sbfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(lsb), imm2: lsb + width - 1)
    }

    /// `bfi Rd, Rn, #lsb, #width` -> `bfm Rd, Rn, #(-lsb mod regWidth), #(width - 1)`
    public static func bfi(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, lsb: UInt8, width: UInt8) -> A64Instruction {
        let regWidth: UInt8 = is64Bit ? 64 : 32
        let immr = (regWidth - (lsb % regWidth)) % regWidth
        return A64Instruction(opcode: .bfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(immr), imm2: width - 1)
    }

    /// `bfxil Rd, Rn, #lsb, #width` -> `bfm Rd, Rn, #lsb, #(lsb + width - 1)`
    public static func bfxil(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR, lsb: UInt8, width: UInt8) -> A64Instruction {
        A64Instruction(opcode: .bfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: Int64(lsb), imm2: lsb + width - 1)
    }

    /// `uxtb Wd, Wn` -> `ubfm Wd, Wn, #0, #7`
    public static func uxtb(rd: A64GPR, rn: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .ubfm, is64Bit: false, rd: rd, rn: rn, imm: 0, imm2: 7)
    }

    /// `uxth Wd, Wn` -> `ubfm Wd, Wn, #0, #15`
    public static func uxth(rd: A64GPR, rn: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .ubfm, is64Bit: false, rd: rd, rn: rn, imm: 0, imm2: 15)
    }

    /// `sxtb Rd, Wn` -> `sbfm Rd, Rn, #0, #7`
    public static func sxtb(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .sbfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: 0, imm2: 7)
    }

    /// `sxth Rd, Wn` -> `sbfm Rd, Rn, #0, #15`
    public static func sxth(is64Bit: Bool = true, rd: A64GPR, rn: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .sbfm, is64Bit: is64Bit, rd: rd, rn: rn, imm: 0, imm2: 15)
    }

    /// `sxtw Xd, Wn` -> `sbfm Xd, Xn, #0, #31`
    public static func sxtw(rd: A64GPR, rn: A64GPR) -> A64Instruction {
        A64Instruction(opcode: .sbfm, is64Bit: true, rd: rd, rn: rn, imm: 0, imm2: 31)
    }
}

/// Shared instruction descriptor table driving `A64Encoder`, `A64Disassembler`, and `Asm` (04-backend.md §4.9).
public enum A64InstructionTable {
    public static let entries: [A64InstrDesc] = [
        // --- 1. Data processing — immediate ---
        A64InstrDesc(id: .addImm,  mnemonic: "add",  format: .addSubImm,  opcodeMask: 0x7F80_0000, opcodeBits: 0x1100_0000),
        A64InstrDesc(id: .addsImm, mnemonic: "adds", format: .addSubImm,  opcodeMask: 0x7F80_0000, opcodeBits: 0x3100_0000),
        A64InstrDesc(id: .subImm,  mnemonic: "sub",  format: .addSubImm,  opcodeMask: 0x7F80_0000, opcodeBits: 0x5100_0000),
        A64InstrDesc(id: .subsImm, mnemonic: "subs", format: .addSubImm,  opcodeMask: 0x7F80_0000, opcodeBits: 0x7100_0000),

        A64InstrDesc(id: .movn, mnemonic: "movn", format: .movWide, opcodeMask: 0x7F80_0000, opcodeBits: 0x1280_0000),
        A64InstrDesc(id: .movz, mnemonic: "movz", format: .movWide, opcodeMask: 0x7F80_0000, opcodeBits: 0x5280_0000),
        A64InstrDesc(id: .movk, mnemonic: "movk", format: .movWide, opcodeMask: 0x7F80_0000, opcodeBits: 0x7280_0000),

        A64InstrDesc(id: .adr,  mnemonic: "adr",  format: .pcRel, opcodeMask: 0x9F00_0000, opcodeBits: 0x1000_0000),
        A64InstrDesc(id: .adrp, mnemonic: "adrp", format: .pcRel, opcodeMask: 0x9F00_0000, opcodeBits: 0x9000_0000),

        A64InstrDesc(id: .andImm,  mnemonic: "and",  format: .logicalImm, opcodeMask: 0x7F80_0000, opcodeBits: 0x1200_0000),
        A64InstrDesc(id: .orrImm,  mnemonic: "orr",  format: .logicalImm, opcodeMask: 0x7F80_0000, opcodeBits: 0x3200_0000),
        A64InstrDesc(id: .eorImm,  mnemonic: "eor",  format: .logicalImm, opcodeMask: 0x7F80_0000, opcodeBits: 0x5200_0000),
        A64InstrDesc(id: .andsImm, mnemonic: "ands", format: .logicalImm, opcodeMask: 0x7F80_0000, opcodeBits: 0x7200_0000),

        A64InstrDesc(id: .sbfm, mnemonic: "sbfm", format: .bitfield, opcodeMask: 0x7F80_0000, opcodeBits: 0x1300_0000),
        A64InstrDesc(id: .bfm,  mnemonic: "bfm",  format: .bitfield, opcodeMask: 0x7F80_0000, opcodeBits: 0x3300_0000),
        A64InstrDesc(id: .ubfm, mnemonic: "ubfm", format: .bitfield, opcodeMask: 0x7F80_0000, opcodeBits: 0x5300_0000),

        A64InstrDesc(id: .extr, mnemonic: "extr", format: .extract, opcodeMask: 0x7FA0_0000, opcodeBits: 0x1380_0000),

        // --- 2. Data processing — register ---
        A64InstrDesc(id: .addShifted,  mnemonic: "add",  format: .addSubShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x0B00_0000),
        A64InstrDesc(id: .addsShifted, mnemonic: "adds", format: .addSubShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x2B00_0000),
        A64InstrDesc(id: .subShifted,  mnemonic: "sub",  format: .addSubShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x4B00_0000),
        A64InstrDesc(id: .subsShifted, mnemonic: "subs", format: .addSubShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x6B00_0000),

        A64InstrDesc(id: .addExtended,  mnemonic: "add",  format: .addSubExtended, opcodeMask: 0x7FE0_0000, opcodeBits: 0x0B20_0000),
        A64InstrDesc(id: .addsExtended, mnemonic: "adds", format: .addSubExtended, opcodeMask: 0x7FE0_0000, opcodeBits: 0x2B20_0000),
        A64InstrDesc(id: .subExtended,  mnemonic: "sub",  format: .addSubExtended, opcodeMask: 0x7FE0_0000, opcodeBits: 0x4B20_0000),
        A64InstrDesc(id: .subsExtended, mnemonic: "subs", format: .addSubExtended, opcodeMask: 0x7FE0_0000, opcodeBits: 0x6B20_0000),

        A64InstrDesc(id: .andShifted,  mnemonic: "and",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x0A00_0000),
        A64InstrDesc(id: .bicShifted,  mnemonic: "bic",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x0A20_0000),
        A64InstrDesc(id: .orrShifted,  mnemonic: "orr",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x2A00_0000),
        A64InstrDesc(id: .ornShifted,  mnemonic: "orn",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x2A20_0000),
        A64InstrDesc(id: .eorShifted,  mnemonic: "eor",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x4A00_0000),
        A64InstrDesc(id: .eonShifted,  mnemonic: "eon",  format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x4A20_0000),
        A64InstrDesc(id: .andsShifted, mnemonic: "ands", format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x6A00_0000),
        A64InstrDesc(id: .bicsShifted, mnemonic: "bics", format: .logicalShifted, opcodeMask: 0x7F20_0000, opcodeBits: 0x6A20_0000),

        A64InstrDesc(id: .udiv, mnemonic: "udiv", format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_0800),
        A64InstrDesc(id: .sdiv, mnemonic: "sdiv", format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_0C00),
        A64InstrDesc(id: .lslv, mnemonic: "lsl",  format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_2000),
        A64InstrDesc(id: .lsrv, mnemonic: "lsr",  format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_2400),
        A64InstrDesc(id: .asrv, mnemonic: "asr",  format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_2800),
        A64InstrDesc(id: .rorv, mnemonic: "ror",  format: .dp2Source, opcodeMask: 0x7FE0_FC00, opcodeBits: 0x1AC0_2C00),

        A64InstrDesc(id: .rbit,  mnemonic: "rbit",  format: .dp1Source, opcodeMask: 0x7FFF_FC00, opcodeBits: 0x5AC0_0000),
        A64InstrDesc(id: .rev16, mnemonic: "rev16", format: .dp1Source, opcodeMask: 0x7FFF_FC00, opcodeBits: 0x5AC0_0400),
        A64InstrDesc(id: .rev32, mnemonic: "rev32", format: .dp1Source, opcodeMask: 0xFFFF_FC00, opcodeBits: 0xDAC0_0800),
        A64InstrDesc(id: .rev,   mnemonic: "rev",   format: .dp1Source, opcodeMask: 0x7FFF_F800, opcodeBits: 0x5AC0_0800),
        A64InstrDesc(id: .clz,   mnemonic: "clz",   format: .dp1Source, opcodeMask: 0x7FFF_FC00, opcodeBits: 0x5AC0_1000),

        A64InstrDesc(id: .smulh, mnemonic: "smulh", format: .mulHigh,   opcodeMask: 0xFFE0_FC00, opcodeBits: 0x9B40_7C00),
        A64InstrDesc(id: .umulh, mnemonic: "umulh", format: .mulHigh,   opcodeMask: 0xFFE0_FC00, opcodeBits: 0x9BC0_7C00),
        A64InstrDesc(id: .madd,  mnemonic: "madd",  format: .dp3Source, opcodeMask: 0x7FE0_8000, opcodeBits: 0x1B00_0000),
        A64InstrDesc(id: .msub,  mnemonic: "msub",  format: .dp3Source, opcodeMask: 0x7FE0_8000, opcodeBits: 0x1B00_8000),

        A64InstrDesc(id: .csel,  mnemonic: "csel",  format: .condSelect, opcodeMask: 0x7FE0_0C00, opcodeBits: 0x1A80_0000),
        A64InstrDesc(id: .csinc, mnemonic: "csinc", format: .condSelect, opcodeMask: 0x7FE0_0C00, opcodeBits: 0x1A80_0400),
        A64InstrDesc(id: .csinv, mnemonic: "csinv", format: .condSelect, opcodeMask: 0x7FE0_0C00, opcodeBits: 0x5A80_0000),
        A64InstrDesc(id: .csneg, mnemonic: "csneg", format: .condSelect, opcodeMask: 0x7FE0_0C00, opcodeBits: 0x5A80_0400),

        A64InstrDesc(id: .ccmpReg, mnemonic: "ccmp", format: .condCompareReg, opcodeMask: 0x7FE0_0C10, opcodeBits: 0x7A40_0000),
        A64InstrDesc(id: .ccmpImm, mnemonic: "ccmp", format: .condCompareImm, opcodeMask: 0x7FE0_0C10, opcodeBits: 0x7A40_0800),

        // --- 3. Branches, exceptions, system ---
        A64InstrDesc(id: .b,     mnemonic: "b",    format: .branchImm26,     opcodeMask: 0xFC00_0000, opcodeBits: 0x1400_0000),
        A64InstrDesc(id: .bl,    mnemonic: "bl",   format: .branchImm26,     opcodeMask: 0xFC00_0000, opcodeBits: 0x9400_0000),
        A64InstrDesc(id: .bCond, mnemonic: "b.",   format: .branchCond19,    opcodeMask: 0xFF00_0010, opcodeBits: 0x5400_0000),
        A64InstrDesc(id: .cbz,   mnemonic: "cbz",  format: .compareBranch19, opcodeMask: 0x7F00_0000, opcodeBits: 0x3400_0000),
        A64InstrDesc(id: .cbnz,  mnemonic: "cbnz", format: .compareBranch19, opcodeMask: 0x7F00_0000, opcodeBits: 0x3500_0000),
        A64InstrDesc(id: .tbz,   mnemonic: "tbz",  format: .testBranch14,    opcodeMask: 0x7F00_0000, opcodeBits: 0x3600_0000),
        A64InstrDesc(id: .tbnz,  mnemonic: "tbnz", format: .testBranch14,    opcodeMask: 0x7F00_0000, opcodeBits: 0x3700_0000),

        A64InstrDesc(id: .br,  mnemonic: "br",  format: .branchReg, opcodeMask: 0xFFFF_FC1F, opcodeBits: 0xD61F_0000),
        A64InstrDesc(id: .blr, mnemonic: "blr", format: .branchReg, opcodeMask: 0xFFFF_FC1F, opcodeBits: 0xD63F_0000),
        A64InstrDesc(id: .ret, mnemonic: "ret", format: .branchReg, opcodeMask: 0xFFFF_FC1F, opcodeBits: 0xD65F_0000),

        A64InstrDesc(id: .svc, mnemonic: "svc", format: .exceptionImm16, opcodeMask: 0xFFE0_001F, opcodeBits: 0xD400_0001),
        A64InstrDesc(id: .hvc, mnemonic: "hvc", format: .exceptionImm16, opcodeMask: 0xFFE0_001F, opcodeBits: 0xD400_0002),
        A64InstrDesc(id: .smc, mnemonic: "smc", format: .exceptionImm16, opcodeMask: 0xFFE0_001F, opcodeBits: 0xD400_0003),
        A64InstrDesc(id: .brk, mnemonic: "brk", format: .exceptionImm16, opcodeMask: 0xFFE0_001F, opcodeBits: 0xD420_0000),
        A64InstrDesc(id: .hlt, mnemonic: "hlt", format: .exceptionImm16, opcodeMask: 0xFFE0_001F, opcodeBits: 0xD440_0000),
        A64InstrDesc(id: .udf, mnemonic: "udf", format: .udfImm16,       opcodeMask: 0xFFFF_0000, opcodeBits: 0x0000_0000),

        A64InstrDesc(id: .eret,  mnemonic: "eret",  format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD69F_03E0),
        A64InstrDesc(id: .nop,   mnemonic: "nop",   format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_201F),
        A64InstrDesc(id: .yield, mnemonic: "yield", format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_203F),
        A64InstrDesc(id: .wfe,   mnemonic: "wfe",   format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_205F),
        A64InstrDesc(id: .wfi,   mnemonic: "wfi",   format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_207F),
        A64InstrDesc(id: .sev,   mnemonic: "sev",   format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_209F),
        A64InstrDesc(id: .sevl,  mnemonic: "sevl",  format: .fixedSystem, opcodeMask: 0xFFFF_FFFF, opcodeBits: 0xD503_20BF),
        A64InstrDesc(id: .hint,  mnemonic: "hint",  format: .hintImm7,    opcodeMask: 0xFFFF_F01F, opcodeBits: 0xD503_201F),

        A64InstrDesc(id: .clrex, mnemonic: "clrex", format: .barrier, opcodeMask: 0xFFFF_F0FF, opcodeBits: 0xD503_305F),
        A64InstrDesc(id: .dsb,   mnemonic: "dsb",   format: .barrier, opcodeMask: 0xFFFF_F0FF, opcodeBits: 0xD503_309F),
        A64InstrDesc(id: .dmb,   mnemonic: "dmb",   format: .barrier, opcodeMask: 0xFFFF_F0FF, opcodeBits: 0xD503_30BF),
        A64InstrDesc(id: .isb,   mnemonic: "isb",   format: .barrier, opcodeMask: 0xFFFF_F0FF, opcodeBits: 0xD503_30DF),

        A64InstrDesc(id: .msrPState, mnemonic: "msr",  format: .msrPState, opcodeMask: 0xFFF8_F01F, opcodeBits: 0xD500_401F),
        A64InstrDesc(id: .sysMaint,  mnemonic: "sys",  format: .sysMaint,  opcodeMask: 0xFFF8_0000, opcodeBits: 0xD508_0000),
        A64InstrDesc(id: .mrs,       mnemonic: "mrs",  format: .mrs,       opcodeMask: 0xFFF0_0000, opcodeBits: 0xD530_0000),
        A64InstrDesc(id: .msrReg,    mnemonic: "msr",  format: .msrReg,    opcodeMask: 0xFFF0_0000, opcodeBits: 0xD510_0000),

        // --- 4. Loads and stores ---
        // Unsigned scaled immediate (GPR)
        A64InstrDesc(id: .ldrImm,     mnemonic: "ldr",   format: .ldstUnsignedImm12, opcodeMask: 0xBFC0_0000, opcodeBits: 0xB940_0000, scaleLog2: 255),
        A64InstrDesc(id: .strImm,     mnemonic: "str",   format: .ldstUnsignedImm12, opcodeMask: 0xBFC0_0000, opcodeBits: 0xB900_0000, scaleLog2: 255),
        A64InstrDesc(id: .ldrbImm,    mnemonic: "ldrb",  format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3940_0000, scaleLog2: 0),
        A64InstrDesc(id: .strbImm,    mnemonic: "strb",  format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3900_0000, scaleLog2: 0),
        A64InstrDesc(id: .ldrhImm,    mnemonic: "ldrh",  format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x7940_0000, scaleLog2: 1),
        A64InstrDesc(id: .strhImm,    mnemonic: "strh",  format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x7900_0000, scaleLog2: 1),
        A64InstrDesc(id: .ldrsbImm64, mnemonic: "ldrsb", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3980_0000, scaleLog2: 0),
        A64InstrDesc(id: .ldrsbImm32, mnemonic: "ldrsb", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x39C0_0000, scaleLog2: 0),
        A64InstrDesc(id: .ldrshImm64, mnemonic: "ldrsh", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x7980_0000, scaleLog2: 1),
        A64InstrDesc(id: .ldrshImm32, mnemonic: "ldrsh", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x79C0_0000, scaleLog2: 1),
        A64InstrDesc(id: .ldrswImm,   mnemonic: "ldrsw", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0xB980_0000, scaleLog2: 2),

        // Unsigned scaled immediate (SIMD/FP b/h/s/d/q)
        A64InstrDesc(id: .ldrFpImmB, mnemonic: "ldr", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3D40_0000, scaleLog2: 0, scalarWidth: .b),
        A64InstrDesc(id: .strFpImmB, mnemonic: "str", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3D00_0000, scaleLog2: 0, scalarWidth: .b),
        A64InstrDesc(id: .ldrFpImmH, mnemonic: "ldr", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x7D40_0000, scaleLog2: 1, scalarWidth: .h),
        A64InstrDesc(id: .strFpImmH, mnemonic: "str", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x7D00_0000, scaleLog2: 1, scalarWidth: .h),
        A64InstrDesc(id: .ldrFpImmS, mnemonic: "ldr", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0xBD40_0000, scaleLog2: 2, scalarWidth: .s),
        A64InstrDesc(id: .strFpImmS, mnemonic: "str", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0xBD00_0000, scaleLog2: 2, scalarWidth: .s),
        A64InstrDesc(id: .ldrFpImmD, mnemonic: "ldr", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0xFD40_0000, scaleLog2: 3, scalarWidth: .d),
        A64InstrDesc(id: .strFpImmD, mnemonic: "str", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0xFD00_0000, scaleLog2: 3, scalarWidth: .d),
        A64InstrDesc(id: .ldrFpImmQ, mnemonic: "ldr", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3DC0_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .strFpImmQ, mnemonic: "str", format: .ldstUnsignedImm12, opcodeMask: 0xFFC0_0000, opcodeBits: 0x3D80_0000, scaleLog2: 4, scalarWidth: .q),

        // Pre-index `[Xn, #simm9]!`
        A64InstrDesc(id: .ldrPre,     mnemonic: "ldr",   format: .ldstPreImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB840_0C00),
        A64InstrDesc(id: .strPre,     mnemonic: "str",   format: .ldstPreImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB800_0C00),
        A64InstrDesc(id: .ldrbPre,    mnemonic: "ldrb",  format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3840_0C00),
        A64InstrDesc(id: .strbPre,    mnemonic: "strb",  format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3800_0C00),
        A64InstrDesc(id: .ldrhPre,    mnemonic: "ldrh",  format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7840_0C00),
        A64InstrDesc(id: .strhPre,    mnemonic: "strh",  format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7800_0C00),
        A64InstrDesc(id: .ldrsbPre64, mnemonic: "ldrsb", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3880_0C00),
        A64InstrDesc(id: .ldrshPre64, mnemonic: "ldrsh", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0C00),
        A64InstrDesc(id: .ldrswPre,   mnemonic: "ldrsw", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB880_0C00),

        // Post-index `[Xn], #simm9`
        A64InstrDesc(id: .ldrPost,     mnemonic: "ldr",   format: .ldstPostImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB840_0400),
        A64InstrDesc(id: .strPost,     mnemonic: "str",   format: .ldstPostImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB800_0400),
        A64InstrDesc(id: .ldrbPost,    mnemonic: "ldrb",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3840_0400),
        A64InstrDesc(id: .strbPost,    mnemonic: "strb",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3800_0400),
        A64InstrDesc(id: .ldrhPost,    mnemonic: "ldrh",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7840_0400),
        A64InstrDesc(id: .strhPost,    mnemonic: "strh",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7800_0400),
        A64InstrDesc(id: .ldrsbPost64, mnemonic: "ldrsb", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3880_0400),
        A64InstrDesc(id: .ldrshPost64, mnemonic: "ldrsh", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0400),
        A64InstrDesc(id: .ldrswPost,   mnemonic: "ldrsw", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB880_0400),

        // Unscaled (`ldur`/`stur`)
        A64InstrDesc(id: .ldur,     mnemonic: "ldur",   format: .ldstUnscaledImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB840_0000),
        A64InstrDesc(id: .stur,     mnemonic: "stur",   format: .ldstUnscaledImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB800_0000),
        A64InstrDesc(id: .ldurb,    mnemonic: "ldurb",  format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3840_0000),
        A64InstrDesc(id: .sturb,    mnemonic: "sturb",  format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3800_0000),
        A64InstrDesc(id: .ldurh,    mnemonic: "ldurh",  format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7840_0000),
        A64InstrDesc(id: .sturh,    mnemonic: "sturh",  format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7800_0000),
        A64InstrDesc(id: .ldursb64, mnemonic: "ldursb", format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3880_0000),
        A64InstrDesc(id: .ldursb32, mnemonic: "ldursb", format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38C0_0000),
        A64InstrDesc(id: .ldursh64, mnemonic: "ldursh", format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0000),
        A64InstrDesc(id: .ldursh32, mnemonic: "ldursh", format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78C0_0000),
        A64InstrDesc(id: .ldursw,   mnemonic: "ldursw", format: .ldstUnscaledImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB880_0000),

        // Unprivileged (`ldtr`/`sttr`)
        A64InstrDesc(id: .ldtr,     mnemonic: "ldtr",   format: .ldstUnprivImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB840_0800),
        A64InstrDesc(id: .sttr,     mnemonic: "sttr",   format: .ldstUnprivImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB800_0800),
        A64InstrDesc(id: .ldtrb,    mnemonic: "ldtrb",  format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3840_0800),
        A64InstrDesc(id: .sttrb,    mnemonic: "sttrb",  format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3800_0800),
        A64InstrDesc(id: .ldtrh,    mnemonic: "ldtrh",  format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7840_0800),
        A64InstrDesc(id: .sttrh,    mnemonic: "sttrh",  format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7800_0800),
        A64InstrDesc(id: .ldtrsb64, mnemonic: "ldtrsb", format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3880_0800),
        A64InstrDesc(id: .ldtrsb32, mnemonic: "ldtrsb", format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38C0_0800),
        A64InstrDesc(id: .ldtrsh64, mnemonic: "ldtrsh", format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0800),
        A64InstrDesc(id: .ldtrsh32, mnemonic: "ldtrsh", format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78C0_0800),
        A64InstrDesc(id: .ldtrsw,   mnemonic: "ldtrsw", format: .ldstUnprivImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB880_0800),

        // Register offset `[Xn, Rm, extend #shift]`
        A64InstrDesc(id: .ldrReg,     mnemonic: "ldr",   format: .ldstRegOffset, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB860_0800, scaleLog2: 255),
        A64InstrDesc(id: .strReg,     mnemonic: "str",   format: .ldstRegOffset, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB820_0800, scaleLog2: 255),
        A64InstrDesc(id: .ldrbReg,    mnemonic: "ldrb",  format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3860_0800, scaleLog2: 0),
        A64InstrDesc(id: .strbReg,    mnemonic: "strb",  format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3820_0800, scaleLog2: 0),
        A64InstrDesc(id: .ldrhReg,    mnemonic: "ldrh",  format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7860_0800, scaleLog2: 1),
        A64InstrDesc(id: .strhReg,    mnemonic: "strh",  format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7820_0800, scaleLog2: 1),
        A64InstrDesc(id: .ldrsbReg64, mnemonic: "ldrsb", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38A0_0800, scaleLog2: 0),
        A64InstrDesc(id: .ldrshReg64, mnemonic: "ldrsh", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78A0_0800, scaleLog2: 1),
        A64InstrDesc(id: .ldrswReg,   mnemonic: "ldrsw", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB8A0_0800, scaleLog2: 2),

        // Literal `ldr Wt/Xt, label`
        A64InstrDesc(id: .ldrLit, mnemonic: "ldr", format: .ldrLiteral, opcodeMask: 0xBF00_0000, opcodeBits: 0x1800_0000),

        // Load/store pairs (`ldp`/`stp` for 32-bit `w`, 64-bit `x`, and 128-bit `q`)
        A64InstrDesc(id: .ldpSigned,  mnemonic: "ldp", format: .ldpStpSigned, opcodeMask: 0x7FC0_0000, opcodeBits: 0x2940_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpSigned,  mnemonic: "stp", format: .ldpStpSigned, opcodeMask: 0x7FC0_0000, opcodeBits: 0x2900_0000, scaleLog2: 255),
        A64InstrDesc(id: .ldpPre,     mnemonic: "ldp", format: .ldpStpPre,    opcodeMask: 0x7FC0_0000, opcodeBits: 0x29C0_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpPre,     mnemonic: "stp", format: .ldpStpPre,    opcodeMask: 0x7FC0_0000, opcodeBits: 0x2980_0000, scaleLog2: 255),
        A64InstrDesc(id: .ldpPost,    mnemonic: "ldp", format: .ldpStpPost,   opcodeMask: 0x7FC0_0000, opcodeBits: 0x28C0_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpPost,    mnemonic: "stp", format: .ldpStpPost,   opcodeMask: 0x7FC0_0000, opcodeBits: 0x2880_0000, scaleLog2: 255),

        A64InstrDesc(id: .ldpSignedQ, mnemonic: "ldp", format: .ldpStpSigned, opcodeMask: 0xFFC0_0000, opcodeBits: 0xAD40_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .stpSignedQ, mnemonic: "stp", format: .ldpStpSigned, opcodeMask: 0xFFC0_0000, opcodeBits: 0xAD00_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .ldpPreQ,    mnemonic: "ldp", format: .ldpStpPre,    opcodeMask: 0xFFC0_0000, opcodeBits: 0xADC0_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .stpPreQ,    mnemonic: "stp", format: .ldpStpPre,    opcodeMask: 0xFFC0_0000, opcodeBits: 0xAD80_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .ldpPostQ,   mnemonic: "ldp", format: .ldpStpPost,   opcodeMask: 0xFFC0_0000, opcodeBits: 0xACC0_0000, scaleLog2: 4, scalarWidth: .q),
        A64InstrDesc(id: .stpPostQ,   mnemonic: "stp", format: .ldpStpPost,   opcodeMask: 0xFFC0_0000, opcodeBits: 0xAC80_0000, scaleLog2: 4, scalarWidth: .q),

        // Atomics & exclusives
        A64InstrDesc(id: .ldxr,  mnemonic: "ldxr",  format: .atomicLoad,      opcodeMask: 0xBFFF_FC00, opcodeBits: 0x885F_7C00),
        A64InstrDesc(id: .ldaxr, mnemonic: "ldaxr", format: .atomicLoad,      opcodeMask: 0xBFFF_FC00, opcodeBits: 0x885F_FC00),
        A64InstrDesc(id: .stxr,  mnemonic: "stxr",  format: .atomicStoreExcl, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x8800_7C00),
        A64InstrDesc(id: .stlxr, mnemonic: "stlxr", format: .atomicStoreExcl, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x8800_FC00),
        A64InstrDesc(id: .ldar,  mnemonic: "ldar",  format: .atomicLoad,      opcodeMask: 0xBFFF_FC00, opcodeBits: 0x88DF_FC00),
        A64InstrDesc(id: .stlr,  mnemonic: "stlr",  format: .atomicStore,     opcodeMask: 0xBFFF_FC00, opcodeBits: 0x889F_FC00),
        A64InstrDesc(id: .ldarb, mnemonic: "ldarb", format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x08DF_FC00),
        A64InstrDesc(id: .stlrb, mnemonic: "stlrb", format: .atomicStore,     opcodeMask: 0xFFFF_FC00, opcodeBits: 0x089F_FC00),
        A64InstrDesc(id: .ldarh, mnemonic: "ldarh", format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x48DF_FC00),
        A64InstrDesc(id: .stlrh, mnemonic: "stlrh", format: .atomicStore,     opcodeMask: 0xFFFF_FC00, opcodeBits: 0x489F_FC00),

        // --- 5. Scalar FP ---
        A64InstrDesc(id: .fmovGprToFp, mnemonic: "fmov",   format: .fpMovGprToFp, opcodeMask: 0x7FBF_FC00, opcodeBits: 0x1E27_0000),
        A64InstrDesc(id: .fmovFpToGpr, mnemonic: "fmov",   format: .fpMovFpToGpr, opcodeMask: 0x7FBF_FC00, opcodeBits: 0x1E26_0000),
        A64InstrDesc(id: .fmovReg,     mnemonic: "fmov",   format: .fpMovReg,     opcodeMask: 0xFFBF_FC00, opcodeBits: 0x1E20_4000),
        A64InstrDesc(id: .fcvtStoD,    mnemonic: "fcvt",   format: .fpCvtReg,     opcodeMask: 0xFFFF_FC00, opcodeBits: 0x1E22_C000),
        A64InstrDesc(id: .fcvtDtoS,    mnemonic: "fcvt",   format: .fpCvtReg,     opcodeMask: 0xFFFF_FC00, opcodeBits: 0x1E62_4000),
        A64InstrDesc(id: .scvtf,       mnemonic: "scvtf",  format: .fpIntToFp,    opcodeMask: 0x7FBF_FC00, opcodeBits: 0x1E22_0000),
        A64InstrDesc(id: .fcvtzs,      mnemonic: "fcvtzs", format: .fpToInt,      opcodeMask: 0x7FBF_FC00, opcodeBits: 0x1E38_0000),
        A64InstrDesc(id: .fmulScalar,  mnemonic: "fmul",   format: .fpBinary,     opcodeMask: 0xFFa0_FC00, opcodeBits: 0x1E20_0800),
        A64InstrDesc(id: .fdivScalar,  mnemonic: "fdiv",   format: .fpBinary,     opcodeMask: 0xFFa0_FC00, opcodeBits: 0x1E20_1800),
        A64InstrDesc(id: .faddScalar,  mnemonic: "fadd",   format: .fpBinary,     opcodeMask: 0xFFa0_FC00, opcodeBits: 0x1E20_2800),
        A64InstrDesc(id: .fsubScalar,  mnemonic: "fsub",   format: .fpBinary,     opcodeMask: 0xFFa0_FC00, opcodeBits: 0x1E20_3800),
        A64InstrDesc(id: .fcmpZero,    mnemonic: "fcmp",   format: .fpCmpZero,    opcodeMask: 0xFFBF_FC1F, opcodeBits: 0x1E20_2008),
        A64InstrDesc(id: .fcmpReg,     mnemonic: "fcmp",   format: .fpCmpReg,     opcodeMask: 0xFFa0_FC1F, opcodeBits: 0x1E20_2000),

        // --- 6. Advanced SIMD (NEON) ---
        A64InstrDesc(id: .simdAdd,  mnemonic: "add",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_8400),
        A64InstrDesc(id: .simdSub,  mnemonic: "sub",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_8400),
        A64InstrDesc(id: .simdMul,  mnemonic: "mul",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_9C00),
        A64InstrDesc(id: .simdCmeq, mnemonic: "cmeq", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_8C00),
        A64InstrDesc(id: .simdCmgt, mnemonic: "cmgt", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_3400),
        A64InstrDesc(id: .simdCmge, mnemonic: "cmge", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_3C00),

        A64InstrDesc(id: .simdAnd, mnemonic: "and", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E20_1C00),
        A64InstrDesc(id: .simdBic, mnemonic: "bic", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E60_1C00),
        A64InstrDesc(id: .simdOrr, mnemonic: "orr", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0EA0_1C00),
        A64InstrDesc(id: .simdOrn, mnemonic: "orn", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0EE0_1C00),
        A64InstrDesc(id: .simdEor, mnemonic: "eor", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x2E20_1C00),

        A64InstrDesc(id: .simdFadd, mnemonic: "fadd", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_D400),
        A64InstrDesc(id: .simdFsub, mnemonic: "fsub", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0EA0_D400),
        A64InstrDesc(id: .simdFmul, mnemonic: "fmul", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_DC00),
        A64InstrDesc(id: .simdFdiv, mnemonic: "fdiv", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_FC00),

        A64InstrDesc(id: .simdUzp1, mnemonic: "uzp1", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_1800),
        A64InstrDesc(id: .simdUzp2, mnemonic: "uzp2", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_5800),
        A64InstrDesc(id: .simdZip1, mnemonic: "zip1", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_3800),
        A64InstrDesc(id: .simdZip2, mnemonic: "zip2", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_7800),

        A64InstrDesc(id: .simdCnt,   mnemonic: "cnt",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_5800),
        A64InstrDesc(id: .simdRev64, mnemonic: "rev64", format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_0800),

        A64InstrDesc(id: .simdShl,  mnemonic: "shl",  format: .simdShiftImm, opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_5400),
        A64InstrDesc(id: .simdSshr, mnemonic: "sshr", format: .simdShiftImm, opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_0400),
        A64InstrDesc(id: .simdUshr, mnemonic: "ushr", format: .simdShiftImm, opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_0400),

        A64InstrDesc(id: .simdDupGpr, mnemonic: "dup",  format: .simdDupGpr,   opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_0C00),
        A64InstrDesc(id: .simdInsGpr, mnemonic: "ins",  format: .simdInsGpr,   opcodeMask: 0xFFE0_FC00, opcodeBits: 0x4E00_1C00),
        A64InstrDesc(id: .simdUmov,   mnemonic: "umov", format: .simdUmovSmov, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_3C00),
        A64InstrDesc(id: .simdSmov,   mnemonic: "smov", format: .simdUmovSmov, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_2C00),

        A64InstrDesc(id: .simdLd1One, mnemonic: "ld1", format: .simdLd1St1One, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C40_7000),
        A64InstrDesc(id: .simdSt1One, mnemonic: "st1", format: .simdLd1St1One, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C00_7000),
        A64InstrDesc(id: .simdTblOne, mnemonic: "tbl", format: .simdTblOne,    opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_0000),
        A64InstrDesc(id: .simdExt,    mnemonic: "ext", format: .simdExt,       opcodeMask: 0xBFE0_8400, opcodeBits: 0x2E00_0000),

        // --- 7. SVE (`croi/kernel/arch/arm64/cpu.S`) ---
        A64InstrDesc(id: .sveLdrZ,  mnemonic: "ldr",   format: .sveLdrStrZ, opcodeMask: 0xFFC0_E000, opcodeBits: 0x8580_4000),
        A64InstrDesc(id: .sveStrZ,  mnemonic: "str",   format: .sveLdrStrZ, opcodeMask: 0xFFC0_E000, opcodeBits: 0xE580_4000),
        A64InstrDesc(id: .sveLdrP,  mnemonic: "ldr",   format: .sveLdrStrP, opcodeMask: 0xFFC0_E010, opcodeBits: 0x8580_0000),
        A64InstrDesc(id: .sveStrP,  mnemonic: "str",   format: .sveLdrStrP, opcodeMask: 0xFFC0_E010, opcodeBits: 0xE580_0000),
        A64InstrDesc(id: .sveAddvl, mnemonic: "addvl", format: .sveAddVlPl, opcodeMask: 0xFFE0_F800, opcodeBits: 0x0420_5000),
        A64InstrDesc(id: .sveAddpl, mnemonic: "addpl", format: .sveAddVlPl, opcodeMask: 0xFFE0_F800, opcodeBits: 0x0460_5000),
        A64InstrDesc(id: .sveRdffr, mnemonic: "rdffr", format: .sveRdffr,   opcodeMask: 0xFFFF_FFF0, opcodeBits: 0x2519_F000),
        A64InstrDesc(id: .sveWrffr, mnemonic: "wrffr", format: .sveWrffr,   opcodeMask: 0xFFFF_FE1F, opcodeBits: 0x2528_9000),
    ]

    @usableFromInline
    internal static let byId: [A64OpcodeId: A64InstrDesc] = {
        var map: [A64OpcodeId: A64InstrDesc] = [:]
        map.reserveCapacity(entries.count)
        for desc in entries {
            map[desc.id] = desc
        }
        return map
    }()

    @inlinable
    public static func descriptor(for id: A64OpcodeId) -> A64InstrDesc {
        byId[id]!
    }
}

// MARK: - 4. AArch64 Table-Driven Encoder (`A64Encoder`)

public enum A64Encoder {
    /// Encodes a structured `A64Instruction` into a 32-bit machine word using `A64InstructionTable`.
    public static func encode(_ instr: A64Instruction) -> UInt32? {
        let desc = A64InstructionTable.descriptor(for: instr.opcode)
        let sf: UInt32 = instr.is64Bit ? (1 << 31) : 0
        let rd = UInt32(instr.rd.rawValue)
        let rn = UInt32(instr.rn.rawValue)
        let rm = UInt32(instr.rm.rawValue)
        let ra = UInt32(instr.ra.rawValue)
        let vd = UInt32(instr.vd.rawValue)
        let vn = UInt32(instr.vn.rawValue)
        let vm = UInt32(instr.vm.rawValue)

        switch desc.format {
        case .addSubImm:
            guard instr.imm >= 0 && instr.imm <= 0xFFF else { return nil }
            let sh: UInt32 = (instr.amount == 12) ? (1 << 22) : 0
            let imm12 = UInt32(instr.imm) & 0xFFF
            return sf | desc.opcodeBits | sh | (imm12 << 10) | (rn << 5) | rd

        case .movWide:
            guard instr.imm >= 0 && instr.imm <= 0xFFFF else { return nil }
            let hw = UInt32(instr.amount / 16) & 0x3
            if !instr.is64Bit && hw >= 2 { return nil }
            let imm16 = UInt32(instr.imm) & 0xFFFF
            return sf | desc.opcodeBits | (hw << 21) | (imm16 << 5) | rd

        case .pcRel:
            let rawDisp: Int64 = (instr.opcode == .adrp) ? (instr.imm >> 12) : instr.imm
            guard rawDisp >= -(1 << 20) && rawDisp < (1 << 20) else { return nil }
            let u21 = UInt32(bitPattern: Int32(truncatingIfNeeded: rawDisp)) & 0x1F_FFFF
            let immlo = u21 & 0x3
            let immhi = (u21 >> 2) & 0x7_FFFF
            return desc.opcodeBits | (immlo << 29) | (immhi << 5) | rd

        case .logicalImm:
            let maskVal = UInt64(bitPattern: instr.imm)
            guard let (n, immr, imms) = A64BitmaskImmediate.encode(value: maskVal, is64Bit: instr.is64Bit) else {
                return nil
            }
            return sf | desc.opcodeBits | (n << 22) | (immr << 16) | (imms << 10) | (rn << 5) | rd

        case .bitfield:
            let n: UInt32 = instr.is64Bit ? (1 << 22) : 0
            let immr = UInt32(instr.imm) & 0x3F
            let imms = UInt32(instr.imm2) & 0x3F
            return sf | desc.opcodeBits | n | (immr << 16) | (imms << 10) | (rn << 5) | rd

        case .extract:
            let n: UInt32 = instr.is64Bit ? (1 << 22) : 0
            let lsb = UInt32(instr.amount) & 0x3F
            return sf | desc.opcodeBits | n | (rm << 16) | (lsb << 10) | (rn << 5) | rd

        case .addSubShifted:
            if instr.shiftKind == .ror { return nil }
            let shift = UInt32(instr.shiftKind.rawValue) & 0x3
            let amt = UInt32(instr.amount) & 0x3F
            return sf | desc.opcodeBits | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd

        case .addSubExtended:
            guard instr.amount <= 4 else { return nil }
            let opt = UInt32(instr.extendKind.rawValue) & 0x7
            let imm3 = UInt32(instr.amount) & 0x7
            return sf | desc.opcodeBits | (rm << 16) | (opt << 13) | (imm3 << 10) | (rn << 5) | rd

        case .logicalShifted:
            let shift = UInt32(instr.shiftKind.rawValue) & 0x3
            let amt = UInt32(instr.amount) & 0x3F
            return sf | desc.opcodeBits | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd

        case .dp2Source:
            return sf | desc.opcodeBits | (rm << 16) | (rn << 5) | rd

        case .dp1Source:
            if instr.opcode == .rev {
                let opcBit10: UInt32 = instr.is64Bit ? (1 << 10) : 0
                return sf | desc.opcodeBits | opcBit10 | (rn << 5) | rd
            } else if instr.opcode == .rev32 {
                return desc.opcodeBits | (rn << 5) | rd
            }
            return sf | desc.opcodeBits | (rn << 5) | rd

        case .dp3Source:
            return sf | desc.opcodeBits | (rm << 16) | (ra << 10) | (rn << 5) | rd

        case .mulHigh:
            return desc.opcodeBits | (rm << 16) | (rn << 5) | rd

        case .condSelect:
            let c = UInt32(instr.cond.rawValue) & 0xF
            return sf | desc.opcodeBits | (rm << 16) | (c << 12) | (rn << 5) | rd

        case .condCompareReg:
            let c = UInt32(instr.cond.rawValue) & 0xF
            let nzcv = UInt32(instr.imm2) & 0xF
            return sf | desc.opcodeBits | (rm << 16) | (c << 12) | (rn << 5) | nzcv

        case .condCompareImm:
            let c = UInt32(instr.cond.rawValue) & 0xF
            let imm5 = UInt32(instr.imm) & 0x1F
            let nzcv = UInt32(instr.imm2) & 0xF
            return sf | desc.opcodeBits | (imm5 << 16) | (c << 12) | (rn << 5) | nzcv

        case .branchImm26:
            let words = instr.imm >> 2
            let imm26 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x03FF_FFFF
            return desc.opcodeBits | imm26

        case .branchCond19:
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            let c = UInt32(instr.cond.rawValue) & 0xF
            return desc.opcodeBits | (imm19 << 5) | c

        case .compareBranch19:
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            return sf | desc.opcodeBits | (imm19 << 5) | rd

        case .testBranch14:
            let bit = UInt32(instr.amount) & 0x3F
            let b5 = (bit >> 5) & 1
            let b40 = bit & 0x1F
            let words = instr.imm >> 2
            let imm14 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x3FFF
            return (b5 << 31) | desc.opcodeBits | (b40 << 19) | (imm14 << 5) | rd

        case .branchReg:
            return desc.opcodeBits | (rn << 5)

        case .exceptionImm16:
            let imm16 = UInt32(instr.imm) & 0xFFFF
            return desc.opcodeBits | (imm16 << 5)

        case .udfImm16:
            let imm16 = UInt32(instr.imm) & 0xFFFF
            return desc.opcodeBits | imm16

        case .fixedSystem:
            return desc.opcodeBits

        case .hintImm7:
            let imm7 = UInt32(instr.imm) & 0x7F
            return desc.opcodeBits | (imm7 << 5)

        case .barrier:
            let crm = UInt32(instr.barrierOption.rawValue) & 0xF
            return desc.opcodeBits | (crm << 8)

        case .mrs, .msrReg:
            let sys = UInt32(instr.sysReg.encoded15Bit)
            return desc.opcodeBits | (sys << 5) | rd

        case .msrPState:
            let crm = UInt32(instr.imm) & 0xF
            return desc.opcodeBits | (instr.pstateField.op1 << 16) | (crm << 8) | (instr.pstateField.op2 << 5)

        case .sysMaint:
            let f = instr.sysMaintOp.sysFields
            let rt: UInt32 = instr.sysMaintOp.takesRegister ? rd : 31
            return desc.opcodeBits | (f.op1 << 16) | (f.crn << 12) | (f.crm << 8) | (f.op2 << 5) | rt

        case .ldstUnsignedImm12:
            let shift: UInt8
            let sizeBit30: UInt32
            if desc.scaleLog2 == 255 {
                shift = instr.is64Bit ? 3 : 2
                sizeBit30 = instr.is64Bit ? (1 << 30) : 0
            } else {
                shift = desc.scaleLog2
                sizeBit30 = 0
            }
            guard instr.imm >= 0 else { return nil }
            let scaled = UInt64(instr.imm) >> shift
            guard (scaled << shift) == UInt64(instr.imm) && scaled <= 0xFFF else { return nil }
            let imm12 = UInt32(scaled) & 0xFFF
            let targetReg = (desc.scalarWidth != nil) ? vd : rd
            return desc.opcodeBits | sizeBit30 | (imm12 << 10) | (rn << 5) | targetReg

        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            guard instr.imm >= -256 && instr.imm <= 255 else { return nil }
            let imm9 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm)) & 0x1FF
            let sizeBit30: UInt32
            switch instr.opcode {
            case .ldrPre, .strPre, .ldrPost, .strPost, .ldur, .stur, .ldtr, .sttr:
                sizeBit30 = instr.is64Bit ? (1 << 30) : 0
            default:
                sizeBit30 = 0
            }
            return desc.opcodeBits | sizeBit30 | (imm9 << 12) | (rn << 5) | rd

        case .ldstRegOffset:
            let sizeBit30: UInt32
            let naturalShift: UInt8
            if desc.scaleLog2 == 255 {
                sizeBit30 = instr.is64Bit ? (1 << 30) : 0
                naturalShift = instr.is64Bit ? 3 : 2
            } else {
                sizeBit30 = 0
                naturalShift = desc.scaleLog2
            }
            let opt = UInt32(instr.extendKind.rawValue) & 0x7
            let sBit: UInt32 = (instr.amount != 0 && instr.amount == naturalShift) ? (1 << 12) : 0
            return desc.opcodeBits | sizeBit30 | (rm << 16) | (opt << 13) | sBit | (rn << 5) | rd

        case .ldrLiteral:
            let sizeBit30: UInt32 = instr.is64Bit ? (1 << 30) : 0
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            return desc.opcodeBits | sizeBit30 | (imm19 << 5) | rd

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            let isQuad = (desc.scalarWidth == .q)
            let shift: Int64 = isQuad ? 4 : (instr.is64Bit ? 3 : 2)
            let scaled = instr.imm >> shift
            guard (scaled << shift) == instr.imm && scaled >= -64 && scaled <= 63 else { return nil }
            let imm7 = UInt32(bitPattern: Int32(truncatingIfNeeded: scaled)) & 0x7F
            if isQuad {
                return desc.opcodeBits | (imm7 << 15) | (vn << 10) | (rn << 5) | vd
            } else {
                let sfBit: UInt32 = instr.is64Bit ? (1 << 31) : 0
                return sfBit | desc.opcodeBits | (imm7 << 15) | (rm << 10) | (rn << 5) | rd
            }

        case .atomicLoad, .atomicStore:
            let sizeBit30: UInt32
            switch instr.opcode {
            case .ldarb, .stlrb, .ldarh, .stlrh:
                sizeBit30 = 0
            default:
                sizeBit30 = instr.is64Bit ? (1 << 30) : 0
            }
            return desc.opcodeBits | sizeBit30 | (rn << 5) | rd

        case .atomicStoreExcl:
            let sizeBit30: UInt32 = instr.is64Bit ? (1 << 30) : 0
            // `rm` holds the status register `Ws`, `rd` holds the data register `Rt`, `rn` holds `[Xn]`
            return desc.opcodeBits | sizeBit30 | (rm << 16) | (rn << 5) | rd

        case .fpMovGprToFp:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            let sfBit: UInt32 = (instr.scalarWidth == .d) ? (1 << 31) : 0
            return sfBit | desc.opcodeBits | ftype | (rn << 5) | vd

        case .fpMovFpToGpr:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            let sfBit: UInt32 = (instr.scalarWidth == .d) ? (1 << 31) : 0
            return sfBit | desc.opcodeBits | ftype | (vn << 5) | rd

        case .fpMovReg:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return desc.opcodeBits | ftype | (vn << 5) | vd

        case .fpCvtReg:
            return desc.opcodeBits | (vn << 5) | vd

        case .fpIntToFp:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return sf | desc.opcodeBits | ftype | (rn << 5) | vd

        case .fpToInt:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return sf | desc.opcodeBits | ftype | (vn << 5) | rd

        case .fpBinary:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return desc.opcodeBits | ftype | (vm << 16) | (vn << 5) | vd

        case .fpCmpReg:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return desc.opcodeBits | ftype | (vm << 16) | (vn << 5)

        case .fpCmpZero:
            let ftype: UInt32 = (instr.scalarWidth == .d) ? (1 << 22) : 0
            return desc.opcodeBits | ftype | (vn << 5)

        case .simdThreeSameInt, .simdPermute:
            let q = instr.arrangement.qBit << 30
            let size = instr.arrangement.sizeBits << 22
            return q | size | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdThreeSameBit:
            let q = instr.arrangement.qBit << 30
            return q | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdThreeSameFp:
            let q = instr.arrangement.qBit << 30
            let sz: UInt32 = (instr.arrangement == .d2) ? (1 << 22) : 0
            return q | sz | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdTwoRegMisc:
            let q = instr.arrangement.qBit << 30
            let size = instr.arrangement.sizeBits << 22
            return q | size | desc.opcodeBits | (vn << 5) | vd

        case .simdShiftImm:
            let q = instr.arrangement.qBit << 30
            let esize: UInt32
            switch instr.arrangement {
            case .b8, .b16: esize = 8
            case .h4, .h8:  esize = 16
            case .s2, .s4:  esize = 32
            case .d1, .d2, .q1: esize = 64
            }
            let shift = UInt32(instr.amount)
            guard shift < esize else { return nil }
            let immhImmb: UInt32
            if instr.opcode == .simdShl {
                immhImmb = esize + shift
            } else {
                guard shift >= 1 else { return nil }
                immhImmb = (2 * esize) - shift
            }
            return q | desc.opcodeBits | ((immhImmb & 0x7F) << 16) | (vn << 5) | vd

        case .simdDupGpr:
            let q = instr.arrangement.qBit << 30
            let imm5: UInt32
            switch instr.arrangement {
            case .b8, .b16: imm5 = 0b00001
            case .h4, .h8:  imm5 = 0b00010
            case .s2, .s4:  imm5 = 0b00100
            case .d1, .d2, .q1: imm5 = 0b01000
            }
            return q | desc.opcodeBits | (imm5 << 16) | (rn << 5) | vd

        case .simdInsGpr:
            let idx = UInt32(instr.index)
            let imm5: UInt32
            switch instr.scalarWidth {
            case .b: imm5 = ((idx & 0xF) << 1) | 0b00001
            case .h: imm5 = ((idx & 0x7) << 2) | 0b00010
            case .s: imm5 = ((idx & 0x3) << 3) | 0b00100
            case .d, .q: imm5 = ((idx & 0x1) << 4) | 0b01000
            }
            return desc.opcodeBits | (imm5 << 16) | (rn << 5) | vd

        case .simdUmovSmov:
            let idx = UInt32(instr.index)
            let imm5: UInt32
            let q: UInt32
            switch instr.scalarWidth {
            case .b:
                imm5 = ((idx & 0xF) << 1) | 0b00001
                q = (instr.opcode == .simdSmov && instr.is64Bit) ? (1 << 30) : 0
            case .h:
                imm5 = ((idx & 0x7) << 2) | 0b00010
                q = (instr.opcode == .simdSmov && instr.is64Bit) ? (1 << 30) : 0
            case .s:
                imm5 = ((idx & 0x3) << 3) | 0b00100
                q = (instr.opcode == .simdSmov && instr.is64Bit) ? (1 << 30) : 0
            case .d, .q:
                imm5 = ((idx & 0x1) << 4) | 0b01000
                q = 1 << 30
            }
            return q | desc.opcodeBits | (imm5 << 16) | (vn << 5) | rd

        case .simdLd1St1One:
            let q = instr.arrangement.qBit << 30
            let size = instr.arrangement.sizeBits << 10
            return q | desc.opcodeBits | size | (rn << 5) | vd

        case .simdTblOne:
            let q = instr.arrangement.qBit << 30
            return q | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdExt:
            let q = instr.arrangement.qBit << 30
            let imm4 = UInt32(instr.amount) & 0xF
            return q | desc.opcodeBits | (vm << 16) | (imm4 << 11) | (vn << 5) | vd

        case .sveLdrStrZ:
            guard instr.imm >= -256 && instr.imm <= 255 else { return nil }
            let imm9 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm)) & 0x1FF
            let imm9h = (imm9 >> 3) & 0x3F
            let imm9l = imm9 & 0x7
            let zt = UInt32(instr.zd.rawValue)
            return desc.opcodeBits | (imm9h << 16) | (imm9l << 10) | (rn << 5) | zt

        case .sveLdrStrP:
            guard instr.imm >= -256 && instr.imm <= 255 else { return nil }
            let imm9 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm)) & 0x1FF
            let imm9h = (imm9 >> 3) & 0x3F
            let imm9l = imm9 & 0x7
            let pt = UInt32(instr.pd.rawValue) & 0xF
            return desc.opcodeBits | (imm9h << 16) | (imm9l << 10) | (rn << 5) | pt

        case .sveAddVlPl:
            guard instr.imm >= -32 && instr.imm <= 31 else { return nil }
            let imm6 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm)) & 0x3F
            return desc.opcodeBits | (rn << 16) | (imm6 << 5) | rd

        case .sveRdffr:
            let pd = UInt32(instr.pd.rawValue) & 0xF
            return desc.opcodeBits | pd

        case .sveWrffr:
            let pn = UInt32(instr.pd.rawValue) & 0xF
            return desc.opcodeBits | (pn << 5)
        }
    }

    /// Encodes a structured `A64Instruction` into 4 little-endian bytes.
    public static func encodeBytes(_ instr: A64Instruction) -> [UInt8]? {
        guard let word = encode(instr) else { return nil }
        return [
            UInt8(truncatingIfNeeded: word),
            UInt8(truncatingIfNeeded: word >> 8),
            UInt8(truncatingIfNeeded: word >> 16),
            UInt8(truncatingIfNeeded: word >> 24),
        ]
    }

    /// Appends 4 little-endian bytes for `instr` into `buffer`.
    @discardableResult
    public static func emit(_ instr: A64Instruction, into buffer: inout [UInt8]) -> Bool {
        guard let word = encode(instr) else { return false }
        buffer.append(UInt8(truncatingIfNeeded: word))
        buffer.append(UInt8(truncatingIfNeeded: word >> 8))
        buffer.append(UInt8(truncatingIfNeeded: word >> 16))
        buffer.append(UInt8(truncatingIfNeeded: word >> 24))
        return true
    }
}

// MARK: - 5. AArch64 Table-Driven Disassembler (`A64Disassembler`)

public enum A64Disassembler {
    @inline(__always)
    private static func signExtend(_ value: UInt32, bits: Int) -> Int64 {
        let shift = 64 - bits
        return (Int64(UInt64(value)) << shift) >> shift
    }

    /// Decodes a 32-bit machine word into a structured `A64Instruction` using `A64InstructionTable`.
    public static func decode(_ word: UInt32) -> A64Instruction? {
        for desc in A64InstructionTable.entries {
            guard (word & desc.opcodeMask) == desc.opcodeBits else { continue }
            if let decoded = decode(word: word, desc: desc) {
                return decoded
            }
        }
        return nil
    }

    private static func decode(word: UInt32, desc: A64InstrDesc) -> A64Instruction? {
        let is64 = ((word >> 31) & 1) != 0
        let rd = A64GPR(rawValue: UInt8(word & 0x1F))
        let rn = A64GPR(rawValue: UInt8((word >> 5) & 0x1F))
        let rm = A64GPR(rawValue: UInt8((word >> 16) & 0x1F))
        let ra = A64GPR(rawValue: UInt8((word >> 10) & 0x1F))
        let vd = A64VReg(rawValue: UInt8(word & 0x1F))
        let vn = A64VReg(rawValue: UInt8((word >> 5) & 0x1F))
        let vm = A64VReg(rawValue: UInt8((word >> 16) & 0x1F))

        switch desc.format {
        case .addSubImm:
            let sh = ((word >> 22) & 1) != 0
            let imm12 = Int64((word >> 10) & 0xFFF)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, amount: sh ? 12 : 0, imm: imm12)

        case .movWide:
            let hw = UInt8((word >> 21) & 0x3)
            if !is64 && hw >= 2 { return nil }
            let imm16 = Int64((word >> 5) & 0xFFFF)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, amount: hw * 16, imm: imm16)

        case .pcRel:
            let immlo = (word >> 29) & 0x3
            let immhi = (word >> 5) & 0x7_FFFF
            let raw21 = (immhi << 2) | immlo
            let signed21 = signExtend(raw21, bits: 21)
            let offset = (desc.id == .adrp) ? (signed21 << 12) : signed21
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: rd, imm: offset)

        case .logicalImm:
            let n = (word >> 22) & 1
            let immr = (word >> 16) & 0x3F
            let imms = (word >> 10) & 0x3F
            guard let maskVal = A64BitmaskImmediate.decode(n: n, immr: immr, imms: imms, is64Bit: is64) else {
                return nil
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, imm: Int64(bitPattern: maskVal))

        case .bitfield:
            let n = ((word >> 22) & 1) != 0
            if n != is64 { return nil }
            let immr = Int64((word >> 16) & 0x3F)
            let imms = UInt8((word >> 10) & 0x3F)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, imm: immr, imm2: imms)

        case .extract:
            let n = ((word >> 22) & 1) != 0
            if n != is64 { return nil }
            let lsb = UInt8((word >> 10) & 0x3F)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, amount: lsb)

        case .addSubShifted:
            let shiftRaw = UInt8((word >> 22) & 0x3)
            if shiftRaw == 3 { return nil }
            let shift = A64ShiftKind(rawValue: shiftRaw)!
            let amt = UInt8((word >> 10) & 0x3F)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, shiftKind: shift, amount: amt)

        case .addSubExtended:
            let optRaw = UInt8((word >> 13) & 0x7)
            let ext = A64ExtendKind(rawValue: optRaw)!
            let imm3 = UInt8((word >> 10) & 0x7)
            if imm3 > 4 { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, extendKind: ext, amount: imm3)

        case .logicalShifted:
            let shiftRaw = UInt8((word >> 22) & 0x3)
            let shift = A64ShiftKind(rawValue: shiftRaw)!
            let amt = UInt8((word >> 10) & 0x3F)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, shiftKind: shift, amount: amt)

        case .dp2Source:
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm)

        case .dp1Source:
            if desc.id == .rev {
                let opcBit10 = ((word >> 10) & 1) != 0
                if is64 != opcBit10 { return nil }
            } else if desc.id == .rev32 {
                if !is64 { return nil }
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn)

        case .dp3Source:
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, ra: ra)

        case .mulHigh:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: rd, rn: rn, rm: rm)

        case .condSelect:
            let cond = A64Cond(rawValue: UInt8((word >> 12) & 0xF))!
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rm, cond: cond)

        case .condCompareReg:
            let cond = A64Cond(rawValue: UInt8((word >> 12) & 0xF))!
            let nzcv = UInt8(word & 0xF)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rn: rn, rm: rm, cond: cond, imm2: nzcv)

        case .condCompareImm:
            let cond = A64Cond(rawValue: UInt8((word >> 12) & 0xF))!
            let imm5 = Int64((word >> 16) & 0x1F)
            let nzcv = UInt8(word & 0xF)
            return A64Instruction(opcode: desc.id, is64Bit: is64, rn: rn, cond: cond, imm: imm5, imm2: nzcv)

        case .branchImm26:
            let raw26 = word & 0x03FF_FFFF
            let offset = signExtend(raw26, bits: 26) << 2
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: offset)

        case .branchCond19:
            let raw19 = (word >> 5) & 0x7_FFFF
            let offset = signExtend(raw19, bits: 19) << 2
            let cond = A64Cond(rawValue: UInt8(word & 0xF))!
            return A64Instruction(opcode: desc.id, is64Bit: true, cond: cond, imm: offset)

        case .compareBranch19:
            let raw19 = (word >> 5) & 0x7_FFFF
            let offset = signExtend(raw19, bits: 19) << 2
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, imm: offset)

        case .testBranch14:
            let b5 = (word >> 31) & 1
            let b40 = (word >> 19) & 0x1F
            let bit = UInt8((b5 << 5) | b40)
            let raw14 = (word >> 5) & 0x3FFF
            let offset = signExtend(raw14, bits: 14) << 2
            return A64Instruction(opcode: desc.id, is64Bit: b5 != 0, rd: rd, amount: bit, imm: offset)

        case .branchReg:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: rn)

        case .exceptionImm16:
            let imm16 = Int64((word >> 5) & 0xFFFF)
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: imm16)

        case .udfImm16:
            let imm16 = Int64(word & 0xFFFF)
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: imm16)

        case .fixedSystem:
            return A64Instruction(opcode: desc.id, is64Bit: true)

        case .hintImm7:
            let imm7 = Int64((word >> 5) & 0x7F)
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: imm7)

        case .barrier:
            let crm = UInt8((word >> 8) & 0xF)
            let opt = A64BarrierOption(rawValue: crm) ?? .sy
            return A64Instruction(opcode: desc.id, is64Bit: true, barrierOption: opt)

        case .mrs, .msrReg:
            let sysBits = UInt16((word >> 5) & 0xFFFF)
            let sysReg = A64SysReg(encoded15Bit: sysBits)
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: rd, sysReg: sysReg)

        case .msrPState:
            let op1 = (word >> 16) & 0x7
            let crm = Int64((word >> 8) & 0xF)
            let op2 = (word >> 5) & 0x7
            guard let field = A64PStateField.from(op1: op1, op2: op2) else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: crm, pstateField: field)

        case .sysMaint:
            let op1 = (word >> 16) & 0x7
            let crn = (word >> 12) & 0xF
            let crm = (word >> 8) & 0xF
            let op2 = (word >> 5) & 0x7
            guard let maintOp = A64SysMaintOp.from(op1: op1, crn: crn, crm: crm, op2: op2) else {
                return nil
            }
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: rd, sysMaintOp: maintOp)

        case .ldstUnsignedImm12:
            let imm12 = Int64((word >> 10) & 0xFFF)
            if let sw = desc.scalarWidth {
                let offset = imm12 << Int64(desc.scaleLog2)
                return A64Instruction(opcode: desc.id, is64Bit: true, rn: rn, vd: vd, scalarWidth: sw, imm: offset)
            }
            let size30 = ((word >> 30) & 1) != 0
            let is64Reg: Bool
            let shift: UInt8
            if desc.scaleLog2 == 255 {
                is64Reg = size30
                shift = size30 ? 3 : 2
            } else {
                switch desc.id {
                case .ldrsbImm64, .ldrshImm64, .ldrswImm: is64Reg = true
                default: is64Reg = false
                }
                shift = desc.scaleLog2
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn, imm: imm12 << Int64(shift))

        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            let raw9 = (word >> 12) & 0x1FF
            let simm9 = signExtend(raw9, bits: 9)
            let size30 = ((word >> 30) & 1) != 0
            let is64Reg: Bool
            switch desc.id {
            case .ldrPre, .strPre, .ldrPost, .strPost, .ldur, .stur, .ldtr, .sttr:
                is64Reg = size30
            case .ldrsbPre64, .ldrshPre64, .ldrswPre,
                 .ldrsbPost64, .ldrshPost64, .ldrswPost,
                 .ldursb64, .ldursh64, .ldursw,
                 .ldtrsb64, .ldtrsh64, .ldtrsw:
                is64Reg = true
            default:
                is64Reg = false
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn, imm: simm9)

        case .ldstRegOffset:
            let size30 = ((word >> 30) & 1) != 0
            let optRaw = UInt8((word >> 13) & 0x7)
            guard let ext = A64ExtendKind(rawValue: optRaw) else { return nil }
            let sBit = ((word >> 12) & 1) != 0
            let is64Reg: Bool
            let naturalShift: UInt8
            if desc.scaleLog2 == 255 {
                is64Reg = size30
                naturalShift = size30 ? 3 : 2
            } else {
                switch desc.id {
                case .ldrsbReg64, .ldrshReg64, .ldrswReg: is64Reg = true
                default: is64Reg = false
                }
                naturalShift = desc.scaleLog2
            }
            return A64Instruction(
                opcode: desc.id,
                is64Bit: is64Reg,
                rd: rd,
                rn: rn,
                rm: rm,
                extendKind: ext,
                amount: sBit ? naturalShift : 0
            )

        case .ldrLiteral:
            let size30 = ((word >> 30) & 1) != 0
            let raw19 = (word >> 5) & 0x7_FFFF
            let offset = signExtend(raw19, bits: 19) << 2
            return A64Instruction(opcode: desc.id, is64Bit: size30, rd: rd, imm: offset)

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            let raw7 = (word >> 15) & 0x7F
            let simm7 = signExtend(raw7, bits: 7)
            if desc.scalarWidth == .q {
                let rt2 = A64VReg(rawValue: UInt8((word >> 10) & 0x1F))
                return A64Instruction(opcode: desc.id, is64Bit: true, rn: rn, vd: vd, vn: rt2, scalarWidth: .q, imm: simm7 << 4)
            } else {
                let rt2 = A64GPR(rawValue: UInt8((word >> 10) & 0x1F))
                let shift: Int64 = is64 ? 3 : 2
                return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rt2, imm: simm7 << shift)
            }

        case .atomicLoad, .atomicStore:
            let size30 = ((word >> 30) & 1) != 0
            let is64Reg: Bool
            switch desc.id {
            case .ldarb, .stlrb, .ldarh, .stlrh: is64Reg = false
            default: is64Reg = size30
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn)

        case .atomicStoreExcl:
            let size30 = ((word >> 30) & 1) != 0
            return A64Instruction(opcode: desc.id, is64Bit: size30, rd: rd, rn: rn, rm: rm)

        case .fpMovGprToFp:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, rn: rn, vd: vd, scalarWidth: sw)

        case .fpMovFpToGpr:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, rd: rd, vn: vn, scalarWidth: sw)

        case .fpMovReg:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vd: vd, vn: vn, scalarWidth: sw)

        case .fpCvtReg:
            let sw: A64ScalarWidth = (desc.id == .fcvtStoD) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vd: vd, vn: vn, scalarWidth: sw)

        case .fpIntToFp:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: is64, rn: rn, vd: vd, scalarWidth: sw)

        case .fpToInt:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, vn: vn, scalarWidth: sw)

        case .fpBinary:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vd: vd, vn: vn, vm: vm, scalarWidth: sw)

        case .fpCmpReg:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vn: vn, vm: vm, scalarWidth: sw)

        case .fpCmpZero:
            let ftype = (word >> 22) & 0x3
            let sw: A64ScalarWidth = (ftype == 1) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vn: vn, scalarWidth: sw)

        case .simdThreeSameInt, .simdPermute:
            let q = (word >> 30) & 1
            let size = (word >> 22) & 0x3
            let arr = A64Arrangement.from(qBit: q, sizeBits: size)
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdThreeSameBit:
            let q = (word >> 30) & 1
            let arr: A64Arrangement = (q == 1) ? .b16 : .b8
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdThreeSameFp:
            let q = (word >> 30) & 1
            let sz = (word >> 22) & 1
            let arr: A64Arrangement = (sz == 1) ? .d2 : ((q == 1) ? .s4 : .s2)
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdTwoRegMisc:
            let q = (word >> 30) & 1
            let size = (word >> 22) & 0x3
            let arr = A64Arrangement.from(qBit: q, sizeBits: size)
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr)

        case .simdShiftImm:
            let q = (word >> 30) & 1
            let immh = (word >> 19) & 0xF
            let immb = (word >> 16) & 0x7
            let immhImmb = (immh << 3) | immb
            if immh == 0 { return nil }
            let sizeBits: UInt32
            let esize: UInt32
            if (immh & 0b1000) != 0 {
                sizeBits = 3; esize = 64
            } else if (immh & 0b0100) != 0 {
                sizeBits = 2; esize = 32
            } else if (immh & 0b0010) != 0 {
                sizeBits = 1; esize = 16
            } else {
                sizeBits = 0; esize = 8
            }
            let arr = A64Arrangement.from(qBit: q, sizeBits: sizeBits)
            let shift: UInt8
            if desc.id == .simdShl {
                shift = UInt8(immhImmb - esize)
            } else {
                shift = UInt8((2 * esize) - immhImmb)
            }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr, amount: shift)

        case .simdDupGpr:
            let q = (word >> 30) & 1
            let imm5 = (word >> 16) & 0x1F
            let sizeBits: UInt32
            if (imm5 & 0b00001) != 0 {
                sizeBits = 0
            } else if (imm5 & 0b00010) != 0 {
                sizeBits = 1
            } else if (imm5 & 0b00100) != 0 {
                sizeBits = 2
            } else if (imm5 & 0b01000) != 0 {
                sizeBits = 3
            } else {
                return nil
            }
            let arr = A64Arrangement.from(qBit: q, sizeBits: sizeBits)
            return A64Instruction(opcode: desc.id, is64Bit: sizeBits == 3, rn: rn, vd: vd, arrangement: arr)

        case .simdInsGpr:
            let imm5 = (word >> 16) & 0x1F
            let sw: A64ScalarWidth
            let idx: UInt8
            if (imm5 & 0b00001) != 0 {
                sw = .b; idx = UInt8((imm5 >> 1) & 0xF)
            } else if (imm5 & 0b00010) != 0 {
                sw = .h; idx = UInt8((imm5 >> 2) & 0x7)
            } else if (imm5 & 0b00100) != 0 {
                sw = .s; idx = UInt8((imm5 >> 3) & 0x3)
            } else if (imm5 & 0b01000) != 0 {
                sw = .d; idx = UInt8((imm5 >> 4) & 0x1)
            } else {
                return nil
            }
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, rn: rn, vd: vd, scalarWidth: sw, index: idx)

        case .simdUmovSmov:
            let q = ((word >> 30) & 1) != 0
            let imm5 = (word >> 16) & 0x1F
            let sw: A64ScalarWidth
            let idx: UInt8
            if (imm5 & 0b00001) != 0 {
                sw = .b; idx = UInt8((imm5 >> 1) & 0xF)
            } else if (imm5 & 0b00010) != 0 {
                sw = .h; idx = UInt8((imm5 >> 2) & 0x7)
            } else if (imm5 & 0b00100) != 0 {
                sw = .s; idx = UInt8((imm5 >> 3) & 0x3)
            } else if (imm5 & 0b01000) != 0 {
                sw = .d; idx = UInt8((imm5 >> 4) & 0x1)
            } else {
                return nil
            }
            let is64Dst = (desc.id == .simdSmov) ? q : (sw == .d)
            return A64Instruction(opcode: desc.id, is64Bit: is64Dst, rd: rd, vn: vn, scalarWidth: sw, index: idx)

        case .simdLd1St1One:
            let q = (word >> 30) & 1
            let size = (word >> 10) & 0x3
            let arr = A64Arrangement.from(qBit: q, sizeBits: size)
            return A64Instruction(opcode: desc.id, rn: rn, vd: vd, arrangement: arr)

        case .simdTblOne:
            let q = (word >> 30) & 1
            let arr: A64Arrangement = (q == 1) ? .b16 : .b8
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdExt:
            let q = (word >> 30) & 1
            let arr: A64Arrangement = (q == 1) ? .b16 : .b8
            let imm4 = UInt8((word >> 11) & 0xF)
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr, amount: imm4)

        case .sveLdrStrZ:
            let imm9h = (word >> 16) & 0x3F
            let imm9l = (word >> 10) & 0x7
            let raw9 = (imm9h << 3) | imm9l
            let simm9 = signExtend(raw9, bits: 9)
            let zt = A64ZReg(rawValue: UInt8(word & 0x1F))
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: rn, zd: zt, imm: simm9)

        case .sveLdrStrP:
            let imm9h = (word >> 16) & 0x3F
            let imm9l = (word >> 10) & 0x7
            let raw9 = (imm9h << 3) | imm9l
            let simm9 = signExtend(raw9, bits: 9)
            let pt = A64PReg(rawValue: UInt8(word & 0xF))
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: rn, pd: pt, imm: simm9)

        case .sveAddVlPl:
            let sveRn = A64GPR(rawValue: UInt8((word >> 16) & 0x1F))
            let raw6 = (word >> 5) & 0x3F
            let simm6 = signExtend(raw6, bits: 6)
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: rd, rn: sveRn, imm: simm6)

        case .sveRdffr:
            let pd = A64PReg(rawValue: UInt8(word & 0xF))
            return A64Instruction(opcode: desc.id, is64Bit: true, pd: pd)

        case .sveWrffr:
            let pn = A64PReg(rawValue: UInt8((word >> 5) & 0xF))
            return A64Instruction(opcode: desc.id, is64Bit: true, pd: pn)
        }
    }

    /// Formats a structured `A64Instruction` into canonical GNU/Unified AArch64 assembly syntax.
    public static func format(_ instr: A64Instruction) -> String {
        let desc = A64InstructionTable.descriptor(for: instr.opcode)
        let is64 = instr.is64Bit

        switch desc.format {
        case .addSubImm:
            let shiftSuffix = (instr.amount == 12) ? ", lsl #12" : ""
            if (instr.opcode == .subsImm || instr.opcode == .addsImm) && instr.rd.rawValue == 31 {
                let alias = (instr.opcode == .subsImm) ? "cmp" : "cmn"
                return "\(alias) \(instr.rn.format(is64Bit: is64, r31IsSP: true)), #\(instr.imm)\(shiftSuffix)"
            }
            if instr.opcode == .addImm && instr.imm == 0 && instr.amount == 0 && (instr.rd.rawValue == 31 || instr.rn.rawValue == 31) {
                return "mov \(instr.rd.format(is64Bit: is64, r31IsSP: true)), \(instr.rn.format(is64Bit: is64, r31IsSP: true))"
            }
            let rdUseSP = (instr.opcode == .addImm || instr.opcode == .subImm)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64, r31IsSP: rdUseSP)), \(instr.rn.format(is64Bit: is64, r31IsSP: true)), #\(instr.imm)\(shiftSuffix)"

        case .movWide:
            let shiftSuffix = (instr.amount != 0) ? ", lsl #\(instr.amount)" : ""
            let hex = String(instr.imm, radix: 16)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), #0x\(hex)\(shiftSuffix)"

        case .pcRel:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: true)), #\(instr.imm)"

        case .logicalImm:
            let maskVal = UInt64(bitPattern: instr.imm)
            let displayVal = is64 ? maskVal : (maskVal & 0xFFFF_FFFF)
            let hex = String(displayVal, radix: 16)
            if instr.opcode == .andsImm && instr.rd.rawValue == 31 {
                return "tst \(instr.rn.format(is64Bit: is64)), #0x\(hex)"
            }
            let rdUseSP = (instr.opcode != .andsImm)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64, r31IsSP: rdUseSP)), \(instr.rn.format(is64Bit: is64)), #0x\(hex)"

        case .bitfield:
            let width: Int64 = is64 ? 64 : 32
            let immr = instr.imm
            let imms = Int64(instr.imm2)
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            if instr.opcode == .ubfm {
                if !is64 && immr == 0 && imms == 7 { return "uxtb \(rdStr), \(rnStr)" }
                if !is64 && immr == 0 && imms == 15 { return "uxth \(rdStr), \(rnStr)" }
                if imms == width - 1 { return "lsr \(rdStr), \(rnStr), #\(immr)" }
                if imms + 1 == immr { return "lsl \(rdStr), \(rnStr), #\(width - immr)" }
                if imms >= immr { return "ubfx \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)" }
            } else if instr.opcode == .sbfm {
                if immr == 0 && imms == 7 { return "sxtb \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if immr == 0 && imms == 15 { return "sxth \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if is64 && immr == 0 && imms == 31 { return "sxtw \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if imms == width - 1 { return "asr \(rdStr), \(rnStr), #\(immr)" }
                if imms >= immr { return "sbfx \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)" }
            } else if instr.opcode == .bfm {
                if imms >= immr {
                    return "bfxil \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)"
                } else {
                    let lsb = (width - immr) % width
                    return "bfi \(rdStr), \(rnStr), #\(lsb), #\(imms + 1)"
                }
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), #\(immr), #\(imms)"

        case .extract:
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            let rmStr = instr.rm.format(is64Bit: is64)
            if instr.rn == instr.rm {
                return "ror \(rdStr), \(rnStr), #\(instr.amount)"
            }
            return "extr \(rdStr), \(rnStr), \(rmStr), #\(instr.amount)"

        case .addSubShifted:
            let shiftSuffix = (instr.shiftKind != .lsl || instr.amount != 0) ? ", \(instr.shiftKind.mnemonic) #\(instr.amount)" : ""
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            let rmStr = instr.rm.format(is64Bit: is64)
            if (instr.opcode == .subsShifted || instr.opcode == .addsShifted) && instr.rd.rawValue == 31 {
                let alias = (instr.opcode == .subsShifted) ? "cmp" : "cmn"
                return "\(alias) \(rnStr), \(rmStr)\(shiftSuffix)"
            }
            if (instr.opcode == .subShifted || instr.opcode == .subsShifted) && instr.rn.rawValue == 31 {
                let alias = (instr.opcode == .subShifted) ? "neg" : "negs"
                return "\(alias) \(rdStr), \(rmStr)\(shiftSuffix)"
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr)\(shiftSuffix)"

        case .addSubExtended:
            let rdUseSP = (instr.opcode == .addExtended || instr.opcode == .subExtended)
            let rdStr = instr.rd.format(is64Bit: is64, r31IsSP: rdUseSP)
            let rnStr = instr.rn.format(is64Bit: is64, r31IsSP: true)
            let rmIs64 = is64 && instr.extendKind.uses64BitRegister
            let rmStr = instr.rm.format(is64Bit: rmIs64)
            let amtSuffix = (instr.amount != 0) ? " #\(instr.amount)" : ""
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr), \(instr.extendKind.mnemonic)\(amtSuffix)"

        case .logicalShifted:
            let shiftSuffix = (instr.shiftKind != .lsl || instr.amount != 0) ? ", \(instr.shiftKind.mnemonic) #\(instr.amount)" : ""
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            let rmStr = instr.rm.format(is64Bit: is64)
            if instr.opcode == .orrShifted && instr.rn.rawValue == 31 && instr.shiftKind == .lsl && instr.amount == 0 {
                return "mov \(rdStr), \(rmStr)"
            }
            if instr.opcode == .ornShifted && instr.rn.rawValue == 31 {
                return "mvn \(rdStr), \(rmStr)\(shiftSuffix)"
            }
            if instr.opcode == .andsShifted && instr.rd.rawValue == 31 {
                return "tst \(rnStr), \(rmStr)\(shiftSuffix)"
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr)\(shiftSuffix)"

        case .dp2Source:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), \(instr.rn.format(is64Bit: is64)), \(instr.rm.format(is64Bit: is64))"

        case .dp1Source:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), \(instr.rn.format(is64Bit: is64))"

        case .dp3Source:
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            let rmStr = instr.rm.format(is64Bit: is64)
            if instr.opcode == .madd && instr.ra.rawValue == 31 {
                return "mul \(rdStr), \(rnStr), \(rmStr)"
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr), \(instr.ra.format(is64Bit: is64))"

        case .mulHigh:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: true)), \(instr.rn.format(is64Bit: true)), \(instr.rm.format(is64Bit: true))"

        case .condSelect:
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            let rmStr = instr.rm.format(is64Bit: is64)
            if instr.opcode == .csinc && instr.rn.rawValue == 31 && instr.rm.rawValue == 31 && instr.cond != .al && instr.cond != .nv {
                return "cset \(rdStr), \(instr.cond.inverted.mnemonic)"
            }
            if instr.opcode == .csinv && instr.rn.rawValue == 31 && instr.rm.rawValue == 31 && instr.cond != .al && instr.cond != .nv {
                return "csetm \(rdStr), \(instr.cond.inverted.mnemonic)"
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr), \(instr.cond.mnemonic)"

        case .condCompareReg:
            return "ccmp \(instr.rn.format(is64Bit: is64)), \(instr.rm.format(is64Bit: is64)), #\(instr.imm2), \(instr.cond.mnemonic)"

        case .condCompareImm:
            return "ccmp \(instr.rn.format(is64Bit: is64)), #\(instr.imm), #\(instr.imm2), \(instr.cond.mnemonic)"

        case .branchImm26:
            return "\(desc.mnemonic) #\(instr.imm)"

        case .branchCond19:
            return "b.\(instr.cond.mnemonic) #\(instr.imm)"

        case .compareBranch19:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), #\(instr.imm)"

        case .testBranch14:
            let use64 = instr.amount >= 32 || instr.is64Bit
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: use64)), #\(instr.amount), #\(instr.imm)"

        case .branchReg:
            if instr.opcode == .ret && instr.rn == .lr {
                return "ret"
            }
            return "\(desc.mnemonic) \(instr.rn.format(is64Bit: true))"

        case .exceptionImm16, .udfImm16, .hintImm7:
            return "\(desc.mnemonic) #\(instr.imm)"

        case .fixedSystem:
            return desc.mnemonic

        case .barrier:
            switch instr.opcode {
            case .clrex, .isb:
                return desc.mnemonic
            default:
                return "\(desc.mnemonic) \(instr.barrierOption.mnemonic)"
            }

        case .mrs:
            return "mrs \(instr.rd.format(is64Bit: true)), \(instr.sysReg.formatted)"

        case .msrReg:
            return "msr \(instr.sysReg.formatted), \(instr.rd.format(is64Bit: true))"

        case .msrPState:
            return "msr \(instr.pstateField.name), #\(instr.imm)"

        case .sysMaint:
            let op = instr.sysMaintOp
            let mnem: String
            switch op.kind {
            case .tlbi: mnem = "tlbi"
            case .ic:   mnem = "ic"
            case .dc:   mnem = "dc"
            }
            if op.takesRegister {
                return "\(mnem) \(op.operandName), \(instr.rd.format(is64Bit: true))"
            } else {
                return "\(mnem) \(op.operandName)"
            }

        case .ldstUnsignedImm12:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            let offStr = (instr.imm != 0) ? ", #\(instr.imm)" : ""
            if let sw = desc.scalarWidth {
                return "\(desc.mnemonic) \(instr.vd.formatScalar(sw)), [\(baseStr)\(offStr)]"
            }
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr)\(offStr)]"

        case .ldstPreImm9:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr), #\(instr.imm)]!"

        case .ldstPostImm9:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr)], #\(instr.imm)"

        case .ldstUnscaledImm9, .ldstUnprivImm9:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            let offStr = (instr.imm != 0) ? ", #\(instr.imm)" : ""
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr)\(offStr)]"

        case .ldstRegOffset:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            let rmStr = instr.rm.format(is64Bit: instr.extendKind.uses64BitRegister)
            let extSuffix: String
            if instr.extendKind == .uxtx {
                extSuffix = (instr.amount != 0) ? ", lsl #\(instr.amount)" : ""
            } else {
                let amtStr = (instr.amount != 0) ? " #\(instr.amount)" : ""
                extSuffix = ", \(instr.extendKind.mnemonic)\(amtStr)"
            }
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr), \(rmStr)\(extSuffix)]"

        case .ldrLiteral:
            return "ldr \(instr.rd.format(is64Bit: is64)), #\(instr.imm)"

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            let r1: String
            let r2: String
            if desc.scalarWidth == .q {
                r1 = instr.vd.formatScalar(.q)
                r2 = instr.vn.formatScalar(.q)
            } else {
                r1 = instr.rd.format(is64Bit: is64)
                r2 = instr.rm.format(is64Bit: is64)
            }
            switch desc.format {
            case .ldpStpSigned:
                let offStr = (instr.imm != 0) ? ", #\(instr.imm)" : ""
                return "\(desc.mnemonic) \(r1), \(r2), [\(baseStr)\(offStr)]"
            case .ldpStpPre:
                return "\(desc.mnemonic) \(r1), \(r2), [\(baseStr), #\(instr.imm)]!"
            default:
                return "\(desc.mnemonic) \(r1), \(r2), [\(baseStr)], #\(instr.imm)"
            }

        case .atomicLoad, .atomicStore:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .atomicStoreExcl:
            return "\(desc.mnemonic) \(instr.rm.format(is64Bit: false)), \(instr.rd.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .fpMovGprToFp:
            let sw = instr.scalarWidth
            return "fmov \(instr.vd.formatScalar(sw)), \(instr.rn.format(is64Bit: sw == .d))"

        case .fpMovFpToGpr:
            let sw = instr.scalarWidth
            return "fmov \(instr.rd.format(is64Bit: sw == .d)), \(instr.vn.formatScalar(sw))"

        case .fpMovReg:
            let sw = instr.scalarWidth
            return "fmov \(instr.vd.formatScalar(sw)), \(instr.vn.formatScalar(sw))"

        case .fpCvtReg:
            if instr.opcode == .fcvtStoD {
                return "fcvt \(instr.vd.formatScalar(.d)), \(instr.vn.formatScalar(.s))"
            } else {
                return "fcvt \(instr.vd.formatScalar(.s)), \(instr.vn.formatScalar(.d))"
            }

        case .fpIntToFp:
            return "scvtf \(instr.vd.formatScalar(instr.scalarWidth)), \(instr.rn.format(is64Bit: is64))"

        case .fpToInt:
            return "fcvtzs \(instr.rd.format(is64Bit: is64)), \(instr.vn.formatScalar(instr.scalarWidth))"

        case .fpBinary:
            let sw = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vd.formatScalar(sw)), \(instr.vn.formatScalar(sw)), \(instr.vm.formatScalar(sw))"

        case .fpCmpReg:
            let sw = instr.scalarWidth
            return "fcmp \(instr.vn.formatScalar(sw)), \(instr.vm.formatScalar(sw))"

        case .fpCmpZero:
            let sw = instr.scalarWidth
            return "fcmp \(instr.vn.formatScalar(sw)), #0.0"

        case .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute:
            let arr = instr.arrangement
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), \(instr.vm.formatVector(arr))"

        case .simdTwoRegMisc:
            let arr = instr.arrangement
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr))"

        case .simdShiftImm:
            let arr = instr.arrangement
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), #\(instr.amount)"

        case .simdDupGpr:
            let arr = instr.arrangement
            let use64 = (arr == .d1 || arr == .d2)
            return "dup \(instr.vd.formatVector(arr)), \(instr.rn.format(is64Bit: use64))"

        case .simdInsGpr:
            let sw = instr.scalarWidth
            return "ins v\(instr.vd.rawValue).\(sw.prefix)[\(instr.index)], \(instr.rn.format(is64Bit: sw == .d))"

        case .simdUmovSmov:
            let sw = instr.scalarWidth
            let use64 = (instr.opcode == .simdSmov) ? is64 : (sw == .d)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: use64)), v\(instr.vn.rawValue).\(sw.prefix)[\(instr.index)]"

        case .simdLd1St1One:
            return "\(desc.mnemonic) {\(instr.vd.formatVector(instr.arrangement))}, [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .simdTblOne:
            let arr = instr.arrangement
            return "tbl \(instr.vd.formatVector(arr)), {\(instr.vn.formatVector(.b16))}, \(instr.vm.formatVector(arr))"

        case .simdExt:
            let arr = instr.arrangement
            return "ext \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), \(instr.vm.formatVector(arr)), #\(instr.amount)"

        case .sveLdrStrZ:
            return "\(desc.mnemonic) \(instr.zd.formatted), [\(instr.rn.format(is64Bit: true, r31IsSP: true)), #\(instr.imm), mul vl]"

        case .sveLdrStrP:
            return "\(desc.mnemonic) \(instr.pd.formatted), [\(instr.rn.format(is64Bit: true, r31IsSP: true)), #\(instr.imm), mul vl]"

        case .sveAddVlPl:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: true, r31IsSP: true)), \(instr.rn.format(is64Bit: true, r31IsSP: true)), #\(instr.imm)"

        case .sveRdffr, .sveWrffr:
            return "\(desc.mnemonic) \(instr.pd.formatted).b"
        }
    }

    /// Disassembles a 32-bit machine word directly into canonical assembly text.
    public static func disassemble(_ word: UInt32) -> String? {
        guard let decoded = decode(word) else { return nil }
        return format(decoded)
    }
}

// MARK: - 6. Exhaustive Table Verification (`A64InstructionTable.verifyRoundTrip`)

extension A64InstructionTable {
    /// Constructs a representative `A64Instruction` for a given `A64InstrDesc`.
    public static func sampleInstruction(for desc: A64InstrDesc) -> A64Instruction {
        switch desc.format {
        case .addSubImm:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, amount: 0, imm: 42)
        case .movWide:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x2, amount: 16, imm: 0x1234)
        case .pcRel:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x3, imm: desc.id == .adrp ? 4096 : 64)
        case .logicalImm:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x4, rn: .x5, imm: 0xFF)
        case .bitfield:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, imm: 4, imm2: 15)
        case .extract:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, amount: 8)
        case .addSubShifted:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, shiftKind: .lsl, amount: 3)
        case .addSubExtended:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .sp, rm: .x1, extendKind: .uxtw, amount: 2)
        case .logicalShifted:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, shiftKind: .lsr, amount: 4)
        case .dp2Source:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2)
        case .dp1Source:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1)
        case .dp3Source:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, ra: .x3)
        case .mulHigh:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2)
        case .condSelect:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, cond: .eq)
        case .condCompareReg:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x1, rm: .x2, cond: .ne, imm2: 3)
        case .condCompareImm:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x1, cond: .lt, imm: 5, imm2: 2)
        case .branchImm26:
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: 64)
        case .branchCond19:
            return A64Instruction(opcode: desc.id, is64Bit: true, cond: .eq, imm: 64)
        case .compareBranch19:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, imm: 64)
        case .testBranch14:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, amount: 37, imm: 64)
        case .branchReg:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: desc.id == .ret ? .lr : .x1)
        case .exceptionImm16, .udfImm16:
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: 7)
        case .fixedSystem:
            return A64Instruction(opcode: desc.id, is64Bit: true)
        case .hintImm7:
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: 7)
        case .barrier:
            return A64Instruction(opcode: desc.id, is64Bit: true, barrierOption: .sy)
        case .mrs, .msrReg:
            let tpidr = A64SysReg(op0: 3, op1: 3, crn: 13, crm: 0, op2: 2)
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, sysReg: tpidr)
        case .msrPState:
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: 2, pstateField: .daifset)
        case .sysMaint:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, sysMaintOp: .vaae1is)
        case .ldstUnsignedImm12:
            if let sw = desc.scalarWidth {
                let off = Int64(1) << Int64(desc.scaleLog2)
                return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x1, vd: .v0, scalarWidth: sw, imm: off)
            }
            let is64: Bool
            let shift: UInt8
            if desc.scaleLog2 == 255 {
                is64 = true; shift = 3
            } else {
                switch desc.id {
                case .ldrsbImm64, .ldrshImm64, .ldrswImm: is64 = true
                default: is64 = false
                }
                shift = desc.scaleLog2
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: .x0, rn: .x1, imm: Int64(2) << Int64(shift))
        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            let is64: Bool
            switch desc.id {
            case .ldrPre, .strPre, .ldrPost, .strPost, .ldur, .stur, .ldtr, .sttr,
                 .ldrsbPre64, .ldrshPre64, .ldrswPre,
                 .ldrsbPost64, .ldrshPost64, .ldrswPost,
                 .ldursb64, .ldursh64, .ldursw,
                 .ldtrsb64, .ldtrsh64, .ldtrsw:
                is64 = true
            default:
                is64 = false
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: .x0, rn: .x1, imm: -8)
        case .ldstRegOffset:
            let is64: Bool
            let naturalShift: UInt8
            if desc.scaleLog2 == 255 {
                is64 = true; naturalShift = 3
            } else {
                switch desc.id {
                case .ldrsbReg64, .ldrshReg64, .ldrswReg: is64 = true
                default: is64 = false
                }
                naturalShift = desc.scaleLog2
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: .x0, rn: .x1, rm: .x2, extendKind: .uxtx, amount: naturalShift)
        case .ldrLiteral:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, imm: 64)
        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            if desc.scalarWidth == .q {
                return A64Instruction(opcode: desc.id, is64Bit: true, rn: .sp, vd: .v0, vn: .v1, scalarWidth: .q, imm: 32)
            }
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .sp, rm: .x1, imm: 16)
        case .atomicLoad, .atomicStore:
            let is64: Bool
            switch desc.id {
            case .ldarb, .stlrb, .ldarh, .stlrh: is64 = false
            default: is64 = true
            }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: .x0, rn: .x1)
        case .atomicStoreExcl:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2)
        case .fpMovGprToFp:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x1, vd: .v0, scalarWidth: .d)
        case .fpMovFpToGpr:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, vn: .v1, scalarWidth: .d)
        case .fpMovReg:
            return A64Instruction(opcode: desc.id, is64Bit: true, vd: .v0, vn: .v1, scalarWidth: .d)
        case .fpCvtReg:
            let sw: A64ScalarWidth = (desc.id == .fcvtStoD) ? .d : .s
            return A64Instruction(opcode: desc.id, is64Bit: sw == .d, vd: .v0, vn: .v1, scalarWidth: sw)
        case .fpIntToFp:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x1, vd: .v0, scalarWidth: .d)
        case .fpToInt:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, vn: .v1, scalarWidth: .d)
        case .fpBinary:
            return A64Instruction(opcode: desc.id, is64Bit: true, vd: .v0, vn: .v1, vm: .v2, scalarWidth: .d)
        case .fpCmpReg:
            return A64Instruction(opcode: desc.id, is64Bit: true, vn: .v0, vm: .v1, scalarWidth: .d)
        case .fpCmpZero:
            return A64Instruction(opcode: desc.id, is64Bit: true, vn: .v0, scalarWidth: .d)
        case .simdThreeSameInt, .simdPermute:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: .s4)
        case .simdThreeSameBit, .simdTblOne:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: .b16)
        case .simdThreeSameFp:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: .s4)
        case .simdTwoRegMisc:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, arrangement: .b16)
        case .simdShiftImm:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, arrangement: .s4, amount: 4)
        case .simdDupGpr:
            return A64Instruction(opcode: desc.id, is64Bit: false, rn: .x1, vd: .v0, arrangement: .s4)
        case .simdInsGpr:
            return A64Instruction(opcode: desc.id, is64Bit: false, rn: .x1, vd: .v0, scalarWidth: .s, index: 1)
        case .simdUmovSmov:
            return A64Instruction(opcode: desc.id, is64Bit: desc.id == .simdSmov, rd: .x0, vn: .v1, scalarWidth: .b, index: 2)
        case .simdLd1St1One:
            return A64Instruction(opcode: desc.id, rn: .x1, vd: .v0, arrangement: .b16)
        case .simdExt:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: .b16, amount: 4)
        case .sveLdrStrZ:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x0, zd: A64ZReg(rawValue: 1), imm: 1)
        case .sveLdrStrP:
            return A64Instruction(opcode: desc.id, is64Bit: true, rn: .x2, pd: A64PReg(rawValue: 1), imm: 1)
        case .sveAddVlPl:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, imm: 1)
        case .sveRdffr, .sveWrffr:
            return A64Instruction(opcode: desc.id, is64Bit: true, pd: A64PReg(rawValue: 0))
        }
    }

    /// Exhaustively verifies every entry in `A64InstructionTable`:
    /// constructs a representative instruction, encodes it to `UInt32`, disassembles it back,
    /// re-encodes the decoded instruction, and asserts `encoded1 == encoded2`.
    public static func verifyRoundTrip() -> [(mnemonic: String, encoded: UInt32, disassembled: String)] {
        var results: [(mnemonic: String, encoded: UInt32, disassembled: String)] = []
        results.reserveCapacity(entries.count)

        for desc in entries {
            let sample = sampleInstruction(for: desc)
            guard let encoded1 = A64Encoder.encode(sample) else {
                preconditionFailure("A64Encoder failed to encode sample for \(desc.id) (\(desc.mnemonic))")
            }
            guard let decoded = A64Disassembler.decode(encoded1) else {
                preconditionFailure("A64Disassembler failed to decode 0x\(String(encoded1, radix: 16)) for \(desc.id)")
            }
            guard decoded.opcode == desc.id else {
                preconditionFailure("Opcode mismatch on round-trip for \(desc.id): decoded \(decoded.opcode)")
            }
            guard let encoded2 = A64Encoder.encode(decoded), encoded1 == encoded2 else {
                preconditionFailure("Re-encoded word mismatch for \(desc.id): 0x\(String(encoded1, radix: 16))")
            }
            let text = A64Disassembler.format(decoded)
            results.append((mnemonic: desc.mnemonic, encoded: encoded1, disassembled: text))
        }

        return results
    }
}
