// Sources/SwiftStack/Encode/RV64Codec.swift
//
// RISC-V 64 (RVA23) table-driven instruction encoder, disassembler,
// compression helper, and pseudoinstruction expander (04-backend.md §4.9,
// 05-assembler.md §4.8, 09-roadmap.md §M2).

import Foundation

// MARK: - 1. RV64 Registers & CSRs

/// 64-bit General Purpose Register (`x0`..`x31`) with LP64D ABI aliases.
@frozen
public enum RVGPR: UInt8, CaseIterable, Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    case x0 = 0, x1 = 1, x2 = 2, x3 = 3, x4 = 4, x5 = 5, x6 = 6, x7 = 7
    case x8 = 8, x9 = 9, x10 = 10, x11 = 11, x12 = 12, x13 = 13, x14 = 14, x15 = 15
    case x16 = 16, x17 = 17, x18 = 18, x19 = 19, x20 = 20, x21 = 21, x22 = 22, x23 = 23
    case x24 = 24, x25 = 25, x26 = 26, x27 = 27, x28 = 28, x29 = 29, x30 = 30, x31 = 31

    // ABI aliases
    public static let zero: RVGPR = .x0
    public static let ra: RVGPR = .x1
    public static let sp: RVGPR = .x2
    public static let gp: RVGPR = .x3
    public static let tp: RVGPR = .x4
    public static let t0: RVGPR = .x5
    public static let t1: RVGPR = .x6
    public static let t2: RVGPR = .x7
    public static let s0: RVGPR = .x8
    public static let fp: RVGPR = .x8
    public static let s1: RVGPR = .x9
    public static let a0: RVGPR = .x10
    public static let a1: RVGPR = .x11
    public static let a2: RVGPR = .x12
    public static let a3: RVGPR = .x13
    public static let a4: RVGPR = .x14
    public static let a5: RVGPR = .x15
    public static let a6: RVGPR = .x16
    public static let a7: RVGPR = .x17
    public static let s2: RVGPR = .x18
    public static let s3: RVGPR = .x19
    public static let s4: RVGPR = .x20
    public static let s5: RVGPR = .x21
    public static let s6: RVGPR = .x22
    public static let s7: RVGPR = .x23
    public static let s8: RVGPR = .x24
    public static let s9: RVGPR = .x25
    public static let s10: RVGPR = .x26
    public static let s11: RVGPR = .x27
    public static let t3: RVGPR = .x28
    public static let t4: RVGPR = .x29
    public static let t5: RVGPR = .x30
    public static let t6: RVGPR = .x31

    /// True if this register is in `x8`..`x15` (`s0`, `s1`, `a0`..`a5`), addressable by 3-bit RVC fields.
    @inlinable
    public var isCompressedReg: Bool {
        rawValue >= 8 && rawValue <= 15
    }

    /// 3-bit RVC register field (`0..7`) if `self` is in `x8`..`x15`, or `nil`.
    @inlinable
    public var compressedBits: UInt8? {
        isCompressedReg ? (rawValue - 8) : nil
    }

    /// Initializes from a 3-bit RVC register field (`0..7` -> `x8`..`x15`).
    @inlinable
    public init(compressedBits: UInt8) {
        self = RVGPR(rawValue: (compressedBits & 0x7) + 8)!
    }

    /// Canonical ABI name (`zero`, `ra`, `sp`, ..., `t6`).
    public var abiName: String {
        switch self {
        case .x0: return "zero"
        case .x1: return "ra"
        case .x2: return "sp"
        case .x3: return "gp"
        case .x4: return "tp"
        case .x5: return "t0"
        case .x6: return "t1"
        case .x7: return "t2"
        case .x8: return "s0"
        case .x9: return "s1"
        case .x10: return "a0"
        case .x11: return "a1"
        case .x12: return "a2"
        case .x13: return "a3"
        case .x14: return "a4"
        case .x15: return "a5"
        case .x16: return "a6"
        case .x17: return "a7"
        case .x18: return "s2"
        case .x19: return "s3"
        case .x20: return "s4"
        case .x21: return "s5"
        case .x22: return "s6"
        case .x23: return "s7"
        case .x24: return "s8"
        case .x25: return "s9"
        case .x26: return "s10"
        case .x27: return "s11"
        case .x28: return "t3"
        case .x29: return "t4"
        case .x30: return "t5"
        case .x31: return "t6"
        }
    }

    /// Architectural register name (`x0`..`x31`).
    public var numericName: String {
        "x\(rawValue)"
    }

    public var description: String {
        abiName
    }

    /// Parses either an ABI register name (`zero`, `ra`, `fp`, `s0`, ...) or `x0`..`x31`.
    public init?(name: String) {
        switch name {
        case "zero", "x0": self = .x0
        case "ra", "x1": self = .x1
        case "sp", "x2": self = .x2
        case "gp", "x3": self = .x3
        case "tp", "x4": self = .x4
        case "t0", "x5": self = .x5
        case "t1", "x6": self = .x6
        case "t2", "x7": self = .x7
        case "s0", "fp", "x8": self = .x8
        case "s1", "x9": self = .x9
        case "a0", "x10": self = .x10
        case "a1", "x11": self = .x11
        case "a2", "x12": self = .x12
        case "a3", "x13": self = .x13
        case "a4", "x14": self = .x14
        case "a5", "x15": self = .x15
        case "a6", "x16": self = .x16
        case "a7", "x17": self = .x17
        case "s2", "x18": self = .x18
        case "s3", "x19": self = .x19
        case "s4", "x20": self = .x20
        case "s5", "x21": self = .x21
        case "s6", "x22": self = .x22
        case "s7", "x23": self = .x23
        case "s8", "x24": self = .x24
        case "s9", "x25": self = .x25
        case "s10", "x26": self = .x26
        case "s11", "x27": self = .x27
        case "t3", "x28": self = .x28
        case "t4", "x29": self = .x29
        case "t5", "x30": self = .x30
        case "t6", "x31": self = .x31
        default: return nil
        }
    }
}

/// 64-bit Floating-Point Register (`f0`..`f31`) with LP64D ABI aliases.
@frozen
public enum RVFPR: UInt8, CaseIterable, Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    case f0 = 0, f1 = 1, f2 = 2, f3 = 3, f4 = 4, f5 = 5, f6 = 6, f7 = 7
    case f8 = 8, f9 = 9, f10 = 10, f11 = 11, f12 = 12, f13 = 13, f14 = 14, f15 = 15
    case f16 = 16, f17 = 17, f18 = 18, f19 = 19, f20 = 20, f21 = 21, f22 = 22, f23 = 23
    case f24 = 24, f25 = 25, f26 = 26, f27 = 27, f28 = 28, f29 = 29, f30 = 30, f31 = 31

    // ABI aliases
    public static let ft0: RVFPR = .f0
    public static let ft1: RVFPR = .f1
    public static let ft2: RVFPR = .f2
    public static let ft3: RVFPR = .f3
    public static let ft4: RVFPR = .f4
    public static let ft5: RVFPR = .f5
    public static let ft6: RVFPR = .f6
    public static let ft7: RVFPR = .f7
    public static let fs0: RVFPR = .f8
    public static let fs1: RVFPR = .f9
    public static let fa0: RVFPR = .f10
    public static let fa1: RVFPR = .f11
    public static let fa2: RVFPR = .f12
    public static let fa3: RVFPR = .f13
    public static let fa4: RVFPR = .f14
    public static let fa5: RVFPR = .f15
    public static let fa6: RVFPR = .f16
    public static let fa7: RVFPR = .f17
    public static let fs2: RVFPR = .f18
    public static let fs3: RVFPR = .f19
    public static let fs4: RVFPR = .f20
    public static let fs5: RVFPR = .f21
    public static let fs6: RVFPR = .f22
    public static let fs7: RVFPR = .f23
    public static let fs8: RVFPR = .f24
    public static let fs9: RVFPR = .f25
    public static let fs10: RVFPR = .f26
    public static let fs11: RVFPR = .f27
    public static let ft8: RVFPR = .f28
    public static let ft9: RVFPR = .f29
    public static let ft10: RVFPR = .f30
    public static let ft11: RVFPR = .f31

    /// True if this FP register is in `f8`..`f15` (`fs0`..`fs1`, `fa0`..`fa5`), addressable by 3-bit RVC fields.
    @inlinable
    public var isCompressedReg: Bool {
        rawValue >= 8 && rawValue <= 15
    }

    /// 3-bit RVC register field (`0..7`) if `self` is in `f8`..`f15`, or `nil`.
    @inlinable
    public var compressedBits: UInt8? {
        isCompressedReg ? (rawValue - 8) : nil
    }

    /// Initializes from a 3-bit RVC register field (`0..7` -> `f8`..`f15`).
    @inlinable
    public init(compressedBits: UInt8) {
        self = RVFPR(rawValue: (compressedBits & 0x7) + 8)!
    }

    public var abiName: String {
        switch self {
        case .f0: return "ft0"
        case .f1: return "ft1"
        case .f2: return "ft2"
        case .f3: return "ft3"
        case .f4: return "ft4"
        case .f5: return "ft5"
        case .f6: return "ft6"
        case .f7: return "ft7"
        case .f8: return "fs0"
        case .f9: return "fs1"
        case .f10: return "fa0"
        case .f11: return "fa1"
        case .f12: return "fa2"
        case .f13: return "fa3"
        case .f14: return "fa4"
        case .f15: return "fa5"
        case .f16: return "fa6"
        case .f17: return "fa7"
        case .f18: return "fs2"
        case .f19: return "fs3"
        case .f20: return "fs4"
        case .f21: return "fs5"
        case .f22: return "fs6"
        case .f23: return "fs7"
        case .f24: return "fs8"
        case .f25: return "fs9"
        case .f26: return "fs10"
        case .f27: return "fs11"
        case .f28: return "ft8"
        case .f29: return "ft9"
        case .f30: return "ft10"
        case .f31: return "ft11"
        }
    }

    public var numericName: String {
        "f\(rawValue)"
    }

    public var description: String {
        abiName
    }

    public init?(name: String) {
        switch name {
        case "ft0", "f0": self = .f0
        case "ft1", "f1": self = .f1
        case "ft2", "f2": self = .f2
        case "ft3", "f3": self = .f3
        case "ft4", "f4": self = .f4
        case "ft5", "f5": self = .f5
        case "ft6", "f6": self = .f6
        case "ft7", "f7": self = .f7
        case "fs0", "f8": self = .f8
        case "fs1", "f9": self = .f9
        case "fa0", "f10": self = .f10
        case "fa1", "f11": self = .f11
        case "fa2", "f12": self = .f12
        case "fa3", "f13": self = .f13
        case "fa4", "f14": self = .f14
        case "fa5", "f15": self = .f15
        case "fa6", "f16": self = .f16
        case "fa7", "f17": self = .f17
        case "fs2", "f18": self = .f18
        case "fs3", "f19": self = .f19
        case "fs4", "f20": self = .f20
        case "fs5", "f21": self = .f21
        case "fs6", "f22": self = .f22
        case "fs7", "f23": self = .f23
        case "fs8", "f24": self = .f24
        case "fs9", "f25": self = .f25
        case "fs10", "f26": self = .f26
        case "fs11", "f27": self = .f27
        case "ft8", "f28": self = .f28
        case "ft9", "f29": self = .f29
        case "ft10", "f30": self = .f30
        case "ft11", "f31": self = .f31
        default: return nil
        }
    }
}

/// RVV 1.0 Vector Register (`v0`..`v31`).
@frozen
public enum RVVReg: UInt8, CaseIterable, Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    case v0 = 0, v1 = 1, v2 = 2, v3 = 3, v4 = 4, v5 = 5, v6 = 6, v7 = 7
    case v8 = 8, v9 = 9, v10 = 10, v11 = 11, v12 = 12, v13 = 13, v14 = 14, v15 = 15
    case v16 = 16, v17 = 17, v18 = 18, v19 = 19, v20 = 20, v21 = 21, v22 = 22, v23 = 23
    case v24 = 24, v25 = 25, v26 = 26, v27 = 27, v28 = 28, v29 = 29, v30 = 30, v31 = 31

    public var name: String {
        "v\(rawValue)"
    }

    public var description: String {
        name
    }

    public init?(name: String) {
        guard name.first == "v", let idx = UInt8(name.dropFirst()), idx < 32 else {
            return nil
        }
        self.init(rawValue: idx)
    }
}

/// Control and Status Register (12-bit address `0x000`..`0xFFF`) with named CSR lookup.
@frozen
public struct RVCSR: Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    public let rawValue: UInt16

    @inlinable
    public init?(rawValue: UInt16) {
        guard rawValue <= 0xFFF else { return nil }
        self.rawValue = rawValue
    }

    @inlinable
    public init(unchecked rawValue: UInt16) {
        self.rawValue = rawValue & 0xFFF
    }

    // Named CSR constants
    public static let ustatus    = RVCSR(unchecked: 0x000)
    public static let fflags     = RVCSR(unchecked: 0x001)
    public static let frm        = RVCSR(unchecked: 0x002)
    public static let fcsr       = RVCSR(unchecked: 0x003)
    public static let vstart     = RVCSR(unchecked: 0x008)
    public static let vxsat      = RVCSR(unchecked: 0x009)
    public static let vxrm       = RVCSR(unchecked: 0x00A)
    public static let vcsr       = RVCSR(unchecked: 0x00F)
    public static let sstatus    = RVCSR(unchecked: 0x100)
    public static let sie        = RVCSR(unchecked: 0x104)
    public static let stvec      = RVCSR(unchecked: 0x105)
    public static let scounteren = RVCSR(unchecked: 0x106)
    public static let senvcfg    = RVCSR(unchecked: 0x10A)
    public static let sscratch   = RVCSR(unchecked: 0x140)
    public static let sepc       = RVCSR(unchecked: 0x141)
    public static let scause     = RVCSR(unchecked: 0x142)
    public static let stval      = RVCSR(unchecked: 0x143)
    public static let sip        = RVCSR(unchecked: 0x144)
    public static let siselect   = RVCSR(unchecked: 0x150)
    public static let sireg      = RVCSR(unchecked: 0x151)
    public static let stopei     = RVCSR(unchecked: 0x15C)
    public static let satp       = RVCSR(unchecked: 0x180)
    public static let mstatus    = RVCSR(unchecked: 0x300)
    public static let misa       = RVCSR(unchecked: 0x301)
    public static let medeleg    = RVCSR(unchecked: 0x302)
    public static let mideleg    = RVCSR(unchecked: 0x303)
    public static let mie        = RVCSR(unchecked: 0x304)
    public static let mtvec      = RVCSR(unchecked: 0x305)
    public static let mcounteren = RVCSR(unchecked: 0x306)
    public static let mscratch   = RVCSR(unchecked: 0x340)
    public static let mepc       = RVCSR(unchecked: 0x341)
    public static let mcause     = RVCSR(unchecked: 0x342)
    public static let mtval      = RVCSR(unchecked: 0x343)
    public static let mip        = RVCSR(unchecked: 0x344)
    public static let cycle      = RVCSR(unchecked: 0xC00)
    public static let time       = RVCSR(unchecked: 0xC01)
    public static let instret    = RVCSR(unchecked: 0xC02)
    public static let vl         = RVCSR(unchecked: 0xC20)
    public static let vtype      = RVCSR(unchecked: 0xC21)
    public static let vlenb      = RVCSR(unchecked: 0xC22)
    public static let scountovf  = RVCSR(unchecked: 0xDA0)
    public static let mvendorid  = RVCSR(unchecked: 0xF11)
    public static let marchid    = RVCSR(unchecked: 0xF12)
    public static let mimpid     = RVCSR(unchecked: 0xF13)
    public static let mhartid    = RVCSR(unchecked: 0xF14)

    public static let namedCSRs: [(name: String, csr: RVCSR)] = [
        ("ustatus", .ustatus),
        ("fflags", .fflags),
        ("frm", .frm),
        ("fcsr", .fcsr),
        ("vstart", .vstart),
        ("vxsat", .vxsat),
        ("vxrm", .vxrm),
        ("vcsr", .vcsr),
        ("sstatus", .sstatus),
        ("sie", .sie),
        ("stvec", .stvec),
        ("scounteren", .scounteren),
        ("senvcfg", .senvcfg),
        ("sscratch", .sscratch),
        ("sepc", .sepc),
        ("scause", .scause),
        ("stval", .stval),
        ("sip", .sip),
        ("siselect", .siselect),
        ("sireg", .sireg),
        ("stopei", .stopei),
        ("satp", .satp),
        ("mstatus", .mstatus),
        ("misa", .misa),
        ("medeleg", .medeleg),
        ("mideleg", .mideleg),
        ("mie", .mie),
        ("mtvec", .mtvec),
        ("mcounteren", .mcounteren),
        ("mscratch", .mscratch),
        ("mepc", .mepc),
        ("mcause", .mcause),
        ("mtval", .mtval),
        ("mip", .mip),
        ("cycle", .cycle),
        ("time", .time),
        ("instret", .instret),
        ("vl", .vl),
        ("vtype", .vtype),
        ("vlenb", .vlenb),
        ("scountovf", .scountovf),
        ("mvendorid", .mvendorid),
        ("marchid", .marchid),
        ("mimpid", .mimpid),
        ("mhartid", .mhartid),
    ]

    public static let nameToCSR: [String: RVCSR] = {
        var map = [String: RVCSR](minimumCapacity: namedCSRs.count)
        for entry in namedCSRs {
            map[entry.name] = entry.csr
        }
        return map
    }()

    public static let csrToName: [UInt16: String] = {
        var map = [UInt16: String](minimumCapacity: namedCSRs.count)
        for entry in namedCSRs {
            map[entry.csr.rawValue] = entry.name
        }
        return map
    }()

    /// Parses a CSR by symbolic name (e.g., `"sstatus"`) or numeric literal (`"0x150"`, `"336"`).
    public init?(name: String) {
        let lower = name.lowercased()
        if let known = RVCSR.nameToCSR[lower] {
            self = known
            return
        }
        if lower.hasPrefix("0x") {
            guard let v = UInt16(lower.dropFirst(2), radix: 16), v <= 0xFFF else { return nil }
            self.rawValue = v
            return
        }
        if let v = UInt16(lower, radix: 10), v <= 0xFFF {
            self.rawValue = v
            return
        }
        return nil
    }

    public var name: String? {
        RVCSR.csrToName[rawValue]
    }

    public var description: String {
        if let name = RVCSR.csrToName[rawValue] {
            return name
        }
        let hex = String(rawValue, radix: 16)
        let pad = String(repeating: "0", count: max(0, 3 - hex.count))
        return "0x\(pad)\(hex)"
    }
}

