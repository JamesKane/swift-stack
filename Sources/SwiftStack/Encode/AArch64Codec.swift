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

/// Shift kind for shifted register operands (`lsl=0, lsr=1, asr=2, ror=3`), plus the "masking shift left"
/// `msl` of Advanced SIMD modified immediates (not encodable in a shifted-register `shift` field).
@frozen
public enum A64ShiftKind: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case lsl = 0
    case lsr = 1
    case asr = 2
    case ror = 3
    case msl = 4

    public var mnemonic: String {
        switch self {
        case .lsl: return "lsl"
        case .lsr: return "lsr"
        case .asr: return "asr"
        case .ror: return "ror"
        case .msl: return "msl"
        }
    }

    public static func parse(_ text: Substring) -> A64ShiftKind? {
        switch text.lowercased() {
        case "lsl": return .lsl
        case "lsr": return .lsr
        case "asr": return .asr
        case "ror": return .ror
        case "msl": return .msl
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

/// Barrier option: the 4-bit `CRm` field of `dmb`/`dsb`, also the `CRm` immediate of `isb`/`clrex`.
/// Every value is a valid encoding; the four without a name (`0`, `4`, `8`, `12`) print as `#imm`.
@frozen
public struct A64BarrierOption: RawRepresentable, Equatable, Hashable, Sendable, BitwiseCopyable {
    public var rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0xF
    }

    public static let oshld = A64BarrierOption(rawValue: 0b0001)
    public static let oshst = A64BarrierOption(rawValue: 0b0010)
    public static let osh   = A64BarrierOption(rawValue: 0b0011)
    public static let nshld = A64BarrierOption(rawValue: 0b0101)
    public static let nshst = A64BarrierOption(rawValue: 0b0110)
    public static let nsh   = A64BarrierOption(rawValue: 0b0111)
    public static let ishld = A64BarrierOption(rawValue: 0b1001)
    public static let ishst = A64BarrierOption(rawValue: 0b1010)
    public static let ish   = A64BarrierOption(rawValue: 0b1011)
    public static let ld    = A64BarrierOption(rawValue: 0b1101)
    public static let st    = A64BarrierOption(rawValue: 0b1110)
    public static let sy    = A64BarrierOption(rawValue: 0b1111)

    private static let names: [String] = [
        "#0", "oshld", "oshst", "osh", "#4", "nshld", "nshst", "nsh",
        "#8", "ishld", "ishst", "ish", "#12", "ld", "st", "sy",
    ]

    public var mnemonic: String { Self.names[Int(rawValue)] }

    /// Parses a named option (`ish`, `sy`, ...). `#imm` forms are parsed by the assembler as immediates.
    public static func parse(_ text: Substring) -> A64BarrierOption? {
        let lower = text.lowercased()
        guard !lower.hasPrefix("#"), let i = names.firstIndex(of: lower) else { return nil }
        return A64BarrierOption(rawValue: UInt8(i))
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

/// System maintenance instruction category (`tlbi`, `ic`, `dc`, `at`), all aliases of `SYS`.
@frozen
public enum A64SysMaintKind: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable {
    case tlbi = 0
    case ic   = 1
    case dc   = 2
    case at   = 3

    public var mnemonic: String {
        switch self {
        case .tlbi: return "tlbi"
        case .ic:   return "ic"
        case .dc:   return "dc"
        case .at:   return "at"
        }
    }
}

/// System maintenance operation for `tlbi`, `ic`, `dc`, and `at` (the base-architecture operations
/// plus the EL2 ones VectraOS's arm64 kernel uses; feature-gated `OS`/range/MTE variants are not included).
@frozen
public enum A64SysMaintOp: UInt8, Equatable, Hashable, Sendable, BitwiseCopyable, CaseIterable {
    // TLBI
    case vmalle1
    case vmalle1is
    case vae1is
    case aside1is
    case vaae1is
    case vale1is
    case vaale1is
    case vae1
    case aside1
    case vaae1
    case vale1
    case vaale1
    case ipas2e1is
    case alle2is
    case vae2is
    case alle1is
    case vmalls12e1is
    case alle2
    case vae2
    case alle1
    case vmalls12e1
    // IC
    case ialluis
    case iallu
    case ivau
    // DC
    case zva
    case ivac
    case isw
    case cvac
    case csw
    case cvau
    case civac
    case cisw
    // AT
    case s1e1r
    case s1e1w
    case s1e0r
    case s1e0w
    case s1e2r
    case s1e2w

    /// `(kind, op1, CRn, CRm, op2, takesRegister)` for the `SYS` encoding (`0xD5080000` base).
    private var fields: (kind: A64SysMaintKind, op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32, takesRegister: Bool) {
        switch self {
        case .vmalle1:     return (.tlbi, 0,  8,  7, 0, false)
        case .vmalle1is:   return (.tlbi, 0,  8,  3, 0, false)
        case .vae1is:      return (.tlbi, 0,  8,  3, 1, true)
        case .aside1is:    return (.tlbi, 0,  8,  3, 2, true)
        case .vaae1is:     return (.tlbi, 0,  8,  3, 3, true)
        case .vale1is:     return (.tlbi, 0,  8,  3, 5, true)
        case .vaale1is:    return (.tlbi, 0,  8,  3, 7, true)
        case .vae1:        return (.tlbi, 0,  8,  7, 1, true)
        case .aside1:      return (.tlbi, 0,  8,  7, 2, true)
        case .vaae1:       return (.tlbi, 0,  8,  7, 3, true)
        case .vale1:       return (.tlbi, 0,  8,  7, 5, true)
        case .vaale1:      return (.tlbi, 0,  8,  7, 7, true)
        case .ipas2e1is:   return (.tlbi, 4,  8,  0, 1, true)
        case .alle2is:     return (.tlbi, 4,  8,  3, 0, false)
        case .vae2is:      return (.tlbi, 4,  8,  3, 1, true)
        case .alle1is:     return (.tlbi, 4,  8,  3, 4, false)
        case .vmalls12e1is: return (.tlbi, 4,  8,  3, 6, false)
        case .alle2:       return (.tlbi, 4,  8,  7, 0, false)
        case .vae2:        return (.tlbi, 4,  8,  7, 1, true)
        case .alle1:       return (.tlbi, 4,  8,  7, 4, false)
        case .vmalls12e1:  return (.tlbi, 4,  8,  7, 6, false)
        case .ialluis:     return (.ic,  0,  7,  1, 0, false)
        case .iallu:       return (.ic,  0,  7,  5, 0, false)
        case .ivau:        return (.ic,  3,  7,  5, 1, true)
        case .zva:         return (.dc,  3,  7,  4, 1, true)
        case .ivac:        return (.dc,  0,  7,  6, 1, true)
        case .isw:         return (.dc,  0,  7,  6, 2, true)
        case .cvac:        return (.dc,  3,  7, 10, 1, true)
        case .csw:         return (.dc,  0,  7, 10, 2, true)
        case .cvau:        return (.dc,  3,  7, 11, 1, true)
        case .civac:       return (.dc,  3,  7, 14, 1, true)
        case .cisw:        return (.dc,  0,  7, 14, 2, true)
        case .s1e1r:       return (.at,  0,  7,  8, 0, true)
        case .s1e1w:       return (.at,  0,  7,  8, 1, true)
        case .s1e0r:       return (.at,  0,  7,  8, 2, true)
        case .s1e0w:       return (.at,  0,  7,  8, 3, true)
        case .s1e2r:       return (.at,  4,  7,  8, 0, true)
        case .s1e2w:       return (.at,  4,  7,  8, 1, true)
        }
    }

    public var kind: A64SysMaintKind { fields.kind }

    /// False for the operations with no register operand (`Rt` is encoded as 31).
    public var takesRegister: Bool { fields.takesRegister }

    public var operandName: String { "\(self)" }

    /// Returns `(op1, crn, crm, op2)` for the `SYS` instruction encoding.
    public var sysFields: (op1: UInt32, crn: UInt32, crm: UInt32, op2: UInt32) {
        let f = fields
        return (f.op1, f.crn, f.crm, f.op2)
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

    public static func parse(kind: A64SysMaintKind, name: Substring) -> A64SysMaintOp? {
        let lower = name.lowercased()
        return allCases.first { $0.kind == kind && $0.operandName == lower }
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

    /// Named system register table covering VectraOS's arm64 loader and kernel (verified against Arm ARM / llvm-mc).
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

// MARK: - 2b. FP and Advanced SIMD Immediates

/// The 8-bit `abcdefgh` floating-point immediate of `fmov` (Arm ARM `VFPExpandImm`): values
/// `±(16..31)/16 * 2^(-3..4)`, i.e. `±0.125 ... ±31.0`.
public enum A64FPImmediate {
    /// The exact value of `imm8` (the same for half, single and double precision).
    public static func decode(_ imm8: UInt8) -> Double {
        let sign = UInt64(imm8 >> 7) & 1
        let b = UInt64(imm8 >> 6) & 1
        let cd = UInt64(imm8 >> 4) & 0b11
        let efgh = UInt64(imm8 & 0xF)
        // Double exponent: NOT(b) : Replicate(b, 8) : c : d.
        let exponent = ((b ^ 1) << 10) | ((b == 1 ? 0xFF : 0) << 2) | cd
        return Double(bitPattern: (sign << 63) | (exponent << 52) | (efgh << 48))
    }

    /// The `imm8` encoding `value` exactly, if there is one.
    public static func encode(_ value: Double) -> UInt8? {
        for candidate in 0...255 where decode(UInt8(candidate)) == value {
            return UInt8(candidate)
        }
        return nil
    }

    /// LLVM's spelling, e.g. `1.00000000` (8 decimals are exact for every encodable value).
    public static func format(_ imm8: UInt8) -> String {
        String(format: "%.8f", decode(imm8))
    }
}

/// The 64-bit "byte mask" immediate of `movi Dd, #imm` / `movi Vd.2d, #imm`: every byte is `0x00` or `0xFF`,
/// and bit `i` of `abcdefgh` selects byte `i`.
public enum A64SIMDByteMask {
    public static func encode(_ value: UInt64) -> UInt8? {
        var imm8: UInt8 = 0
        for i in 0..<8 {
            switch (value >> (8 * UInt64(i))) & 0xFF {
            case 0xFF: imm8 |= 1 << UInt8(i)
            case 0x00: break
            default:   return nil
            }
        }
        return imm8
    }

    public static func decode(_ imm8: UInt8) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 where (imm8 >> UInt8(i)) & 1 != 0 {
            value |= 0xFF << (8 * UInt64(i))
        }
        return value
    }
}

/// PSTATE `hint` aliases that LLVM prints (with `+pauth`/`+bti`) and accepts, keyed by the `CRm:op2` immediate.
public enum A64HintAlias {
    public static let names: [Int64: String] = [
        6: "dgh", 7: "xpaclri", 8: "pacia1716", 10: "pacib1716", 12: "autia1716", 14: "autib1716", 20: "csdb",
        24: "paciaz", 25: "paciasp", 26: "pacibz", 27: "pacibsp", 28: "autiaz", 29: "autiasp", 30: "autibz", 31: "autibsp",
        32: "bti", 34: "bti c", 36: "bti j", 38: "bti jc",
    ]

    public static let byName: [String: Int64] = {
        var map: [String: Int64] = [:]
        for (imm, name) in names { map[name] = imm }
        return map
    }()
}

// MARK: - 3. Shared Instruction Descriptor Table & Structured Instruction Model

/// Encoding format classes for the AArch64 table-driven encoder and disassembler.
///
/// Field conventions in `A64Instruction` that are not obvious from the names: `scalarWidth` is the FP
/// register width or the memory access size (LSE: `.b`/`.h`/`.s`=32-bit/`.d`=64-bit); `scalarWidth2` is the
/// source width of `fcvt`; `imm2` is a second immediate (`nzcv`, `imms`, a source lane, a register-list
/// length, or the explicit `S` bit of a byte register-offset load); `va` is the fourth FP register (`Ra`).
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
    case hintImm7           // hint (#imm7), printed as its PAC/BTI/CSDB alias where one exists
    case barrier            // dmb, dsb, isb, clrex (CRm option or #imm4)
    case mrs                // mrs Xt, <sysreg>
    case msrReg             // msr <sysreg>, Xt
    case msrPState          // msr <pstatefield>, #imm4
    case sysMaint           // tlbi, ic, dc, at

    // Loads and stores
    case ldstUnsignedImm12  // ldr, str, ldrb, strb, ldrh, strh, ldrsb, ldrsh, ldrsw (unsigned scaled offset)
    case ldstPreImm9        // ldr, str, ... [Xn, #simm9]!
    case ldstPostImm9       // ldr, str, ... [Xn], #simm9
    case ldstUnscaledImm9   // ldur, stur, ldurb, sturb, ldurh, sturh, ldursb, ldursh, ldursw
    case ldstUnprivImm9     // ldtr, sttr, ldtrb, sttrb, ldtrh, sttrh, ldtrsb, ldtrsh, ldtrsw
    case ldstRegOffset      // ldr, str, ... [Xn, Rm, extend #shift]
    case ldrLiteral         // ldr Wt/Xt, ldrsw Xt, label (imm19 * 4)
    case ldpStpSigned       // ldp, stp (Wt/Xt, [Xn, #simm7 * scale])
    case ldpStpPre          // ldp, stp (Wt/Xt, [Xn, #simm7 * scale]!)
    case ldpStpPost         // ldp, stp (Wt/Xt, [Xn], #simm7 * scale)
    case atomicLoad         // ldxr, ldaxr, ldar (+b/h) (Rt, [Xn])
    case atomicStore        // stlr, stlrb, stlrh (Rt, [Xn])
    case atomicStoreExcl    // stxr, stlxr (+b/h) (Ws, Rt, [Xn])
    case atomicLoadPair     // ldxp, ldaxp (Rt, Rt2, [Xn])
    case atomicStoreExclPair // stxp, stlxp (Ws, Rt, Rt2, [Xn])

    // LSE atomics (FEAT_LSE)
    case lseAtomic          // ld<op>[a][l][b|h], swp[a][l][b|h] (Rs, Rt, [Xn]); st<op> alias when Rt = zr
    case lseCas             // cas[a][l][b|h] (Rs, Rt, [Xn])
    case lseCasp            // casp[a][l] (Rs, Rs+1, Rt, Rt+1, [Xn])

    // SIMD/FP loads and stores (b/h/s/d/q)
    case fpLdstPreImm9      // ldr, str Bt..Qt, [Xn, #simm9]!
    case fpLdstPostImm9     // ldr, str Bt..Qt, [Xn], #simm9
    case fpLdstUnscaledImm9 // ldur, stur Bt..Qt, [Xn, #simm9]
    case fpLdstRegOffset    // ldr, str Bt..Qt, [Xn, Rm, extend #shift]
    case fpLdrLiteral       // ldr St/Dt/Qt, label
    case fpLdpStpSigned     // ldp, stp St/Dt/Qt, [Xn, #simm7 * scale]
    case fpLdpStpPre        // ldp, stp St/Dt/Qt, [Xn, #simm7 * scale]!
    case fpLdpStpPost       // ldp, stp St/Dt/Qt, [Xn], #simm7 * scale

    // Scalar FP (h/s/d)
    case fpMovGprToFp       // fmov Hd/Sd/Dd, Wn/Xn
    case fpMovFpToGpr       // fmov Wd/Xd, Hn/Sn/Dn
    case fpDp1              // fmov, fabs, fneg, fsqrt, frint[npmzaxi] (Fd, Fn)
    case fpCvtPrecision     // fcvt (Fd, Fn) between h, s, d
    case fpIntToFp          // scvtf, ucvtf (Fd, Rn)
    case fpToInt            // fcvt[npmza][su] (Rd, Fn)
    case fpFixedToFp        // scvtf, ucvtf (Fd, Rn, #fbits)
    case fpToFixed          // fcvtzs, fcvtzu (Rd, Fn, #fbits)
    case fpBinary           // fadd, fsub, fmul, fdiv, fmax, fmin, fmaxnm, fminnm, fnmul (Fd, Fn, Fm)
    case fpDp3              // fmadd, fmsub, fnmadd, fnmsub (Fd, Fn, Fm, Fa)
    case fpCmpReg           // fcmp, fcmpe (Fn, Fm)
    case fpCmpZero          // fcmp, fcmpe (Fn, #0.0)
    case fpCondCompare      // fccmp, fccmpe (Fn, Fm, #nzcv, cond)
    case fpCondSelect       // fcsel (Fd, Fn, Fm, cond)
    case fpImm              // fmov (Fd, #fp8)

    // Advanced SIMD (NEON)
    case simdThreeSameInt   // add, sub, mul, mla, mls, cm*, s/u max/min/abd, addp, sq/uq add/sub, s/u shl
    case simdThreeSameBit   // and, bic, orr (mov alias), orn, eor, bsl, bit, bif (8b/16b)
    case simdThreeSameFp    // fadd, fsub, fmul, fdiv, fmax, fmin, fmaxnm, fminnm, fmla, fmls, fcm*, faddp, fabd
    case simdPermute        // uzp1, uzp2, zip1, zip2, trn1, trn2
    case simdTwoRegMisc     // cnt, not (mvn), rbit, rev16/32/64, cls, clz, abs, neg
    case simdCmpZero        // cmeq, cmge, cmgt, cmle, cmlt (Vd, Vn, #0)
    case simdTwoRegMiscFp   // fabs, fneg, fsqrt, scvtf, ucvtf, fcvtzs, fcvtzu, frint[npmzaxi]
    case simdAcrossLanes    // addv, smaxv, sminv, umaxv, uminv (scalar Vd, Vn.<T>)
    case simdNarrow         // xtn, xtn2 (Vd.<Tb>, Vn.<Ta>)
    case simdShiftImm       // shl, sli, sshr, ushr, ssra, usra, sri
    case simdShiftLong      // sshll[2], ushll[2] (Vd.<Ta>, Vn.<Tb>, #shift)
    case simdShiftNarrow    // shrn[2] (Vd.<Tb>, Vn.<Ta>, #shift)
    case simdDupElem        // dup Vd.<T>, Vn.<Ts>[idx]
    case simdDupGpr         // dup Vd.<T>, Wn/Xn
    case simdDupScalar      // mov (dup) Bd/Hd/Sd/Dd, Vn.<Ts>[idx]
    case simdInsGpr         // mov (ins) Vd.<Ts>[idx], Wn/Xn
    case simdInsElem        // mov (ins) Vd.<Ts>[idx], Vn.<Ts>[idx2]
    case simdUmovSmov       // umov (mov alias for s/d), smov Wd/Xd, Vn.<Ts>[idx]
    case simdModImm         // movi, mvni, orr, bic, fmov (vector, immediate)
    case simdLdStMulti      // ld1-4, st1-4 {list}, [Xn]
    case simdLdStMultiPost  // ld1-4, st1-4 {list}, [Xn], #imm|Xm
    case simdLd1R           // ld1r {Vt.<T>}, [Xn]
    case simdLd1RPost       // ld1r {Vt.<T>}, [Xn], #imm|Xm
    case simdLdStLane       // ld1, st1 {Vt.<Ts>}[idx], [Xn]
    case simdLdStLanePost   // ld1, st1 {Vt.<Ts>}[idx], [Xn], #imm|Xm
    case simdTbl            // tbl, tbx Vd.<8b|16b>, {list .16b}, Vm.<8b|16b>
    case simdExt            // ext v0.<8b|16b>, v1.<8b|16b>, v2.<8b|16b>, #imm4

    // SVE (the VectraOS kernel/arch/arm64/cpu.S subset)
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
    case ldrPre, strPre, ldrbPre, strbPre, ldrhPre, strhPre, ldrsbPre64, ldrsbPre32, ldrshPre64, ldrshPre32, ldrswPre
    case ldrPost, strPost, ldrbPost, strbPost, ldrhPost, strhPost, ldrsbPost64, ldrsbPost32, ldrshPost64, ldrshPost32, ldrswPost

    // Loads and stores — unscaled (`ldur`/`stur`)
    case ldur, stur, ldurb, sturb, ldurh, sturh, ldursb64, ldursb32, ldursh64, ldursh32, ldursw

    // Loads and stores — unprivileged (`ldtr`/`sttr`)
    case ldtr, sttr, ldtrb, sttrb, ldtrh, sttrh, ldtrsb64, ldtrsb32, ldtrsh64, ldtrsh32, ldtrsw

    // Loads and stores — register offset & literal
    case ldrReg, strReg, ldrbReg, strbReg, ldrhReg, strhReg, ldrsbReg64, ldrsbReg32, ldrshReg64, ldrshReg32, ldrswReg
    case ldrLit, ldrswLit

    // Loads and stores — pairs (`ldp`/`stp`)
    case ldpSigned, stpSigned, ldpPre, stpPre, ldpPost, stpPost

    // Atomics / exclusives
    case ldxr, stxr, ldaxr, stlxr, ldar, stlr, ldarb, stlrb, ldarh, stlrh
    case ldxrb, ldxrh, ldaxrb, ldaxrh, stxrb, stxrh, stlxrb, stlxrh
    case ldxp, ldaxp, stxp, stlxp

    // LSE atomics
    case ldadd, ldclr, ldeor, ldset, ldsmax, ldsmin, ldumax, ldumin, swp
    case cas, casp

    // SIMD/FP loads and stores
    case ldrFpPre, strFpPre, ldrFpPost, strFpPost, ldurFp, sturFp, ldrFpReg, strFpReg, ldrFpLit
    case ldpFpSigned, stpFpSigned, ldpFpPre, stpFpPre, ldpFpPost, stpFpPost

    // Scalar FP
    case fmovGprToFp, fmovFpToGpr
    case fmovReg, fabs, fneg, fsqrt, frintn, frintp, frintm, frintz, frinta, frintx, frinti
    case fcvt
    case scvtf, ucvtf, fcvtns, fcvtnu, fcvtas, fcvtau, fcvtps, fcvtpu, fcvtms, fcvtmu, fcvtzs, fcvtzu
    case scvtfFixed, ucvtfFixed, fcvtzsFixed, fcvtzuFixed
    case fmulScalar, fdivScalar, faddScalar, fsubScalar, fmaxScalar, fminScalar, fmaxnmScalar, fminnmScalar, fnmul
    case fmadd, fmsub, fnmadd, fnmsub
    case fcmpReg, fcmpeReg, fcmpZero, fcmpeZero
    case fccmp, fccmpe, fcsel, fmovImm

    // Advanced SIMD (NEON)
    case simdAdd, simdSub, simdMul, simdMla, simdMls, simdCmeq, simdCmtst, simdCmgt, simdCmge, simdCmhi, simdCmhs
    case simdSmax, simdSmin, simdUmax, simdUmin, simdSabd, simdUabd, simdAddp
    case simdSqadd, simdUqadd, simdSqsub, simdUqsub, simdSshl, simdUshl
    case simdAnd, simdBic, simdOrr, simdOrn, simdEor, simdBsl, simdBit, simdBif
    case simdFadd, simdFsub, simdFmul, simdFdiv, simdFmax, simdFmin, simdFmaxnm, simdFminnm
    case simdFmla, simdFmls, simdFcmeq, simdFcmge, simdFcmgt, simdFaddp, simdFabd
    case simdUzp1, simdUzp2, simdZip1, simdZip2, simdTrn1, simdTrn2
    case simdCnt, simdNot, simdRbit, simdRev16, simdRev32, simdRev64, simdCls, simdClz, simdAbs, simdNeg
    case simdCmeqZero, simdCmgeZero, simdCmgtZero, simdCmleZero, simdCmltZero
    case simdFabs, simdFneg, simdFsqrt, simdScvtf, simdUcvtf, simdFcvtzs, simdFcvtzu
    case simdFrintn, simdFrintp, simdFrintm, simdFrintz, simdFrinta, simdFrintx, simdFrinti
    case simdAddv, simdSmaxv, simdSminv, simdUmaxv, simdUminv
    case simdXtn
    case simdShl, simdSli, simdSshr, simdUshr, simdSsra, simdUsra, simdSri
    case simdSshll, simdUshll, simdShrn
    case simdDupElem, simdDupGpr, simdDupScalar, simdInsGpr, simdInsElem, simdUmov, simdSmov
    case simdMovi, simdMvni, simdOrrImm, simdBicImm, simdFmovImm
    case simdLd1, simdSt1, simdLd2, simdSt2, simdLd3, simdSt3, simdLd4, simdSt4
    case simdLd1Post, simdSt1Post, simdLd2Post, simdSt2Post, simdLd3Post, simdSt3Post, simdLd4Post, simdSt4Post
    case simdLd1R, simdLd1RPost, simdLd1Lane, simdSt1Lane, simdLd1LanePost, simdSt1LanePost
    case simdTbl, simdTbx, simdExt

    // SVE
    case sveLdrZ, sveStrZ, sveLdrP, sveStrP
    case sveAddvl, sveAddpl, sveRdffr, sveWrffr
}

/// Bit sets of the scalar widths (`1 << A64ScalarWidth.rawValue`) and vector arrangements
/// (`1 << A64Arrangement.rawValue`) a descriptor accepts. The encoder rejects anything outside them,
/// and the exhaustive round-trip test sweeps exactly them.
public enum A64Variants {
    public static let b: UInt8 = 1 << 0
    public static let h: UInt8 = 1 << 1
    public static let s: UInt8 = 1 << 2
    public static let d: UInt8 = 1 << 3
    public static let q: UInt8 = 1 << 4
    public static let hsd: UInt8 = h | s | d
    public static let sd: UInt8 = s | d
    public static let sdq: UInt8 = s | d | q
    public static let bhsd: UInt8 = b | h | s | d
    public static let bhsdq: UInt8 = b | h | s | d | q

    public static let b8: UInt16 = 1 << 0
    public static let b16: UInt16 = 1 << 1
    public static let h4: UInt16 = 1 << 2
    public static let h8: UInt16 = 1 << 3
    public static let s2: UInt16 = 1 << 4
    public static let s4: UInt16 = 1 << 5
    public static let d1: UInt16 = 1 << 6
    public static let d2: UInt16 = 1 << 7
    public static let bytes: UInt16 = b8 | b16
    public static let bh: UInt16 = b8 | b16 | h4 | h8
    public static let bhs: UInt16 = b8 | b16 | h4 | h8 | s2 | s4
    public static let bhsd2: UInt16 = bhs | d2
    public static let allArr: UInt16 = bhsd2 | d1
    public static let fp: UInt16 = s2 | s4 | d2
    public static let acrossLanes: UInt16 = bh | s4
}

extension A64ScalarWidth {
    /// Size of the register or memory access in bytes.
    @inlinable
    public var byteCount: Int { 1 << Int(rawValue) }

    /// The scalar FP `ftype` field (bits 23:22): `s`=00, `d`=01, `h`=11.
    @inlinable
    public var ftype: UInt32? {
        switch self {
        case .s: return 0b00
        case .d: return 0b01
        case .h: return 0b11
        default: return nil
        }
    }

    @inlinable
    public static func fromFtype(_ bits: UInt32) -> A64ScalarWidth? {
        switch bits & 3 {
        case 0b00: return .s
        case 0b01: return .d
        case 0b11: return .h
        default:   return nil
        }
    }
}

extension A64Arrangement {
    /// Width of one element (`.q` for `1q`).
    @inlinable
    public var elementWidth: A64ScalarWidth {
        switch self {
        case .b8, .b16: return .b
        case .h4, .h8:  return .h
        case .s2, .s4:  return .s
        case .d1, .d2:  return .d
        case .q1:       return .q
        }
    }

    /// The `1 << rawValue` member bit used by `A64InstrDesc.arrangements`.
    @inlinable
    public var variantBit: UInt16 { 1 << UInt16(rawValue) }

    public static func from(element: A64ScalarWidth, q: Bool) -> A64Arrangement? {
        switch element {
        case .b: return q ? .b16 : .b8
        case .h: return q ? .h8 : .h4
        case .s: return q ? .s4 : .s2
        case .d: return q ? .d2 : .d1
        case .q: return nil
        }
    }

    /// The arrangement whose elements are twice as wide in a full 128-bit register (`8b`/`16b` -> `8h`).
    public var widened: A64Arrangement? {
        switch elementWidth {
        case .b: return .h8
        case .h: return .s4
        case .s: return .d2
        default: return nil
        }
    }
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
    /// Fixed scalar width for SIMD/FP unsigned-offset loads/stores.
    public let scalarWidth: A64ScalarWidth?
    /// Accepted scalar widths (`A64Variants.b`...`q` bits) for formats whose width is a variable field.
    public let widths: UInt8
    /// Accepted vector arrangements (`A64Variants.b8`...`d2` bits) for Advanced SIMD formats.
    public let arrangements: UInt16

    public init(
        id: A64OpcodeId,
        mnemonic: String,
        format: A64InstrFormat,
        opcodeMask: UInt32,
        opcodeBits: UInt32,
        scaleLog2: UInt8 = 0,
        scalarWidth: A64ScalarWidth? = nil,
        widths: UInt8 = 0,
        arrangements: UInt16 = 0
    ) {
        self.id = id
        self.mnemonic = mnemonic
        self.format = format
        self.opcodeMask = opcodeMask
        self.opcodeBits = opcodeBits
        self.scaleLog2 = scaleLog2
        self.scalarWidth = scalarWidth
        self.widths = widths
        self.arrangements = arrangements
    }

    @inlinable
    public func allows(_ width: A64ScalarWidth) -> Bool {
        (widths >> width.rawValue) & 1 != 0
    }

    @inlinable
    public func allows(_ arrangement: A64Arrangement) -> Bool {
        (arrangements >> UInt16(arrangement.rawValue)) & 1 != 0
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
    public var va: A64VReg
    public var zd: A64ZReg
    public var pd: A64PReg
    public var scalarWidth: A64ScalarWidth
    public var scalarWidth2: A64ScalarWidth
    public var arrangement: A64Arrangement
    public var cond: A64Cond
    public var shiftKind: A64ShiftKind
    public var extendKind: A64ExtendKind
    public var amount: UInt8
    public var index: UInt8
    public var imm: Int64
    public var imm2: UInt8
    public var acquire: Bool
    public var release: Bool
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
        va: A64VReg = .v0,
        zd: A64ZReg = A64ZReg(rawValue: 0),
        pd: A64PReg = A64PReg(rawValue: 0),
        scalarWidth: A64ScalarWidth = .d,
        scalarWidth2: A64ScalarWidth = .d,
        arrangement: A64Arrangement = .b16,
        cond: A64Cond = .eq,
        shiftKind: A64ShiftKind = .lsl,
        extendKind: A64ExtendKind = .uxtw,
        amount: UInt8 = 0,
        index: UInt8 = 0,
        imm: Int64 = 0,
        imm2: UInt8 = 0,
        acquire: Bool = false,
        release: Bool = false,
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
        self.va = va
        self.zd = zd
        self.pd = pd
        self.scalarWidth = scalarWidth
        self.scalarWidth2 = scalarWidth2
        self.arrangement = arrangement
        self.cond = cond
        self.shiftKind = shiftKind
        self.extendKind = extendKind
        self.amount = amount
        self.index = index
        self.imm = imm
        self.imm2 = imm2
        self.acquire = acquire
        self.release = release
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
        A64InstrDesc(id: .ldrsbPre32, mnemonic: "ldrsb", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38C0_0C00),
        A64InstrDesc(id: .ldrshPre64, mnemonic: "ldrsh", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0C00),
        A64InstrDesc(id: .ldrshPre32, mnemonic: "ldrsh", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78C0_0C00),
        A64InstrDesc(id: .ldrswPre,   mnemonic: "ldrsw", format: .ldstPreImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB880_0C00),

        // Post-index `[Xn], #simm9`
        A64InstrDesc(id: .ldrPost,     mnemonic: "ldr",   format: .ldstPostImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB840_0400),
        A64InstrDesc(id: .strPost,     mnemonic: "str",   format: .ldstPostImm9, opcodeMask: 0xBFE0_0C00, opcodeBits: 0xB800_0400),
        A64InstrDesc(id: .ldrbPost,    mnemonic: "ldrb",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3840_0400),
        A64InstrDesc(id: .strbPost,    mnemonic: "strb",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3800_0400),
        A64InstrDesc(id: .ldrhPost,    mnemonic: "ldrh",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7840_0400),
        A64InstrDesc(id: .strhPost,    mnemonic: "strh",  format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7800_0400),
        A64InstrDesc(id: .ldrsbPost64, mnemonic: "ldrsb", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x3880_0400),
        A64InstrDesc(id: .ldrsbPost32, mnemonic: "ldrsb", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38C0_0400),
        A64InstrDesc(id: .ldrshPost64, mnemonic: "ldrsh", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x7880_0400),
        A64InstrDesc(id: .ldrshPost32, mnemonic: "ldrsh", format: .ldstPostImm9, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78C0_0400),
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
        A64InstrDesc(id: .ldrsbReg32, mnemonic: "ldrsb", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x38E0_0800, scaleLog2: 0),
        A64InstrDesc(id: .ldrshReg64, mnemonic: "ldrsh", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78A0_0800, scaleLog2: 1),
        A64InstrDesc(id: .ldrshReg32, mnemonic: "ldrsh", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0x78E0_0800, scaleLog2: 1),
        A64InstrDesc(id: .ldrswReg,   mnemonic: "ldrsw", format: .ldstRegOffset, opcodeMask: 0xFFE0_0C00, opcodeBits: 0xB8A0_0800, scaleLog2: 2),

        // Literal `ldr Wt/Xt, label`
        A64InstrDesc(id: .ldrLit,   mnemonic: "ldr",   format: .ldrLiteral, opcodeMask: 0xBF00_0000, opcodeBits: 0x1800_0000),
        A64InstrDesc(id: .ldrswLit, mnemonic: "ldrsw", format: .ldrLiteral, opcodeMask: 0xFF00_0000, opcodeBits: 0x9800_0000),

        // Load/store pairs (`ldp`/`stp` for 32-bit `w` and 64-bit `x`)
        A64InstrDesc(id: .ldpSigned,  mnemonic: "ldp", format: .ldpStpSigned, opcodeMask: 0x7FC0_0000, opcodeBits: 0x2940_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpSigned,  mnemonic: "stp", format: .ldpStpSigned, opcodeMask: 0x7FC0_0000, opcodeBits: 0x2900_0000, scaleLog2: 255),
        A64InstrDesc(id: .ldpPre,     mnemonic: "ldp", format: .ldpStpPre,    opcodeMask: 0x7FC0_0000, opcodeBits: 0x29C0_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpPre,     mnemonic: "stp", format: .ldpStpPre,    opcodeMask: 0x7FC0_0000, opcodeBits: 0x2980_0000, scaleLog2: 255),
        A64InstrDesc(id: .ldpPost,    mnemonic: "ldp", format: .ldpStpPost,   opcodeMask: 0x7FC0_0000, opcodeBits: 0x28C0_0000, scaleLog2: 255),
        A64InstrDesc(id: .stpPost,    mnemonic: "stp", format: .ldpStpPost,   opcodeMask: 0x7FC0_0000, opcodeBits: 0x2880_0000, scaleLog2: 255),

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
        A64InstrDesc(id: .ldxrb,  mnemonic: "ldxrb",  format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x085F_7C00),
        A64InstrDesc(id: .ldxrh,  mnemonic: "ldxrh",  format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x485F_7C00),
        A64InstrDesc(id: .ldaxrb, mnemonic: "ldaxrb", format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x085F_FC00),
        A64InstrDesc(id: .ldaxrh, mnemonic: "ldaxrh", format: .atomicLoad,      opcodeMask: 0xFFFF_FC00, opcodeBits: 0x485F_FC00),
        A64InstrDesc(id: .stxrb,  mnemonic: "stxrb",  format: .atomicStoreExcl, opcodeMask: 0xFFE0_FC00, opcodeBits: 0x0800_7C00),
        A64InstrDesc(id: .stxrh,  mnemonic: "stxrh",  format: .atomicStoreExcl, opcodeMask: 0xFFE0_FC00, opcodeBits: 0x4800_7C00),
        A64InstrDesc(id: .stlxrb, mnemonic: "stlxrb", format: .atomicStoreExcl, opcodeMask: 0xFFE0_FC00, opcodeBits: 0x0800_FC00),
        A64InstrDesc(id: .stlxrh, mnemonic: "stlxrh", format: .atomicStoreExcl, opcodeMask: 0xFFE0_FC00, opcodeBits: 0x4800_FC00),
        A64InstrDesc(id: .ldxp,   mnemonic: "ldxp",   format: .atomicLoadPair,      opcodeMask: 0xBFFF_8000, opcodeBits: 0x887F_0000),
        A64InstrDesc(id: .ldaxp,  mnemonic: "ldaxp",  format: .atomicLoadPair,      opcodeMask: 0xBFFF_8000, opcodeBits: 0x887F_8000),
        A64InstrDesc(id: .stxp,   mnemonic: "stxp",   format: .atomicStoreExclPair, opcodeMask: 0xBFE0_8000, opcodeBits: 0x8820_0000),
        A64InstrDesc(id: .stlxp,  mnemonic: "stlxp",  format: .atomicStoreExclPair, opcodeMask: 0xBFE0_8000, opcodeBits: 0x8820_8000),

        // LSE atomics: `scalarWidth` is the access size (b/h/s=32-bit/d=64-bit); acquire = A/L bit, release = R/o0 bit.
        A64InstrDesc(id: .ldadd,  mnemonic: "ldadd",  format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_0000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldclr,  mnemonic: "ldclr",  format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_1000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldeor,  mnemonic: "ldeor",  format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_2000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldset,  mnemonic: "ldset",  format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_3000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldsmax, mnemonic: "ldsmax", format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_4000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldsmin, mnemonic: "ldsmin", format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_5000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldumax, mnemonic: "ldumax", format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_6000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .ldumin, mnemonic: "ldumin", format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_7000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .swp,    mnemonic: "swp",    format: .lseAtomic, opcodeMask: 0x3F20_FC00, opcodeBits: 0x3820_8000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .cas,    mnemonic: "cas",    format: .lseCas,    opcodeMask: 0x3FA0_7C00, opcodeBits: 0x08A0_7C00, widths: A64Variants.bhsd),
        A64InstrDesc(id: .casp,   mnemonic: "casp",   format: .lseCasp,   opcodeMask: 0xBFA0_7C00, opcodeBits: 0x0820_7C00, widths: A64Variants.sd),

        // SIMD/FP loads and stores with a variable register width (`size` bits 31:30 and `opc<1>` bit 23).
        A64InstrDesc(id: .ldrFpPre,  mnemonic: "ldr",  format: .fpLdstPreImm9,      opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C40_0C00, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .strFpPre,  mnemonic: "str",  format: .fpLdstPreImm9,      opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C00_0C00, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .ldrFpPost, mnemonic: "ldr",  format: .fpLdstPostImm9,     opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C40_0400, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .strFpPost, mnemonic: "str",  format: .fpLdstPostImm9,     opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C00_0400, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .ldurFp,    mnemonic: "ldur", format: .fpLdstUnscaledImm9, opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C40_0000, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .sturFp,    mnemonic: "stur", format: .fpLdstUnscaledImm9, opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C00_0000, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .ldrFpReg,  mnemonic: "ldr",  format: .fpLdstRegOffset,    opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C60_0800, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .strFpReg,  mnemonic: "str",  format: .fpLdstRegOffset,    opcodeMask: 0x3F60_0C00, opcodeBits: 0x3C20_0800, widths: A64Variants.bhsdq),
        A64InstrDesc(id: .ldrFpLit,  mnemonic: "ldr",  format: .fpLdrLiteral,       opcodeMask: 0x3F00_0000, opcodeBits: 0x1C00_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .ldpFpSigned, mnemonic: "ldp", format: .fpLdpStpSigned, opcodeMask: 0x3FC0_0000, opcodeBits: 0x2D40_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .stpFpSigned, mnemonic: "stp", format: .fpLdpStpSigned, opcodeMask: 0x3FC0_0000, opcodeBits: 0x2D00_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .ldpFpPre,    mnemonic: "ldp", format: .fpLdpStpPre,    opcodeMask: 0x3FC0_0000, opcodeBits: 0x2DC0_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .stpFpPre,    mnemonic: "stp", format: .fpLdpStpPre,    opcodeMask: 0x3FC0_0000, opcodeBits: 0x2D80_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .ldpFpPost,   mnemonic: "ldp", format: .fpLdpStpPost,   opcodeMask: 0x3FC0_0000, opcodeBits: 0x2CC0_0000, widths: A64Variants.sdq),
        A64InstrDesc(id: .stpFpPost,   mnemonic: "stp", format: .fpLdpStpPost,   opcodeMask: 0x3FC0_0000, opcodeBits: 0x2C80_0000, widths: A64Variants.sdq),

        // --- 5. Scalar FP (h/s/d via `ftype`, bits 23:22) ---
        A64InstrDesc(id: .fmovGprToFp, mnemonic: "fmov", format: .fpMovGprToFp, opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E27_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fmovFpToGpr, mnemonic: "fmov", format: .fpMovFpToGpr, opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E26_0000, widths: A64Variants.hsd),

        A64InstrDesc(id: .fmovReg, mnemonic: "fmov",   format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E20_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fabs,    mnemonic: "fabs",   format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E20_C000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fneg,    mnemonic: "fneg",   format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E21_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fsqrt,   mnemonic: "fsqrt",  format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E21_C000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frintn,  mnemonic: "frintn", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E24_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frintp,  mnemonic: "frintp", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E24_C000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frintm,  mnemonic: "frintm", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E25_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frintz,  mnemonic: "frintz", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E25_C000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frinta,  mnemonic: "frinta", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E26_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frintx,  mnemonic: "frintx", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E27_4000, widths: A64Variants.hsd),
        A64InstrDesc(id: .frinti,  mnemonic: "frinti", format: .fpDp1, opcodeMask: 0xFF3F_FC00, opcodeBits: 0x1E27_C000, widths: A64Variants.hsd),
        // `fcvt`: source width in `ftype`, destination width in `opc` (bits 16:15).
        A64InstrDesc(id: .fcvt,    mnemonic: "fcvt",   format: .fpCvtPrecision, opcodeMask: 0xFF3E_7C00, opcodeBits: 0x1E22_4000, widths: A64Variants.hsd),

        A64InstrDesc(id: .scvtf,  mnemonic: "scvtf",  format: .fpIntToFp, opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E22_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .ucvtf,  mnemonic: "ucvtf",  format: .fpIntToFp, opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E23_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtns, mnemonic: "fcvtns", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E20_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtnu, mnemonic: "fcvtnu", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E21_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtas, mnemonic: "fcvtas", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E24_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtau, mnemonic: "fcvtau", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E25_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtps, mnemonic: "fcvtps", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E28_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtpu, mnemonic: "fcvtpu", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E29_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtms, mnemonic: "fcvtms", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E30_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtmu, mnemonic: "fcvtmu", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E31_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtzs, mnemonic: "fcvtzs", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E38_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtzu, mnemonic: "fcvtzu", format: .fpToInt,   opcodeMask: 0x7F3F_FC00, opcodeBits: 0x1E39_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .scvtfFixed,  mnemonic: "scvtf",  format: .fpFixedToFp, opcodeMask: 0x7F3F_0000, opcodeBits: 0x1E02_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .ucvtfFixed,  mnemonic: "ucvtf",  format: .fpFixedToFp, opcodeMask: 0x7F3F_0000, opcodeBits: 0x1E03_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtzsFixed, mnemonic: "fcvtzs", format: .fpToFixed,   opcodeMask: 0x7F3F_0000, opcodeBits: 0x1E18_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcvtzuFixed, mnemonic: "fcvtzu", format: .fpToFixed,   opcodeMask: 0x7F3F_0000, opcodeBits: 0x1E19_0000, widths: A64Variants.hsd),

        A64InstrDesc(id: .fmulScalar,   mnemonic: "fmul",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_0800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fdivScalar,   mnemonic: "fdiv",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_1800, widths: A64Variants.hsd),
        A64InstrDesc(id: .faddScalar,   mnemonic: "fadd",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_2800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fsubScalar,   mnemonic: "fsub",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_3800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fmaxScalar,   mnemonic: "fmax",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_4800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fminScalar,   mnemonic: "fmin",   format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_5800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fmaxnmScalar, mnemonic: "fmaxnm", format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_6800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fminnmScalar, mnemonic: "fminnm", format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_7800, widths: A64Variants.hsd),
        A64InstrDesc(id: .fnmul,        mnemonic: "fnmul",  format: .fpBinary, opcodeMask: 0xFF20_FC00, opcodeBits: 0x1E20_8800, widths: A64Variants.hsd),

        A64InstrDesc(id: .fmadd,  mnemonic: "fmadd",  format: .fpDp3, opcodeMask: 0xFF20_8000, opcodeBits: 0x1F00_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fmsub,  mnemonic: "fmsub",  format: .fpDp3, opcodeMask: 0xFF20_8000, opcodeBits: 0x1F00_8000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fnmadd, mnemonic: "fnmadd", format: .fpDp3, opcodeMask: 0xFF20_8000, opcodeBits: 0x1F20_0000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fnmsub, mnemonic: "fnmsub", format: .fpDp3, opcodeMask: 0xFF20_8000, opcodeBits: 0x1F20_8000, widths: A64Variants.hsd),

        A64InstrDesc(id: .fcmpZero,  mnemonic: "fcmp",  format: .fpCmpZero, opcodeMask: 0xFF3F_FC1F, opcodeBits: 0x1E20_2008, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcmpeZero, mnemonic: "fcmpe", format: .fpCmpZero, opcodeMask: 0xFF3F_FC1F, opcodeBits: 0x1E20_2018, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcmpReg,   mnemonic: "fcmp",  format: .fpCmpReg,  opcodeMask: 0xFF20_FC1F, opcodeBits: 0x1E20_2000, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcmpeReg,  mnemonic: "fcmpe", format: .fpCmpReg,  opcodeMask: 0xFF20_FC1F, opcodeBits: 0x1E20_2010, widths: A64Variants.hsd),
        A64InstrDesc(id: .fccmp,     mnemonic: "fccmp",  format: .fpCondCompare, opcodeMask: 0xFF20_0C10, opcodeBits: 0x1E20_0400, widths: A64Variants.hsd),
        A64InstrDesc(id: .fccmpe,    mnemonic: "fccmpe", format: .fpCondCompare, opcodeMask: 0xFF20_0C10, opcodeBits: 0x1E20_0410, widths: A64Variants.hsd),
        A64InstrDesc(id: .fcsel,     mnemonic: "fcsel",  format: .fpCondSelect,  opcodeMask: 0xFF20_0C00, opcodeBits: 0x1E20_0C00, widths: A64Variants.hsd),
        A64InstrDesc(id: .fmovImm,   mnemonic: "fmov",   format: .fpImm,         opcodeMask: 0xFF20_1FE0, opcodeBits: 0x1E20_1000, widths: A64Variants.hsd),

        // --- 6. Advanced SIMD (NEON) ---
        // Three registers of the same type (`size` bits 23:22 select the element width).
        A64InstrDesc(id: .simdAdd,   mnemonic: "add",   format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_8400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSub,   mnemonic: "sub",   format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_8400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdMul,   mnemonic: "mul",   format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_9C00, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdMla,   mnemonic: "mla",   format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_9400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdMls,   mnemonic: "mls",   format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_9400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdCmeq,  mnemonic: "cmeq",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_8C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmtst, mnemonic: "cmtst", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_8C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmgt,  mnemonic: "cmgt",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_3400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmge,  mnemonic: "cmge",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_3C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmhi,  mnemonic: "cmhi",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_3400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmhs,  mnemonic: "cmhs",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_3C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSmax,  mnemonic: "smax",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_6400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdSmin,  mnemonic: "smin",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_6C00, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdUmax,  mnemonic: "umax",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_6400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdUmin,  mnemonic: "umin",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_6C00, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdSabd,  mnemonic: "sabd",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_7400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdUabd,  mnemonic: "uabd",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_7400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdAddp,  mnemonic: "addp",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_BC00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSqadd, mnemonic: "sqadd", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_0C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUqadd, mnemonic: "uqadd", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_0C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSqsub, mnemonic: "sqsub", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_2C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUqsub, mnemonic: "uqsub", format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_2C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSshl,  mnemonic: "sshl",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E20_4400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUshl,  mnemonic: "ushl",  format: .simdThreeSameInt, opcodeMask: 0xBF20_FC00, opcodeBits: 0x2E20_4400, arrangements: A64Variants.bhsd2),

        A64InstrDesc(id: .simdAnd, mnemonic: "and", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E20_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdBic, mnemonic: "bic", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E60_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdOrr, mnemonic: "orr", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0EA0_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdOrn, mnemonic: "orn", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0EE0_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdEor, mnemonic: "eor", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x2E20_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdBsl, mnemonic: "bsl", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x2E60_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdBit, mnemonic: "bit", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x2EA0_1C00, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdBif, mnemonic: "bif", format: .simdThreeSameBit, opcodeMask: 0xBFE0_FC00, opcodeBits: 0x2EE0_1C00, arrangements: A64Variants.bytes),

        A64InstrDesc(id: .simdFmaxnm, mnemonic: "fmaxnm", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_C400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFmla,   mnemonic: "fmla",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_CC00, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFadd,   mnemonic: "fadd",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_D400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFcmeq,  mnemonic: "fcmeq",  format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_E400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFmax,   mnemonic: "fmax",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0E20_F400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFminnm, mnemonic: "fminnm", format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0EA0_C400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFmls,   mnemonic: "fmls",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0EA0_CC00, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFsub,   mnemonic: "fsub",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0EA0_D400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFmin,   mnemonic: "fmin",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x0EA0_F400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFaddp,  mnemonic: "faddp",  format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_D400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFmul,   mnemonic: "fmul",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_DC00, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFcmge,  mnemonic: "fcmge",  format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_E400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFdiv,   mnemonic: "fdiv",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2E20_FC00, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFabd,   mnemonic: "fabd",   format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2EA0_D400, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFcmgt,  mnemonic: "fcmgt",  format: .simdThreeSameFp, opcodeMask: 0xBFA0_FC00, opcodeBits: 0x2EA0_E400, arrangements: A64Variants.fp),

        A64InstrDesc(id: .simdUzp1, mnemonic: "uzp1", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_1800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdTrn1, mnemonic: "trn1", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_2800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdZip1, mnemonic: "zip1", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_3800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUzp2, mnemonic: "uzp2", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_5800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdTrn2, mnemonic: "trn2", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_6800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdZip2, mnemonic: "zip2", format: .simdPermute, opcodeMask: 0xBF20_FC00, opcodeBits: 0x0E00_7800, arrangements: A64Variants.bhsd2),

        // Two-register miscellaneous. `not` and `rbit` fix `size` (00 / 01), so their masks include it.
        A64InstrDesc(id: .simdRev64, mnemonic: "rev64", format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_0800, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdRev16, mnemonic: "rev16", format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_1800, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdRev32, mnemonic: "rev32", format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E20_0800, arrangements: A64Variants.bh),
        A64InstrDesc(id: .simdCls,   mnemonic: "cls",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_4800, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdClz,   mnemonic: "clz",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E20_4800, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdCnt,   mnemonic: "cnt",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_5800, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdNot,   mnemonic: "not",   format: .simdTwoRegMisc, opcodeMask: 0xBFFF_FC00, opcodeBits: 0x2E20_5800, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdRbit,  mnemonic: "rbit",  format: .simdTwoRegMisc, opcodeMask: 0xBFFF_FC00, opcodeBits: 0x2E60_5800, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdAbs,   mnemonic: "abs",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_B800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdNeg,   mnemonic: "neg",   format: .simdTwoRegMisc, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E20_B800, arrangements: A64Variants.bhsd2),

        A64InstrDesc(id: .simdCmgtZero, mnemonic: "cmgt", format: .simdCmpZero, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_8800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmeqZero, mnemonic: "cmeq", format: .simdCmpZero, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_9800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmltZero, mnemonic: "cmlt", format: .simdCmpZero, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E20_A800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmgeZero, mnemonic: "cmge", format: .simdCmpZero, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E20_8800, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdCmleZero, mnemonic: "cmle", format: .simdCmpZero, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E20_9800, arrangements: A64Variants.bhsd2),

        A64InstrDesc(id: .simdFabs,   mnemonic: "fabs",   format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0EA0_F800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFneg,   mnemonic: "fneg",   format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2EA0_F800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFsqrt,  mnemonic: "fsqrt",  format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2EA1_F800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdScvtf,  mnemonic: "scvtf",  format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0E21_D800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdUcvtf,  mnemonic: "ucvtf",  format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2E21_D800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFcvtzs, mnemonic: "fcvtzs", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0EA1_B800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFcvtzu, mnemonic: "fcvtzu", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2EA1_B800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrintn, mnemonic: "frintn", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0E21_8800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrintm, mnemonic: "frintm", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0E21_9800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrintp, mnemonic: "frintp", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0EA1_8800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrintz, mnemonic: "frintz", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x0EA1_9800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrinta, mnemonic: "frinta", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2E21_8800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrintx, mnemonic: "frintx", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2E21_9800, arrangements: A64Variants.fp),
        A64InstrDesc(id: .simdFrinti, mnemonic: "frinti", format: .simdTwoRegMiscFp, opcodeMask: 0xBFBF_FC00, opcodeBits: 0x2EA1_9800, arrangements: A64Variants.fp),

        A64InstrDesc(id: .simdAddv,  mnemonic: "addv",  format: .simdAcrossLanes, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E31_B800, arrangements: A64Variants.acrossLanes),
        A64InstrDesc(id: .simdSmaxv, mnemonic: "smaxv", format: .simdAcrossLanes, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E30_A800, arrangements: A64Variants.acrossLanes),
        A64InstrDesc(id: .simdSminv, mnemonic: "sminv", format: .simdAcrossLanes, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E31_A800, arrangements: A64Variants.acrossLanes),
        A64InstrDesc(id: .simdUmaxv, mnemonic: "umaxv", format: .simdAcrossLanes, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E30_A800, arrangements: A64Variants.acrossLanes),
        A64InstrDesc(id: .simdUminv, mnemonic: "uminv", format: .simdAcrossLanes, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x2E31_A800, arrangements: A64Variants.acrossLanes),

        // `xtn`/`shrn` arrangements are the narrow destination; `sshll`/`ushll` the narrow source.
        A64InstrDesc(id: .simdXtn, mnemonic: "xtn", format: .simdNarrow, opcodeMask: 0xBF3F_FC00, opcodeBits: 0x0E21_2800, arrangements: A64Variants.bhs),

        // Shift by immediate (`immh:immb`, bits 22:16; `immh` = 0 is the modified-immediate class).
        A64InstrDesc(id: .simdSshr,  mnemonic: "sshr",  format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUshr,  mnemonic: "ushr",  format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_0400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSsra,  mnemonic: "ssra",  format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_1400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdUsra,  mnemonic: "usra",  format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_1400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSri,   mnemonic: "sri",   format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_4400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdShl,   mnemonic: "shl",   format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_5400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSli,   mnemonic: "sli",   format: .simdShiftImm,    opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_5400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdShrn,  mnemonic: "shrn",  format: .simdShiftNarrow, opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_8400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdSshll, mnemonic: "sshll", format: .simdShiftLong,   opcodeMask: 0xBF80_FC00, opcodeBits: 0x0F00_A400, arrangements: A64Variants.bhs),
        A64InstrDesc(id: .simdUshll, mnemonic: "ushll", format: .simdShiftLong,   opcodeMask: 0xBF80_FC00, opcodeBits: 0x2F00_A400, arrangements: A64Variants.bhs),

        // Copy (`imm5` bits 20:16 encode the element size and lane).
        A64InstrDesc(id: .simdDupElem,   mnemonic: "dup",  format: .simdDupElem,   opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_0400, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdDupGpr,    mnemonic: "dup",  format: .simdDupGpr,    opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_0C00, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdDupScalar, mnemonic: "mov",  format: .simdDupScalar, opcodeMask: 0xFFE0_FC00, opcodeBits: 0x5E00_0400, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdInsGpr,    mnemonic: "mov",  format: .simdInsGpr,    opcodeMask: 0xFFE0_FC00, opcodeBits: 0x4E00_1C00, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdInsElem,   mnemonic: "mov",  format: .simdInsElem,   opcodeMask: 0xFFE0_8400, opcodeBits: 0x6E00_0400, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdUmov,      mnemonic: "umov", format: .simdUmovSmov,  opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_3C00, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdSmov,      mnemonic: "smov", format: .simdUmovSmov,  opcodeMask: 0xBFE0_FC00, opcodeBits: 0x0E00_2C00, widths: A64Variants.b | A64Variants.h | A64Variants.s),

        // Modified immediate: one mask for the class; `op:cmode` (bits 29, 15:12) select the descriptor.
        A64InstrDesc(id: .simdMovi,    mnemonic: "movi", format: .simdModImm, opcodeMask: 0x9FF8_0C00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdMvni,    mnemonic: "mvni", format: .simdModImm, opcodeMask: 0x9FF8_0C00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.h4 | A64Variants.h8 | A64Variants.s2 | A64Variants.s4),
        A64InstrDesc(id: .simdOrrImm,  mnemonic: "orr",  format: .simdModImm, opcodeMask: 0x9FF8_0C00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.h4 | A64Variants.h8 | A64Variants.s2 | A64Variants.s4),
        A64InstrDesc(id: .simdBicImm,  mnemonic: "bic",  format: .simdModImm, opcodeMask: 0x9FF8_0C00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.h4 | A64Variants.h8 | A64Variants.s2 | A64Variants.s4),
        A64InstrDesc(id: .simdFmovImm, mnemonic: "fmov", format: .simdModImm, opcodeMask: 0x9FF8_0C00, opcodeBits: 0x0F00_0400, arrangements: A64Variants.fp),

        // Structure loads/stores. `ld1`/`st1` take 1-4 registers (the opcode encodes the count).
        A64InstrDesc(id: .simdLd1, mnemonic: "ld1", format: .simdLdStMulti, opcodeMask: 0xBFFF_0000, opcodeBits: 0x0C40_0000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdSt1, mnemonic: "st1", format: .simdLdStMulti, opcodeMask: 0xBFFF_0000, opcodeBits: 0x0C00_0000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdLd2, mnemonic: "ld2", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C40_8000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt2, mnemonic: "st2", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C00_8000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd3, mnemonic: "ld3", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C40_4000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt3, mnemonic: "st3", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C00_4000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd4, mnemonic: "ld4", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C40_0000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt4, mnemonic: "st4", format: .simdLdStMulti, opcodeMask: 0xBFFF_F000, opcodeBits: 0x0C00_0000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd1Post, mnemonic: "ld1", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_0000, opcodeBits: 0x0CC0_0000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdSt1Post, mnemonic: "st1", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_0000, opcodeBits: 0x0C80_0000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdLd2Post, mnemonic: "ld2", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0CC0_8000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt2Post, mnemonic: "st2", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0C80_8000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd3Post, mnemonic: "ld3", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0CC0_4000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt3Post, mnemonic: "st3", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0C80_4000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd4Post, mnemonic: "ld4", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0CC0_0000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdSt4Post, mnemonic: "st4", format: .simdLdStMultiPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0C80_0000, arrangements: A64Variants.bhsd2),
        A64InstrDesc(id: .simdLd1R,     mnemonic: "ld1r", format: .simdLd1R,     opcodeMask: 0xBFFF_F000, opcodeBits: 0x0D40_C000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdLd1RPost, mnemonic: "ld1r", format: .simdLd1RPost, opcodeMask: 0xBFE0_F000, opcodeBits: 0x0DC0_C000, arrangements: A64Variants.allArr),
        A64InstrDesc(id: .simdLd1Lane,     mnemonic: "ld1", format: .simdLdStLane,     opcodeMask: 0xBFFF_2000, opcodeBits: 0x0D40_0000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdSt1Lane,     mnemonic: "st1", format: .simdLdStLane,     opcodeMask: 0xBFFF_2000, opcodeBits: 0x0D00_0000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdLd1LanePost, mnemonic: "ld1", format: .simdLdStLanePost, opcodeMask: 0xBFE0_2000, opcodeBits: 0x0DC0_0000, widths: A64Variants.bhsd),
        A64InstrDesc(id: .simdSt1LanePost, mnemonic: "st1", format: .simdLdStLanePost, opcodeMask: 0xBFE0_2000, opcodeBits: 0x0D80_0000, widths: A64Variants.bhsd),

        A64InstrDesc(id: .simdTbl, mnemonic: "tbl", format: .simdTbl, opcodeMask: 0xBFE0_9C00, opcodeBits: 0x0E00_0000, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdTbx, mnemonic: "tbx", format: .simdTbl, opcodeMask: 0xBFE0_9C00, opcodeBits: 0x0E00_1000, arrangements: A64Variants.bytes),
        A64InstrDesc(id: .simdExt, mnemonic: "ext", format: .simdExt, opcodeMask: 0xBFE0_8400, opcodeBits: 0x2E00_0000, arrangements: A64Variants.bytes),

        // --- 7. SVE (VectraOS `kernel/arch/arm64/cpu.S`) ---
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
    /// True if a byte displacement is word-aligned and fits a signed `bits`-wide word-offset field.
    @inline(__always)
    static func pcRelInRange(_ byteDisp: Int64, bits: Int) -> Bool {
        let limit = Int64(1) << (bits + 1)
        return (byteDisp & 3) == 0 && byteDisp >= -limit && byteDisp < limit
    }

    /// Bit 30 (`size<0>`) for a GPR load/store whose register width is a variable field of `desc`
    /// (`ldr`, `str`, `ldxr`, ...); zero when the descriptor fixes the size (`ldrb`, `ldrsw`, ...).
    @inline(__always)
    static func variableSizeBit30(_ desc: A64InstrDesc, is64Bit: Bool) -> UInt32 {
        (desc.opcodeMask & (1 << 30)) == 0 && is64Bit ? (1 << 30) : 0
    }

    /// `imm5` (bits 20:16) of the Advanced SIMD copy class: the element size marker plus the lane index.
    @inline(__always)
    static func copyImm5(_ width: A64ScalarWidth, index: UInt8) -> UInt32? {
        guard width != .q else { return nil }
        let log2 = UInt32(width.rawValue)
        guard Int(index) < (16 >> log2) else { return nil }
        return (UInt32(index) << (log2 + 1)) | (1 << log2)
    }

    /// `size` (bits 31:30) and `opc<1>` (bit 23) of a SIMD/FP load/store for register width `w`.
    @inline(__always)
    static func fpLdstSizeBits(_ w: A64ScalarWidth) -> UInt32 {
        w == .q ? (1 << 23) : (UInt32(w.rawValue) << 30)
    }

    /// `opc` (bits 31:30) of a SIMD/FP literal load or register pair: `s`=00, `d`=01, `q`=10.
    @inline(__always)
    static func fpPairOpc(_ w: A64ScalarWidth) -> UInt32? {
        switch w {
        case .s: return 0
        case .d: return 1
        case .q: return 2
        default: return nil
        }
    }

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
        let va = UInt32(instr.va.rawValue)

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
            if instr.shiftKind == .ror || instr.shiftKind == .msl { return nil }
            guard instr.amount < (instr.is64Bit ? 64 : 32) else { return nil }
            let shift = UInt32(instr.shiftKind.rawValue) & 0x3
            let amt = UInt32(instr.amount) & 0x3F
            return sf | desc.opcodeBits | (shift << 22) | (rm << 16) | (amt << 10) | (rn << 5) | rd

        case .addSubExtended:
            guard instr.amount <= 4 else { return nil }
            let opt = UInt32(instr.extendKind.rawValue) & 0x7
            let imm3 = UInt32(instr.amount) & 0x7
            return sf | desc.opcodeBits | (rm << 16) | (opt << 13) | (imm3 << 10) | (rn << 5) | rd

        case .logicalShifted:
            guard instr.shiftKind != .msl, instr.amount < (instr.is64Bit ? 64 : 32) else { return nil }
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
            guard pcRelInRange(instr.imm, bits: 26) else { return nil }
            let words = instr.imm >> 2
            let imm26 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x03FF_FFFF
            return desc.opcodeBits | imm26

        case .branchCond19:
            guard pcRelInRange(instr.imm, bits: 19) else { return nil }
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            let c = UInt32(instr.cond.rawValue) & 0xF
            return desc.opcodeBits | (imm19 << 5) | c

        case .compareBranch19:
            guard pcRelInRange(instr.imm, bits: 19) else { return nil }
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            return sf | desc.opcodeBits | (imm19 << 5) | rd

        case .testBranch14:
            let bit = UInt32(instr.amount) & 0x3F
            let b5 = (bit >> 5) & 1
            let b40 = bit & 0x1F
            guard pcRelInRange(instr.imm, bits: 14) else { return nil }
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
            let sizeBit30 = variableSizeBit30(desc, is64Bit: instr.is64Bit)
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
            // `option<1>` must be set: only `uxtw`, `lsl`/`uxtx`, `sxtw`, `sxtx` index registers exist.
            guard instr.extendKind.rawValue & 0b010 != 0 else { return nil }
            guard instr.amount == 0 || instr.amount == naturalShift else { return nil }
            let opt = UInt32(instr.extendKind.rawValue) & 0x7
            // Byte accesses have no shift, so `S` (an explicit `#0`) is carried in `imm2`.
            let sBit: UInt32 = (naturalShift == 0 ? instr.imm2 != 0 : instr.amount == naturalShift) ? (1 << 12) : 0
            return desc.opcodeBits | sizeBit30 | (rm << 16) | (opt << 13) | sBit | (rn << 5) | rd

        case .ldrLiteral:
            guard pcRelInRange(instr.imm, bits: 19) else { return nil }
            let sizeBit30 = variableSizeBit30(desc, is64Bit: instr.is64Bit)
            let words = instr.imm >> 2
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: words)) & 0x7_FFFF
            return desc.opcodeBits | sizeBit30 | (imm19 << 5) | rd

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            let shift: Int64 = instr.is64Bit ? 3 : 2
            let scaled = instr.imm >> shift
            guard (scaled << shift) == instr.imm && scaled >= -64 && scaled <= 63 else { return nil }
            let imm7 = UInt32(bitPattern: Int32(truncatingIfNeeded: scaled)) & 0x7F
            let sfBit: UInt32 = instr.is64Bit ? (1 << 31) : 0
            return sfBit | desc.opcodeBits | (imm7 << 15) | (rm << 10) | (rn << 5) | rd

        case .atomicLoad, .atomicStore:
            return desc.opcodeBits | variableSizeBit30(desc, is64Bit: instr.is64Bit) | (rn << 5) | rd

        case .atomicStoreExcl:
            // `rm` holds the status register `Ws`, `rd` holds the data register `Rt`, `rn` holds `[Xn]`
            return desc.opcodeBits | variableSizeBit30(desc, is64Bit: instr.is64Bit) | (rm << 16) | (rn << 5) | rd

        case .atomicLoadPair:
            // `ra` holds `Rt2` (bits 14:10).
            return desc.opcodeBits | variableSizeBit30(desc, is64Bit: instr.is64Bit) | (ra << 10) | (rn << 5) | rd

        case .atomicStoreExclPair:
            return desc.opcodeBits | variableSizeBit30(desc, is64Bit: instr.is64Bit) | (rm << 16) | (ra << 10) | (rn << 5) | rd

        case .lseAtomic:
            guard desc.allows(instr.scalarWidth) else { return nil }
            let size = UInt32(instr.scalarWidth.rawValue) << 30
            let a: UInt32 = instr.acquire ? (1 << 23) : 0
            let r: UInt32 = instr.release ? (1 << 22) : 0
            return size | desc.opcodeBits | a | r | (rm << 16) | (rn << 5) | rd

        case .lseCas:
            guard desc.allows(instr.scalarWidth) else { return nil }
            let size = UInt32(instr.scalarWidth.rawValue) << 30
            let l: UInt32 = instr.acquire ? (1 << 22) : 0
            let o0: UInt32 = instr.release ? (1 << 15) : 0
            return size | desc.opcodeBits | l | (rm << 16) | o0 | (rn << 5) | rd

        case .lseCasp:
            // `Rs`/`Rt` name the first register of an even-numbered consecutive pair.
            guard rm & 1 == 0, rd & 1 == 0 else { return nil }
            let l: UInt32 = instr.acquire ? (1 << 22) : 0
            let o0: UInt32 = instr.release ? (1 << 15) : 0
            return (instr.is64Bit ? 1 << 30 : 0) | desc.opcodeBits | l | (rm << 16) | o0 | (rn << 5) | rd

        case .fpLdstPreImm9, .fpLdstPostImm9, .fpLdstUnscaledImm9:
            guard desc.allows(instr.scalarWidth), instr.imm >= -256 && instr.imm <= 255 else { return nil }
            let imm9 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm)) & 0x1FF
            return fpLdstSizeBits(instr.scalarWidth) | desc.opcodeBits | (imm9 << 12) | (rn << 5) | vd

        case .fpLdstRegOffset:
            guard desc.allows(instr.scalarWidth), instr.extendKind.rawValue & 0b010 != 0 else { return nil }
            let naturalShift = instr.scalarWidth.rawValue
            guard instr.amount == 0 || instr.amount == naturalShift else { return nil }
            let opt = UInt32(instr.extendKind.rawValue) & 0x7
            let sBit: UInt32 = (naturalShift == 0 ? instr.imm2 != 0 : instr.amount == naturalShift) ? (1 << 12) : 0
            return fpLdstSizeBits(instr.scalarWidth) | desc.opcodeBits | (rm << 16) | (opt << 13) | sBit | (rn << 5) | vd

        case .fpLdrLiteral:
            guard desc.allows(instr.scalarWidth), let opc = fpPairOpc(instr.scalarWidth), pcRelInRange(instr.imm, bits: 19) else { return nil }
            let imm19 = UInt32(bitPattern: Int32(truncatingIfNeeded: instr.imm >> 2)) & 0x7_FFFF
            return (opc << 30) | desc.opcodeBits | (imm19 << 5) | vd

        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            // `vn` holds `Rt2` (bits 14:10).
            guard desc.allows(instr.scalarWidth), let opc = fpPairOpc(instr.scalarWidth) else { return nil }
            let shift = Int64(instr.scalarWidth.rawValue)
            let scaled = instr.imm >> shift
            guard (scaled << shift) == instr.imm && scaled >= -64 && scaled <= 63 else { return nil }
            let imm7 = UInt32(bitPattern: Int32(truncatingIfNeeded: scaled)) & 0x7F
            return (opc << 30) | desc.opcodeBits | (imm7 << 15) | (vn << 10) | (rn << 5) | vd

        case .fpMovGprToFp, .fpMovFpToGpr:
            // `fmov` general: (32-bit, s), (64-bit, d), and either GPR width with `h`.
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            guard instr.scalarWidth == .h || instr.is64Bit == (instr.scalarWidth == .d) else { return nil }
            let regs = desc.format == .fpMovGprToFp ? (rn << 5) | vd : (vn << 5) | rd
            return sf | desc.opcodeBits | (ft << 22) | regs

        case .fpDp1:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return desc.opcodeBits | (ft << 22) | (vn << 5) | vd

        case .fpCvtPrecision:
            // `scalarWidth` is the destination, `scalarWidth2` the source.
            guard desc.allows(instr.scalarWidth), desc.allows(instr.scalarWidth2), instr.scalarWidth != instr.scalarWidth2,
                  let dst = instr.scalarWidth.ftype, let src = instr.scalarWidth2.ftype else { return nil }
            return desc.opcodeBits | (src << 22) | (dst << 15) | (vn << 5) | vd

        case .fpIntToFp:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return sf | desc.opcodeBits | (ft << 22) | (rn << 5) | vd

        case .fpToInt:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return sf | desc.opcodeBits | (ft << 22) | (vn << 5) | rd

        case .fpFixedToFp, .fpToFixed:
            // `imm` is the number of fraction bits; the field holds `64 - fbits`.
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype,
                  instr.imm >= 1 && instr.imm <= (instr.is64Bit ? 64 : 32) else { return nil }
            let scale = UInt32(64 - instr.imm)
            let regs = desc.format == .fpFixedToFp ? (rn << 5) | vd : (vn << 5) | rd
            return sf | desc.opcodeBits | (ft << 22) | (scale << 10) | regs

        case .fpBinary:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return desc.opcodeBits | (ft << 22) | (vm << 16) | (vn << 5) | vd

        case .fpDp3:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return desc.opcodeBits | (ft << 22) | (vm << 16) | (va << 10) | (vn << 5) | vd

        case .fpCmpReg:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return desc.opcodeBits | (ft << 22) | (vm << 16) | (vn << 5)

        case .fpCmpZero:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            return desc.opcodeBits | (ft << 22) | (vn << 5)

        case .fpCondCompare:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            let c = UInt32(instr.cond.rawValue) & 0xF
            return desc.opcodeBits | (ft << 22) | (vm << 16) | (c << 12) | (vn << 5) | (UInt32(instr.imm2) & 0xF)

        case .fpCondSelect:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype else { return nil }
            let c = UInt32(instr.cond.rawValue) & 0xF
            return desc.opcodeBits | (ft << 22) | (vm << 16) | (c << 12) | (vn << 5) | vd

        case .fpImm:
            guard desc.allows(instr.scalarWidth), let ft = instr.scalarWidth.ftype, instr.imm >= 0 && instr.imm <= 0xFF else { return nil }
            return desc.opcodeBits | (ft << 22) | (UInt32(instr.imm) << 13) | vd

        case .simdThreeSameInt, .simdPermute:
            guard desc.allows(instr.arrangement) else { return nil }
            let q = instr.arrangement.qBit << 30
            let size = instr.arrangement.sizeBits << 22
            return q | size | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdThreeSameBit, .simdTbl:
            guard desc.allows(instr.arrangement) else { return nil }
            let q = instr.arrangement.qBit << 30
            if desc.format == .simdTbl {
                // `imm2` is the table register count (1-4); `vn` the first table register.
                guard instr.imm2 >= 1 && instr.imm2 <= 4 else { return nil }
                return q | desc.opcodeBits | (vm << 16) | (UInt32(instr.imm2 - 1) << 13) | (vn << 5) | vd
            }
            return q | desc.opcodeBits | (vm << 16) | (vn << 5) | vd

        case .simdThreeSameFp, .simdTwoRegMiscFp:
            guard desc.allows(instr.arrangement) else { return nil }
            let q = instr.arrangement.qBit << 30
            let sz: UInt32 = (instr.arrangement == .d2) ? (1 << 22) : 0
            let regs = desc.format == .simdThreeSameFp ? (vm << 16) | (vn << 5) | vd : (vn << 5) | vd
            return q | sz | desc.opcodeBits | regs

        case .simdTwoRegMisc, .simdCmpZero, .simdAcrossLanes, .simdNarrow:
            // `simdNarrow` takes the destination arrangement; its `size` is the narrow element size.
            guard desc.allows(instr.arrangement) else { return nil }
            let q = instr.arrangement.qBit << 30
            let size = instr.arrangement.sizeBits << 22
            return q | size | desc.opcodeBits | (vn << 5) | vd

        case .simdShiftImm, .simdShiftLong, .simdShiftNarrow:
            // `simdShiftLong` takes the source arrangement, `simdShiftNarrow` the destination one.
            guard desc.allows(instr.arrangement) else { return nil }
            let q = instr.arrangement.qBit << 30
            let esize = UInt32(8 << instr.arrangement.elementWidth.rawValue)
            let shift = UInt32(instr.amount)
            let immhImmb: UInt32
            switch desc.id {
            case .simdShl, .simdSli, .simdSshll, .simdUshll:
                guard shift < esize else { return nil }
                immhImmb = esize + shift
            default:
                guard shift >= 1 && shift <= esize else { return nil }
                immhImmb = (2 * esize) - shift
            }
            return q | desc.opcodeBits | ((immhImmb & 0x7F) << 16) | (vn << 5) | vd

        case .simdDupElem:
            guard desc.allows(instr.arrangement), let imm5 = copyImm5(instr.arrangement.elementWidth, index: instr.index) else { return nil }
            return instr.arrangement.qBit << 30 | desc.opcodeBits | (imm5 << 16) | (vn << 5) | vd

        case .simdDupGpr:
            guard desc.allows(instr.arrangement), let imm5 = copyImm5(instr.arrangement.elementWidth, index: 0) else { return nil }
            return instr.arrangement.qBit << 30 | desc.opcodeBits | (imm5 << 16) | (rn << 5) | vd

        case .simdDupScalar:
            guard desc.allows(instr.scalarWidth), let imm5 = copyImm5(instr.scalarWidth, index: instr.index) else { return nil }
            return desc.opcodeBits | (imm5 << 16) | (vn << 5) | vd

        case .simdInsGpr:
            guard desc.allows(instr.scalarWidth), let imm5 = copyImm5(instr.scalarWidth, index: instr.index) else { return nil }
            return desc.opcodeBits | (imm5 << 16) | (rn << 5) | vd

        case .simdInsElem:
            // `index` is the destination lane, `imm2` the source lane.
            guard desc.allows(instr.scalarWidth), let imm5 = copyImm5(instr.scalarWidth, index: instr.index),
                  copyImm5(instr.scalarWidth, index: instr.imm2) != nil else { return nil }
            let imm4 = UInt32(instr.imm2) << UInt32(instr.scalarWidth.rawValue)
            return desc.opcodeBits | (imm5 << 16) | (imm4 << 11) | (vn << 5) | vd

        case .simdUmovSmov:
            // `umov`: W from b/h/s, X from d. `smov`: W from b/h, X from b/h/s. `Q` is the destination width.
            guard desc.allows(instr.scalarWidth), let imm5 = copyImm5(instr.scalarWidth, index: instr.index) else { return nil }
            let valid = desc.id == .simdUmov ? instr.is64Bit == (instr.scalarWidth == .d) : (instr.is64Bit || instr.scalarWidth != .s)
            guard valid else { return nil }
            return (instr.is64Bit ? 1 << 30 : 0) | desc.opcodeBits | (imm5 << 16) | (vn << 5) | rd

        case .simdModImm:
            guard let (op, cmode, imm8) = simdModImmFields(instr, desc) else { return nil }
            return instr.arrangement.qBit << 30 | (op << 29) | desc.opcodeBits | ((imm8 >> 5) << 16) | (cmode << 12) | ((imm8 & 0x1F) << 5) | vd

        case .simdLdStMulti, .simdLdStMultiPost:
            // `imm2` is the register count; `ld1`/`st1` encode it in the opcode, `ldN`/`stN` fix it at N.
            guard desc.allows(instr.arrangement) else { return nil }
            let count = Int(instr.imm2)
            var opcode: UInt32 = 0
            switch desc.id {
            case .simdLd1, .simdSt1, .simdLd1Post, .simdSt1Post:
                let opcodes: [UInt32] = [0b0111, 0b1010, 0b0110, 0b0010]
                guard count >= 1 && count <= 4 else { return nil }
                opcode = opcodes[count - 1] << 12
            case .simdLd2, .simdSt2, .simdLd2Post, .simdSt2Post: guard count == 2 else { return nil }
            case .simdLd3, .simdSt3, .simdLd3Post, .simdSt3Post: guard count == 3 else { return nil }
            default: guard count == 4 else { return nil }
            }
            let q = instr.arrangement.qBit
            let base = q << 30 | desc.opcodeBits | opcode | (instr.arrangement.sizeBits << 10) | (rn << 5) | vd
            guard desc.format == .simdLdStMultiPost else { return base }
            guard let m = postIndexRm(instr, bytes: Int64(count) * (q == 1 ? 16 : 8)) else { return nil }
            return base | (m << 16)

        case .simdLd1R, .simdLd1RPost:
            guard desc.allows(instr.arrangement) else { return nil }
            let base = instr.arrangement.qBit << 30 | desc.opcodeBits | (instr.arrangement.sizeBits << 10) | (rn << 5) | vd
            guard desc.format == .simdLd1RPost else { return base }
            guard let m = postIndexRm(instr, bytes: Int64(instr.arrangement.elementWidth.byteCount)) else { return nil }
            return base | (m << 16)

        case .simdLdStLane, .simdLdStLanePost:
            guard desc.allows(instr.scalarWidth), copyImm5(instr.scalarWidth, index: instr.index) != nil else { return nil }
            let idx = UInt32(instr.index)
            let opcode: UInt32, s: UInt32, size: UInt32, q: UInt32
            switch instr.scalarWidth {
            case .b: (opcode, q, s, size) = (0b000, idx >> 3, (idx >> 2) & 1, idx & 3)
            case .h: (opcode, q, s, size) = (0b010, idx >> 2, (idx >> 1) & 1, (idx & 1) << 1)
            case .s: (opcode, q, s, size) = (0b100, idx >> 1, idx & 1, 0b00)
            default: (opcode, q, s, size) = (0b100, idx, 0, 0b01)
            }
            let base = q << 30 | desc.opcodeBits | (opcode << 13) | (s << 12) | (size << 10) | (rn << 5) | vd
            guard desc.format == .simdLdStLanePost else { return base }
            guard let m = postIndexRm(instr, bytes: Int64(instr.scalarWidth.byteCount)) else { return nil }
            return base | (m << 16)

        case .simdExt:
            guard desc.allows(instr.arrangement), instr.amount < (instr.arrangement.qBit == 1 ? 16 : 8) else { return nil }
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

    /// The `Rm` field of a post-indexed structure load/store: `rm` for a register offset, or 31 (the
    /// immediate form) when `rm` is 31 and `imm` equals the bytes transferred, the only legal immediate.
    static func postIndexRm(_ instr: A64Instruction, bytes: Int64) -> UInt32? {
        if instr.rm.rawValue != 31 { return UInt32(instr.rm.rawValue) }
        return instr.imm == bytes ? 31 : nil
    }

    /// `(op, cmode, abcdefgh)` of an Advanced SIMD modified immediate. `imm` is the 8-bit immediate, except
    /// for the 64-bit `movi` byte mask (the expanded value) and `fmov` (the FP8 encoding).
    static func simdModImmFields(_ instr: A64Instruction, _ desc: A64InstrDesc) -> (op: UInt32, cmode: UInt32, imm8: UInt32)? {
        let arr = instr.arrangement
        guard desc.allows(arr) else { return nil }
        let imm8: UInt32? = (0...255).contains(instr.imm) ? UInt32(instr.imm) : nil
        let amount = UInt32(instr.amount)
        switch desc.id {
        case .simdFmovImm:
            guard let imm8 else { return nil }
            return (arr == .d2 ? 1 : 0, 0b1111, imm8)
        case .simdMovi where arr.elementWidth == .d:
            guard amount == 0, let mask = A64SIMDByteMask.encode(UInt64(bitPattern: instr.imm)) else { return nil }
            return (1, 0b1110, UInt32(mask))
        case .simdMovi where arr.elementWidth == .b:
            guard amount == 0, instr.shiftKind == .lsl, let imm8 else { return nil }
            return (0, 0b1110, imm8)
        default:
            break
        }
        guard let imm8 else { return nil }
        let op: UInt32 = (desc.id == .simdMvni || desc.id == .simdBicImm) ? 1 : 0
        let orrBic: UInt32 = (desc.id == .simdOrrImm || desc.id == .simdBicImm) ? 1 : 0
        switch (arr.elementWidth, instr.shiftKind) {
        case (.h, .lsl):
            guard amount == 0 || amount == 8 else { return nil }
            return (op, 0b1000 | (amount / 8) << 1 | orrBic, imm8)
        case (.s, .lsl):
            guard amount % 8 == 0 && amount <= 24 else { return nil }
            return (op, (amount / 8) << 1 | orrBic, imm8)
        case (.s, .msl):
            guard orrBic == 0, amount == 8 || amount == 16 else { return nil }
            return (op, 0b1100 | (amount == 16 ? 1 : 0), imm8)
        default:
            return nil
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

    /// Register width of a GPR load/store: bit 30 when the descriptor leaves the size variable; otherwise
    /// sign-extending loads (`opc<1>` = 1) target X when `opc<0>` = 0, and everything else targets W.
    @inline(__always)
    private static func gprLoadIs64(word: UInt32, desc: A64InstrDesc) -> Bool {
        if (desc.opcodeMask & (1 << 30)) == 0 { return (word >> 30) & 1 != 0 }
        return (word >> 23) & 1 != 0 && (word >> 22) & 1 == 0
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
            let opt = A64BarrierOption(rawValue: crm)
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
            let is64Reg = gprLoadIs64(word: word, desc: desc)
            let shift: UInt8 = desc.scaleLog2 == 255 ? (is64Reg ? 3 : 2) : desc.scaleLog2
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn, imm: imm12 << Int64(shift))

        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            let raw9 = (word >> 12) & 0x1FF
            let simm9 = signExtend(raw9, bits: 9)
            return A64Instruction(opcode: desc.id, is64Bit: gprLoadIs64(word: word, desc: desc), rd: rd, rn: rn, imm: simm9)

        case .ldstRegOffset:
            let optRaw = UInt8((word >> 13) & 0x7)
            guard optRaw & 0b010 != 0, let ext = A64ExtendKind(rawValue: optRaw) else { return nil }
            let sBit = ((word >> 12) & 1) != 0
            let is64Reg = gprLoadIs64(word: word, desc: desc)
            let naturalShift: UInt8 = desc.scaleLog2 == 255 ? (is64Reg ? 3 : 2) : desc.scaleLog2
            return A64Instruction(
                opcode: desc.id,
                is64Bit: is64Reg,
                rd: rd,
                rn: rn,
                rm: rm,
                extendKind: ext,
                amount: sBit ? naturalShift : 0,
                imm2: sBit && naturalShift == 0 ? 1 : 0
            )

        case .ldrLiteral:
            let raw19 = (word >> 5) & 0x7_FFFF
            let offset = signExtend(raw19, bits: 19) << 2
            let is64Reg = desc.id == .ldrswLit || (word >> 30) & 1 != 0
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, imm: offset)

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            // `ldp`/`ldpsw` with `opc` = 11 does not exist; `opc` = 01 is `ldpsw`/`stgp` (not in the table).
            guard (word >> 30) & 1 == 0 else { return nil }
            let raw7 = (word >> 15) & 0x7F
            let simm7 = signExtend(raw7, bits: 7)
            let rt2 = A64GPR(rawValue: UInt8((word >> 10) & 0x1F))
            let shift: Int64 = is64 ? 3 : 2
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, rm: rt2, imm: simm7 << shift)

        case .atomicLoad, .atomicStore:
            // Fixed-size (`b`/`h`) exclusives and acquire/release forms always use W registers.
            let is64Reg = (desc.opcodeMask & (1 << 30)) == 0 && (word >> 30) & 1 != 0
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn)

        case .atomicStoreExcl:
            let is64Reg = (desc.opcodeMask & (1 << 30)) == 0 && (word >> 30) & 1 != 0
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn, rm: rm)

        case .atomicLoadPair:
            return A64Instruction(opcode: desc.id, is64Bit: (word >> 30) & 1 != 0, rd: rd, rn: rn, ra: ra)

        case .atomicStoreExclPair:
            return A64Instruction(opcode: desc.id, is64Bit: (word >> 30) & 1 != 0, rd: rd, rn: rn, rm: rm, ra: ra)

        case .lseAtomic:
            let size = A64ScalarWidth(rawValue: UInt8(word >> 30))!
            return A64Instruction(opcode: desc.id, is64Bit: size == .d, rd: rd, rn: rn, rm: rm, scalarWidth: size,
                                  acquire: (word >> 23) & 1 != 0, release: (word >> 22) & 1 != 0)

        case .lseCas:
            let size = A64ScalarWidth(rawValue: UInt8(word >> 30))!
            return A64Instruction(opcode: desc.id, is64Bit: size == .d, rd: rd, rn: rn, rm: rm, scalarWidth: size,
                                  acquire: (word >> 22) & 1 != 0, release: (word >> 15) & 1 != 0)

        case .lseCasp:
            guard rm.rawValue & 1 == 0, rd.rawValue & 1 == 0 else { return nil }
            let is64Reg = (word >> 30) & 1 != 0
            return A64Instruction(opcode: desc.id, is64Bit: is64Reg, rd: rd, rn: rn, rm: rm, scalarWidth: is64Reg ? .d : .s,
                                  acquire: (word >> 22) & 1 != 0, release: (word >> 15) & 1 != 0)

        case .fpLdstPreImm9, .fpLdstPostImm9, .fpLdstUnscaledImm9:
            guard let w = fpLdstWidth(word) else { return nil }
            let simm9 = signExtend((word >> 12) & 0x1FF, bits: 9)
            return A64Instruction(opcode: desc.id, rn: rn, vd: vd, scalarWidth: w, imm: simm9)

        case .fpLdstRegOffset:
            guard let w = fpLdstWidth(word) else { return nil }
            let optRaw = UInt8((word >> 13) & 0x7)
            guard optRaw & 0b010 != 0, let ext = A64ExtendKind(rawValue: optRaw) else { return nil }
            let sBit = (word >> 12) & 1 != 0
            return A64Instruction(opcode: desc.id, rn: rn, rm: rm, vd: vd, scalarWidth: w, extendKind: ext,
                                  amount: sBit ? w.rawValue : 0, imm2: sBit && w == .b ? 1 : 0)

        case .fpLdrLiteral:
            guard let w = fpPairWidth(word) else { return nil }
            let offset = signExtend((word >> 5) & 0x7_FFFF, bits: 19) << 2
            return A64Instruction(opcode: desc.id, vd: vd, scalarWidth: w, imm: offset)

        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            guard let w = fpPairWidth(word) else { return nil }
            let simm7 = signExtend((word >> 15) & 0x7F, bits: 7)
            let rt2 = A64VReg(rawValue: UInt8((word >> 10) & 0x1F))
            return A64Instruction(opcode: desc.id, rn: rn, vd: vd, vn: rt2, scalarWidth: w, imm: simm7 << Int64(w.rawValue))

        case .fpMovGprToFp, .fpMovFpToGpr:
            guard let w = A64ScalarWidth.fromFtype(word >> 22), w == .h || is64 == (w == .d) else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, vd: vd, vn: vn, scalarWidth: w)

        case .fpDp1:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: w)

        case .fpCvtPrecision:
            guard let src = A64ScalarWidth.fromFtype(word >> 22), let dst = A64ScalarWidth.fromFtype(word >> 15), src != dst else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: dst, scalarWidth2: src)

        case .fpIntToFp, .fpToInt:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, vd: vd, vn: vn, scalarWidth: w)

        case .fpFixedToFp, .fpToFixed:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            let fbits = 64 - Int64((word >> 10) & 0x3F)
            guard is64 || fbits <= 32 else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: rd, rn: rn, vd: vd, vn: vn, scalarWidth: w, imm: fbits)

        case .fpBinary, .fpCmpReg, .fpCmpZero:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, scalarWidth: w)

        case .fpDp3:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            let va = A64VReg(rawValue: UInt8((word >> 10) & 0x1F))
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, va: va, scalarWidth: w)

        case .fpCondCompare, .fpCondSelect:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            let cond = A64Cond(rawValue: UInt8((word >> 12) & 0xF))!
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, scalarWidth: w, cond: cond, imm2: UInt8(word & 0xF))

        case .fpImm:
            guard let w = A64ScalarWidth.fromFtype(word >> 22) else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, scalarWidth: w, imm: Int64((word >> 13) & 0xFF))

        case .simdThreeSameInt, .simdPermute, .simdTwoRegMisc, .simdCmpZero, .simdAcrossLanes, .simdNarrow:
            let q = (word >> 30) & 1
            // Byte-only operations with a fixed `size` field (`not`, `rbit`) take their arrangement from `Q` alone.
            let arr = desc.arrangements == A64Variants.bytes ? (q == 1 ? A64Arrangement.b16 : .b8)
                                                             : A64Arrangement.from(qBit: q, sizeBits: (word >> 22) & 0x3)
            guard desc.allows(arr) else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdThreeSameBit:
            let arr: A64Arrangement = (word >> 30) & 1 == 1 ? .b16 : .b8
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdThreeSameFp, .simdTwoRegMiscFp:
            let q = (word >> 30) & 1
            let sz = (word >> 22) & 1
            guard !(sz == 1 && q == 0) else { return nil }
            let arr: A64Arrangement = (sz == 1) ? .d2 : ((q == 1) ? .s4 : .s2)
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr)

        case .simdShiftImm, .simdShiftLong, .simdShiftNarrow:
            let immh = (word >> 19) & 0xF
            guard immh != 0 else { return nil }
            let sizeBits = UInt32(31 - immh.leadingZeroBitCount)
            let esize = UInt32(8) << sizeBits
            let arr = A64Arrangement.from(qBit: (word >> 30) & 1, sizeBits: sizeBits)
            guard desc.allows(arr) else { return nil }
            let immhImmb = (word >> 16) & 0x7F
            let shift: UInt32
            switch desc.id {
            case .simdShl, .simdSli, .simdSshll, .simdUshll: shift = immhImmb - esize
            default: shift = (2 * esize) - immhImmb
            }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, arrangement: arr, amount: UInt8(shift))

        case .simdDupElem, .simdDupGpr:
            guard let (w, idx) = copyElement(word) else { return nil }
            guard let arr = A64Arrangement.from(element: w, q: (word >> 30) & 1 != 0), desc.allows(arr) else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: w == .d, rn: rn, vd: vd, vn: vn, arrangement: arr,
                                  index: desc.format == .simdDupElem ? idx : 0)

        case .simdDupScalar, .simdInsGpr:
            guard let (w, idx) = copyElement(word) else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: w == .d, rn: rn, vd: vd, vn: vn, scalarWidth: w, index: idx)

        case .simdInsElem:
            guard let (w, idx) = copyElement(word) else { return nil }
            let imm4 = (word >> 11) & 0xF
            let lowMask: UInt32 = (1 << UInt32(w.rawValue)) - 1
            guard imm4 & lowMask == 0 else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, scalarWidth: w, index: idx, imm2: UInt8(imm4 >> UInt32(w.rawValue)))

        case .simdUmovSmov:
            guard let (w, idx) = copyElement(word) else { return nil }
            let q = (word >> 30) & 1 != 0
            let valid = desc.id == .simdUmov ? q == (w == .d) : (w != .d && (q || w != .s))
            guard valid else { return nil }
            return A64Instruction(opcode: desc.id, is64Bit: q, rd: rd, vn: vn, scalarWidth: w, index: idx)

        case .simdModImm:
            return decodeModImm(word: word, desc: desc)

        case .simdLdStMulti, .simdLdStMultiPost:
            let q = (word >> 30) & 1
            let arr = A64Arrangement.from(qBit: q, sizeBits: (word >> 10) & 0x3)
            guard desc.allows(arr) else { return nil }
            let count: UInt8
            switch desc.id {
            case .simdLd1, .simdSt1, .simdLd1Post, .simdSt1Post:
                switch (word >> 12) & 0xF {
                case 0b0111: count = 1
                case 0b1010: count = 2
                case 0b0110: count = 3
                case 0b0010: count = 4
                default: return nil
                }
            case .simdLd2, .simdSt2, .simdLd2Post, .simdSt2Post: count = 2
            case .simdLd3, .simdSt3, .simdLd3Post, .simdSt3Post: count = 3
            default: count = 4
            }
            let bytes = Int64(count) * (q == 1 ? 16 : 8)
            let isPost = desc.format == .simdLdStMultiPost
            return A64Instruction(opcode: desc.id, rn: rn, rm: isPost ? rm : .xzr, vd: vd, arrangement: arr,
                                  imm: isPost && rm.rawValue == 31 ? bytes : 0, imm2: count)

        case .simdLd1R, .simdLd1RPost:
            let arr = A64Arrangement.from(qBit: (word >> 30) & 1, sizeBits: (word >> 10) & 0x3)
            let isPost = desc.format == .simdLd1RPost
            return A64Instruction(opcode: desc.id, rn: rn, rm: isPost ? rm : .xzr, vd: vd, arrangement: arr,
                                  imm: isPost && rm.rawValue == 31 ? Int64(arr.elementWidth.byteCount) : 0)

        case .simdLdStLane, .simdLdStLanePost:
            let q = (word >> 30) & 1
            let s = (word >> 12) & 1
            let size = (word >> 10) & 3
            let w: A64ScalarWidth
            let idx: UInt32
            switch (word >> 13) & 0b111 {
            case 0b000: (w, idx) = (.b, q << 3 | s << 2 | size)
            case 0b010:
                guard size & 1 == 0 else { return nil }
                (w, idx) = (.h, q << 2 | s << 1 | size >> 1)
            case 0b100 where size == 0b00: (w, idx) = (.s, q << 1 | s)
            case 0b100 where size == 0b01 && s == 0: (w, idx) = (.d, q)
            default: return nil
            }
            let isPost = desc.format == .simdLdStLanePost
            return A64Instruction(opcode: desc.id, rn: rn, rm: isPost ? rm : .xzr, vd: vd, scalarWidth: w, index: UInt8(idx),
                                  imm: isPost && rm.rawValue == 31 ? Int64(w.byteCount) : 0)

        case .simdTbl:
            let arr: A64Arrangement = (word >> 30) & 1 == 1 ? .b16 : .b8
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: arr, imm2: UInt8((word >> 13) & 3) + 1)

        case .simdExt:
            let q = (word >> 30) & 1
            let imm4 = UInt8((word >> 11) & 0xF)
            guard q == 1 || imm4 < 8 else { return nil }
            return A64Instruction(opcode: desc.id, vd: vd, vn: vn, vm: vm, arrangement: q == 1 ? .b16 : .b8, amount: imm4)

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

    /// Formats a structured `A64Instruction` as LLVM MC prints it (`llvm-objdump`/`llvm-mc --disassemble`),
    /// including its preferred aliases (`mov`, `cmp`, `lsl`, `cset`, `stadd`, ...).
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
            if instr.opcode != .movk, let value = movAliasValue(instr) {
                return "mov \(instr.rd.format(is64Bit: is64)), #\(value)"
            }
            let shiftSuffix = (instr.amount != 0) ? ", lsl #\(instr.amount)" : ""
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), #\(instr.imm)\(shiftSuffix)"

        case .pcRel:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: true)), #\(instr.imm)"

        case .logicalImm:
            let maskVal = UInt64(bitPattern: instr.imm)
            let displayVal = is64 ? maskVal : (maskVal & 0xFFFF_FFFF)
            let hex = String(displayVal, radix: 16)
            if instr.opcode == .andsImm && instr.rd.rawValue == 31 {
                return "tst \(instr.rn.format(is64Bit: is64)), #0x\(hex)"
            }
            // `orr Rd, zr, #imm` is `mov` unless `movz`/`movn` can materialize the value (they take precedence).
            if instr.opcode == .orrImm && instr.rn.rawValue == 31 && !isMovWideValue(displayVal, is64Bit: is64) {
                let signed = is64 ? Int64(bitPattern: displayVal) : Int64(Int32(truncatingIfNeeded: displayVal))
                return "mov \(instr.rd.format(is64Bit: is64, r31IsSP: true)), #\(signed)"
            }
            let rdUseSP = (instr.opcode != .andsImm)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64, r31IsSP: rdUseSP)), \(instr.rn.format(is64Bit: is64)), #0x\(hex)"

        case .bitfield:
            let width: Int64 = is64 ? 64 : 32
            let immr = instr.imm
            let imms = Int64(instr.imm2)
            let rdStr = instr.rd.format(is64Bit: is64)
            let rnStr = instr.rn.format(is64Bit: is64)
            // Fields outside the register width have no alias (and are reserved); print the raw form.
            guard immr < width && imms < width else {
                return "\(desc.mnemonic) \(rdStr), \(rnStr), #\(immr), #\(imms)"
            }
            let insertLsb = (width - immr) % width
            if instr.opcode == .ubfm {
                if !is64 && immr == 0 && imms == 7 { return "uxtb \(rdStr), \(rnStr)" }
                if !is64 && immr == 0 && imms == 15 { return "uxth \(rdStr), \(rnStr)" }
                if imms == width - 1 { return "lsr \(rdStr), \(rnStr), #\(immr)" }
                if imms + 1 == immr { return "lsl \(rdStr), \(rnStr), #\(width - immr)" }
                if imms >= immr { return "ubfx \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)" }
                return "ubfiz \(rdStr), \(rnStr), #\(insertLsb), #\(imms + 1)"
            } else if instr.opcode == .sbfm {
                if immr == 0 && imms == 7 { return "sxtb \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if immr == 0 && imms == 15 { return "sxth \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if is64 && immr == 0 && imms == 31 { return "sxtw \(rdStr), \(instr.rn.format(is64Bit: false))" }
                if imms == width - 1 { return "asr \(rdStr), \(rnStr), #\(immr)" }
                if imms >= immr { return "sbfx \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)" }
                return "sbfiz \(rdStr), \(rnStr), #\(insertLsb), #\(imms + 1)"
            }
            if imms >= immr {
                return "bfxil \(rdStr), \(rnStr), #\(immr), #\(imms - immr + 1)"
            }
            if instr.rn.rawValue == 31 {
                return "bfc \(rdStr), #\(insertLsb), #\(imms + 1)"
            }
            return "bfi \(rdStr), \(rnStr), #\(insertLsb), #\(imms + 1)"

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
            // With SP as an operand, the register-width extend (`uxtx`/`uxtw`) is written `lsl` (or omitted).
            let spInvolved = instr.rn.rawValue == 31 || (rdUseSP && instr.rd.rawValue == 31)
            let extStr: String
            if spInvolved && instr.extendKind == (is64 ? .uxtx : .uxtw) {
                extStr = instr.amount != 0 ? ", lsl #\(instr.amount)" : ""
            } else {
                extStr = ", \(instr.extendKind.mnemonic)\(amtSuffix)"
            }
            if (instr.opcode == .subsExtended || instr.opcode == .addsExtended) && instr.rd.rawValue == 31 {
                return "\(instr.opcode == .subsExtended ? "cmp" : "cmn") \(rnStr), \(rmStr)\(extStr)"
            }
            return "\(desc.mnemonic) \(rdStr), \(rnStr), \(rmStr)\(extStr)"

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
            if instr.ra.rawValue == 31 {
                return "\(instr.opcode == .madd ? "mul" : "mneg") \(rdStr), \(rnStr), \(rmStr)"
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
            if instr.opcode != .csel && instr.rn == instr.rm && instr.rn.rawValue != 31 && instr.cond != .al && instr.cond != .nv {
                let alias = instr.opcode == .csinc ? "cinc" : (instr.opcode == .csinv ? "cinv" : "cneg")
                return "\(alias) \(rdStr), \(rnStr), \(instr.cond.inverted.mnemonic)"
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

        case .hintImm7:
            if let alias = A64HintAlias.names[instr.imm] { return alias }
            return "hint #\(instr.imm)"

        case .exceptionImm16:
            return "\(desc.mnemonic) #\(instr.imm == 0 ? "0" : "0x" + String(instr.imm, radix: 16))"

        case .udfImm16:
            return "udf #\(instr.imm)"

        case .fixedSystem:
            return desc.mnemonic

        case .barrier:
            let crm = instr.barrierOption.rawValue
            switch instr.opcode {
            case .clrex, .isb:
                return crm == 15 ? desc.mnemonic : "\(desc.mnemonic) #\(crm)"
            case .dsb where crm == 0:
                return "ssbb"
            case .dsb where crm == 4:
                return "pssbb"
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
            let mnem = op.kind.mnemonic
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
            let extSuffix = registerOffsetSuffix(instr)
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(baseStr), \(rmStr)\(extSuffix)]"

        case .ldrLiteral:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), #\(instr.imm)"

        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            let regs = "\(instr.rd.format(is64Bit: is64)), \(instr.rm.format(is64Bit: is64))"
            return "\(desc.mnemonic) \(regs), \(memOperand(instr, format: desc.format))"

        case .atomicLoad, .atomicStore:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .atomicStoreExcl:
            return "\(desc.mnemonic) \(instr.rm.format(is64Bit: false)), \(instr.rd.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .atomicLoadPair:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), \(instr.ra.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .atomicStoreExclPair:
            return "\(desc.mnemonic) \(instr.rm.format(is64Bit: false)), \(instr.rd.format(is64Bit: is64)), \(instr.ra.format(is64Bit: is64)), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .lseAtomic, .lseCas:
            let w = instr.scalarWidth
            let sizeSuffix = w == .b ? "b" : (w == .h ? "h" : "")
            let rs = instr.rm.format(is64Bit: w == .d)
            let mem = "[\(instr.rn.format(is64Bit: true, r31IsSP: true))]"
            // `ld<op>[l]` discarding its result (Rt = zr, no acquire) is the store alias `st<op>[l]`.
            if desc.format == .lseAtomic && instr.opcode != .swp && instr.rd.rawValue == 31 && !instr.acquire {
                return "st\(desc.mnemonic.dropFirst(2))\(instr.release ? "l" : "")\(sizeSuffix) \(rs), \(mem)"
            }
            let order = (instr.acquire ? "a" : "") + (instr.release ? "l" : "")
            return "\(desc.mnemonic)\(order)\(sizeSuffix) \(rs), \(instr.rd.format(is64Bit: w == .d)), \(mem)"

        case .lseCasp:
            let is64Reg = instr.is64Bit
            let order = (instr.acquire ? "a" : "") + (instr.release ? "l" : "")
            let rs1 = A64GPR(rawValue: instr.rm.rawValue + 1), rt1 = A64GPR(rawValue: instr.rd.rawValue + 1)
            let regs = [instr.rm, rs1, instr.rd, rt1].map { $0.format(is64Bit: is64Reg) }.joined(separator: ", ")
            return "casp\(order) \(regs), [\(instr.rn.format(is64Bit: true, r31IsSP: true))]"

        case .fpLdstPreImm9, .fpLdstPostImm9, .fpLdstUnscaledImm9:
            return "\(desc.mnemonic) \(instr.vd.formatScalar(instr.scalarWidth)), \(memOperand(instr, format: desc.format))"

        case .fpLdstRegOffset:
            let baseStr = instr.rn.format(is64Bit: true, r31IsSP: true)
            let rmStr = instr.rm.format(is64Bit: instr.extendKind.uses64BitRegister)
            return "\(desc.mnemonic) \(instr.vd.formatScalar(instr.scalarWidth)), [\(baseStr), \(rmStr)\(registerOffsetSuffix(instr))]"

        case .fpLdrLiteral:
            return "ldr \(instr.vd.formatScalar(instr.scalarWidth)), #\(instr.imm)"

        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vd.formatScalar(w)), \(instr.vn.formatScalar(w)), \(memOperand(instr, format: desc.format))"

        case .fpMovGprToFp:
            return "fmov \(instr.vd.formatScalar(instr.scalarWidth)), \(instr.rn.format(is64Bit: is64))"

        case .fpMovFpToGpr:
            return "fmov \(instr.rd.format(is64Bit: is64)), \(instr.vn.formatScalar(instr.scalarWidth))"

        case .fpDp1:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vd.formatScalar(w)), \(instr.vn.formatScalar(w))"

        case .fpCvtPrecision:
            return "fcvt \(instr.vd.formatScalar(instr.scalarWidth)), \(instr.vn.formatScalar(instr.scalarWidth2))"

        case .fpIntToFp:
            return "\(desc.mnemonic) \(instr.vd.formatScalar(instr.scalarWidth)), \(instr.rn.format(is64Bit: is64))"

        case .fpToInt:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), \(instr.vn.formatScalar(instr.scalarWidth))"

        case .fpFixedToFp:
            return "\(desc.mnemonic) \(instr.vd.formatScalar(instr.scalarWidth)), \(instr.rn.format(is64Bit: is64)), #\(instr.imm)"

        case .fpToFixed:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: is64)), \(instr.vn.formatScalar(instr.scalarWidth)), #\(instr.imm)"

        case .fpBinary:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vd.formatScalar(w)), \(instr.vn.formatScalar(w)), \(instr.vm.formatScalar(w))"

        case .fpDp3:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vd.formatScalar(w)), \(instr.vn.formatScalar(w)), \(instr.vm.formatScalar(w)), \(instr.va.formatScalar(w))"

        case .fpCmpReg:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vn.formatScalar(w)), \(instr.vm.formatScalar(w))"

        case .fpCmpZero:
            return "\(desc.mnemonic) \(instr.vn.formatScalar(instr.scalarWidth)), #0.0"

        case .fpCondCompare:
            let w = instr.scalarWidth
            return "\(desc.mnemonic) \(instr.vn.formatScalar(w)), \(instr.vm.formatScalar(w)), #\(instr.imm2), \(instr.cond.mnemonic)"

        case .fpCondSelect:
            let w = instr.scalarWidth
            return "fcsel \(instr.vd.formatScalar(w)), \(instr.vn.formatScalar(w)), \(instr.vm.formatScalar(w)), \(instr.cond.mnemonic)"

        case .fpImm:
            return "fmov \(instr.vd.formatScalar(instr.scalarWidth)), #\(A64FPImmediate.format(UInt8(truncatingIfNeeded: instr.imm)))"

        case .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute:
            let arr = instr.arrangement
            if instr.opcode == .simdOrr && instr.vn == instr.vm {
                return "mov \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr))"
            }
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), \(instr.vm.formatVector(arr))"

        case .simdTwoRegMisc, .simdTwoRegMiscFp:
            let arr = instr.arrangement
            let mnem = instr.opcode == .simdNot ? "mvn" : desc.mnemonic
            return "\(mnem) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr))"

        case .simdCmpZero:
            let arr = instr.arrangement
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), #0"

        case .simdAcrossLanes:
            return "\(desc.mnemonic) \(instr.vd.formatScalar(instr.arrangement.elementWidth)), \(instr.vn.formatVector(instr.arrangement))"

        case .simdNarrow, .simdShiftNarrow:
            let arr = instr.arrangement
            let wide = arr.widened ?? arr
            let shift = desc.format == .simdShiftNarrow ? ", #\(instr.amount)" : ""
            return "\(desc.mnemonic)\(arr.qBit == 1 ? "2" : "") \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(wide))\(shift)"

        case .simdShiftLong:
            let arr = instr.arrangement
            let wide = arr.widened ?? arr
            return "\(desc.mnemonic)\(arr.qBit == 1 ? "2" : "") \(instr.vd.formatVector(wide)), \(instr.vn.formatVector(arr)), #\(instr.amount)"

        case .simdShiftImm:
            let arr = instr.arrangement
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), #\(instr.amount)"

        case .simdDupElem:
            let arr = instr.arrangement
            return "dup \(instr.vd.formatVector(arr)), \(element(instr.vn, arr.elementWidth, instr.index))"

        case .simdDupGpr:
            let arr = instr.arrangement
            return "dup \(instr.vd.formatVector(arr)), \(instr.rn.format(is64Bit: arr.elementWidth == .d))"

        case .simdDupScalar:
            let w = instr.scalarWidth
            return "mov \(instr.vd.formatScalar(w)), \(element(instr.vn, w, instr.index))"

        case .simdInsGpr:
            let w = instr.scalarWidth
            return "mov \(element(instr.vd, w, instr.index)), \(instr.rn.format(is64Bit: w == .d))"

        case .simdInsElem:
            let w = instr.scalarWidth
            return "mov \(element(instr.vd, w, instr.index)), \(element(instr.vn, w, instr.imm2))"

        case .simdUmovSmov:
            let w = instr.scalarWidth
            // `umov` from a 32/64-bit lane is printed as `mov`.
            let mnem = instr.opcode == .simdUmov && (w == .s || w == .d) ? "mov" : desc.mnemonic
            return "\(mnem) \(instr.rd.format(is64Bit: is64)), \(element(instr.vn, w, instr.index))"

        case .simdModImm:
            let arr = instr.arrangement
            let dest = arr == .d1 ? instr.vd.formatScalar(.d) : instr.vd.formatVector(arr)
            if instr.opcode == .simdFmovImm {
                return "fmov \(dest), #\(A64FPImmediate.format(UInt8(truncatingIfNeeded: instr.imm)))"
            }
            if arr.elementWidth == .d {
                // LLVM prints the byte mask with C's `%#016llx`: zero-padded to 16 characters, and zero without `0x`.
                let value = UInt64(bitPattern: instr.imm)
                let digits = String(value, radix: 16)
                let mask = value == 0 ? String(repeating: "0", count: 16)
                                      : "0x" + String(repeating: "0", count: max(0, 14 - digits.count)) + digits
                return "movi \(dest), #\(mask)"
            }
            let shift = (instr.amount != 0 || instr.shiftKind == .msl) ? ", \(instr.shiftKind.mnemonic) #\(instr.amount)" : ""
            return "\(desc.mnemonic) \(dest), #\(instr.imm)\(shift)"

        case .simdLdStMulti, .simdLdStMultiPost:
            let list = registerList(instr.vd, count: Int(instr.imm2), arrangement: instr.arrangement)
            return "\(desc.mnemonic) \(list), \(structureMemOperand(instr, isPost: desc.format == .simdLdStMultiPost))"

        case .simdLd1R, .simdLd1RPost:
            let list = registerList(instr.vd, count: 1, arrangement: instr.arrangement)
            return "ld1r \(list), \(structureMemOperand(instr, isPost: desc.format == .simdLd1RPost))"

        case .simdLdStLane, .simdLdStLanePost:
            let lane = "{ v\(instr.vd.rawValue).\(instr.scalarWidth.prefix) }[\(instr.index)]"
            return "\(desc.mnemonic) \(lane), \(structureMemOperand(instr, isPost: desc.format == .simdLdStLanePost))"

        case .simdTbl:
            let arr = instr.arrangement
            let list = registerList(instr.vn, count: Int(instr.imm2), arrangement: .b16)
            return "\(desc.mnemonic) \(instr.vd.formatVector(arr)), \(list), \(instr.vm.formatVector(arr))"

        case .simdExt:
            let arr = instr.arrangement
            return "ext \(instr.vd.formatVector(arr)), \(instr.vn.formatVector(arr)), \(instr.vm.formatVector(arr)), #\(instr.amount)"

        case .sveLdrStrZ, .sveLdrStrP:
            let reg = desc.format == .sveLdrStrZ ? instr.zd.formatted : instr.pd.formatted
            let base = instr.rn.format(is64Bit: true, r31IsSP: true)
            return "\(desc.mnemonic) \(reg), [\(base)\(instr.imm != 0 ? ", #\(instr.imm), mul vl" : "")]"

        case .sveAddVlPl:
            return "\(desc.mnemonic) \(instr.rd.format(is64Bit: true, r31IsSP: true)), \(instr.rn.format(is64Bit: true, r31IsSP: true)), #\(instr.imm)"

        case .sveRdffr, .sveWrffr:
            return "\(desc.mnemonic) \(instr.pd.formatted).b"
        }
    }

    // MARK: Formatting and decoding helpers

    /// The value `movz`/`movn` writes when it is printed as `mov Rd, #value` (Arm's preferred disassembly,
    /// as LLVM implements it), or nil when the raw `movz`/`movn` form is preferred.
    static func movAliasValue(_ instr: A64Instruction) -> Int64? {
        let is64 = instr.is64Bit
        let imm16 = UInt64(instr.imm & 0xFFFF)
        let shift = UInt64(instr.amount)
        // A zero immediate is `mov` only without a shift (`movz x0, #0, lsl #16` keeps its form).
        if imm16 == 0 && shift != 0 { return nil }
        let mask: UInt64 = is64 ? .max : 0xFFFF_FFFF
        var value = (imm16 << shift) & mask
        if instr.opcode == .movn {
            value = ~value & mask
            // `movz` takes precedence, so a value it can produce stays `movn` to keep this encoding.
            if isMovzValue(value, is64Bit: is64) { return nil }
        }
        return is64 ? Int64(bitPattern: value) : Int64(Int32(truncatingIfNeeded: value))
    }

    /// True if `movz` can produce `value` (one 16-bit chunk at a 16-bit-aligned shift).
    static func isMovzValue(_ value: UInt64, is64Bit: Bool) -> Bool {
        for shift in stride(from: UInt64(0), to: is64Bit ? 64 : 32, by: 16) where value & ~(UInt64(0xFFFF) << shift) == 0 {
            return true
        }
        return false
    }

    /// True if `movz` or `movn` can produce `value`, which then takes precedence over `orr Rd, zr, #imm`.
    static func isMovWideValue(_ value: UInt64, is64Bit: Bool) -> Bool {
        let mask: UInt64 = is64Bit ? .max : 0xFFFF_FFFF
        return isMovzValue(value & mask, is64Bit: is64Bit) || isMovzValue(~value & mask, is64Bit: is64Bit)
    }

    /// `, <extend> {#amount}` of a register-offset load/store; `uxtx` is written `lsl`. The amount is shown
    /// when `S` is set, including a byte access's explicit `#0` (carried in `imm2`).
    static func registerOffsetSuffix(_ instr: A64Instruction) -> String {
        let shown = instr.amount != 0 || instr.imm2 != 0
        if instr.extendKind == .uxtx {
            return shown ? ", lsl #\(instr.amount)" : ""
        }
        return ", \(instr.extendKind.mnemonic)" + (shown ? " #\(instr.amount)" : "")
    }

    /// `[Xn{, #imm}]`, `[Xn, #imm]!`, or `[Xn], #imm` for an immediate-offset load/store format.
    static func memOperand(_ instr: A64Instruction, format: A64InstrFormat) -> String {
        let base = instr.rn.format(is64Bit: true, r31IsSP: true)
        switch format {
        case .ldpStpPre, .fpLdpStpPre, .fpLdstPreImm9:
            return "[\(base), #\(instr.imm)]!"
        case .ldpStpPost, .fpLdpStpPost, .fpLdstPostImm9:
            return "[\(base)], #\(instr.imm)"
        default:
            return instr.imm != 0 ? "[\(base), #\(instr.imm)]" : "[\(base)]"
        }
    }

    /// `[Xn]`, or for post-indexed structure accesses `[Xn], #imm` / `[Xn], Xm`.
    static func structureMemOperand(_ instr: A64Instruction, isPost: Bool) -> String {
        let base = "[\(instr.rn.format(is64Bit: true, r31IsSP: true))]"
        guard isPost else { return base }
        return instr.rm.rawValue == 31 ? "\(base), #\(instr.imm)" : "\(base), \(instr.rm.format(is64Bit: true))"
    }

    static func element(_ reg: A64VReg, _ width: A64ScalarWidth, _ index: UInt8) -> String {
        "v\(reg.rawValue).\(width.prefix)[\(index)]"
    }

    /// `{ v0.16b, v1.16b }`: `count` consecutive registers (wrapping from `v31` to `v0`).
    static func registerList(_ first: A64VReg, count: Int, arrangement: A64Arrangement) -> String {
        let regs = (0..<count).map { A64VReg(rawValue: (first.rawValue &+ UInt8($0)) & 31).formatVector(arrangement) }
        return "{ \(regs.joined(separator: ", ")) }"
    }

    /// Register width of a SIMD/FP load/store from `size` (bits 31:30) and `opc<1>` (bit 23).
    static func fpLdstWidth(_ word: UInt32) -> A64ScalarWidth? {
        let size = UInt8(word >> 30)
        if (word >> 23) & 1 == 1 { return size == 0 ? .q : nil }
        return A64ScalarWidth(rawValue: size)
    }

    /// Register width of a SIMD/FP literal load or register pair from `opc` (bits 31:30).
    static func fpPairWidth(_ word: UInt32) -> A64ScalarWidth? {
        switch word >> 30 {
        case 0:  return .s
        case 1:  return .d
        case 2:  return .q
        default: return nil
        }
    }

    /// Element width and lane from the `imm5` field (bits 20:16) of the Advanced SIMD copy class.
    static func copyElement(_ word: UInt32) -> (A64ScalarWidth, UInt8)? {
        let imm5 = (word >> 16) & 0x1F
        guard imm5 & 0xF != 0 else { return nil }
        let log2 = UInt32(imm5.trailingZeroBitCount)
        return (A64ScalarWidth(rawValue: UInt8(log2))!, UInt8(imm5 >> (log2 + 1)))
    }

    /// Decodes the Advanced SIMD modified-immediate class for one of its five descriptors, or nil if
    /// `op:cmode` belongs to another one.
    static func decodeModImm(word: UInt32, desc: A64InstrDesc) -> A64Instruction? {
        let q = (word >> 30) & 1 == 1
        let op = (word >> 29) & 1
        let cmode = (word >> 12) & 0xF
        let imm8 = ((word >> 16) & 0x7) << 5 | ((word >> 5) & 0x1F)
        var inst = A64Instruction(opcode: desc.id, vd: A64VReg(rawValue: UInt8(word & 0x1F)), imm: Int64(imm8))
        let isOrrBic = cmode & 1 == 1 && cmode < 0b1100
        switch desc.id {
        case .simdFmovImm:
            guard cmode == 0b1111, op == 0 || q else { return nil }
            inst.arrangement = op == 1 ? .d2 : (q ? .s4 : .s2)
            return inst
        case .simdMovi:
            if cmode == 0b1110 {
                if op == 1 {
                    inst.arrangement = q ? .d2 : .d1
                    inst.imm = Int64(bitPattern: A64SIMDByteMask.decode(UInt8(imm8)))
                } else {
                    inst.arrangement = q ? .b16 : .b8
                }
                return inst
            }
            guard op == 0, !isOrrBic, cmode != 0b1111 else { return nil }
        case .simdMvni:
            guard op == 1, !isOrrBic, cmode < 0b1110 else { return nil }
        case .simdOrrImm:
            guard op == 0, isOrrBic else { return nil }
        case .simdBicImm:
            guard op == 1, isOrrBic else { return nil }
        default:
            return nil
        }
        if cmode & 0b1000 == 0 {
            inst.arrangement = q ? .s4 : .s2
            inst.amount = UInt8((cmode >> 1) & 3) * 8
        } else if cmode & 0b0100 == 0 {
            inst.arrangement = q ? .h8 : .h4
            inst.amount = UInt8((cmode >> 1) & 1) * 8
        } else {
            inst.arrangement = q ? .s4 : .s2
            inst.shiftKind = .msl
            inst.amount = cmode & 1 == 1 ? 16 : 8
        }
        return inst
    }

    /// Disassembles a 32-bit machine word directly into canonical assembly text.
    public static func disassemble(_ word: UInt32) -> String? {
        guard let decoded = decode(word) else { return nil }
        return format(decoded)
    }
}