// MARK: - 2. Rounding Mode, Fence, Vtype & Instruction Format

/// Floating-point rounding mode (`rm` field in FP instructions).
@frozen
public enum RVRoundingMode: UInt8, CaseIterable, Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    case rne = 0b000 // Round to Nearest, ties to Even
    case rtz = 0b001 // Round towards Zero
    case rdn = 0b010 // Round Down (towards -infinity)
    case rup = 0b011 // Round Up (towards +infinity)
    case rmm = 0b100 // Round to Nearest, ties to Max Magnitude
    case dyn = 0b111 // Dynamic rounding mode (from frm CSR)

    public var description: String {
        switch self {
        case .rne: return "rne"
        case .rtz: return "rtz"
        case .rdn: return "rdn"
        case .rup: return "rup"
        case .rmm: return "rmm"
        case .dyn: return "dyn"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "rne": self = .rne
        case "rtz": self = .rtz
        case "rdn": self = .rdn
        case "rup": self = .rup
        case "rmm": self = .rmm
        case "dyn": self = .dyn
        default: return nil
        }
    }
}

/// 4-bit memory ordering mask for `fence` predecessor/successor (`i=8, o=4, r=2, w=1`).
@frozen
public struct RVFenceMask: Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0xF
    }

    public static let w    = RVFenceMask(rawValue: 0b0001)
    public static let r    = RVFenceMask(rawValue: 0b0010)
    public static let rw   = RVFenceMask(rawValue: 0b0011)
    public static let o    = RVFenceMask(rawValue: 0b0100)
    public static let ow   = RVFenceMask(rawValue: 0b0101)
    public static let or   = RVFenceMask(rawValue: 0b0110)
    public static let orw  = RVFenceMask(rawValue: 0b0111)
    public static let i    = RVFenceMask(rawValue: 0b1000)
    public static let iw   = RVFenceMask(rawValue: 0b1001)
    public static let ir   = RVFenceMask(rawValue: 0b1010)
    public static let irw  = RVFenceMask(rawValue: 0b1011)
    public static let io   = RVFenceMask(rawValue: 0b1100)
    public static let iow  = RVFenceMask(rawValue: 0b1101)
    public static let ior  = RVFenceMask(rawValue: 0b1110)
    public static let iorw = RVFenceMask(rawValue: 0b1111)

    public init?(name: String) {
        var mask: UInt8 = 0
        for ch in name.lowercased() {
            switch ch {
            case "i": mask |= 8
            case "o": mask |= 4
            case "r": mask |= 2
            case "w": mask |= 1
            default: return nil
            }
        }
        guard mask != 0 else { return nil }
        self.rawValue = mask
    }

    public var description: String {
        if rawValue == 0 { return "0" }
        var s = ""
        if (rawValue & 8) != 0 { s.append("i") }
        if (rawValue & 4) != 0 { s.append("o") }
        if (rawValue & 2) != 0 { s.append("r") }
        if (rawValue & 1) != 0 { s.append("w") }
        return s
    }
}

/// Zfa `fli.s` / `fli.d` 5-bit constant table (`rs1` field 0..31).
public enum RVZfaFLITable {
    public static let names: [String] = [
        "-1.0", "min", "1.52587890625e-05", "3.0517578125e-05",
        "0.00390625", "0.0078125", "0.0625", "0.125",
        "0.25", "0.3125", "0.375", "0.4375",
        "0.5", "0.625", "0.75", "0.875",
        "1.0", "1.25", "1.5", "1.75",
        "2.0", "2.5", "3.0", "4.0",
        "8.0", "16.0", "128.0", "256.0",
        "32768.0", "65536.0", "inf", "nan",
    ]

    public static func index(for name: String) -> UInt8? {
        let lower = name.lowercased()
        if let idx = names.firstIndex(of: lower) {
            return UInt8(idx)
        }
        switch lower {
        case "-1": return 0
        case "1": return 16
        case "2": return 20
        case "3": return 22
        case "4": return 23
        case "8": return 24
        case "16": return 25
        case "128": return 26
        case "256": return 27
        case "32768": return 28
        case "65536": return 29
        default: return nil
        }
    }
}

/// RVV `vtypei` immediate helper for `vsetvli` (11-bit) and `vsetivli` (10-bit).
@frozen
public struct RVVType: Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    public let rawValue: UInt16

    @inlinable
    public init(rawValue: UInt16) {
        self.rawValue = rawValue & 0x7FF
    }

    /// Constructs a `vtypei` value from `sew` (`8, 16, 32, 64`), `lmul` (`m1, m2, m4, m8, mf2, mf4, mf8`),
    /// `ta` (tail agnostic), and `ma` (mask agnostic).
    public init?(sewBits: Int, lmulBits: UInt8 = 0, tailAgnostic: Bool = true, maskAgnostic: Bool = true) {
        let vsew: UInt16
        switch sewBits {
        case 8:  vsew = 0b000
        case 16: vsew = 0b001
        case 32: vsew = 0b010
        case 64: vsew = 0b011
        default: return nil
        }
        let vlmul = UInt16(lmulBits & 0x7)
        let vta: UInt16 = tailAgnostic ? 1 : 0
        let vma: UInt16 = maskAgnostic ? 1 : 0
        self.rawValue = (vma << 7) | (vta << 6) | (vsew << 3) | vlmul
    }

    public var description: String {
        let vlmul = rawValue & 0x7
        let vsew = (rawValue >> 3) & 0x7
        let vta = (rawValue >> 6) & 0x1
        let vma = (rawValue >> 7) & 0x1

        let sewStr: String
        switch vsew {
        case 0b000: sewStr = "e8"
        case 0b001: sewStr = "e16"
        case 0b010: sewStr = "e32"
        case 0b011: sewStr = "e64"
        default: return "0x\(String(rawValue, radix: 16))"
        }

        let lmulStr: String
        switch vlmul {
        case 0b000: lmulStr = "m1"
        case 0b001: lmulStr = "m2"
        case 0b010: lmulStr = "m4"
        case 0b011: lmulStr = "m8"
        case 0b101: lmulStr = "mf8"
        case 0b110: lmulStr = "mf4"
        case 0b111: lmulStr = "mf2"
        default: return "0x\(String(rawValue, radix: 16))"
        }

        let taStr = vta != 0 ? "ta" : "tu"
        let maStr = vma != 0 ? "ma" : "mu"
        return "\(sewStr), \(lmulStr), \(taStr), \(maStr)"
    }
}

/// Hardware instruction encoding format used by `RV64InstructionTable`.
@frozen
public enum RV64EncodingFormat: UInt8, Sendable, BitwiseCopyable, Hashable {
    // 32-bit standard formats
    case r          // funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rUnary     // funct7[31:25] | fixed_rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rShift64   // funct6[31:26] | shamt6[25:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rShift32   // funct7[31:25] | shamt5[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rAMO       // funct5[31:27] | aq[26] | rl[25] | rs2[24:20] | (rs1)[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rLR        // funct5[31:27] | aq[26] | rl[25] | 00000[24:20] | (rs1)[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case rFP        // funct7[31:25] | rs2(f)[24:20] | rs1(f)[19:15] | rm[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPFixed   // funct7[31:25] | rs2(f)[24:20] | rs1(f)[19:15] | funct3[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPUnary   // funct7[31:25] | fixed_rs2[24:20] | rs1(f)[19:15] | rm[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPCmp     // funct7[31:25] | rs2(f)[24:20] | rs1(f)[19:15] | funct3[14:12] | rd(x)[11:7] | opcode[6:0]
    case rFPCvtF2I  // funct7[31:25] | fixed_rs2[24:20] | rs1(f)[19:15] | rm[14:12] | rd(x)[11:7] | opcode[6:0]
    case rFPCvtI2F  // funct7[31:25] | fixed_rs2[24:20] | rs1(x)[19:15] | rm[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPMvF2I   // funct7[31:25] | 00000[24:20] | rs1(f)[19:15] | funct3[14:12] | rd(x)[11:7] | opcode[6:0]
    case rFPMvI2F   // funct7[31:25] | 00000[24:20] | rs1(x)[19:15] | funct3[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFLI       // funct7[31:25] | 00001[24:20] | imm5[19:15] | 000[14:12] | rd(f)[11:7] | opcode[6:0]
    case i          // imm12[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case iLoad      // imm12[31:20] | (rs1)[19:15] | funct3[14:12] | rd[11:7] | opcode[6:0]
    case iFPLoad    // imm12[31:20] | (rs1)[19:15] | funct3[14:12] | rd(f)[11:7] | opcode[6:0]
    case s          // imm[11:5] | rs2[24:20] | (rs1)[19:15] | funct3[14:12] | imm[4:0] | opcode[6:0]
    case sFP        // imm[11:5] | rs2(f)[24:20] | (rs1)[19:15] | funct3[14:12] | imm[4:0] | opcode[6:0]
    case b          // imm[12|10:5] | rs2[24:20] | rs1[19:15] | funct3[14:12] | imm[4:1|11] | opcode[6:0]
    case u          // imm[31:12] | rd[11:7] | opcode[6:0]
    case j          // imm[20|10:1|11|19:12] | rd[11:7] | opcode[6:0]
    case fence      // 0000[31:28] | pred[27:24] | succ[23:20] | 00000 | 000 | 00000 | 0001111
    case csrReg     // csr[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | 1110011
    case csrImm     // csr[31:20] | uimm5[19:15] | funct3[14:12] | rd[11:7] | 1110011
    case systemFixed// fixed 32-bit encoding (ecall, ebreak, fence.i, sret, mret, wfi)
    case sfenceVMA  // 0001001[31:25] | rs2[24:20] | rs1[19:15] | 000[14:12] | 00000[11:7] | 1110011

    // RVV 1.0 32-bit formats
    case vsetvli    // 0[31] | zimm11[30:20] | rs1[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vsetivli   // 11[31:30] | zimm10[29:20] | uimm5[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vsetvl     // 1000000[31:25] | rs2[24:20] | rs1[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vLoadWhole // nf[31:29] | 000 | 1 | 01000 | rs1[19:15] | width[14:12] | vd[11:7] | 0000111
    case vStoreWhole// nf[31:29] | 000 | 1 | 01000 | rs1[19:15] | 000[14:12] | vs3[11:7] | 0100111
    case vLoadUnit  // 000000 | vm[25] | 00000 | rs1[19:15] | width[14:12] | vd[11:7] | 0000111
    case vStoreUnit // 000000 | vm[25] | 00000 | rs1[19:15] | width[14:12] | vs3[11:7] | 0100111
    case vOpiVV     // funct6[31:26] | vm[25] | vs2[24:20] | vs1[19:15] | funct3[14:12] | vd[11:7] | 1010111
    case vOpiVX     // funct6[31:26] | vm[25] | vs2[24:20] | rs1[19:15] | funct3[14:12] | vd[11:7] | 1010111
    case vOpiVI     // funct6[31:26] | vm[25] | vs2[24:20] | simm5[19:15] | funct3[14:12] | vd[11:7] | 1010111
    case vMvVV      // 010111 | 1[25] | 00000[24:20] | vs1[19:15] | 000[14:12] | vd[11:7] | 1010111
    case vMvVX      // 010111 | 1[25] | 00000[24:20] | rs1[19:15] | 100[14:12] | vd[11:7] | 1010111
    case vMvVI      // 010111 | 1[25] | 00000[24:20] | simm5[19:15] | 011[14:12] | vd[11:7] | 1010111

    // 16-bit compressed (RVC & Zcb) formats
    case cFixed     // c.nop, c.ebreak, c.unimp
    case cAddi      // c.addi, c.addiw, c.li (signed 6-bit imm in [12] + [6:2], rd/rs1 in [11:7])
    case cAddi16sp  // c.addi16sp (signed 10-bit imm multiple of 16, rd=x2)
    case cAddi4spn  // c.addi4spn rd', sp, nzuimm10 (multiple of 4)
    case cLui       // c.lui rd, nzimm[17:12]
    case cShift     // c.srli, c.srai (rd'/rs1' in [9:7], shamt6 in [12] + [6:2])
    case cAndi      // c.andi rd'/rs1' in [9:7], signed imm6 in [12] + [6:2]
    case cAlu       // c.sub, c.xor, c.or, c.and, c.subw, c.addw, c.mul (rd'/rs1' in [9:7], rs2' in [4:2])
    case cZcbUnary  // c.zext.b, c.sext.b, c.zext.h, c.sext.h, c.zext.w, c.not (rd'/rs1' in [9:7])
    case cSlli      // c.slli rd/rs1 in [11:7], shamt6 in [12] + [6:2]
    case cCR        // c.mv, c.add (rd in [11:7], rs2 in [6:2])
    case cJr        // c.jr, c.jalr (rs1 in [11:7], rs2=0)
    case cLw        // c.lw rd', uimm7(rs1')
    case cLd        // c.ld rd', uimm8(rs1')
    case cFld       // c.fld fd', uimm8(rs1')
    case cSw        // c.sw rs2', uimm7(rs1')
    case cSd        // c.sd rs2', uimm8(rs1')
    case cFsd       // c.fsd fs2', uimm8(rs1')
    case cLwsp      // c.lwsp rd, uimm8(sp)
    case cLdsp      // c.ldsp rd, uimm9(sp)
    case cFldsp     // c.fldsp fd, uimm9(sp)
    case cSwsp      // c.swsp rs2, uimm8(sp)
    case cSdsp      // c.sdsp rs2, uimm9(sp)
    case cFsdsp     // c.fsdsp fs2, uimm9(sp)
    case cJ         // c.j imm12
    case cBranch    // c.beqz, c.bnez rs1', imm9
    case cZcbByte   // c.lbu, c.sb (rd'/rs2' in [4:2], rs1' in [9:7], uimm2 in [5|6])
    case cZcbHalf   // c.lhu, c.lh, c.sh (rd'/rs2' in [4:2], rs1' in [9:7], uimm2[1] in [5])
}

/// Complete enumeration of RV64 (RVA23) instruction opcodes in `RV64InstructionTable`.
@frozen
public enum RV64Opcode: UInt16, CaseIterable, Sendable, BitwiseCopyable, Hashable {
    // RV64I base (53)
    case lui, auipc, jal, jalr
    case beq, bne, blt, bge, bltu, bgeu
    case lb, lh, lw, ld, lbu, lhu, lwu
    case sb, sh, sw, sd
    case addi, slti, sltiu, xori, ori, andi
    case slli, srli, srai
    case add, sub, sll, slt, sltu, xor, srl, sra, or, and
    case addiw, slliw, srliw, sraiw
    case addw, subw, sllw, srlw, sraw
    case fence, fence_i, ecall, ebreak

    // Privileged & Zicsr (10)
    case csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci
    case sret, mret, wfi, sfence_vma

    // M extension (13)
    case mul, mulh, mulhsu, mulhu, div, divu, rem, remu
    case mulw, divw, divuw, remw, remuw

    // A extension (22)
    case lr_w, sc_w, lr_d, sc_d
    case amoswap_w, amoadd_w, amoxor_w, amoand_w, amoor_w, amomin_w, amomax_w, amominu_w, amomaxu_w
    case amoswap_d, amoadd_d, amoxor_d, amoand_d, amoor_d, amomin_d, amomax_d, amominu_d, amomaxu_d

    // F & D & Zfa & Zfhmin extensions (62)
    case flw, fsw, fld, fsd, flh, fsh
    case fadd_s, fsub_s, fmul_s, fdiv_s, fsqrt_s
    case fadd_d, fsub_d, fmul_d, fdiv_d, fsqrt_d
    case fsgnj_s, fsgnjn_s, fsgnjx_s
    case fsgnj_d, fsgnjn_d, fsgnjx_d
    case fmin_s, fmax_s, fmin_d, fmax_d
    case feq_s, flt_s, fle_s
    case feq_d, flt_d, fle_d
    case fcvt_w_s, fcvt_wu_s, fcvt_l_s, fcvt_lu_s
    case fcvt_s_w, fcvt_s_wu, fcvt_s_l, fcvt_s_lu
    case fcvt_w_d, fcvt_wu_d, fcvt_l_d, fcvt_lu_d
    case fcvt_d_w, fcvt_d_wu, fcvt_d_l, fcvt_d_lu
    case fcvt_s_d, fcvt_d_s
    case fmv_x_w, fmv_w_x, fmv_x_d, fmv_d_x
    case fclass_s, fclass_d
    case fli_s, fli_d
    case fminm_s, fmaxm_s, fminm_d, fmaxm_d

    // Zba (8)
    case add_uw, sh1add, sh1add_uw, sh2add, sh2add_uw, sh3add, sh3add_uw, slli_uw

    // Zbb (24)
    case andn, orn, xnor
    case clz, clzw, ctz, ctzw, cpop, cpopw
    case max, maxu, min, minu
    case sext_b, sext_h, zext_h
    case rol, rolw, ror, rori, roriw, rorw
    case orc_b, rev8

    // Zbs (8)
    case bclr, bclri, bext, bexti, binv, binvi, bset, bseti

    // Zicond (2)
    case czero_eqz, czero_nez

    // RVC & Zcb (49)
    case c_unimp, c_nop, c_addi, c_addiw, c_addi16sp, c_addi4spn
    case c_li, c_lui, c_srli, c_srai, c_andi
    case c_sub, c_xor, c_or, c_and, c_subw, c_addw
    case c_slli, c_mv, c_add
    case c_lw, c_ld, c_sw, c_sd
    case c_lwsp, c_ldsp, c_swsp, c_sdsp
    case c_fld, c_fsd, c_fldsp, c_fsdsp
    case c_j, c_jr, c_jalr, c_beqz, c_bnez, c_ebreak
    case c_zext_b, c_sext_b, c_zext_h, c_sext_h, c_zext_w, c_not, c_mul
    case c_lbu, c_lhu, c_lh, c_sb, c_sh

    // RVV 1.0 (34)
    case vsetvli, vsetivli, vsetvl
    case vl1re8_v, vl2re8_v, vl4re8_v, vl8re8_v
    case vs1r_v, vs2r_v, vs4r_v, vs8r_v
    case vle8_v, vle16_v, vle32_v, vle64_v
    case vse8_v, vse16_v, vse32_v, vse64_v
    case vadd_vv, vadd_vx, vadd_vi
    case vsub_vv, vsub_vx
    case vmul_vv
    case vand_vv, vor_vv, vxor_vv
    case vmv_v_v, vmv_v_x, vmv_v_i
    case vfadd_vv, vfsub_vv, vfmul_vv
}

/// Decoded or constructed RV64 instruction value.
/// Flat, value-type representation (`BitwiseCopyable`, `Sendable`) shared across Codegen, Asm, and Disassembler.
@frozen
public struct RV64Instruction: Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    public var opcode: RV64Opcode
    public var rd: UInt8        // GPR, FPR, or VReg index (0..31)
    public var rs1: UInt8       // GPR, FPR, or VReg index (0..31)
    public var rs2: UInt8       // GPR, FPR, or VReg index (0..31)
    public var imm: Int64       // Immediate, branch/jump offset, CSR number, or vtypei
    public var rm: RVRoundingMode
    public var aq: Bool         // Atomic acquire
    public var rl: Bool         // Atomic release
    public var vm: Bool         // RVV unmasked (true = vm=1 unmasked, false = vm=0 v0.t masked)

    @inlinable
    public init(
        opcode: RV64Opcode,
        rd: UInt8 = 0,
        rs1: UInt8 = 0,
        rs2: UInt8 = 0,
        imm: Int64 = 0,
        rm: RVRoundingMode = .dyn,
        aq: Bool = false,
        rl: Bool = false,
        vm: Bool = true
    ) {
        self.opcode = opcode
        self.rd = rd
        self.rs1 = rs1
        self.rs2 = rs2
        self.imm = imm
        self.rm = rm
        self.aq = aq
        self.rl = rl
        self.vm = vm
    }

    // Convenience typed initializers for GPR / FPR / VReg
    @inlinable
    public static func gpr(
        _ opcode: RV64Opcode,
        rd: RVGPR = .zero,
        rs1: RVGPR = .zero,
        rs2: RVGPR = .zero,
        imm: Int64 = 0,
        aq: Bool = false,
        rl: Bool = false
    ) -> RV64Instruction {
        RV64Instruction(opcode: opcode, rd: rd.rawValue, rs1: rs1.rawValue, rs2: rs2.rawValue, imm: imm, aq: aq, rl: rl)
    }

    @inlinable
    public static func fp(
        _ opcode: RV64Opcode,
        rd: UInt8 = 0,
        rs1: UInt8 = 0,
        rs2: UInt8 = 0,
        imm: Int64 = 0,
        rm: RVRoundingMode = .dyn
    ) -> RV64Instruction {
        RV64Instruction(opcode: opcode, rd: rd, rs1: rs1, rs2: rs2, imm: imm, rm: rm)
    }

    @inlinable
    public static func vec(
        _ opcode: RV64Opcode,
        vd: RVVReg = .v0,
        vs1: UInt8 = 0,
        vs2: RVVReg = .v0,
        imm: Int64 = 0,
        vm: Bool = true
    ) -> RV64Instruction {
        RV64Instruction(opcode: opcode, rd: vd.rawValue, rs1: vs1, rs2: vs2.rawValue, imm: imm, vm: vm)
    }

    public var isCompressed: Bool {
        RV64InstructionTable.descriptor(for: opcode).isCompressed
    }

    public var description: String {
        RV64Disassembler.format(self)
    }
}

/// Table entry describing a single RV64 or RVC instruction's mnemonic, format, fixed bits, and mask.
@frozen
public struct RV64InstrDesc: Sendable {
    public let opcode: RV64Opcode
    public let mnemonic: String
    public let format: RV64EncodingFormat
    public let match: UInt32
    public let mask: UInt32
    public let isCompressed: Bool

    public init(
        opcode: RV64Opcode,
        mnemonic: String,
        format: RV64EncodingFormat,
        match: UInt32,
        mask: UInt32,
        isCompressed: Bool = false
    ) {
        self.opcode = opcode
        self.mnemonic = mnemonic
        self.format = format
        self.match = match
        self.mask = mask
        self.isCompressed = isCompressed
    }
}

// MARK: - 3. Shared Instruction Descriptor Table (`RV64InstructionTable`)