// MARK: - 6. Table Verification (`A64InstructionTable.verifyRoundTrip`)

extension A64InstructionTable {
    /// Constructs a representative `A64Instruction` for a given `A64InstrDesc`. (The exhaustive operand
    /// sweep over every descriptor lives in `M2AArch64ExhaustiveTests`.)
    public static func sampleInstruction(for desc: A64InstrDesc) -> A64Instruction {
        let width: A64ScalarWidth = desc.allows(.d) ? .d : (desc.allows(.s) ? .s : .b)
        let arr: A64Arrangement = desc.allows(.s4) ? .s4 : (desc.allows(.b16) ? .b16 : .d2)
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
        case .dp2Source, .mulHigh:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2)
        case .dp1Source:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1)
        case .dp3Source:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, ra: .x3)
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
        case .exceptionImm16, .udfImm16, .hintImm7:
            return A64Instruction(opcode: desc.id, is64Bit: true, imm: 9)
        case .fixedSystem:
            return A64Instruction(opcode: desc.id, is64Bit: true)
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
            let is64 = sampleIs64(desc)
            let shift: UInt8 = desc.scaleLog2 == 255 ? 3 : desc.scaleLog2
            return A64Instruction(opcode: desc.id, is64Bit: is64, rd: .x0, rn: .x1, imm: Int64(2) << Int64(shift))
        case .ldstPreImm9, .ldstPostImm9, .ldstUnscaledImm9, .ldstUnprivImm9:
            return A64Instruction(opcode: desc.id, is64Bit: sampleIs64(desc), rd: .x0, rn: .x1, imm: -8)
        case .ldstRegOffset:
            let naturalShift: UInt8 = desc.scaleLog2 == 255 ? 3 : desc.scaleLog2
            return A64Instruction(opcode: desc.id, is64Bit: sampleIs64(desc), rd: .x0, rn: .x1, rm: .x2, extendKind: .uxtx, amount: naturalShift)
        case .ldrLiteral:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, imm: 64)
        case .ldpStpSigned, .ldpStpPre, .ldpStpPost:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .sp, rm: .x1, imm: 16)
        case .atomicLoad, .atomicStore, .atomicStoreExcl, .atomicLoadPair, .atomicStoreExclPair:
            return A64Instruction(opcode: desc.id, is64Bit: (desc.opcodeMask & (1 << 30)) == 0, rd: .x0, rn: .x1, rm: .x2, ra: .x3)
        case .lseAtomic, .lseCas:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, rm: .x2, scalarWidth: .d, acquire: true, release: true)
        case .lseCasp:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x4, rn: .x1, rm: .x2, scalarWidth: .d, acquire: true)
        case .fpLdstPreImm9, .fpLdstPostImm9, .fpLdstUnscaledImm9:
            return A64Instruction(opcode: desc.id, rn: .x1, vd: .v0, scalarWidth: .q, imm: -16)
        case .fpLdstRegOffset:
            return A64Instruction(opcode: desc.id, rn: .x1, rm: .x2, vd: .v0, scalarWidth: .d, extendKind: .sxtw, amount: 3)
        case .fpLdrLiteral:
            return A64Instruction(opcode: desc.id, vd: .v3, scalarWidth: .q, imm: 64)
        case .fpLdpStpSigned, .fpLdpStpPre, .fpLdpStpPost:
            return A64Instruction(opcode: desc.id, rn: .sp, vd: .v8, vn: .v9, scalarWidth: .d, imm: -16)
        case .fpMovGprToFp, .fpMovFpToGpr, .fpIntToFp, .fpToInt:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, vd: .v0, vn: .v1, scalarWidth: width)
        case .fpFixedToFp, .fpToFixed:
            return A64Instruction(opcode: desc.id, is64Bit: true, rd: .x0, rn: .x1, vd: .v0, vn: .v1, scalarWidth: width, imm: 16)
        case .fpDp1:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, scalarWidth: width)
        case .fpCvtPrecision:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, scalarWidth: .d, scalarWidth2: .s)
        case .fpBinary, .fpDp3, .fpCmpReg, .fpCmpZero, .fpCondSelect:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, va: .v3, scalarWidth: width, cond: .ge)
        case .fpCondCompare:
            return A64Instruction(opcode: desc.id, vn: .v1, vm: .v2, scalarWidth: width, cond: .ge, imm2: 4)
        case .fpImm:
            return A64Instruction(opcode: desc.id, vd: .v0, scalarWidth: width, imm: 0x70)
        case .simdThreeSameInt, .simdThreeSameBit, .simdThreeSameFp, .simdPermute, .simdTwoRegMisc,
             .simdCmpZero, .simdTwoRegMiscFp, .simdAcrossLanes, .simdNarrow:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: arr)
        case .simdShiftImm, .simdShiftLong, .simdShiftNarrow:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, arrangement: arr, amount: 4)
        case .simdDupElem, .simdDupGpr:
            return A64Instruction(opcode: desc.id, is64Bit: false, rn: .x1, vd: .v0, vn: .v1, arrangement: arr, index: 1)
        case .simdDupScalar, .simdInsGpr, .simdInsElem:
            return A64Instruction(opcode: desc.id, is64Bit: false, rn: .x1, vd: .v0, vn: .v1, scalarWidth: .s, index: 1, imm2: 2)
        case .simdUmovSmov:
            return A64Instruction(opcode: desc.id, is64Bit: desc.id == .simdSmov, rd: .x0, vn: .v1, scalarWidth: .b, index: 2)
        case .simdModImm:
            switch desc.id {
            case .simdFmovImm:
                return A64Instruction(opcode: desc.id, vd: .v0, arrangement: .s4, imm: 0x70)
            case .simdMovi:
                return A64Instruction(opcode: desc.id, vd: .v0, arrangement: .d2, imm: Int64(bitPattern: 0xFF00_FF00_0000_FFFF))
            default:
                return A64Instruction(opcode: desc.id, vd: .v0, arrangement: .s4, shiftKind: .lsl, amount: 8, imm: 0xAB)
            }
        case .simdLdStMulti, .simdLdStMultiPost:
            let count: UInt8
            switch desc.id {
            case .simdLd2, .simdSt2, .simdLd2Post, .simdSt2Post: count = 2
            case .simdLd3, .simdSt3, .simdLd3Post, .simdSt3Post: count = 3
            case .simdLd4, .simdSt4, .simdLd4Post, .simdSt4Post: count = 4
            default: count = 1
            }
            return A64Instruction(opcode: desc.id, rn: .x1, rm: .xzr, vd: .v0, arrangement: .b16, imm: Int64(count) * 16, imm2: count)
        case .simdLd1R, .simdLd1RPost:
            return A64Instruction(opcode: desc.id, rn: .x1, rm: .xzr, vd: .v0, arrangement: .s4, imm: 4)
        case .simdLdStLane, .simdLdStLanePost:
            return A64Instruction(opcode: desc.id, rn: .x1, rm: .xzr, vd: .v0, scalarWidth: .s, index: 3, imm: 4)
        case .simdTbl:
            return A64Instruction(opcode: desc.id, vd: .v0, vn: .v1, vm: .v2, arrangement: .b16, imm2: 1)
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

    /// The register width a sample GPR load/store uses: X where the descriptor allows it.
    private static func sampleIs64(_ desc: A64InstrDesc) -> Bool {
        if desc.scaleLog2 == 255 || (desc.opcodeMask & (1 << 30)) == 0 { return true }
        // Fixed-size sign-extending loads target X when `opc<0>` = 0.
        return (desc.opcodeBits >> 23) & 1 != 0 && (desc.opcodeBits >> 22) & 1 == 0
    }

    /// Verifies one representative instruction per entry in `A64InstructionTable`: encodes it, decodes the
    /// word, re-encodes the decoded instruction, and asserts the two words are equal.
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