public enum RV64InstructionTable {
    /// Master table of all RV64 (RVA23) 32-bit and 16-bit compressed instructions,
    /// indexed directly by `RV64Opcode.rawValue`.
    public static let descriptors: [RV64InstrDesc] = [
        // --- RV64I Base ---
        RV64InstrDesc(opcode: .lui,     mnemonic: "lui",     format: .u,           match: 0x00000037, mask: 0x0000007F),
        RV64InstrDesc(opcode: .auipc,   mnemonic: "auipc",   format: .u,           match: 0x00000017, mask: 0x0000007F),
        RV64InstrDesc(opcode: .jal,     mnemonic: "jal",     format: .j,           match: 0x0000006F, mask: 0x0000007F),
        RV64InstrDesc(opcode: .jalr,    mnemonic: "jalr",    format: .i,           match: 0x00000067, mask: 0x0000707F),

        RV64InstrDesc(opcode: .beq,     mnemonic: "beq",     format: .b,           match: 0x00000063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bne,     mnemonic: "bne",     format: .b,           match: 0x00001063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .blt,     mnemonic: "blt",     format: .b,           match: 0x00004063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bge,     mnemonic: "bge",     format: .b,           match: 0x00005063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bltu,    mnemonic: "bltu",    format: .b,           match: 0x00006063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bgeu,    mnemonic: "bgeu",    format: .b,           match: 0x00007063, mask: 0x0000707F),

        RV64InstrDesc(opcode: .lb,      mnemonic: "lb",      format: .iLoad,       match: 0x00000003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lh,      mnemonic: "lh",      format: .iLoad,       match: 0x00001003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lw,      mnemonic: "lw",      format: .iLoad,       match: 0x00002003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .ld,      mnemonic: "ld",      format: .iLoad,       match: 0x00003003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lbu,     mnemonic: "lbu",     format: .iLoad,       match: 0x00004003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lhu,     mnemonic: "lhu",     format: .iLoad,       match: 0x00005003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lwu,     mnemonic: "lwu",     format: .iLoad,       match: 0x00006003, mask: 0x0000707F),

        RV64InstrDesc(opcode: .sb,      mnemonic: "sb",      format: .s,           match: 0x00000023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sh,      mnemonic: "sh",      format: .s,           match: 0x00001023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sw,      mnemonic: "sw",      format: .s,           match: 0x00002023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sd,      mnemonic: "sd",      format: .s,           match: 0x00003023, mask: 0x0000707F),

        RV64InstrDesc(opcode: .addi,    mnemonic: "addi",    format: .i,           match: 0x00000013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .slti,    mnemonic: "slti",    format: .i,           match: 0x00002013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sltiu,   mnemonic: "sltiu",   format: .i,           match: 0x00003013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .xori,    mnemonic: "xori",    format: .i,           match: 0x00004013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .ori,     mnemonic: "ori",     format: .i,           match: 0x00006013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .andi,    mnemonic: "andi",    format: .i,           match: 0x00007013, mask: 0x0000707F),

        RV64InstrDesc(opcode: .slli,    mnemonic: "slli",    format: .rShift64,    match: 0x00001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .srli,    mnemonic: "srli",    format: .rShift64,    match: 0x00005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .srai,    mnemonic: "srai",    format: .rShift64,    match: 0x40005013, mask: 0xFC00707F),

        RV64InstrDesc(opcode: .add,     mnemonic: "add",     format: .r,           match: 0x00000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sub,     mnemonic: "sub",     format: .r,           match: 0x40000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sll,     mnemonic: "sll",     format: .r,           match: 0x00001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .slt,     mnemonic: "slt",     format: .r,           match: 0x00002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sltu,    mnemonic: "sltu",    format: .r,           match: 0x00003033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .xor,     mnemonic: "xor",     format: .r,           match: 0x00004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srl,     mnemonic: "srl",     format: .r,           match: 0x00005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sra,     mnemonic: "sra",     format: .r,           match: 0x40005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .or,      mnemonic: "or",      format: .r,           match: 0x00006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .and,     mnemonic: "and",     format: .r,           match: 0x00007033, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .addiw,   mnemonic: "addiw",   format: .i,           match: 0x0000001B, mask: 0x0000707F),
        RV64InstrDesc(opcode: .slliw,   mnemonic: "slliw",   format: .rShift32,    match: 0x0000101B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srliw,   mnemonic: "srliw",   format: .rShift32,    match: 0x0000501B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sraiw,   mnemonic: "sraiw",   format: .rShift32,    match: 0x4000501B, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .addw,    mnemonic: "addw",    format: .r,           match: 0x0000003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .subw,    mnemonic: "subw",    format: .r,           match: 0x4000003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sllw,    mnemonic: "sllw",    format: .r,           match: 0x0000103B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srlw,    mnemonic: "srlw",    format: .r,           match: 0x0000503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sraw,    mnemonic: "sraw",    format: .r,           match: 0x4000503B, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .fence,   mnemonic: "fence",   format: .fence,       match: 0x0000000F, mask: 0xF00FFFFF),
        RV64InstrDesc(opcode: .fence_i, mnemonic: "fence.i", format: .systemFixed, match: 0x0000100F, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ecall,   mnemonic: "ecall",   format: .systemFixed, match: 0x00000073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ebreak,  mnemonic: "ebreak",  format: .systemFixed, match: 0x00100073, mask: 0xFFFFFFFF),

        // --- Privileged & Zicsr ---
        RV64InstrDesc(opcode: .csrrw,   mnemonic: "csrrw",   format: .csrReg,      match: 0x00001073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrs,   mnemonic: "csrrs",   format: .csrReg,      match: 0x00002073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrc,   mnemonic: "csrrc",   format: .csrReg,      match: 0x00003073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrwi,  mnemonic: "csrrwi",  format: .csrImm,      match: 0x00005073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrsi,  mnemonic: "csrrsi",  format: .csrImm,      match: 0x00006073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrci,  mnemonic: "csrrci",  format: .csrImm,      match: 0x00007073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sret,    mnemonic: "sret",    format: .systemFixed, match: 0x10200073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .mret,    mnemonic: "mret",    format: .systemFixed, match: 0x30200073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .wfi,     mnemonic: "wfi",     format: .systemFixed, match: 0x10500073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .sfence_vma, mnemonic: "sfence.vma", format: .sfenceVMA, match: 0x12000073, mask: 0xFE007FFF),

        // --- M Extension ---
        RV64InstrDesc(opcode: .mul,     mnemonic: "mul",     format: .r,           match: 0x02000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulh,    mnemonic: "mulh",    format: .r,           match: 0x02001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulhsu,  mnemonic: "mulhsu",  format: .r,           match: 0x02002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulhu,   mnemonic: "mulhu",   format: .r,           match: 0x02003033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .div,     mnemonic: "div",     format: .r,           match: 0x02004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divu,    mnemonic: "divu",    format: .r,           match: 0x02005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rem,     mnemonic: "rem",     format: .r,           match: 0x02006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remu,    mnemonic: "remu",    format: .r,           match: 0x02007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulw,    mnemonic: "mulw",    format: .r,           match: 0x0200003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divw,    mnemonic: "divw",    format: .r,           match: 0x0200403B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divuw,   mnemonic: "divuw",   format: .r,           match: 0x0200503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remw,    mnemonic: "remw",    format: .r,           match: 0x0200603B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remuw,   mnemonic: "remuw",   format: .r,           match: 0x0200703B, mask: 0xFE00707F),

        // --- A Extension ---
        RV64InstrDesc(opcode: .lr_w,      mnemonic: "lr.w",      format: .rLR,  match: 0x1000202F, mask: 0xF9F0707F),
        RV64InstrDesc(opcode: .sc_w,      mnemonic: "sc.w",      format: .rAMO, match: 0x1800202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .lr_d,      mnemonic: "lr.d",      format: .rLR,  match: 0x1000302F, mask: 0xF9F0707F),
        RV64InstrDesc(opcode: .sc_d,      mnemonic: "sc.d",      format: .rAMO, match: 0x1800302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoswap_w, mnemonic: "amoswap.w", format: .rAMO, match: 0x0800202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoadd_w,  mnemonic: "amoadd.w",  format: .rAMO, match: 0x0000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoxor_w,  mnemonic: "amoxor.w",  format: .rAMO, match: 0x2000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoand_w,  mnemonic: "amoand.w",  format: .rAMO, match: 0x6000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoor_w,   mnemonic: "amoor.w",   format: .rAMO, match: 0x4000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomin_w,  mnemonic: "amomin.w",  format: .rAMO, match: 0x8000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomax_w,  mnemonic: "amomax.w",  format: .rAMO, match: 0xA000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amominu_w, mnemonic: "amominu.w", format: .rAMO, match: 0xC000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomaxu_w, mnemonic: "amomaxu.w", format: .rAMO, match: 0xE000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoswap_d, mnemonic: "amoswap.d", format: .rAMO, match: 0x0800302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoadd_d,  mnemonic: "amoadd.d",  format: .rAMO, match: 0x0000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoxor_d,  mnemonic: "amoxor.d",  format: .rAMO, match: 0x2000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoand_d,  mnemonic: "amoand.d",  format: .rAMO, match: 0x6000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoor_d,   mnemonic: "amoor.d",   format: .rAMO, match: 0x4000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomin_d,  mnemonic: "amomin.d",  format: .rAMO, match: 0x8000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomax_d,  mnemonic: "amomax.d",  format: .rAMO, match: 0xA000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amominu_d, mnemonic: "amominu.d", format: .rAMO, match: 0xC000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomaxu_d, mnemonic: "amomaxu.d", format: .rAMO, match: 0xE000302F, mask: 0xF800707F),

        // --- F, D, Zfa, Zfhmin Extensions ---
        RV64InstrDesc(opcode: .flw,       mnemonic: "flw",       format: .iFPLoad,    match: 0x00002007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsw,       mnemonic: "fsw",       format: .sFP,        match: 0x00002027, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fld,       mnemonic: "fld",       format: .iFPLoad,    match: 0x00003007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsd,       mnemonic: "fsd",       format: .sFP,        match: 0x00003027, mask: 0x0000707F),
        RV64InstrDesc(opcode: .flh,       mnemonic: "flh",       format: .iFPLoad,    match: 0x00001007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsh,       mnemonic: "fsh",       format: .sFP,        match: 0x00001027, mask: 0x0000707F),

        RV64InstrDesc(opcode: .fadd_s,    mnemonic: "fadd.s",    format: .rFP,        match: 0x00000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsub_s,    mnemonic: "fsub.s",    format: .rFP,        match: 0x08000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fmul_s,    mnemonic: "fmul.s",    format: .rFP,        match: 0x10000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fdiv_s,    mnemonic: "fdiv.s",    format: .rFP,        match: 0x18000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsqrt_s,   mnemonic: "fsqrt.s",   format: .rFPUnary,   match: 0x58000053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fadd_d,    mnemonic: "fadd.d",    format: .rFP,        match: 0x02000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsub_d,    mnemonic: "fsub.d",    format: .rFP,        match: 0x0A000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fmul_d,    mnemonic: "fmul.d",    format: .rFP,        match: 0x12000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fdiv_d,    mnemonic: "fdiv.d",    format: .rFP,        match: 0x1A000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsqrt_d,   mnemonic: "fsqrt.d",   format: .rFPUnary,   match: 0x5A000053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fsgnj_s,   mnemonic: "fsgnj.s",   format: .rFPFixed,   match: 0x20000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjn_s,  mnemonic: "fsgnjn.s",  format: .rFPFixed,   match: 0x20001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjx_s,  mnemonic: "fsgnjx.s",  format: .rFPFixed,   match: 0x20002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnj_d,   mnemonic: "fsgnj.d",   format: .rFPFixed,   match: 0x22000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjn_d,  mnemonic: "fsgnjn.d",  format: .rFPFixed,   match: 0x22001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjx_d,  mnemonic: "fsgnjx.d",  format: .rFPFixed,   match: 0x22002053, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .fmin_s,    mnemonic: "fmin.s",    format: .rFPFixed,   match: 0x28000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmax_s,    mnemonic: "fmax.s",    format: .rFPFixed,   match: 0x28001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmin_d,    mnemonic: "fmin.d",    format: .rFPFixed,   match: 0x2A000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmax_d,    mnemonic: "fmax.d",    format: .rFPFixed,   match: 0x2A001053, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .feq_s,     mnemonic: "feq.s",     format: .rFPCmp,     match: 0xA0002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .flt_s,     mnemonic: "flt.s",     format: .rFPCmp,     match: 0xA0001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fle_s,     mnemonic: "fle.s",     format: .rFPCmp,     match: 0xA0000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .feq_d,     mnemonic: "feq.d",     format: .rFPCmp,     match: 0xA2002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .flt_d,     mnemonic: "flt.d",     format: .rFPCmp,     match: 0xA2001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fle_d,     mnemonic: "fle.d",     format: .rFPCmp,     match: 0xA2000053, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .fcvt_w_s,  mnemonic: "fcvt.w.s",  format: .rFPCvtF2I,  match: 0xC0000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_wu_s, mnemonic: "fcvt.wu.s", format: .rFPCvtF2I,  match: 0xC0100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_l_s,  mnemonic: "fcvt.l.s",  format: .rFPCvtF2I,  match: 0xC0200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_lu_s, mnemonic: "fcvt.lu.s", format: .rFPCvtF2I,  match: 0xC0300053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fcvt_s_w,  mnemonic: "fcvt.s.w",  format: .rFPCvtI2F,  match: 0xD0000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_wu, mnemonic: "fcvt.s.wu", format: .rFPCvtI2F,  match: 0xD0100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_l,  mnemonic: "fcvt.s.l",  format: .rFPCvtI2F,  match: 0xD0200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_lu, mnemonic: "fcvt.s.lu", format: .rFPCvtI2F,  match: 0xD0300053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fcvt_w_d,  mnemonic: "fcvt.w.d",  format: .rFPCvtF2I,  match: 0xC2000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_wu_d, mnemonic: "fcvt.wu.d", format: .rFPCvtF2I,  match: 0xC2100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_l_d,  mnemonic: "fcvt.l.d",  format: .rFPCvtF2I,  match: 0xC2200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_lu_d, mnemonic: "fcvt.lu.d", format: .rFPCvtF2I,  match: 0xC2300053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fcvt_d_w,  mnemonic: "fcvt.d.w",  format: .rFPCvtI2F,  match: 0xD2000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_wu, mnemonic: "fcvt.d.wu", format: .rFPCvtI2F,  match: 0xD2100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_l,  mnemonic: "fcvt.d.l",  format: .rFPCvtI2F,  match: 0xD2200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_lu, mnemonic: "fcvt.d.lu", format: .rFPCvtI2F,  match: 0xD2300053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fcvt_s_d,  mnemonic: "fcvt.s.d",  format: .rFPUnary,   match: 0x40100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_s,  mnemonic: "fcvt.d.s",  format: .rFPUnary,   match: 0x42000053, mask: 0xFFF0007F),

        RV64InstrDesc(opcode: .fmv_x_w,   mnemonic: "fmv.x.w",   format: .rFPMvF2I,   match: 0xE0000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_w_x,   mnemonic: "fmv.w.x",   format: .rFPMvI2F,   match: 0xF0000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_x_d,   mnemonic: "fmv.x.d",   format: .rFPMvF2I,   match: 0xE2000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_d_x,   mnemonic: "fmv.d.x",   format: .rFPMvI2F,   match: 0xF2000053, mask: 0xFFF0707F),

        RV64InstrDesc(opcode: .fclass_s,  mnemonic: "fclass.s",  format: .rFPMvF2I,   match: 0xE0001053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fclass_d,  mnemonic: "fclass.d",  format: .rFPMvF2I,   match: 0xE2001053, mask: 0xFFF0707F),

        RV64InstrDesc(opcode: .fli_s,     mnemonic: "fli.s",     format: .rFLI,       match: 0xF0100053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fli_d,     mnemonic: "fli.d",     format: .rFLI,       match: 0xF2100053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fminm_s,   mnemonic: "fminm.s",   format: .rFPFixed,   match: 0x28002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmaxm_s,   mnemonic: "fmaxm.s",   format: .rFPFixed,   match: 0x28003053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fminm_d,   mnemonic: "fminm.d",   format: .rFPFixed,   match: 0x2A002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmaxm_d,   mnemonic: "fmaxm.d",   format: .rFPFixed,   match: 0x2A003053, mask: 0xFE00707F),

        // --- Zba (Address Generation) ---
        RV64InstrDesc(opcode: .add_uw,    mnemonic: "add.uw",    format: .r,          match: 0x0800003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh1add,    mnemonic: "sh1add",    format: .r,          match: 0x20002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh1add_uw, mnemonic: "sh1add.uw", format: .r,          match: 0x2000203B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh2add,    mnemonic: "sh2add",    format: .r,          match: 0x20004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh2add_uw, mnemonic: "sh2add.uw", format: .r,          match: 0x2000403B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh3add,    mnemonic: "sh3add",    format: .r,          match: 0x20006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh3add_uw, mnemonic: "sh3add.uw", format: .r,          match: 0x2000603B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .slli_uw,   mnemonic: "slli.uw",   format: .rShift64,   match: 0x0800101B, mask: 0xFC00707F),

        // --- Zbb (Basic Bit Manipulation) ---
        RV64InstrDesc(opcode: .andn,      mnemonic: "andn",      format: .r,          match: 0x40007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .orn,       mnemonic: "orn",       format: .r,          match: 0x40006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .xnor,      mnemonic: "xnor",      format: .r,          match: 0x40004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .clz,       mnemonic: "clz",       format: .rUnary,     match: 0x60001013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .clzw,      mnemonic: "clzw",      format: .rUnary,     match: 0x6000101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .ctz,       mnemonic: "ctz",       format: .rUnary,     match: 0x60101013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .ctzw,      mnemonic: "ctzw",      format: .rUnary,     match: 0x6010101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .cpop,      mnemonic: "cpop",      format: .rUnary,     match: 0x60201013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .cpopw,     mnemonic: "cpopw",     format: .rUnary,     match: 0x6020101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .max,       mnemonic: "max",       format: .r,          match: 0x0A006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .maxu,      mnemonic: "maxu",      format: .r,          match: 0x0A007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .min,       mnemonic: "min",       format: .r,          match: 0x0A004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .minu,      mnemonic: "minu",      format: .r,          match: 0x0A005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sext_b,    mnemonic: "sext.b",    format: .rUnary,     match: 0x60401013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .sext_h,    mnemonic: "sext.h",    format: .rUnary,     match: 0x60501013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .zext_h,    mnemonic: "zext.h",    format: .rUnary,     match: 0x0800403B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .rol,       mnemonic: "rol",       format: .r,          match: 0x60001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rolw,      mnemonic: "rolw",      format: .r,          match: 0x6000103B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .ror,       mnemonic: "ror",       format: .r,          match: 0x60005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rori,      mnemonic: "rori",      format: .rShift64,   match: 0x60005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .roriw,     mnemonic: "roriw",     format: .rShift32,   match: 0x6000501B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rorw,      mnemonic: "rorw",      format: .r,          match: 0x6000503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .orc_b,     mnemonic: "orc.b",     format: .rUnary,     match: 0x28705013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .rev8,      mnemonic: "rev8",      format: .rUnary,     match: 0x6B805013, mask: 0xFFF0707F),

        // --- Zbs (Single-Bit Manipulation) ---
        RV64InstrDesc(opcode: .bclr,      mnemonic: "bclr",      format: .r,          match: 0x48001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bclri,     mnemonic: "bclri",     format: .rShift64,   match: 0x48001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .bext,      mnemonic: "bext",      format: .r,          match: 0x48005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bexti,     mnemonic: "bexti",     format: .rShift64,   match: 0x48005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .binv,      mnemonic: "binv",      format: .r,          match: 0x68001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .binvi,     mnemonic: "binvi",     format: .rShift64,   match: 0x68001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .bset,      mnemonic: "bset",      format: .r,          match: 0x28001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bseti,     mnemonic: "bseti",     format: .rShift64,   match: 0x28001013, mask: 0xFC00707F),

        // --- Zicond (Conditional Zero) ---
        RV64InstrDesc(opcode: .czero_eqz, mnemonic: "czero.eqz", format: .r,          match: 0x0E005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .czero_nez, mnemonic: "czero.nez", format: .r,          match: 0x0E007033, mask: 0xFE00707F),

        // --- RVC (16-bit Compressed) & Zcb ---
        RV64InstrDesc(opcode: .c_unimp,    mnemonic: "c.unimp",    format: .cFixed,    match: 0x0000, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_nop,      mnemonic: "c.nop",      format: .cFixed,    match: 0x0001, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi,     mnemonic: "c.addi",     format: .cAddi,     match: 0x0001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_addiw,    mnemonic: "c.addiw",    format: .cAddi,     match: 0x2001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi16sp, mnemonic: "c.addi16sp", format: .cAddi16sp, match: 0x6101, mask: 0xEF83, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi4spn, mnemonic: "c.addi4spn", format: .cAddi4spn, match: 0x0000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_li,       mnemonic: "c.li",       format: .cAddi,     match: 0x4001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lui,      mnemonic: "c.lui",      format: .cLui,      match: 0x6001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_srli,     mnemonic: "c.srli",     format: .cShift,    match: 0x8001, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_srai,     mnemonic: "c.srai",     format: .cShift,    match: 0x8401, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_andi,     mnemonic: "c.andi",     format: .cAndi,     match: 0x8801, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_sub,      mnemonic: "c.sub",      format: .cAlu,      match: 0x8C01, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_xor,      mnemonic: "c.xor",      format: .cAlu,      match: 0x8C21, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_or,       mnemonic: "c.or",       format: .cAlu,      match: 0x8C41, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_and,      mnemonic: "c.and",      format: .cAlu,      match: 0x8C61, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_subw,     mnemonic: "c.subw",     format: .cAlu,      match: 0x9C01, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_addw,     mnemonic: "c.addw",     format: .cAlu,      match: 0x9C21, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_slli,     mnemonic: "c.slli",     format: .cSlli,     match: 0x0002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_mv,       mnemonic: "c.mv",       format: .cCR,       match: 0x8002, mask: 0xF003, isCompressed: true),
        RV64InstrDesc(opcode: .c_add,      mnemonic: "c.add",      format: .cCR,       match: 0x9002, mask: 0xF003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lw,       mnemonic: "c.lw",       format: .cLw,       match: 0x4000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ld,       mnemonic: "c.ld",       format: .cLd,       match: 0x6000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sw,       mnemonic: "c.sw",       format: .cSw,       match: 0xC000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sd,       mnemonic: "c.sd",       format: .cSd,       match: 0xE000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lwsp,     mnemonic: "c.lwsp",     format: .cLwsp,     match: 0x4002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ldsp,     mnemonic: "c.ldsp",     format: .cLdsp,     match: 0x6002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_swsp,     mnemonic: "c.swsp",     format: .cSwsp,     match: 0xC002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sdsp,     mnemonic: "c.sdsp",     format: .cSdsp,     match: 0xE002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fld,      mnemonic: "c.fld",      format: .cFld,      match: 0x2000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fsd,      mnemonic: "c.fsd",      format: .cFsd,      match: 0xA000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fldsp,    mnemonic: "c.fldsp",    format: .cFldsp,    match: 0x2002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fsdsp,    mnemonic: "c.fsdsp",    format: .cFsdsp,    match: 0xA002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_j,        mnemonic: "c.j",        format: .cJ,        match: 0xA001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_jr,       mnemonic: "c.jr",       format: .cJr,       match: 0x8002, mask: 0xF07F, isCompressed: true),
        RV64InstrDesc(opcode: .c_jalr,     mnemonic: "c.jalr",     format: .cJr,       match: 0x9002, mask: 0xF07F, isCompressed: true),
        RV64InstrDesc(opcode: .c_beqz,     mnemonic: "c.beqz",     format: .cBranch,   match: 0xC001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_bnez,     mnemonic: "c.bnez",     format: .cBranch,   match: 0xE001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ebreak,   mnemonic: "c.ebreak",   format: .cFixed,    match: 0x9002, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_b,   mnemonic: "c.zext.b",   format: .cZcbUnary, match: 0x9C61, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_sext_b,   mnemonic: "c.sext.b",   format: .cZcbUnary, match: 0x9C65, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_h,   mnemonic: "c.zext.h",   format: .cZcbUnary, match: 0x9C69, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_sext_h,   mnemonic: "c.sext.h",   format: .cZcbUnary, match: 0x9C6D, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_w,   mnemonic: "c.zext.w",   format: .cZcbUnary, match: 0x9C71, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_not,      mnemonic: "c.not",      format: .cZcbUnary, match: 0x9C75, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_mul,      mnemonic: "c.mul",      format: .cAlu,      match: 0x9C41, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_lbu,      mnemonic: "c.lbu",      format: .cZcbByte,  match: 0x8000, mask: 0xFC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_lhu,      mnemonic: "c.lhu",      format: .cZcbHalf,  match: 0x8400, mask: 0xFC43, isCompressed: true),
        RV64InstrDesc(opcode: .c_lh,       mnemonic: "c.lh",       format: .cZcbHalf,  match: 0x8440, mask: 0xFC43, isCompressed: true),
        RV64InstrDesc(opcode: .c_sb,       mnemonic: "c.sb",       format: .cZcbByte,  match: 0x8800, mask: 0xFC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_sh,       mnemonic: "c.sh",       format: .cZcbHalf,  match: 0x8C00, mask: 0xFC43, isCompressed: true),

        // --- RVV 1.0 (Vector Extension) ---
        RV64InstrDesc(opcode: .vsetvli,    mnemonic: "vsetvli",    format: .vsetvli,    match: 0x00007057, mask: 0x8000707F),
        RV64InstrDesc(opcode: .vsetivli,   mnemonic: "vsetivli",   format: .vsetivli,   match: 0xC0007057, mask: 0xC000707F),
        RV64InstrDesc(opcode: .vsetvl,     mnemonic: "vsetvl",     format: .vsetvl,     match: 0x80007057, mask: 0xFE00707F),

        RV64InstrDesc(opcode: .vl1re8_v,   mnemonic: "vl1re8.v",   format: .vLoadWhole, match: 0x02800007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl2re8_v,   mnemonic: "vl2re8.v",   format: .vLoadWhole, match: 0x22800007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl4re8_v,   mnemonic: "vl4re8.v",   format: .vLoadWhole, match: 0x62800007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl8re8_v,   mnemonic: "vl8re8.v",   format: .vLoadWhole, match: 0xE2800007, mask: 0xFFF0707F),

        RV64InstrDesc(opcode: .vs1r_v,     mnemonic: "vs1r.v",     format: .vStoreWhole, match: 0x02800027, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vs2r_v,     mnemonic: "vs2r.v",     format: .vStoreWhole, match: 0x22800027, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vs4r_v,     mnemonic: "vs4r.v",     format: .vStoreWhole, match: 0x62800027, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vs8r_v,     mnemonic: "vs8r.v",     format: .vStoreWhole, match: 0xE2800027, mask: 0xFFF0707F),

        RV64InstrDesc(opcode: .vle8_v,     mnemonic: "vle8.v",     format: .vLoadUnit,  match: 0x00000007, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle16_v,    mnemonic: "vle16.v",    format: .vLoadUnit,  match: 0x00005007, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle32_v,    mnemonic: "vle32.v",    format: .vLoadUnit,  match: 0x00006007, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle64_v,    mnemonic: "vle64.v",    format: .vLoadUnit,  match: 0x00007007, mask: 0xFDF0707F),

        RV64InstrDesc(opcode: .vse8_v,     mnemonic: "vse8.v",     format: .vStoreUnit, match: 0x00000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vse16_v,    mnemonic: "vse16.v",    format: .vStoreUnit, match: 0x00005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vse32_v,    mnemonic: "vse32.v",    format: .vStoreUnit, match: 0x00006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vse64_v,    mnemonic: "vse64.v",    format: .vStoreUnit, match: 0x00007027, mask: 0xFDF0707F),

        RV64InstrDesc(opcode: .vadd_vv,    mnemonic: "vadd.vv",    format: .vOpiVV,     match: 0x00000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vadd_vx,    mnemonic: "vadd.vx",    format: .vOpiVX,     match: 0x00004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vadd_vi,    mnemonic: "vadd.vi",    format: .vOpiVI,     match: 0x00003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsub_vv,    mnemonic: "vsub.vv",    format: .vOpiVV,     match: 0x08000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsub_vx,    mnemonic: "vsub.vx",    format: .vOpiVX,     match: 0x08004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmul_vv,    mnemonic: "vmul.vv",    format: .vOpiVV,     match: 0x94002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vand_vv,    mnemonic: "vand.vv",    format: .vOpiVV,     match: 0x24000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vor_vv,     mnemonic: "vor.vv",     format: .vOpiVV,     match: 0x28000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vxor_vv,    mnemonic: "vxor.vv",    format: .vOpiVV,     match: 0x2C000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmv_v_v,    mnemonic: "vmv.v.v",    format: .vMvVV,      match: 0x5E000057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmv_v_x,    mnemonic: "vmv.v.x",    format: .vMvVX,      match: 0x5E004057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmv_v_i,    mnemonic: "vmv.v.i",    format: .vMvVI,      match: 0x5E003057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vfadd_vv,   mnemonic: "vfadd.vv",   format: .vOpiVV,     match: 0x00001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfsub_vv,   mnemonic: "vfsub.vv",   format: .vOpiVV,     match: 0x08001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfmul_vv,   mnemonic: "vfmul.vv",   format: .vOpiVV,     match: 0x90001057, mask: 0xFC00707F),
    ]

    /// Direct O(1) lookup by `RV64Opcode`.
    @inlinable
    public static func descriptor(for opcode: RV64Opcode) -> RV64InstrDesc {
        descriptors[Int(opcode.rawValue)]
    }

    /// Lookup table from canonical mnemonic string to `RV64Opcode`.
    public static let mnemonicToOpcode: [String: RV64Opcode] = {
        var map = [String: RV64Opcode](minimumCapacity: descriptors.count)
        for desc in descriptors {
            map[desc.mnemonic] = desc.opcode
        }
        return map
    }()

    /// Lookup table from canonical mnemonic string to `RV64InstrDesc`.
    public static func descriptor(forMnemonic mnemonic: String) -> RV64InstrDesc? {
        guard let op = mnemonicToOpcode[mnemonic] else { return nil }
        return descriptors[Int(op.rawValue)]
    }
}

// MARK: - 4. RV64 Encoder, Compression & Pseudoinstruction Expansion

public enum RV64Encoder {
    /// Encodes an `RV64Instruction` into 2 bytes (16-bit compressed) or 4 bytes (32-bit standard),
    /// optionally compressing 32-bit instructions into RVC when `rvcEnabled` is true.
    public static func encode(_ inst: RV64Instruction, rvcEnabled: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        encode(inst, into: &bytes, rvcEnabled: rvcEnabled)
        return bytes
    }

    /// Appends the encoded little-endian bytes of `inst` into `buffer`.
    public static func encode(_ inst: RV64Instruction, into buffer: inout [UInt8], rvcEnabled: Bool = false) {
        if inst.isCompressed {
            let hw = encode16(inst)
            buffer.append(UInt8(truncatingIfNeeded: hw))
            buffer.append(UInt8(truncatingIfNeeded: hw >> 8))
            return
        }
        if rvcEnabled, let hw = tryCompress(inst) {
            buffer.append(UInt8(truncatingIfNeeded: hw))
            buffer.append(UInt8(truncatingIfNeeded: hw >> 8))
            return
        }
        let word = encode32(inst)
        buffer.append(UInt8(truncatingIfNeeded: word))
        buffer.append(UInt8(truncatingIfNeeded: word >> 8))
        buffer.append(UInt8(truncatingIfNeeded: word >> 16))
        buffer.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    /// Encodes a 16-bit compressed RVC/Zcb instruction into a `UInt16`.
    public static func encode16(_ inst: RV64Instruction) -> UInt16 {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        var hw = UInt16(truncatingIfNeeded: desc.match)
        let rd = UInt16(inst.rd & 0x1F)
        let rs1 = UInt16(inst.rs1 & 0x1F)
        let rs2 = UInt16(inst.rs2 & 0x1F)
        let rdp = UInt16((inst.rd &- 8) & 0x7)
        let rs1p = UInt16((inst.rs1 &- 8) & 0x7)
        let rs2p = UInt16((inst.rs2 &- 8) & 0x7)
        let imm = Int(inst.imm)

        switch desc.format {
        case .cFixed:
            break

        case .cAddi:
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_2 = UInt16(imm & 0x1F) << 2
            hw |= b12 | (rd << 7) | b6_2

        case .cAddi16sp:
            let b12 = UInt16((imm >> 9) & 0x1) << 12
            let b6 = UInt16((imm >> 4) & 0x1) << 6
            let b5 = UInt16((imm >> 6) & 0x1) << 5
            let b4_3 = UInt16((imm >> 7) & 0x3) << 3
            let b2 = UInt16((imm >> 5) & 0x1) << 2
            hw |= b12 | b6 | b5 | b4_3 | b2

        case .cAddi4spn:
            let b12_11 = UInt16((imm >> 4) & 0x3) << 11
            let b10_7 = UInt16((imm >> 6) & 0xF) << 7
            let b6 = UInt16((imm >> 2) & 0x1) << 6
            let b5 = UInt16((imm >> 3) & 0x1) << 5
            hw |= b12_11 | b10_7 | b6 | b5 | (rdp << 2)

        case .cLui:
            let nzimm: Int
            if (imm & 0xFFF) == 0 && (imm >= 4096 || imm <= -4096) {
                nzimm = imm >> 12
            } else {
                nzimm = imm
            }
            let b12 = UInt16((nzimm >> 5) & 0x1) << 12
            let b6_2 = UInt16(nzimm & 0x1F) << 2
            hw |= b12 | (rd << 7) | b6_2

        case .cShift, .cAndi:
            let regp = inst.rd != 0 ? rdp : rs1p
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_2 = UInt16(imm & 0x1F) << 2
            hw |= b12 | (regp << 7) | b6_2

        case .cAlu:
            let dstp = inst.rd != 0 ? rdp : rs1p
            hw |= (dstp << 7) | (rs2p << 2)

        case .cZcbUnary:
            let dstp = inst.rd != 0 ? rdp : rs1p
            hw |= (dstp << 7)

        case .cSlli:
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_2 = UInt16(imm & 0x1F) << 2
            hw |= b12 | (rd << 7) | b6_2

        case .cCR:
            hw |= (rd << 7) | (rs2 << 2)

        case .cJr:
            let reg = rs1 != 0 ? rs1 : rd
            hw |= (reg << 7)

        case .cLw:
            let b12_10 = UInt16((imm >> 3) & 0x7) << 10
            let b6 = UInt16((imm >> 2) & 0x1) << 6
            let b5 = UInt16((imm >> 6) & 0x1) << 5
            hw |= b12_10 | (rs1p << 7) | b6 | b5 | (rdp << 2)

        case .cSw:
            let b12_10 = UInt16((imm >> 3) & 0x7) << 10
            let b6 = UInt16((imm >> 2) & 0x1) << 6
            let b5 = UInt16((imm >> 6) & 0x1) << 5
            hw |= b12_10 | (rs1p << 7) | b6 | b5 | (rs2p << 2)

        case .cLd, .cFld:
            let b12_10 = UInt16((imm >> 3) & 0x7) << 10
            let b6_5 = UInt16((imm >> 6) & 0x3) << 5
            hw |= b12_10 | (rs1p << 7) | b6_5 | (rdp << 2)

        case .cSd, .cFsd:
            let b12_10 = UInt16((imm >> 3) & 0x7) << 10
            let b6_5 = UInt16((imm >> 6) & 0x3) << 5
            hw |= b12_10 | (rs1p << 7) | b6_5 | (rs2p << 2)

        case .cLwsp:
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_4 = UInt16((imm >> 2) & 0x7) << 4
            let b3_2 = UInt16((imm >> 6) & 0x3) << 2
            hw |= b12 | (rd << 7) | b6_4 | b3_2

        case .cLdsp, .cFldsp:
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_5 = UInt16((imm >> 3) & 0x3) << 5
            let b4_2 = UInt16((imm >> 6) & 0x7) << 2
            hw |= b12 | (rd << 7) | b6_5 | b4_2

        case .cSwsp:
            let src = inst.rs2 != 0 ? rs2 : rd
            let b12_9 = UInt16((imm >> 2) & 0xF) << 9
            let b8_7 = UInt16((imm >> 6) & 0x3) << 7
            hw |= b12_9 | b8_7 | (src << 2)

        case .cSdsp, .cFsdsp:
            let src = inst.rs2 != 0 ? rs2 : rd
            let b12_10 = UInt16((imm >> 3) & 0x7) << 10
            let b9_7 = UInt16((imm >> 6) & 0x7) << 7
            hw |= b12_10 | b9_7 | (src << 2)

        case .cJ:
            let b12 = UInt16((imm >> 11) & 0x1) << 12
            let b11 = UInt16((imm >> 4) & 0x1) << 11
            let b10_9 = UInt16((imm >> 8) & 0x3) << 9
            let b8 = UInt16((imm >> 10) & 0x1) << 8
            let b7 = UInt16((imm >> 6) & 0x1) << 7
            let b6 = UInt16((imm >> 7) & 0x1) << 6
            let b5_3 = UInt16((imm >> 1) & 0x7) << 3
            let b2 = UInt16((imm >> 5) & 0x1) << 2
            hw |= b12 | b11 | b10_9 | b8 | b7 | b6 | b5_3 | b2

        case .cBranch:
            let regp = inst.rs1 != 0 ? rs1p : rdp
            let b12 = UInt16((imm >> 8) & 0x1) << 12
            let b11_10 = UInt16((imm >> 3) & 0x3) << 10
            let b6_5 = UInt16((imm >> 6) & 0x3) << 5
            let b4_3 = UInt16((imm >> 1) & 0x3) << 3
            let b2 = UInt16((imm >> 5) & 0x1) << 2
            hw |= b12 | b11_10 | (regp << 7) | b6_5 | b4_3 | b2

        case .cZcbByte:
            let regp = desc.opcode == .c_sb ? rs2p : rdp
            let b6 = UInt16(imm & 0x1) << 6
            let b5 = UInt16((imm >> 1) & 0x1) << 5
            hw |= (rs1p << 7) | b6 | b5 | (regp << 2)

        case .cZcbHalf:
            let regp = desc.opcode == .c_sh ? rs2p : rdp
            let b5 = UInt16((imm >> 1) & 0x1) << 5
            hw |= (rs1p << 7) | b5 | (regp << 2)

        default:
            break
        }

        return hw
    }

    /// Encodes a 32-bit standard instruction into a `UInt32`.
    public static func encode32(_ inst: RV64Instruction) -> UInt32 {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        var word = desc.match
        let rd = UInt32(inst.rd & 0x1F)
        let rs1 = UInt32(inst.rs1 & 0x1F)
        let rs2 = UInt32(inst.rs2 & 0x1F)
        let rm = UInt32(inst.rm.rawValue & 0x7)
        let imm = inst.imm

        switch desc.format {
        case .r:
            word |= (rs2 << 20) | (rs1 << 15) | (rd << 7)

        case .rUnary:
            word |= (rs1 << 15) | (rd << 7)

        case .rShift64:
            let shamt = UInt32(imm & 0x3F)
            word |= (shamt << 20) | (rs1 << 15) | (rd << 7)

        case .rShift32:
            let shamt = UInt32(imm & 0x1F)
            word |= (shamt << 20) | (rs1 << 15) | (rd << 7)

        case .rAMO:
            let aqBit: UInt32 = inst.aq ? (1 << 26) : 0
            let rlBit: UInt32 = inst.rl ? (1 << 25) : 0
            word |= aqBit | rlBit | (rs2 << 20) | (rs1 << 15) | (rd << 7)

        case .rLR:
            let aqBit: UInt32 = inst.aq ? (1 << 26) : 0
            let rlBit: UInt32 = inst.rl ? (1 << 25) : 0
            word |= aqBit | rlBit | (rs1 << 15) | (rd << 7)

        case .rFP:
            word |= (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7)

        case .rFPFixed, .rFPCmp:
            word |= (rs2 << 20) | (rs1 << 15) | (rd << 7)

        case .rFPUnary, .rFPCvtF2I, .rFPCvtI2F:
            word |= (rs1 << 15) | (rm << 12) | (rd << 7)

        case .rFPMvF2I, .rFPMvI2F:
            word |= (rs1 << 15) | (rd << 7)

        case .rFLI:
            let imm5 = UInt32(imm & 0x1F)
            word |= (imm5 << 15) | (rd << 7)

        case .i, .iLoad, .iFPLoad:
            let imm12 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm)) & 0xFFF
            word |= (imm12 << 20) | (rs1 << 15) | (rd << 7)

        case .s, .sFP:
            let uimm = UInt32(bitPattern: Int32(truncatingIfNeeded: imm)) & 0xFFF
            let hi = (uimm >> 5) & 0x7F
            let lo = uimm & 0x1F
            word |= (hi << 25) | (rs2 << 20) | (rs1 << 15) | (lo << 7)

        case .b:
            let uimm = UInt32(bitPattern: Int32(truncatingIfNeeded: imm))
            let b12 = (uimm >> 12) & 0x1
            let b11 = (uimm >> 11) & 0x1
            let b10_5 = (uimm >> 5) & 0x3F
            let b4_1 = (uimm >> 1) & 0xF
            word |= (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (b4_1 << 8) | (b11 << 7)

        case .u:
            let u20: UInt32
            if (imm & 0xFFF) == 0 && (imm > 0xFFFFF || imm < -0x80000) {
                u20 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm >> 12)) & 0xFFFFF
            } else {
                u20 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm)) & 0xFFFFF
            }
            word |= (u20 << 12) | (rd << 7)

        case .j:
            let uimm = UInt32(bitPattern: Int32(truncatingIfNeeded: imm))
            let b20 = (uimm >> 20) & 0x1
            let b19_12 = (uimm >> 12) & 0xFF
            let b11 = (uimm >> 11) & 0x1
            let b10_1 = (uimm >> 1) & 0x3FF
            word |= (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | (rd << 7)

        case .fence:
            let fenceImm = imm == 0 ? 0xFF : UInt32(imm & 0xFF)
            word |= (fenceImm << 20)

        case .csrReg:
            let csr = UInt32(imm & 0xFFF)
            word |= (csr << 20) | (rs1 << 15) | (rd << 7)

        case .csrImm:
            let csr = UInt32(imm & 0xFFF)
            let zimm = rs1 // uimm5 stored in rs1
            word |= (csr << 20) | (zimm << 15) | (rd << 7)

        case .systemFixed:
            break

        case .sfenceVMA:
            word |= (rs2 << 20) | (rs1 << 15)

        case .vsetvli:
            let zimm11 = UInt32(imm & 0x7FF)
            word |= (zimm11 << 20) | (rs1 << 15) | (rd << 7)

        case .vsetivli:
            let zimm10 = UInt32(imm & 0x3FF)
            let uimm5 = rs1
            word |= (zimm10 << 20) | (uimm5 << 15) | (rd << 7)

        case .vsetvl:
            word |= (rs2 << 20) | (rs1 << 15) | (rd << 7)

        case .vLoadWhole:
            word |= (rs1 << 15) | (rd << 7)

        case .vStoreWhole:
            let vs3 = inst.rd != 0 ? rd : rs2
            word |= (rs1 << 15) | (vs3 << 7)

        case .vLoadUnit:
            let vmBit: UInt32 = inst.vm ? (1 << 25) : 0
            word |= vmBit | (rs1 << 15) | (rd << 7)

        case .vStoreUnit:
            let vmBit: UInt32 = inst.vm ? (1 << 25) : 0
            let vs3 = inst.rd != 0 ? rd : rs2
            word |= vmBit | (rs1 << 15) | (vs3 << 7)

        case .vOpiVV, .vOpiVX:
            let vmBit: UInt32 = inst.vm ? (1 << 25) : 0
            word |= vmBit | (rs2 << 20) | (rs1 << 15) | (rd << 7)

        case .vOpiVI:
            let vmBit: UInt32 = inst.vm ? (1 << 25) : 0
            let simm5 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm)) & 0x1F
            word |= vmBit | (rs2 << 20) | (simm5 << 15) | (rd << 7)

        case .vMvVV, .vMvVX:
            word |= (rs1 << 15) | (rd << 7)

        case .vMvVI:
            let simm5 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm)) & 0x1F
            word |= (simm5 << 15) | (rd << 7)

        default:
            break
        }

        return word
    }

    // MARK: - 3.1 RVC Compression Helper (`tryCompress`)

    /// Attempts to compress an `RV64Instruction` into its 16-bit RVC / Zcb equivalent.
    /// Returns the exact 16-bit encoding when registers and immediates fit, or `nil`.
    public static func tryCompress(_ inst: RV64Instruction) -> UInt16? {
        if inst.isCompressed {
            return encode16(inst)
        }
        guard let compressedInst = compressInstruction(inst) else {
            return nil
        }
        return encode16(compressedInst)
    }

    /// Converts a 32-bit `RV64Instruction` into its compressed `RV64Instruction` form if valid.
    public static func compressInstruction(_ inst: RV64Instruction) -> RV64Instruction? {
        if inst.isCompressed { return inst }

        let rd = RVGPR(rawValue: inst.rd) ?? .zero
        let rs1 = RVGPR(rawValue: inst.rs1) ?? .zero
        let rs2 = RVGPR(rawValue: inst.rs2) ?? .zero
        let imm = inst.imm

        switch inst.opcode {
        case .addi:
            // c.nop: addi x0, x0, 0
            if rd == .zero && rs1 == .zero && imm == 0 {
                return RV64Instruction(opcode: .c_nop)
            }
            // c.mv: addi rd, rs1, 0 (rd != x0, rs1 != x0)
            if imm == 0 && rd != .zero && rs1 != .zero {
                return RV64Instruction(opcode: .c_mv, rd: rd.rawValue, rs2: rs1.rawValue)
            }
            // c.li: addi rd, x0, imm (rd != x0, imm in -32..31)
            if rs1 == .zero && rd != .zero && imm >= -32 && imm <= 31 {
                return RV64Instruction(opcode: .c_li, rd: rd.rawValue, imm: imm)
            }
            // c.addi: addi rd, rd, nzimm (rd != x0, imm in -32..31, imm != 0). Checked before c.addi16sp, so
            // `addi sp, sp, -16` is `c.addi` as in GNU `as` and LLVM MC.
            if rd == rs1 && rd != .zero && imm != 0 && imm >= -32 && imm <= 31 {
                return RV64Instruction(opcode: .c_addi, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            // c.addi16sp: addi sp, sp, nzimm (imm in -512..496, multiple of 16, imm != 0)
            if rd == .sp && rs1 == .sp && imm != 0 && imm >= -512 && imm <= 496 && (imm & 0xF) == 0 {
                return RV64Instruction(opcode: .c_addi16sp, rd: RVGPR.sp.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)
            }
            // c.addi4spn: addi rd', sp, nzuimm (rd in x8..x15, imm in 4..1020, multiple of 4)
            if rs1 == .sp && rd.isCompressedReg && imm >= 4 && imm <= 1020 && (imm & 0x3) == 0 {
                return RV64Instruction(opcode: .c_addi4spn, rd: rd.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)
            }
            return nil

        case .addiw:
            // c.zext.w: add.uw rd', rd', zero (note: addiw rd, rs1, 0 is sext.w, which is c.addiw rd, 0!)
            if rd == rs1 && rd != .zero && imm >= -32 && imm <= 31 {
                return RV64Instruction(opcode: .c_addiw, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            return nil

        case .lui:
            guard rd != .zero && rd != .sp else { return nil }
            // Check 20-bit upper immediate in `imm`: sign-extended 6-bit non-zero
            let u20: Int64
            if (imm & 0xFFF) == 0 && (imm > 0xFFFFF || imm < -0x80000) {
                u20 = (imm >> 12) & 0xFFFFF
            } else {
                u20 = imm & 0xFFFFF
            }
            let signed20 = (u20 & 0x80000) != 0 ? (u20 - 0x100000) : u20
            if signed20 != 0 && signed20 >= -32 && signed20 <= 31 {
                return RV64Instruction(opcode: .c_lui, rd: rd.rawValue, imm: signed20)
            }
            return nil

        case .slli:
            if rd == rs1 && rd != .zero && imm >= 1 && imm <= 63 {
                return RV64Instruction(opcode: .c_slli, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            return nil

        case .srli:
            if rd == rs1 && rd.isCompressedReg && imm >= 1 && imm <= 63 {
                return RV64Instruction(opcode: .c_srli, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            return nil

        case .srai:
            if rd == rs1 && rd.isCompressedReg && imm >= 1 && imm <= 63 {
                return RV64Instruction(opcode: .c_srai, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            return nil

        case .andi:
            if rd == rs1 && rd.isCompressedReg && imm >= -32 && imm <= 31 {
                if imm == 255 {
                    return RV64Instruction(opcode: .c_zext_b, rd: rd.rawValue, rs1: rd.rawValue)
                }
                return RV64Instruction(opcode: .c_andi, rd: rd.rawValue, rs1: rd.rawValue, imm: imm)
            }
            if rd == rs1 && rd.isCompressedReg && imm == 0xFF {
                return RV64Instruction(opcode: .c_zext_b, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .xori:
            if rd == rs1 && rd.isCompressedReg && imm == -1 {
                return RV64Instruction(opcode: .c_not, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .add:
            guard rd != .zero else { return nil }
            if rs1 == .zero && rs2 != .zero {
                return RV64Instruction(opcode: .c_mv, rd: rd.rawValue, rs2: rs2.rawValue)
            }
            if rs2 == .zero && rs1 != .zero {
                return RV64Instruction(opcode: .c_mv, rd: rd.rawValue, rs2: rs1.rawValue)
            }
            if rd == rs1 && rs2 != .zero {
                return RV64Instruction(opcode: .c_add, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
            }
            if rd == rs2 && rs1 != .zero {
                return RV64Instruction(opcode: .c_add, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
            }
            return nil

        case .sub:
            if rd == rs1 && rd.isCompressedReg && rs2.isCompressedReg {
                return RV64Instruction(opcode: .c_sub, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
            }
            return nil

        case .xor:
            if rd.isCompressedReg {
                if rd == rs1 && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_xor, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
                }
                if rd == rs2 && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_xor, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
                }
            }
            return nil

        case .or:
            if rd.isCompressedReg {
                if rd == rs1 && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_or, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
                }
                if rd == rs2 && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_or, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
                }
            }
            return nil

        case .and:
            if rd.isCompressedReg {
                if rd == rs1 && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_and, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
                }
                if rd == rs2 && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_and, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
                }
            }
            return nil

        case .subw:
            if rd == rs1 && rd.isCompressedReg && rs2.isCompressedReg {
                return RV64Instruction(opcode: .c_subw, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
            }
            return nil

        case .addw:
            if rd.isCompressedReg {
                if rd == rs1 && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_addw, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
                }
                if rd == rs2 && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_addw, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
                }
            }
            return nil

        case .mul:
            if rd.isCompressedReg {
                if rd == rs1 && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_mul, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs2.rawValue)
                }
                if rd == rs2 && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_mul, rd: rd.rawValue, rs1: rd.rawValue, rs2: rs1.rawValue)
                }
            }
            return nil

        case .sext_b:
            if rd == rs1 && rd.isCompressedReg {
                return RV64Instruction(opcode: .c_sext_b, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .sext_h:
            if rd == rs1 && rd.isCompressedReg {
                return RV64Instruction(opcode: .c_sext_h, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .zext_h:
            if rd == rs1 && rd.isCompressedReg {
                return RV64Instruction(opcode: .c_zext_h, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .add_uw:
            if rd == rs1 && rs2 == .zero && rd.isCompressedReg {
                return RV64Instruction(opcode: .c_zext_w, rd: rd.rawValue, rs1: rd.rawValue)
            }
            return nil

        case .lw:
            if rs1 == .sp && rd != .zero && imm >= 0 && imm <= 252 && (imm & 0x3) == 0 {
                return RV64Instruction(opcode: .c_lwsp, rd: rd.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)
            }
            if rd.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 124 && (imm & 0x3) == 0 {
                return RV64Instruction(opcode: .c_lw, rd: rd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .ld:
            if rs1 == .sp && rd != .zero && imm >= 0 && imm <= 504 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_ldsp, rd: rd.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)
            }
            if rd.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 248 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_ld, rd: rd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .sw:
            if rs1 == .sp && imm >= 0 && imm <= 252 && (imm & 0x3) == 0 {
                return RV64Instruction(opcode: .c_swsp, rs1: RVGPR.sp.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            if rs2.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 124 && (imm & 0x3) == 0 {
                return RV64Instruction(opcode: .c_sw, rs1: rs1.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            return nil

        case .sd:
            if rs1 == .sp && imm >= 0 && imm <= 504 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_sdsp, rs1: RVGPR.sp.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            if rs2.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 248 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_sd, rs1: rs1.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            return nil

        case .fld:
            let fd = RVFPR(rawValue: inst.rd) ?? .f0
            if rs1 == .sp && imm >= 0 && imm <= 504 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_fldsp, rd: fd.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)
            }
            if fd.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 248 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_fld, rd: fd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .fsd:
            let fs2 = RVFPR(rawValue: inst.rs2) ?? .f0
            if rs1 == .sp && imm >= 0 && imm <= 504 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_fsdsp, rs1: RVGPR.sp.rawValue, rs2: fs2.rawValue, imm: imm)
            }
            if fs2.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 248 && (imm & 0x7) == 0 {
                return RV64Instruction(opcode: .c_fsd, rs1: rs1.rawValue, rs2: fs2.rawValue, imm: imm)
            }
            return nil

        case .lbu:
            if rd.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 3 {
                return RV64Instruction(opcode: .c_lbu, rd: rd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .lhu:
            if rd.isCompressedReg && rs1.isCompressedReg && (imm == 0 || imm == 2) {
                return RV64Instruction(opcode: .c_lhu, rd: rd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .lh:
            if rd.isCompressedReg && rs1.isCompressedReg && (imm == 0 || imm == 2) {
                return RV64Instruction(opcode: .c_lh, rd: rd.rawValue, rs1: rs1.rawValue, imm: imm)
            }
            return nil

        case .sb:
            if rs2.isCompressedReg && rs1.isCompressedReg && imm >= 0 && imm <= 3 {
                return RV64Instruction(opcode: .c_sb, rs1: rs1.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            return nil

        case .sh:
            if rs2.isCompressedReg && rs1.isCompressedReg && (imm == 0 || imm == 2) {
                return RV64Instruction(opcode: .c_sh, rs1: rs1.rawValue, rs2: rs2.rawValue, imm: imm)
            }
            return nil

        case .jal:
            if rd == .zero && imm >= -2048 && imm <= 2046 && (imm & 0x1) == 0 {
                return RV64Instruction(opcode: .c_j, imm: imm)
            }
            return nil

        case .jalr:
            if imm == 0 && rs1 != .zero {
                if rd == .zero {
                    return RV64Instruction(opcode: .c_jr, rs1: rs1.rawValue)
                }
                if rd == .ra {
                    return RV64Instruction(opcode: .c_jalr, rd: RVGPR.ra.rawValue, rs1: rs1.rawValue)
                }
            }
            return nil

        case .beq:
            if imm >= -256 && imm <= 254 && (imm & 0x1) == 0 {
                if rs2 == .zero && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_beqz, rs1: rs1.rawValue, imm: imm)
                }
                if rs1 == .zero && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_beqz, rs1: rs2.rawValue, imm: imm)
                }
            }
            return nil

        case .bne:
            if imm >= -256 && imm <= 254 && (imm & 0x1) == 0 {
                if rs2 == .zero && rs1.isCompressedReg {
                    return RV64Instruction(opcode: .c_bnez, rs1: rs1.rawValue, imm: imm)
                }
                if rs1 == .zero && rs2.isCompressedReg {
                    return RV64Instruction(opcode: .c_bnez, rs1: rs2.rawValue, imm: imm)
                }
            }
            return nil

        case .ebreak:
            return RV64Instruction(opcode: .c_ebreak)

        default:
            return nil
        }
    }

    // MARK: - 3.2 `li` 64-Bit Constant Materialization (`expandLi`)

    /// Materializes any 64-bit constant `imm` into `rd` in up to 8 instructions,
    /// matching GNU `as` / LLVM MC sequences (32-bit sign-extended LUI+ADDIW, trailing-zero shifts,
    /// and recursive high-to-low `slli` + `addi` decomposition), using compressed forms when `rvcEnabled` is true.
    public static func expandLi(rd: RVGPR, imm: Int64, rvcEnabled: Bool = true) -> [RV64Instruction] {
        if rd == .zero {
            let nop = RV64Instruction.gpr(.addi, rd: .zero, rs1: .zero, imm: 0)
            return [rvcEnabled ? (compressInstruction(nop) ?? nop) : nop]
        }

        let rawSeq = synthesizeLi64(rd: rd, val: imm)
        if !rvcEnabled {
            return rawSeq
        }
        return rawSeq.map { compressInstruction($0) ?? $0 }
    }

    private static func synthesizeLi64(rd: RVGPR, val: Int64) -> [RV64Instruction] {
        // 1. Fits in signed 12-bit immediate (-2048..2047)
        if val >= -2048 && val <= 2047 {
            return [.gpr(.addi, rd: rd, rs1: .zero, imm: val)]
        }

        let uval = UInt64(bitPattern: val)
        let tz = uval.trailingZeroBitCount

        // 2. Single-bit power-of-two in upper 33 bits (bit 31..63): single Zbs `bseti rd, zero, shamt`
        if uval.nonzeroBitCount == 1 && tz >= 31 {
            return [.gpr(.bseti, rd: rd, rs1: .zero, imm: Int64(tz))]
        }

        // 3. Fits in signed 32-bit immediate (-0x80000000..0x7FFFFFFF)
        if val >= -0x8000_0000 && val <= 0x7FFF_FFFF {
            let lo12 = (val << 52) >> 52 // sign-extend low 12 bits
            let hi20 = ((val &- lo12) >> 12) & 0xFFFFF
            if hi20 == 0 {
                return [.gpr(.addi, rd: rd, rs1: .zero, imm: lo12)]
            }
            let luiInst = RV64Instruction.gpr(.lui, rd: rd, imm: hi20)
            if lo12 == 0 {
                return [luiInst]
            }
            // If `val >> tz` fits in 6-bit signed `c.li` (-32..31) while `lo12` does not fit in 6-bit signed `c.addi`,
            // `c.li rd, (val >> tz); c.slli rd, tz` is 4 bytes vs 6/8 bytes for `lui + addi` (e.g., `li t0, 0xC00`).
            if tz > 0 {
                let shifted = val >> tz
                if shifted >= -32 && shifted <= 31 && !(lo12 >= -32 && lo12 <= 31) {
                    return [
                        .gpr(.addi, rd: rd, rs1: .zero, imm: shifted),
                        .gpr(.slli, rd: rd, rs1: rd, imm: Int64(tz)),
                    ]
                }
            }
            // Note: on RV64, LUI already sign-extends bit 31 to 64 bits.
            // Only when hi20 == 0x80000 (-0x80000000) and lo12 > 0 (+0x7FFFF800..+0x7FFFFFFF) is ADDIW required to wrap;
            // otherwise LLVM/GNU `as` emits ADDI (which can also compress to `c.addi`).
            let addOp: RV64Opcode = (hi20 == 0x80000 && lo12 > 0) ? .addiw : .addi
            return [
                luiInst,
                .gpr(addOp, rd: rd, rs1: rd, imm: lo12),
            ]
        }

        // 4. Check if shifting out trailing zeros allows a shorter sequence
        if tz > 0 {
            let shiftedSigned = val >> tz
            let signedCandidate = synthesizeLiNoTrailingShift(rd: rd, val: shiftedSigned) + [
                .gpr(.slli, rd: rd, rs1: rd, imm: Int64(tz))
            ]

            let shiftedUnsigned = Int64(bitPattern: uval >> tz)
            if shiftedUnsigned != shiftedSigned && shiftedUnsigned > 0 {
                let unsignedCandidate = synthesizeLiNoTrailingShift(rd: rd, val: shiftedUnsigned) + [
                    .gpr(.slli, rd: rd, rs1: rd, imm: Int64(tz))
                ]
                if unsignedCandidate.count < signedCandidate.count {
                    let directCandidate = synthesizeLiNoTrailingShift(rd: rd, val: val)
                    return unsignedCandidate.count <= directCandidate.count ? unsignedCandidate : directCandidate
                }
            }

            let directCandidate = synthesizeLiNoTrailingShift(rd: rd, val: val)
            if signedCandidate.count <= directCandidate.count {
                return signedCandidate
            }
            return directCandidate
        }

        return synthesizeLiNoTrailingShift(rd: rd, val: val)
    }

    private static func synthesizeLiNoTrailingShift(rd: RVGPR, val: Int64) -> [RV64Instruction] {
        if val >= -2048 && val <= 2047 {
            return [.gpr(.addi, rd: rd, rs1: .zero, imm: val)]
        }
        if val >= -0x8000_0000 && val <= 0x7FFF_FFFF {
            let lo12 = (val << 52) >> 52
            let hi20 = ((val &- lo12) >> 12) & 0xFFFFF
            let luiInst = RV64Instruction.gpr(.lui, rd: rd, imm: hi20)
            if lo12 == 0 {
                return [luiInst]
            }
            let addOp: RV64Opcode = (hi20 == 0x80000 && lo12 > 0) ? .addiw : .addi
            return [
                luiInst,
                .gpr(addOp, rd: rd, rs1: rd, imm: lo12),
            ]
        }

        // Decompose 64-bit value: extract signed 12-bit low chunk, recurse on upper bits
        let lo12 = (val << 52) >> 52
        var hi = (val &- lo12) >> 12
        var shift = 12
        while hi != 0 && (hi & 1) == 0 && !(hi >= -0x8000_0000 && hi <= 0x7FFF_FFFF) {
            hi >>= 1
            shift += 1
        }

        var seq = synthesizeLi64(rd: rd, val: hi)
        seq.append(.gpr(.slli, rd: rd, rs1: rd, imm: Int64(shift)))
        if lo12 != 0 {
            seq.append(.gpr(.addi, rd: rd, rs1: rd, imm: lo12))
        }
        return seq
    }
}

// MARK: - 5. RV64 Disassembler & Round-Trip Verification

public enum RV64Disassembler {
    /// Compressed descriptors sorted by mask specificity (most specific first) so
    /// `c.unimp`, `c.nop`, `c.addi16sp`, `c.ebreak`, `c.jr`, `c.jalr` match before broader masks.
    private static let compressedDecodeTable: [RV64InstrDesc] = {
        RV64InstructionTable.descriptors
            .filter { $0.isCompressed }
            .sorted { a, b in
                let ca = a.mask.nonzeroBitCount
                let cb = b.mask.nonzeroBitCount
                if ca != cb { return ca > cb }
                return a.opcode.rawValue < b.opcode.rawValue
            }
    }()

    /// Standard 32-bit descriptors sorted by mask specificity (most specific first).
    private static let standardDecodeTable: [RV64InstrDesc] = {
        RV64InstructionTable.descriptors
            .filter { !$0.isCompressed }
            .sorted { a, b in
                let ca = a.mask.nonzeroBitCount
                let cb = b.mask.nonzeroBitCount
                if ca != cb { return ca > cb }
                return a.opcode.rawValue < b.opcode.rawValue
            }
    }()

    /// Decodes a single instruction from `bytes` starting at `offset`.
    /// Returns the decoded `RV64Instruction` and its byte length (2 or 4), or `nil` if truncated or unknown.
    public static func decode(from bytes: [UInt8], at offset: Int = 0) -> (instruction: RV64Instruction, size: Int)? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let lo16 = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        if (lo16 & 0x3) != 0x3 {
            guard let inst = decode16(lo16) else { return nil }
            return (inst, 2)
        }
        guard offset + 4 <= bytes.count else { return nil }
        let hi16 = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
        let word = UInt32(lo16) | (UInt32(hi16) << 16)
        guard let inst = decode32(word) else { return nil }
        return (inst, 4)
    }

    /// Disassembles an entire byte buffer into an array of `(offset, size, instruction, text)` tuples.
    public static func disassemble(_ bytes: [UInt8]) -> [(offset: Int, size: Int, instruction: RV64Instruction, text: String)] {
        var result: [(offset: Int, size: Int, instruction: RV64Instruction, text: String)] = []
        var offset = 0
        while offset < bytes.count {
            guard let (inst, size) = decode(from: bytes, at: offset) else {
                break
            }
            result.append((offset: offset, size: size, instruction: inst, text: format(inst)))
            offset += size
        }
        return result
    }

    /// Decodes a 16-bit compressed RVC/Zcb instruction word.
    public static func decode16(_ hw: UInt16) -> RV64Instruction? {
        let hw32 = UInt32(hw)
        for desc in compressedDecodeTable {
            guard (hw32 & desc.mask) == desc.match else { continue }
            // Additional architectural validity guards where required
            switch desc.opcode {
            case .c_addi:
                let rd = (hw >> 7) & 0x1F
                if rd == 0 { continue }
            case .c_addiw:
                let rd = (hw >> 7) & 0x1F
                if rd == 0 { continue }
            case .c_addi16sp:
                let imm = extractCAddi16spImm(hw)
                if imm == 0 { continue }
            case .c_addi4spn:
                let imm = extractCAddi4spnImm(hw)
                if imm == 0 { continue }
            case .c_lui:
                let rd = (hw >> 7) & 0x1F
                let imm = extractCIImm(hw)
                if rd == 0 || rd == 2 || imm == 0 { continue }
            case .c_jr, .c_jalr:
                let rs1 = (hw >> 7) & 0x1F
                if rs1 == 0 { continue }
            case .c_mv, .c_add:
                let rd = (hw >> 7) & 0x1F
                let rs2 = (hw >> 2) & 0x1F
                if rd == 0 || rs2 == 0 { continue }
            case .c_lwsp, .c_ldsp:
                let rd = (hw >> 7) & 0x1F
                if rd == 0 { continue }
            default:
                break
            }
            return decodeCompressedFields(hw, desc: desc)
        }
        return nil
    }

    private static func extractCIImm(_ hw: UInt16) -> Int64 {
        let u6 = Int64(((hw >> 12) & 0x1) << 5) | Int64((hw >> 2) & 0x1F)
        return (u6 << 58) >> 58
    }

    private static func extractCAddi16spImm(_ hw: UInt16) -> Int64 {
        let b9 = Int64((hw >> 12) & 0x1) << 9
        let b4 = Int64((hw >> 6) & 0x1) << 4
        let b6 = Int64((hw >> 5) & 0x1) << 6
        let b8_7 = Int64((hw >> 3) & 0x3) << 7
        let b5 = Int64((hw >> 2) & 0x1) << 5
        let u10 = b9 | b8_7 | b6 | b5 | b4
        return (u10 << 54) >> 54
    }

    private static func extractCAddi4spnImm(_ hw: UInt16) -> Int64 {
        let b5_4 = Int64((hw >> 11) & 0x3) << 4
        let b9_6 = Int64((hw >> 7) & 0xF) << 6
        let b2 = Int64((hw >> 6) & 0x1) << 2
        let b3 = Int64((hw >> 5) & 0x1) << 3
        return b9_6 | b5_4 | b3 | b2
    }

    private static func decodeCompressedFields(_ hw: UInt16, desc: RV64InstrDesc) -> RV64Instruction {
        let rdFull = UInt8((hw >> 7) & 0x1F)
        let rs2Full = UInt8((hw >> 2) & 0x1F)
        let rs1Prime = UInt8(((hw >> 7) & 0x7) + 8)
        let rdPrime = UInt8(((hw >> 2) & 0x7) + 8)

        switch desc.format {
        case .cFixed:
            return RV64Instruction(opcode: desc.opcode)

        case .cAddi:
            let imm = extractCIImm(hw)
            let rs1 = desc.opcode == .c_li ? 0 : rdFull
            return RV64Instruction(opcode: desc.opcode, rd: rdFull, rs1: rs1, imm: imm)

        case .cAddi16sp:
            let imm = extractCAddi16spImm(hw)
            return RV64Instruction(opcode: .c_addi16sp, rd: RVGPR.sp.rawValue, rs1: RVGPR.sp.rawValue, imm: imm)

        case .cAddi4spn:
            let imm = extractCAddi4spnImm(hw)
            return RV64Instruction(opcode: .c_addi4spn, rd: rdPrime, rs1: RVGPR.sp.rawValue, imm: imm)

        case .cLui:
            let imm = extractCIImm(hw)
            return RV64Instruction(opcode: .c_lui, rd: rdFull, imm: imm)

        case .cShift:
            let shamt = Int64(((hw >> 12) & 0x1) << 5) | Int64((hw >> 2) & 0x1F)
            return RV64Instruction(opcode: desc.opcode, rd: rs1Prime, rs1: rs1Prime, imm: shamt)

        case .cAndi:
            let imm = extractCIImm(hw)
            return RV64Instruction(opcode: .c_andi, rd: rs1Prime, rs1: rs1Prime, imm: imm)

        case .cAlu:
            return RV64Instruction(opcode: desc.opcode, rd: rs1Prime, rs1: rs1Prime, rs2: rdPrime)

        case .cZcbUnary:
            return RV64Instruction(opcode: desc.opcode, rd: rs1Prime, rs1: rs1Prime)

        case .cSlli:
            let shamt = Int64(((hw >> 12) & 0x1) << 5) | Int64((hw >> 2) & 0x1F)
            return RV64Instruction(opcode: .c_slli, rd: rdFull, rs1: rdFull, imm: shamt)

        case .cCR:
            let rs1 = desc.opcode == .c_add ? rdFull : 0
            return RV64Instruction(opcode: desc.opcode, rd: rdFull, rs1: rs1, rs2: rs2Full)

        case .cJr:
            let rd: UInt8 = desc.opcode == .c_jalr ? RVGPR.ra.rawValue : 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rdFull)

        case .cLw:
            let uimm = (Int64((hw >> 10) & 0x7) << 3) | (Int64((hw >> 6) & 0x1) << 2) | (Int64((hw >> 5) & 0x1) << 6)
            return RV64Instruction(opcode: .c_lw, rd: rdPrime, rs1: rs1Prime, imm: uimm)

        case .cSw:
            let uimm = (Int64((hw >> 10) & 0x7) << 3) | (Int64((hw >> 6) & 0x1) << 2) | (Int64((hw >> 5) & 0x1) << 6)
            return RV64Instruction(opcode: .c_sw, rs1: rs1Prime, rs2: rdPrime, imm: uimm)

        case .cLd, .cFld:
            let uimm = (Int64((hw >> 10) & 0x7) << 3) | (Int64((hw >> 5) & 0x3) << 6)
            return RV64Instruction(opcode: desc.opcode, rd: rdPrime, rs1: rs1Prime, imm: uimm)

        case .cSd, .cFsd:
            let uimm = (Int64((hw >> 10) & 0x7) << 3) | (Int64((hw >> 5) & 0x3) << 6)
            return RV64Instruction(opcode: desc.opcode, rs1: rs1Prime, rs2: rdPrime, imm: uimm)

        case .cLwsp:
            let uimm = (Int64((hw >> 12) & 0x1) << 5) | (Int64((hw >> 4) & 0x7) << 2) | (Int64((hw >> 2) & 0x3) << 6)
            return RV64Instruction(opcode: .c_lwsp, rd: rdFull, rs1: RVGPR.sp.rawValue, imm: uimm)

        case .cLdsp, .cFldsp:
            let uimm = (Int64((hw >> 12) & 0x1) << 5) | (Int64((hw >> 5) & 0x3) << 3) | (Int64((hw >> 2) & 0x7) << 6)
            return RV64Instruction(opcode: desc.opcode, rd: rdFull, rs1: RVGPR.sp.rawValue, imm: uimm)

        case .cSwsp:
            let uimm = (Int64((hw >> 9) & 0xF) << 2) | (Int64((hw >> 7) & 0x3) << 6)
            return RV64Instruction(opcode: .c_swsp, rs1: RVGPR.sp.rawValue, rs2: rs2Full, imm: uimm)

        case .cSdsp, .cFsdsp:
            let uimm = (Int64((hw >> 10) & 0x7) << 3) | (Int64((hw >> 7) & 0x7) << 6)
            return RV64Instruction(opcode: desc.opcode, rs1: RVGPR.sp.rawValue, rs2: rs2Full, imm: uimm)

        case .cJ:
            let b11 = Int64((hw >> 12) & 0x1) << 11
            let b4 = Int64((hw >> 11) & 0x1) << 4
            let b9_8 = Int64((hw >> 9) & 0x3) << 8
            let b10 = Int64((hw >> 8) & 0x1) << 10
            let b6 = Int64((hw >> 7) & 0x1) << 6
            let b7 = Int64((hw >> 6) & 0x1) << 7
            let b3_1 = Int64((hw >> 3) & 0x7) << 1
            let b5 = Int64((hw >> 2) & 0x1) << 5
            let u12 = b11 | b10 | b9_8 | b7 | b6 | b5 | b4 | b3_1
            let imm = (u12 << 52) >> 52
            return RV64Instruction(opcode: .c_j, imm: imm)

        case .cBranch:
            let b8 = Int64((hw >> 12) & 0x1) << 8
            let b4_3 = Int64((hw >> 10) & 0x3) << 3
            let b7_6 = Int64((hw >> 5) & 0x3) << 6
            let b2_1 = Int64((hw >> 3) & 0x3) << 1
            let b5 = Int64((hw >> 2) & 0x1) << 5
            let u9 = b8 | b7_6 | b5 | b4_3 | b2_1
            let imm = (u9 << 55) >> 55
            return RV64Instruction(opcode: desc.opcode, rs1: rs1Prime, imm: imm)

        case .cZcbByte:
            let uimm = Int64((hw >> 6) & 0x1) | (Int64((hw >> 5) & 0x1) << 1)
            if desc.opcode == .c_sb {
                return RV64Instruction(opcode: .c_sb, rs1: rs1Prime, rs2: rdPrime, imm: uimm)
            }
            return RV64Instruction(opcode: .c_lbu, rd: rdPrime, rs1: rs1Prime, imm: uimm)

        case .cZcbHalf:
            let uimm = Int64((hw >> 5) & 0x1) << 1
            if desc.opcode == .c_sh {
                return RV64Instruction(opcode: .c_sh, rs1: rs1Prime, rs2: rdPrime, imm: uimm)
            }
            return RV64Instruction(opcode: desc.opcode, rd: rdPrime, rs1: rs1Prime, imm: uimm)

        default:
            return RV64Instruction(opcode: desc.opcode)
        }
    }

    /// Decodes a 32-bit standard instruction word.
    public static func decode32(_ word: UInt32) -> RV64Instruction? {
        for desc in standardDecodeTable {
            guard (word & desc.mask) == desc.match else { continue }
            return decodeStandardFields(word, desc: desc)
        }
        return nil
    }

    private static func decodeStandardFields(_ word: UInt32, desc: RV64InstrDesc) -> RV64Instruction {
        let rd = UInt8((word >> 7) & 0x1F)
        let rs1 = UInt8((word >> 15) & 0x1F)
        let rs2 = UInt8((word >> 20) & 0x1F)
        let rmRaw = UInt8((word >> 12) & 0x7)
        let rm = RVRoundingMode(rawValue: rmRaw) ?? .dyn

        switch desc.format {
        case .r:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rs2)

        case .rUnary:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1)

        case .rShift64:
            let shamt = Int64((word >> 20) & 0x3F)
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, imm: shamt)

        case .rShift32:
            let shamt = Int64((word >> 20) & 0x1F)
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, imm: shamt)

        case .rAMO:
            let aq = ((word >> 26) & 0x1) != 0
            let rl = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rs2, aq: aq, rl: rl)

        case .rLR:
            let aq = ((word >> 26) & 0x1) != 0
            let rl = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, aq: aq, rl: rl)

        case .rFP:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rs2, rm: rm)

        case .rFPFixed, .rFPCmp:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rs2)

        case .rFPUnary, .rFPCvtF2I, .rFPCvtI2F:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rm: rm)

        case .rFPMvF2I, .rFPMvI2F:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1)

        case .rFLI:
            return RV64Instruction(opcode: desc.opcode, rd: rd, imm: Int64(rs1))

        case .i, .iLoad, .iFPLoad:
            let imm12 = (Int64(word >> 20) << 52) >> 52
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, imm: imm12)

        case .s, .sFP:
            let u12 = (Int64((word >> 25) & 0x7F) << 5) | Int64((word >> 7) & 0x1F)
            let imm12 = (u12 << 52) >> 52
            return RV64Instruction(opcode: desc.opcode, rs1: rs1, rs2: rs2, imm: imm12)

        case .b:
            let b12 = Int64((word >> 31) & 0x1) << 12
            let b11 = Int64((word >> 7) & 0x1) << 11
            let b10_5 = Int64((word >> 25) & 0x3F) << 5
            let b4_1 = Int64((word >> 8) & 0xF) << 1
            let u13 = b12 | b11 | b10_5 | b4_1
            let imm13 = (u13 << 51) >> 51
            return RV64Instruction(opcode: desc.opcode, rs1: rs1, rs2: rs2, imm: imm13)

        case .u:
            let u20 = Int64((word >> 12) & 0xFFFFF)
            return RV64Instruction(opcode: desc.opcode, rd: rd, imm: u20)

        case .j:
            let b20 = Int64((word >> 31) & 0x1) << 20
            let b19_12 = Int64((word >> 12) & 0xFF) << 12
            let b11 = Int64((word >> 20) & 0x1) << 11
            let b10_1 = Int64((word >> 21) & 0x3FF) << 1
            let u21 = b20 | b19_12 | b11 | b10_1
            let imm21 = (u21 << 43) >> 43
            return RV64Instruction(opcode: desc.opcode, rd: rd, imm: imm21)

        case .fence:
            let fenceImm = Int64((word >> 20) & 0xFF)
            return RV64Instruction(opcode: .fence, imm: fenceImm)

        case .csrReg:
            let csr = Int64((word >> 20) & 0xFFF)
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, imm: csr)

        case .csrImm:
            let csr = Int64((word >> 20) & 0xFFF)
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, imm: csr)

        case .systemFixed:
            return RV64Instruction(opcode: desc.opcode)

        case .sfenceVMA:
            return RV64Instruction(opcode: .sfence_vma, rs1: rs1, rs2: rs2)

        case .vsetvli:
            let zimm11 = Int64((word >> 20) & 0x7FF)
            return RV64Instruction(opcode: .vsetvli, rd: rd, rs1: rs1, imm: zimm11)

        case .vsetivli:
            let zimm10 = Int64((word >> 20) & 0x3FF)
            return RV64Instruction(opcode: .vsetivli, rd: rd, rs1: rs1, imm: zimm10)

        case .vsetvl:
            return RV64Instruction(opcode: .vsetvl, rd: rd, rs1: rs1, rs2: rs2)

        case .vLoadWhole:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1)

        case .vStoreWhole:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rd)

        case .vLoadUnit:
            let vm = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, vm: vm)

        case .vStoreUnit:
            let vm = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rd, vm: vm)

        case .vOpiVV, .vOpiVX:
            let vm = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, rs2: rs2, vm: vm)

        case .vOpiVI:
            let vm = ((word >> 25) & 0x1) != 0
            let simm5 = (Int64(rs1) << 59) >> 59
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs2: rs2, imm: simm5, vm: vm)

        case .vMvVV, .vMvVX:
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: rs1, vm: true)

        case .vMvVI:
            let simm5 = (Int64(rs1) << 59) >> 59
            return RV64Instruction(opcode: .vmv_v_i, rd: rd, imm: simm5, vm: true)

        default:
            return RV64Instruction(opcode: desc.opcode)
        }
    }

    /// Formats an `RV64Instruction` into canonical GNU/LLVM RISC-V assembly syntax.
    public static func format(_ inst: RV64Instruction) -> String {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        let gprRd = RVGPR(rawValue: inst.rd & 0x1F)!.abiName
        let gprRs1 = RVGPR(rawValue: inst.rs1 & 0x1F)!.abiName
        let gprRs2 = RVGPR(rawValue: inst.rs2 & 0x1F)!.abiName
        let fprRd = RVFPR(rawValue: inst.rd & 0x1F)!.abiName
        let fprRs1 = RVFPR(rawValue: inst.rs1 & 0x1F)!.abiName
        let fprRs2 = RVFPR(rawValue: inst.rs2 & 0x1F)!.abiName
        let vRd = RVVReg(rawValue: inst.rd & 0x1F)!.name
        let vRs1 = RVVReg(rawValue: inst.rs1 & 0x1F)!.name
        let vRs2 = RVVReg(rawValue: inst.rs2 & 0x1F)!.name

        switch desc.format {
        case .r:
            return "\(desc.mnemonic) \(gprRd), \(gprRs1), \(gprRs2)"

        case .rUnary:
            return "\(desc.mnemonic) \(gprRd), \(gprRs1)"

        case .rShift64, .rShift32:
            return "\(desc.mnemonic) \(gprRd), \(gprRs1), \(inst.imm)"

        case .rAMO:
            var suffix = ""
            if inst.aq && inst.rl { suffix = ".aqrl" }
            else if inst.aq { suffix = ".aq" }
            else if inst.rl { suffix = ".rl" }
            return "\(desc.mnemonic)\(suffix) \(gprRd), \(gprRs2), (\(gprRs1))"

        case .rLR:
            var suffix = ""
            if inst.aq && inst.rl { suffix = ".aqrl" }
            else if inst.aq { suffix = ".aq" }
            else if inst.rl { suffix = ".rl" }
            return "\(desc.mnemonic)\(suffix) \(gprRd), (\(gprRs1))"

        case .rFP:
            if inst.rm == .dyn {
                return "\(desc.mnemonic) \(fprRd), \(fprRs1), \(fprRs2)"
            }
            return "\(desc.mnemonic) \(fprRd), \(fprRs1), \(fprRs2), \(inst.rm)"

        case .rFPFixed:
            return "\(desc.mnemonic) \(fprRd), \(fprRs1), \(fprRs2)"

        case .rFPUnary:
            if inst.rm == .dyn {
                return "\(desc.mnemonic) \(fprRd), \(fprRs1)"
            }
            return "\(desc.mnemonic) \(fprRd), \(fprRs1), \(inst.rm)"

        case .rFPCmp:
            return "\(desc.mnemonic) \(gprRd), \(fprRs1), \(fprRs2)"

        case .rFPCvtF2I:
            if inst.rm == .dyn {
                return "\(desc.mnemonic) \(gprRd), \(fprRs1)"
            }
            return "\(desc.mnemonic) \(gprRd), \(fprRs1), \(inst.rm)"

        case .rFPCvtI2F:
            if inst.rm == .dyn {
                return "\(desc.mnemonic) \(fprRd), \(gprRs1)"
            }
            return "\(desc.mnemonic) \(fprRd), \(gprRs1), \(inst.rm)"

        case .rFPMvF2I:
            return "\(desc.mnemonic) \(gprRd), \(fprRs1)"

        case .rFPMvI2F:
            return "\(desc.mnemonic) \(fprRd), \(gprRs1)"

        case .rFLI:
            let idx = Int(inst.imm & 0x1F)
            let lit = RVZfaFLITable.names[idx]
            return "\(desc.mnemonic) \(fprRd), \(lit)"

        case .i:
            return "\(desc.mnemonic) \(gprRd), \(gprRs1), \(inst.imm)"

        case .iLoad:
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)(\(gprRs1))"

        case .iFPLoad:
            return "\(desc.mnemonic) \(fprRd), \(inst.imm)(\(gprRs1))"

        case .s:
            return "\(desc.mnemonic) \(gprRs2), \(inst.imm)(\(gprRs1))"

        case .sFP:
            return "\(desc.mnemonic) \(fprRs2), \(inst.imm)(\(gprRs1))"

        case .b:
            return "\(desc.mnemonic) \(gprRs1), \(gprRs2), \(inst.imm)"

        case .u, .j:
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)"

        case .fence:
            let imm8 = UInt8(inst.imm == 0 ? 0xFF : (inst.imm & 0xFF))
            let pred = RVFenceMask(rawValue: (imm8 >> 4) & 0xF)
            let succ = RVFenceMask(rawValue: imm8 & 0xF)
            return "fence \(pred), \(succ)"

        case .csrReg:
            let csr = RVCSR(unchecked: UInt16(inst.imm & 0xFFF))
            return "\(desc.mnemonic) \(gprRd), \(csr), \(gprRs1)"

        case .csrImm:
            let csr = RVCSR(unchecked: UInt16(inst.imm & 0xFFF))
            return "\(desc.mnemonic) \(gprRd), \(csr), \(inst.rs1)"

        case .systemFixed, .cFixed:
            return desc.mnemonic

        case .sfenceVMA:
            return "sfence.vma \(gprRs1), \(gprRs2)"

        case .vsetvli:
            let vt = RVVType(rawValue: UInt16(inst.imm & 0x7FF))
            return "vsetvli \(gprRd), \(gprRs1), \(vt)"

        case .vsetivli:
            let vt = RVVType(rawValue: UInt16(inst.imm & 0x3FF))
            return "vsetivli \(gprRd), \(inst.rs1), \(vt)"

        case .vsetvl:
            return "vsetvl \(gprRd), \(gprRs1), \(gprRs2)"

        case .vLoadWhole:
            return "\(desc.mnemonic) \(vRd), (\(gprRs1))"

        case .vStoreWhole:
            let vs3 = inst.rd != 0 ? vRd : vRs2
            return "\(desc.mnemonic) \(vs3), (\(gprRs1))"

        case .vLoadUnit:
            let maskSuffix = inst.vm ? "" : ", v0.t"
            return "\(desc.mnemonic) \(vRd), (\(gprRs1))\(maskSuffix)"

        case .vStoreUnit:
            let vs3 = inst.rd != 0 ? vRd : vRs2
            let maskSuffix = inst.vm ? "" : ", v0.t"
            return "\(desc.mnemonic) \(vs3), (\(gprRs1))\(maskSuffix)"

        case .vOpiVV:
            let maskSuffix = inst.vm ? "" : ", v0.t"
            return "\(desc.mnemonic) \(vRd), \(vRs2), \(vRs1)\(maskSuffix)"

        case .vOpiVX:
            let maskSuffix = inst.vm ? "" : ", v0.t"
            return "\(desc.mnemonic) \(vRd), \(vRs2), \(gprRs1)\(maskSuffix)"

        case .vOpiVI:
            let maskSuffix = inst.vm ? "" : ", v0.t"
            return "\(desc.mnemonic) \(vRd), \(vRs2), \(inst.imm)\(maskSuffix)"

        case .vMvVV:
            return "\(desc.mnemonic) \(vRd), \(vRs1)"

        case .vMvVX:
            return "\(desc.mnemonic) \(vRd), \(gprRs1)"

        case .vMvVI:
            return "\(desc.mnemonic) \(vRd), \(inst.imm)"

        case .cAddi, .cLui, .cShift, .cAndi, .cSlli:
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)"

        case .cAddi16sp:
            return "c.addi16sp sp, \(inst.imm)"

        case .cAddi4spn:
            return "c.addi4spn \(gprRd), sp, \(inst.imm)"

        case .cAlu, .cCR:
            return "\(desc.mnemonic) \(gprRd), \(gprRs2)"

        case .cZcbUnary:
            return "\(desc.mnemonic) \(gprRd)"

        case .cJr:
            let reg = inst.rs1 != 0 ? gprRs1 : gprRd
            return "\(desc.mnemonic) \(reg)"

        case .cLw, .cLd:
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)(\(gprRs1))"

        case .cFld:
            return "c.fld \(fprRd), \(inst.imm)(\(gprRs1))"

        case .cSw, .cSd:
            return "\(desc.mnemonic) \(gprRs2), \(inst.imm)(\(gprRs1))"

        case .cFsd:
            return "c.fsd \(fprRs2), \(inst.imm)(\(gprRs1))"

        case .cLwsp, .cLdsp:
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)(sp)"

        case .cFldsp:
            return "c.fldsp \(fprRd), \(inst.imm)(sp)"

        case .cSwsp, .cSdsp:
            let src = inst.rs2 != 0 ? gprRs2 : gprRd
            return "\(desc.mnemonic) \(src), \(inst.imm)(sp)"

        case .cFsdsp:
            let src = inst.rs2 != 0 ? fprRs2 : fprRd
            return "c.fsdsp \(src), \(inst.imm)(sp)"

        case .cJ:
            return "c.j \(inst.imm)"

        case .cBranch:
            let reg = inst.rs1 != 0 ? gprRs1 : gprRd
            return "\(desc.mnemonic) \(reg), \(inst.imm)"

        case .cZcbByte, .cZcbHalf:
            if desc.opcode == .c_sb || desc.opcode == .c_sh {
                return "\(desc.mnemonic) \(gprRs2), \(inst.imm)(\(gprRs1))"
            }
            return "\(desc.mnemonic) \(gprRd), \(inst.imm)(\(gprRs1))"
        }
    }
}

extension RV64InstructionTable {
    /// Generates a valid representative instruction for a table entry, used by `verifyRoundTrip()`.
    public static func sampleInstruction(for desc: RV64InstrDesc) -> RV64Instruction {
        let a0 = RVGPR.a0.rawValue
        let a1 = RVGPR.a1.rawValue
        let a2 = RVGPR.a2.rawValue
        let sp = RVGPR.sp.rawValue
        let fa0 = RVFPR.fa0.rawValue
        let fa1 = RVFPR.fa1.rawValue
        let fa2 = RVFPR.fa2.rawValue
        let v1 = RVVReg.v1.rawValue
        let v2 = RVVReg.v2.rawValue
        let v3 = RVVReg.v3.rawValue

        switch desc.format {
        case .r:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, rs2: a2)
        case .rUnary:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1)
        case .rShift64:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: 37)
        case .rShift32:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: 15)
        case .rAMO:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, rs2: a2, aq: true, rl: true)
        case .rLR:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, aq: true, rl: false)
        case .rFP:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: fa1, rs2: fa2, rm: .rne)
        case .rFPFixed:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: fa1, rs2: fa2)
        case .rFPUnary:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: fa1, rm: .rne)
        case .rFPCmp:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: fa1, rs2: fa2)
        case .rFPCvtF2I:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: fa1, rm: .rtz)
        case .rFPCvtI2F:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: a1, rm: .rne)
        case .rFPMvF2I:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: fa1)
        case .rFPMvI2F:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: a1)
        case .rFLI:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, imm: 16) // 1.0
        case .i:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: -24)
        case .iLoad:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: 16)
        case .iFPLoad:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: a1, imm: 16)
        case .s:
            return RV64Instruction(opcode: desc.opcode, rs1: a1, rs2: a0, imm: 24)
        case .sFP:
            return RV64Instruction(opcode: desc.opcode, rs1: a1, rs2: fa0, imm: 24)
        case .b:
            return RV64Instruction(opcode: desc.opcode, rs1: a0, rs2: a1, imm: 32)
        case .u:
            return RV64Instruction(opcode: desc.opcode, rd: a0, imm: 0x12345)
        case .j:
            return RV64Instruction(opcode: desc.opcode, rd: RVGPR.ra.rawValue, imm: 128)
        case .fence:
            return RV64Instruction(opcode: .fence, imm: 0xFF) // iorw, iorw
        case .csrReg:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: Int64(RVCSR.sstatus.rawValue))
        case .csrImm:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: 2, imm: Int64(RVCSR.sstatus.rawValue))
        case .systemFixed, .cFixed:
            return RV64Instruction(opcode: desc.opcode)
        case .sfenceVMA:
            return RV64Instruction(opcode: .sfence_vma, rs1: a0, rs2: a1)
        case .vsetvli:
            let vt = RVVType(sewBits: 64, lmulBits: 0, tailAgnostic: true, maskAgnostic: true)!
            return RV64Instruction(opcode: .vsetvli, rd: a0, rs1: a1, imm: Int64(vt.rawValue))
        case .vsetivli:
            let vt = RVVType(sewBits: 32, lmulBits: 0, tailAgnostic: true, maskAgnostic: true)!
            return RV64Instruction(opcode: .vsetivli, rd: a0, rs1: 8, imm: Int64(vt.rawValue))
        case .vsetvl:
            return RV64Instruction(opcode: .vsetvl, rd: a0, rs1: a1, rs2: a2)
        case .vLoadWhole:
            return RV64Instruction(opcode: desc.opcode, rd: RVVReg.v8.rawValue, rs1: a0)
        case .vStoreWhole:
            return RV64Instruction(opcode: desc.opcode, rd: RVVReg.v8.rawValue, rs1: a0, rs2: RVVReg.v8.rawValue)
        case .vLoadUnit:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: a0, vm: true)
        case .vStoreUnit:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: a0, rs2: v1, vm: true)
        case .vOpiVV:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: v2, rs2: v3, vm: true)
        case .vOpiVX:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: a0, rs2: v2, vm: true)
        case .vOpiVI:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs2: v2, imm: -5, vm: true)
        case .vMvVV:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: v2, vm: true)
        case .vMvVX:
            return RV64Instruction(opcode: desc.opcode, rd: v1, rs1: a0, vm: true)
        case .vMvVI:
            return RV64Instruction(opcode: .vmv_v_i, rd: v1, imm: 7, vm: true)
        case .cAddi:
            let rs1 = desc.opcode == .c_li ? 0 : a0
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: rs1, imm: -7)
        case .cAddi16sp:
            return RV64Instruction(opcode: .c_addi16sp, rd: sp, rs1: sp, imm: -112)
        case .cAddi4spn:
            return RV64Instruction(opcode: .c_addi4spn, rd: a0, rs1: sp, imm: 32)
        case .cLui:
            return RV64Instruction(opcode: .c_lui, rd: a0, imm: 15)
        case .cShift:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a0, imm: 12)
        case .cAndi:
            return RV64Instruction(opcode: .c_andi, rd: a0, rs1: a0, imm: 15)
        case .cAlu:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a0, rs2: a1)
        case .cZcbUnary:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a0)
        case .cSlli:
            return RV64Instruction(opcode: .c_slli, rd: a0, rs1: a0, imm: 12)
        case .cCR:
            let rs1 = desc.opcode == .c_add ? a0 : 0
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: rs1, rs2: a1)
        case .cJr:
            let rd: UInt8 = desc.opcode == .c_jalr ? RVGPR.ra.rawValue : 0
            return RV64Instruction(opcode: desc.opcode, rd: rd, rs1: a0)
        case .cLw:
            return RV64Instruction(opcode: .c_lw, rd: a0, rs1: a1, imm: 20)
        case .cSw:
            return RV64Instruction(opcode: .c_sw, rs1: a1, rs2: a0, imm: 20)
        case .cLd:
            return RV64Instruction(opcode: .c_ld, rd: a0, rs1: a1, imm: 24)
        case .cSd:
            return RV64Instruction(opcode: .c_sd, rs1: a1, rs2: a0, imm: 24)
        case .cFld:
            return RV64Instruction(opcode: .c_fld, rd: fa0, rs1: a1, imm: 24)
        case .cFsd:
            return RV64Instruction(opcode: .c_fsd, rs1: a1, rs2: fa0, imm: 24)
        case .cLwsp:
            return RV64Instruction(opcode: .c_lwsp, rd: a0, rs1: sp, imm: 36)
        case .cLdsp:
            return RV64Instruction(opcode: .c_ldsp, rd: a0, rs1: sp, imm: 48)
        case .cFldsp:
            return RV64Instruction(opcode: .c_fldsp, rd: fa0, rs1: sp, imm: 48)
        case .cSwsp:
            return RV64Instruction(opcode: .c_swsp, rs1: sp, rs2: a0, imm: 36)
        case .cSdsp:
            return RV64Instruction(opcode: .c_sdsp, rs1: sp, rs2: a0, imm: 48)
        case .cFsdsp:
            return RV64Instruction(opcode: .c_fsdsp, rs1: sp, rs2: fa0, imm: 48)
        case .cJ:
            return RV64Instruction(opcode: .c_j, imm: -24)
        case .cBranch:
            return RV64Instruction(opcode: desc.opcode, rs1: a0, imm: 18)
        case .cZcbByte:
            if desc.opcode == .c_sb {
                return RV64Instruction(opcode: .c_sb, rs1: a1, rs2: a0, imm: 3)
            }
            return RV64Instruction(opcode: .c_lbu, rd: a0, rs1: a1, imm: 3)
        case .cZcbHalf:
            if desc.opcode == .c_sh {
                return RV64Instruction(opcode: .c_sh, rs1: a1, rs2: a0, imm: 2)
            }
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1, imm: 2)
        }
    }

    /// Exhaustively encodes a representative instruction for every table entry (32-bit and 16-bit),
    /// disassembles it, re-encodes the decoded instruction, and verifies byte-for-byte identity.
    public static func verifyRoundTrip() -> [(mnemonic: String, bytes: [UInt8], disassembled: String)] {
        var results: [(mnemonic: String, bytes: [UInt8], disassembled: String)] = []
        results.reserveCapacity(descriptors.count)

        for (index, desc) in descriptors.enumerated() {
            precondition(
                Int(desc.opcode.rawValue) == index,
                "RV64InstructionTable index \(index) does not match opcode \(desc.opcode) rawValue \(desc.opcode.rawValue)"
            )
            let sample = sampleInstruction(for: desc)
            let encoded = RV64Encoder.encode(sample, rvcEnabled: false)
            let expectedSize = desc.isCompressed ? 2 : 4
            precondition(
                encoded.count == expectedSize,
                "Expected \(expectedSize) bytes for \(desc.mnemonic), got \(encoded.count)"
            )
            guard let (decoded, decodedSize) = RV64Disassembler.decode(from: encoded, at: 0) else {
                preconditionFailure("Failed to decode \(desc.mnemonic) from bytes \(encoded)")
            }
            precondition(
                decodedSize == expectedSize,
                "Decoded size mismatch for \(desc.mnemonic): expected \(expectedSize), got \(decodedSize)"
            )
            precondition(
                decoded.opcode == desc.opcode,
                "Opcode mismatch for \(desc.mnemonic): expected \(desc.opcode), got \(decoded.opcode)"
            )
            let reencoded = RV64Encoder.encode(decoded, rvcEnabled: false)
            precondition(
                reencoded == encoded,
                "Byte mismatch on round-trip for \(desc.mnemonic): \(encoded) != \(reencoded)"
            )
            let text = RV64Disassembler.format(decoded)
            results.append((mnemonic: desc.mnemonic, bytes: encoded, disassembled: text))
        }
        return results
    }
}
